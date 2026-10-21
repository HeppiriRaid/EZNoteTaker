import Foundation
import SwiftData
import UIKit

/// Runs Claude Opus 5.5 on the student's own Claude subscription, fully automatically, through
/// Claude Code on their Mac:
///
///   iPhone ──(iCloud Drive folder)──▶ Mac relay runs `claude -p` ──(same folder)──▶ iPhone imports
///
/// Folder layout (inside the folder the student picks, e.g. iCloud Drive/EZNoteTaker):
///   jobs/<lecture-id>/prompt.md, P1.jpg, P2.jpg…, READY   ← written by the phone
///   results/<lecture-id>.json                               ← written by the Mac
///   results/<lecture-id>.error.txt                          ← written by the Mac on failure
///   relay-heartbeat.txt                                      ← touched by the Mac on every run
///   install-relay.command, ez-relay.sh                       ← Mac setup files, copied by the phone
@MainActor
enum ClaudeRelay {
    private static let bookmarkKey = "relayFolderBookmark"
    /// A typical class has ~40 photos; leave plenty of headroom.
    static let maxPhotos = 80
    /// Bump when the instructions to Claude change in a way worth re-running old classes for.
    /// 1: first release · 2: photo stops, captions, every photo assigned, whole-word corrections.
    static let promptVersion = 2

    // MARK: Folder

    static var isConfigured: Bool { UserDefaults.standard.data(forKey: bookmarkKey) != nil }

    static var folderName: String? { resolveFolder()?.lastPathComponent }

    /// Remembers the folder the student picked and copies the Mac setup files into it.
    static func setFolder(_ url: URL) throws {
        guard url.startAccessingSecurityScopedResource() else {
            throw RelayError.noAccess
        }
        defer { url.stopAccessingSecurityScopedResource() }
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        try installMacFiles(in: url)
    }

