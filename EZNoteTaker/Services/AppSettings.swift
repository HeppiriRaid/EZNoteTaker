import Foundation
import SwiftUI

/// User preferences, stored in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    var courseName: String { didSet { defaults.set(courseName, forKey: "courseName") } }
    var city: String { didSet { defaults.set(city, forKey: "city") } }
    var professorName: String { didSet { defaults.set(professorName, forKey: "professorName") } }
    /// Names the professor uses a lot (architects, buildings). Helps both speech recognition and Claude.
    var customVocabulary: String { didSet { defaults.set(customVocabulary, forKey: "customVocabulary") } }
    var localeIdentifier: String { didSet { defaults.set(localeIdentifier, forKey: "localeIdentifier") } }
    /// On-device Apple Intelligence guesses which building is being discussed while recording.
    var liveDetection: Bool { didSet { defaults.set(liveDetection, forKey: "liveDetection") } }
    /// Attach the class photos when sending a lecture to Claude.
    var sharePhotos: Bool { didSet { defaults.set(sharePhotos, forKey: "sharePhotos") } }
    var keepScreenOn: Bool { didSet { defaults.set(keepScreenOn, forKey: "keepScreenOn") } }

    private init() {
        courseName = defaults.string(forKey: "courseName") ?? "Architecture History"
        city = defaults.string(forKey: "city") ?? ""
        professorName = defaults.string(forKey: "professorName") ?? ""
        customVocabulary = defaults.string(forKey: "customVocabulary") ?? ""
        localeIdentifier = defaults.string(forKey: "localeIdentifier") ?? "en-US"
        liveDetection = defaults.object(forKey: "liveDetection") as? Bool ?? true
        sharePhotos = defaults.object(forKey: "sharePhotos") as? Bool ?? true
        keepScreenOn = defaults.object(forKey: "keepScreenOn") as? Bool ?? false
    }

    var vocabularyList: [String] {
        customVocabulary
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// One paragraph of course context included in every prompt.
    var courseContext: String {
        var parts = ["Course: \(courseName.isEmpty ? "Architecture History" : courseName)."]
        let place = city.isEmpty ? "the city" : city
        parts.append("Classes are walking tours around \(place); the professor stops at buildings and talks about their history and stories.")
        if !professorName.isEmpty { parts.append("Professor: \(professorName).") }
        if !vocabularyList.isEmpty { parts.append("Names the professor often uses: \(vocabularyList.joined(separator: ", ")).") }
        parts.append("The final exam asks which buildings we visited, when each was built (year) and by whom (architect).")
        return parts.joined(separator: " ")
    }
}
