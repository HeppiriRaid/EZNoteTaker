import Foundation
import SwiftData
import UIKit

/// Fetches a reference photo for buildings the student didn't photograph: from the building's
/// Wikipedia article (via Wikipedia's free REST API), or from the freely licensed image link Claude
/// found. Saved locally, so it also works offline. The student's own photos always take priority.
@MainActor
enum ReferenceImages {
    private static var inFlight = Set<UUID>()

    /// Fetches missing reference photos for every building of these lectures. Safe to call often.
    static func fetchMissing(in lectures: [Lecture], context: ModelContext) {
        let buildings = lectures.flatMap(\.buildings).filter { building in
            !building.isDeleted && building.photos.isEmpty && building.referenceImageFile.isEmpty
                && (!building.wikipediaTitle.isEmpty || !building.referenceImageURL.isEmpty)
                && !inFlight.contains(building.id)
        }
        guard !buildings.isEmpty else { return }
        for building in buildings { inFlight.insert(building.id) }

        Task {
            for building in buildings {
                defer { inFlight.remove(building.id) }
                guard case let (data, credit)? = await download(title: building.wikipediaTitle, url: building.referenceImageURL),
                      let fileName = try? FileStore.savePhotoData(data),
                      !building.isDeleted else { continue }
                building.referenceImageFile = fileName
                building.referenceImageCredit = credit
            }
            try? context.save()
        }
    }

    private static func download(title: String, url: String) async -> (Data, String)? {
        if !title.isEmpty, let result = await fromWikipedia(title: title) { return result }
        if let link = URL(string: url), link.scheme == "https", let data = await get(link), UIImage(data: data) != nil {
            return (data, "Reference photo · \(link.host() ?? "web")")
        }
        return nil
    }

    /// Wikipedia's page summary includes the article's lead image.
    private static func fromWikipedia(title: String) async -> (Data, String)? {
        let slug = title.replacingOccurrences(of: " ", with: "_")
        guard let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))),
              let summaryURL = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)"),
              let json = await get(summaryURL),
              let summary = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }

        let thumbnail = (summary["thumbnail"] as? [String: Any])?["source"] as? String
        let original = (summary["originalimage"] as? [String: Any])?["source"] as? String
        // Ask for a 1024 px rendition of the thumbnail instead of the (often huge) original.
        let sized = thumbnail?.replacingOccurrences(of: #"/\d+px-"#, with: "/1024px-", options: .regularExpression)
        for candidate in [sized, thumbnail, original].compactMap({ $0 }) {
            if let imageURL = URL(string: candidate), let data = await get(imageURL), UIImage(data: data) != nil {
                return (data, "Reference photo · Wikipedia: \(title)")
            }
        }
        return nil
    }

    private static func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        // Wikimedia asks apps to identify themselves.
        request.setValue("EZNoteTaker/1.0 (iOS study app for an architecture history class)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}