    static func clearFolder() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    private static func resolveFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        return url
    }

    private static func withFolder<T>(_ body: (URL) throws -> T) throws -> T {
        guard let url = resolveFolder() else { throw RelayError.notConfigured }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }

    /// Copies the relay script and installer from the app bundle into the shared folder.
    static func installMacFiles(in folder: URL) throws {
        let fm = FileManager.default
        for name in ["ez-relay.sh", "install-relay.command"] {
            guard let source = Bundle.main.url(forResource: name, withExtension: nil) else { continue }
            let target = folder.appendingPathComponent(name)
            try? fm.removeItem(at: target)
            try fm.copyItem(at: source, to: target)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        }
        for dir in ["jobs", "results"] {
            try fm.createDirectory(at: folder.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
    }

    /// When the Mac relay last ran, from its heartbeat file.
    static func lastHeartbeat() -> Date? {
        try? withFolder { folder in
            let url = folder.appendingPathComponent("relay-heartbeat.txt")
            Self.requestDownload(url)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.modificationDate] as? Date
        }
    }

    // MARK: Submit

    /// Drops the lecture into the shared folder for the Mac to pick up.
    static func submit(_ lecture: Lecture, settings: AppSettings) throws {
        try withFolder { folder in
            let fm = FileManager.default
            let id = lecture.id.uuidString
            let job = folder.appendingPathComponent("jobs/\(id)", isDirectory: true)
            try? fm.removeItem(at: job)
            try? fm.removeItem(at: folder.appendingPathComponent("results/\(id).json"))
            try? fm.removeItem(at: folder.appendingPathComponent("results/\(id).error.txt"))
            try fm.createDirectory(at: job, withIntermediateDirectories: true)

            let photos = lecture.sortedPhotos
            lecture.promptPhotoOrder = photos.map { $0.id.uuidString }

            if settings.sharePhotos {
                for (i, photo) in photos.prefix(maxPhotos).enumerated() {
                    guard let image = ImageCache.shared.full(for: photo.fileName),
                          let jpeg = image.resized(maxPixel: 1024).jpegData(compressionQuality: 0.7) else { continue }
                    try jpeg.write(to: job.appendingPathComponent("P\(i + 1).jpg"))
                }
            }

            try prompt(for: lecture, settings: settings, photosAttached: settings.sharePhotos)
                .write(to: job.appendingPathComponent("prompt.md"), atomically: true, encoding: .utf8)
            // Written last so the Mac never starts on a half-synced job.
            try Date().ISO8601Format().write(to: job.appendingPathComponent("READY"), atomically: true, encoding: .utf8)
        }
        lecture.claudeJob = .waiting
        lecture.claudeJobSentAt = Date()
        lecture.claudeJobError = nil
    }

    // MARK: Collect

    enum CheckResult {
        case imported(LectureAnalysis.ApplySummary)
        case failed(String)
        case pending
    }

    /// Looks for a finished result for this lecture and imports it.
    static func collect(_ lecture: Lecture, context: ModelContext) -> CheckResult {
        let outcome: CheckResult? = try? withFolder { folder in
            let id = lecture.id.uuidString
            let resultURL = folder.appendingPathComponent("results/\(id).json")
            let errorURL = folder.appendingPathComponent("results/\(id).error.txt")
            let fm = FileManager.default

            if let text = readCoordinated(resultURL) {
                do {
                    let analysis = try LectureAnalysis.parse(text)
                    let summary = analysis.apply(to: lecture, photoOrder: lecture.promptPhotoOrder,
                                                 source: .claude, context: context)
                    lecture.claudeJob = .done
                    lecture.analysisVersion = promptVersion
                    try? fm.removeItem(at: resultURL)
                    return .imported(summary)
                } catch {
                    lecture.claudeJob = .failed
                    lecture.claudeJobError = error.localizedDescription
                    try? fm.removeItem(at: resultURL)
                    return .failed(error.localizedDescription)
                }
            }
            if let text = readCoordinated(errorURL) {
                lecture.claudeJob = .failed
                lecture.claudeJobError = String(text.suffix(400))
                try? fm.removeItem(at: errorURL)
                return .failed(lecture.claudeJobError ?? "")
            }
            return .pending
        }
        return outcome ?? .pending
    }

    /// Reads a file that may still be an iCloud placeholder; asks iCloud to download it if so.
    private static func readCoordinated(_ url: URL) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            requestDownload(url)
            return nil
        }
        var text: String?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { readURL in
            text = try? String(contentsOf: readURL, encoding: .utf8)
        }
        return text
    }

    /// iCloud keeps not-yet-downloaded files as hidden ".name.icloud" placeholders.
    private static func requestDownload(_ url: URL) {
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        if FileManager.default.fileExists(atPath: placeholder.path) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
    }

    // MARK: Prompt

    static func prompt(for lecture: Lecture, settings: AppSettings, photosAttached: Bool) -> String {
        let photos = lecture.sortedPhotos
        var text = """
        You are my teaching assistant for my university architecture history course. Turn the raw, automatically \
        transcribed lecture below into study material that helps me ace the final exam.

        ## Course context
        \(settings.courseContext)

        ## Accuracy rules
        - The transcript comes from speech recognition and contains misheard names (e.g. "Lou Corbusier" → "Le Corbusier", \
        "Miss van der Ro" → "Mies van der Rohe"). Use your architecture knowledge to recover the real names.
        - Prefer what the professor said. If the professor's year or architect differs from the commonly cited fact, keep the \
        professor's version and explain the difference in "verification_note". If the professor didn't give a year or architect, \
        fill it from well-established knowledge and say so in "verification_note".
        - Only list buildings the class actually discussed. Never invent buildings.
        - Write for fast review: short, concrete sentences, easy to understand. You may use **bold** inside strings for names, years and architects.

        ## Lecture
        Date: \(lecture.date.formatted(date: .complete, time: .shortened))
        Length: \(TimeFormat.clock(lecture.durationSeconds))

        """

        let markers = lecture.sortedMarkers
        if !markers.isEmpty {
            text += "\nI tapped \"new stop\" while walking at these times (strong hints that we arrived at a new building):\n"
            for m in markers {
                var line = "- [\(TimeFormat.clock(m.time))] \(m.label.isEmpty ? "(unnamed stop)" : m.label)"
                if let la = m.latitude, let lo = m.longitude { line += String(format: " — GPS %.5f, %.5f", la, lo) }
                text += line + "\n"
            }
        }

        if !photos.isEmpty {
            let number = Dictionary(photos.enumerated().map { ($1.id, $0 + 1) }, uniquingKeysWith: { a, _ in a })
            text += """

            ## Photos
            I photograph each building while the class stands in front of it, so every photo marks a stop on the walk: \
            at the photo's time the professor is usually talking about the building in the photo (read the transcript \
            around that time). Photos are grouped below into stops by time and GPS; photos in one stop usually show the \
            same building, or details and neighbours of it.
            """
            if photosAttached {
                text += " The images are in the current folder as P1.jpg, P2.jpg… — look at each one with the Read tool before assigning it."
            }
            text += """

            Assign EVERY photo to the building it shows, using the exact name from "buildings". Photos of artworks, \
            rooms, windows or details inside or on a building belong to that building (e.g. a painting in a museum \
            gallery → the museum building). Leave building_name empty only if a photo truly shows none of them.

            """
            for (n, stop) in PhotoStops.group(photos).enumerated() {
                guard let first = stop.first else { continue }
                let ids = stop.compactMap { number[$0.id].map { "P\($0)" } }
                var line = "- Stop \(n + 1) at [\(TimeFormat.clock(first.takenAt))]: \(ids.joined(separator: ", "))"
                if let la = first.latitude, let lo = first.longitude { line += String(format: " — GPS %.5f, %.5f", la, lo) }
                if let guess = stop.first(where: { !$0.liveHint.isEmpty })?.liveHint { line += " — live guess: \(guess)" }
                for p in stop where p.manuallyAssigned {
                    if let b = p.building, let n = number[p.id] { line += " — I labeled P\(n): \(b.name)" }
                }
                if stop.count > 1, let last = stop.last { line += " (until [\(TimeFormat.clock(last.takenAt))])" }
                text += line + "\n"
            }
        }

        let transcript = lecture.sortedSegments
            .map { "[\(TimeFormat.clock($0.start))] \($0.text)" }
            .joined(separator: "\n")
        text += """

        <transcript>
        \(transcript)
        </transcript>

        ## Output format
        Your entire reply must be ONLY the JSON object below (no prose, no code fence). My app parses it automatically.

        \(jsonTemplate)

        Include every building we discussed (in the order visited), one photo_assignments entry per photo, \
        and 10–20 exam_questions in the style of the final. Classes are long walks (often 1½–2 hours, \
        15–25 buildings), so keep each building's facts focused on what is likely to be tested.
        """
        return text
    }

    static let jsonTemplate = """
    {
      "title": "Short lecture title, e.g. The Loop: Birth of the Skyscraper",
      "overview": "2–3 sentence overview of the class and the route we walked",
      "sections": [
        { "heading": "Section heading", "body": "Short, clear paragraph explaining this part of the lecture", "bullets": ["key point", "key point"] }
      ],
      "key_takeaways": ["5–8 big-picture takeaways"],
      "key_terms": [ { "term": "Architecture term or style", "definition": "Plain-language definition" } ],
      "exam_questions": [ { "question": "Likely exam question", "answer": "Concise answer" } ],
      "buildings": [
        {
          "name": "Official building name",
          "architect": "Architect(s) or firm, empty string if unknown",
          "year_built": "1891 or 1889–1891",
          "year_sort": 1891,
          "style": "Architectural style / movement",
          "location": "Address or neighborhood",
          "significance": "1–2 sentences: why it matters in architecture history",
          "key_facts": ["3–6 exam-relevant facts: materials, innovations, firsts, influences"],
          "trivia": ["Stories and anecdotes the professor told, plus memory hooks"],
          "professor_emphasis": ["Things the professor stressed, repeated, or hinted will be on the test"],
          "verification_note": "Differences from commonly cited facts, or which fields you filled in; empty if none",
          "exam_importance": "high | medium | low",
          "first_mentioned_seconds": 754,
          "latitude": 41.8789,
          "longitude": -87.6359
        }
      ],
      "photo_assignments": [ { "photo_id": "P1", "building_name": "Exact name from buildings", "caption": "1–2 sentences: what the photo shows and what the professor was explaining at that moment" } ],
      "name_corrections": [ { "heard": "Misheard proper noun exactly as in the transcript (never an ordinary English word)", "correct": "Just the correct spelling, no explanation" } ]
    }
    """

    enum RelayError: LocalizedError {
        case notConfigured
        case noAccess

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Pick the shared Claude relay folder in Settings first."
            case .noAccess: "EZNoteTaker couldn't access that folder. Pick it again in Settings."
            }
        }
    }
}
