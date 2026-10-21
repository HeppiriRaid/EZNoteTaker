import Foundation
import FoundationModels

/// Free, private, instant draft of the study notes using Apple Intelligence on the iPhone.
/// The on-device model has a small context window, so the transcript is read in parts and the
/// buildings found in each part are merged. Claude's version (from the Mac relay) replaces it.
enum OnDeviceAnalyzer {
    @Generable
    struct PartNotes {
        @Guide(description: "A short heading (max 8 words) for this part of the lecture.")
        var heading: String

        @Guide(description: "Two or three plain sentences explaining what was covered in this part.")
        var summary: String

        @Guide(description: "The most important points from this part.", .maximumCount(5))
        var keyPoints: [String]

        @Guide(description: "Specific buildings the professor talked about in this part. Empty if none.", .maximumCount(4))
        var buildings: [PartBuilding]
    }

    @Generable
    struct PartBuilding {
        @Guide(description: "Building name, correctly spelled.")
        var name: String

        @Guide(description: "Architect as said in class, or an empty string.")
        var architect: String

        @Guide(description: "Year built as said in class, or an empty string.")
        var year: String

        @Guide(description: "Architectural style, or an empty string.")
        var style: String

        @Guide(description: "Facts about the building from the lecture.", .maximumCount(5))
        var facts: [String]

        @Guide(description: "Stories or trivia the professor told about it.", .maximumCount(3))
        var trivia: [String]
    }

    @Generable
    struct Overview {
        @Guide(description: "A short title for the whole lecture (max 8 words).")
        var title: String

        @Guide(description: "Two or three sentences summarizing the whole class.")
        var overview: String

        @Guide(description: "The big-picture takeaways of the class.", .maximumCount(6))
        var takeaways: [String]
    }

    static var isAvailable: Bool { LiveBuildingDetector.isAvailable }

    /// - Parameter onProgress: (parts done, total parts)
    static func analyze(segments: [(start: Double, text: String)], photos: [(id: String, takenAt: Double, hint: String)],
                        courseContext: String, onProgress: @MainActor @escaping (Int, Int) -> Void) async throws -> LectureAnalysis {
        let parts = chunk(segments, maxCharacters: 4500)
        let instructions = """
        You help a university student review an architecture history class held as a walking tour. \(courseContext)
        The text is a speech-recognized transcript, so names may be misheard; fix them when obvious. \
        Only report what the professor said; do not invent facts.
        """

        var analysis = LectureAnalysis()
        var buildingOrder: [String] = []
        var merged: [String: LectureAnalysis.BuildingInfo] = [:]

        await onProgress(0, parts.count + 1)
        for (index, part) in parts.enumerated() {
            try Task.checkCancellation()
            let session = LanguageModelSession(instructions: instructions)
            let prompt = "Lecture part \(index + 1) of \(parts.count), starting at \(TimeFormat.clock(part.start)):\n\n\(part.text)"
            do {
                let notes = try await session.respond(to: prompt, generating: PartNotes.self).content
                analysis.sections.append(SummarySection(heading: notes.heading, body: notes.summary, bullets: notes.keyPoints))
                for found in notes.buildings where !found.name.isEmpty {
                    let key = LectureAnalysis.normalize(found.name)
                    var info: LectureAnalysis.BuildingInfo
                    if let existing = merged[key] {
                        info = existing
                    } else {
                        info = LectureAnalysis.BuildingInfo(name: found.name)
                        info.firstMentionedSeconds = part.start
                        info.verificationNote = "Draft from Apple Intelligence — the Claude version will double-check names, years and architects."
                        buildingOrder.append(key)
                    }
                    if info.architect.isEmpty { info.architect = found.architect }
                    if info.yearBuilt.isEmpty { info.yearBuilt = found.year }
                    if info.style.isEmpty { info.style = found.style }
                    info.keyFacts = unique(info.keyFacts + found.facts)
                    info.trivia = unique(info.trivia + found.trivia)
                    merged[key] = info
                }
            } catch let error as LanguageModelSession.GenerationError {
                // Skip a part the model can't handle (e.g. guardrails) rather than failing the whole lecture.
                print("On-device analysis skipped part \(index + 1): \(error)")
            }
            await onProgress(index + 1, parts.count + 1)
        }

        analysis.buildings = buildingOrder.compactMap { merged[$0] }.map { info in
            var info = info
            info.examImportance = info.keyFacts.count + info.trivia.count >= 4 ? "high" : "medium"
            return info
        }

        // Overall title + overview from the part summaries.
        let digest = analysis.sections.map { "\($0.heading): \($0.body)" }.joined(separator: "\n").suffix(6000)
        if !digest.isEmpty {
            let session = LanguageModelSession(instructions: instructions)
            if let overview = try? await session.respond(
                to: "Here are summaries of each part of the class:\n\n\(digest)", generating: Overview.self
            ).content {
                analysis.title = overview.title
                analysis.overview = overview.overview
                analysis.keyTakeaways = overview.takeaways
            }
        }
        await onProgress(parts.count + 1, parts.count + 1)

        analysis.examQuestions = analysis.buildings.flatMap { b -> [ExamQuestion] in
            var questions: [ExamQuestion] = []
            if !b.architect.isEmpty { questions.append(ExamQuestion(question: "Who designed \(b.name)?", answer: b.architect)) }
            if !b.yearBuilt.isEmpty { questions.append(ExamQuestion(question: "When was \(b.name) built?", answer: b.yearBuilt)) }
            return questions
        }

        analysis.photoAssignments = photos.map { photo in
            LectureAnalysis.PhotoAssignment(photoId: photo.id, buildingName: building(for: photo, in: analysis.buildings))
        }
        return analysis
    }

    /// Photo → the live guess if it names a known building, otherwise the building being discussed at that time.
    private static func building(for photo: (id: String, takenAt: Double, hint: String),
                                 in buildings: [LectureAnalysis.BuildingInfo]) -> String {
        let hint = LectureAnalysis.normalize(photo.hint)
        if !hint.isEmpty, let match = buildings.first(where: { hint.contains(LectureAnalysis.normalize($0.name)) }) {
            return match.name
        }
        let earlier = buildings.filter { ($0.firstMentionedSeconds ?? 0) <= photo.takenAt }
        return (earlier.max { ($0.firstMentionedSeconds ?? 0) < ($1.firstMentionedSeconds ?? 0) } ?? buildings.first)?.name ?? ""
    }

    private static func chunk(_ segments: [(start: Double, text: String)], maxCharacters: Int) -> [(start: Double, text: String)] {
        var parts: [(start: Double, text: String)] = []
        var current = ""
        var start = segments.first?.start ?? 0
        for segment in segments {
            if current.count + segment.text.count > maxCharacters, !current.isEmpty {
                parts.append((start, current))
                current = ""
                start = segment.start
            }
            current += "[\(TimeFormat.clock(segment.start))] \(segment.text)\n"
        }
        if !current.isEmpty { parts.append((start, current)) }
        return parts
    }

    private static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.lowercased()).inserted }
    }
}
