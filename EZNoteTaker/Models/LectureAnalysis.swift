import Foundation
import SwiftData

/// The study material for one lecture, produced either by Claude (via the Mac relay)
/// or by the on-device model. Applying it fills the Summary, Buildings and Cheat Sheet.
struct LectureAnalysis: Decodable {
    struct BuildingInfo: Decodable {
        var name = "", architect = "", yearBuilt = "", style = "", location = "", significance = ""
        var verificationNote = "", examImportance = "medium"
        var keyFacts: [String] = [], trivia: [String] = [], professorEmphasis: [String] = []
        var yearSort: Int?
        var firstMentionedSeconds: Double?
        var latitude: Double?
        var longitude: Double?

        init(name: String) { self.name = name }

        enum CodingKeys: String, CodingKey {
            case name, architect, yearBuilt, style, location, significance, verificationNote, examImportance
            case keyFacts, trivia, professorEmphasis, yearSort, firstMentionedSeconds, latitude, longitude
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = c.string(.name)
            architect = c.string(.architect)
            yearBuilt = c.string(.yearBuilt)
            style = c.string(.style)
            location = c.string(.location)
            significance = c.string(.significance)
            verificationNote = c.string(.verificationNote)
            examImportance = c.string(.examImportance, default: "medium")
            keyFacts = c.strings(.keyFacts)
            trivia = c.strings(.trivia)
            professorEmphasis = c.strings(.professorEmphasis)
            yearSort = c.number(.yearSort).map { Int($0) }
            firstMentionedSeconds = c.number(.firstMentionedSeconds)
            latitude = c.number(.latitude)
            longitude = c.number(.longitude)
        }
    }

    struct PhotoAssignment: Decodable {
        var photoId = "", buildingName = "", caption = ""

        init(photoId: String, buildingName: String, caption: String = "") {
            self.photoId = photoId
            self.buildingName = buildingName
            self.caption = caption
        }

        enum CodingKeys: String, CodingKey { case photoId, buildingName, caption }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            photoId = c.string(.photoId)
            buildingName = c.string(.buildingName)
            caption = c.string(.caption)
        }
    }

    struct NameCorrection: Decodable {
        var heard = "", correct = ""
        enum CodingKeys: String, CodingKey { case heard, correct }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            heard = c.string(.heard)
            correct = c.string(.correct)
        }
    }

    var title = "", overview = ""
    var sections: [SummarySection] = []
    var keyTakeaways: [String] = []
    var keyTerms: [KeyTerm] = []
    var examQuestions: [ExamQuestion] = []
    var buildings: [BuildingInfo] = []
    var photoAssignments: [PhotoAssignment] = []
    var nameCorrections: [NameCorrection] = []

    init() {}

    enum CodingKeys: String, CodingKey {
        case title, overview, sections, keyTakeaways, keyTerms, examQuestions, buildings, photoAssignments, nameCorrections
    }

    // Every field is optional on the wire: a result shouldn't fail just because the model
    // skipped a field or wrote a number as a string.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.string(.title)
        overview = c.string(.overview)
        sections = (try? c.decodeIfPresent([LenientSection].self, forKey: .sections))?.map(\.value) ?? []
        keyTakeaways = c.strings(.keyTakeaways)
        keyTerms = (try? c.decodeIfPresent([KeyTerm].self, forKey: .keyTerms)) ?? []
        examQuestions = (try? c.decodeIfPresent([ExamQuestion].self, forKey: .examQuestions)) ?? []
        buildings = (try? c.decodeIfPresent([BuildingInfo].self, forKey: .buildings)) ?? []
        photoAssignments = (try? c.decodeIfPresent([PhotoAssignment].self, forKey: .photoAssignments)) ?? []
        nameCorrections = (try? c.decodeIfPresent([NameCorrection].self, forKey: .nameCorrections)) ?? []
    }

    private struct LenientSection: Decodable {
        var value: SummarySection
        enum CodingKeys: String, CodingKey { case heading, body, bullets }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            value = SummarySection(heading: c.string(.heading), body: c.string(.body), bullets: c.strings(.bullets))
        }
    }

    // MARK: - Parsing

    enum ParseError: LocalizedError {
        case noJSON
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .noJSON: "Claude's answer didn't contain the expected JSON."
            case .invalid(let detail): "Couldn't read Claude's answer (\(detail))."
            }
        }
    }

    /// Accepts raw JSON or JSON wrapped in a ```json fence with text around it.
    static func parse(_ text: String) throws -> LectureAnalysis {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            throw ParseError.noJSON
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            let analysis = try decoder.decode(LectureAnalysis.self, from: Data(text[start...end].utf8))
            guard !analysis.buildings.isEmpty || !analysis.sections.isEmpty || !analysis.overview.isEmpty else {
                throw ParseError.invalid("it has no summary or buildings")
            }
            return analysis
        } catch let error as ParseError {
            throw error
        } catch {
            throw ParseError.invalid(error.localizedDescription)
        }
    }

    // MARK: - Applying

    struct ApplySummary {
        var buildings: Int
        var photosPlaced: Int
        var corrections: Int
    }

    /// Writes the analysis into the lecture, replacing earlier results but keeping the student's
    /// own notes, stars, study stats and manual photo assignments.
    @MainActor
    @discardableResult
    func apply(to lecture: Lecture, photoOrder: [String], source: AnalysisSource, context: ModelContext) -> ApplySummary {
        guard lecture.modelContext != nil, !lecture.isDeleted else { return ApplySummary(buildings: 0, photosPlaced: 0, corrections: 0) }
        if lecture.title.isEmpty || lecture.analysisSource == .onDevice, !title.isEmpty { lecture.title = title }
        lecture.overview = overview
        lecture.summarySections = sections
        lecture.keyTakeaways = keyTakeaways
        lecture.keyTerms = keyTerms
        lecture.examQuestions = examQuestions

        let oldBuildings = lecture.buildings
        var previous: [String: Building] = [:]
        for b in oldBuildings { previous[Self.normalize(b.name)] = b }
        let manualLinks: [(LecturePhoto, String)] = lecture.photos.compactMap { p in
            guard p.manuallyAssigned, let b = p.building else { return nil }
            return (p, Self.normalize(b.name))
        }

        // Buildings are updated in place when the name matches, so screens showing them stay valid.
        var created: [String: Building] = [:]
        for (index, info) in buildings.enumerated() where !info.name.isEmpty {
            let key = Self.normalize(info.name)
            guard created[key] == nil else { continue }
            let b: Building
            if let existing = previous[key] {
                b = existing
                b.name = info.name
            } else {
                b = Building(name: info.name)
                context.insert(b)
                b.lecture = lecture
            }
            b.architect = info.architect
            b.yearBuilt = info.yearBuilt
            b.yearSort = info.yearSort ?? Self.firstYear(in: info.yearBuilt)
            b.style = info.style
            b.location = info.location
            b.significance = info.significance
            b.keyFacts = info.keyFacts
            b.trivia = info.trivia
            b.professorEmphasis = info.professorEmphasis
            b.verificationNote = info.verificationNote
            b.importance = ExamImportance(rawValue: info.examImportance.lowercased()) ?? .medium
            b.firstMentioned = info.firstMentionedSeconds ?? 0
            b.latitude = info.latitude
            b.longitude = info.longitude
            b.order = index
            created[key] = b
        }
        let kept = Set(created.values.map(\.id))
        for old in oldBuildings where !kept.contains(old.id) { context.delete(old) }

        // P1, P2… → photos, in the order they were numbered when the job was created.
        let byUUID = Dictionary(lecture.photos.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        let order = photoOrder.isEmpty ? lecture.sortedPhotos.map { $0.id.uuidString } : photoOrder
        var photoByPromptID: [String: LecturePhoto] = [:]
        for (i, uuid) in order.enumerated() {
            if let photo = byUUID[uuid] { photoByPromptID["P\(i + 1)"] = photo }
        }

        /// Exact name first; Claude sometimes shortens or extends a name ("Rookery" vs "The Rookery Building").
        func building(named name: String) -> Building? {
            let key = Self.normalize(name)
            guard !key.isEmpty else { return nil }
            if let exact = created[key] { return exact }
            return created.filter { $0.key.contains(key) || key.contains($0.key) }
                .max { $0.key.count < $1.key.count }?.value
        }

        // Photos Claude placed on a building.
        var decided = Set<UUID>()
        for assignment in photoAssignments {
            let key = assignment.photoId.uppercased().replacingOccurrences(of: ".JPG", with: "")
            guard let photo = photoByPromptID[key] else { continue }
            if !assignment.caption.isEmpty { photo.caption = assignment.caption }
            guard !photo.manuallyAssigned else { continue }
            if let match = building(named: assignment.buildingName) {
                photo.building = match
                decided.insert(photo.id)
            }
        }
        for (photo, name) in manualLinks {
            if let building = created[name] {
                photo.building = building
            } else {
                // The building the student picked no longer exists; let automatic matching take over.
                photo.building = nil
                photo.manuallyAssigned = false
            }
        }

        // Every other photo goes to the building of its stop, or the one being discussed when it was taken.
        for photo in lecture.photos where !photo.manuallyAssigned && !decided.contains(photo.id) {
            photo.building = nil
        }
        PhotoPlacement.fillGaps(in: lecture)
        let placed = lecture.photos.filter { photo in photo.building.map { kept.contains($0.id) } ?? false }.count

        // Fix misheard proper nouns in the transcript.
        // Whole words only, so "Burn up" → "Burnham" can't touch "burning", and explanations in
        // parentheses ("Bundy Fountain (pun on …)") are not pasted into the transcript.
        var applied = 0
        for fix in nameCorrections {
            let heard = fix.heard.trimmingCharacters(in: .whitespaces)
            let correct = fix.correct
                .replacingOccurrences(of: #"\s*\(.*\)"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard heard.count >= 4, !correct.isEmpty, heard.lowercased() != correct.lowercased(),
                  let regex = try? NSRegularExpression(
                      pattern: "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: heard) + "(?![\\p{L}\\p{N}])",
                      options: [.caseInsensitive]) else { continue }
            let template = NSRegularExpression.escapedTemplate(for: correct)
            for segment in lecture.segments {
                let range = NSRange(segment.text.startIndex..., in: segment.text)
                let count = regex.numberOfMatches(in: segment.text, range: range)
                guard count > 0 else { continue }
                segment.text = regex.stringByReplacingMatches(in: segment.text, range: range, withTemplate: template)
                applied += count
            }
        }
        lecture.correctionsApplied += applied

        lecture.analyzedAt = Date()
        lecture.analysisSource = source
        lecture.status = .ready
        try? context.save()
        return ApplySummary(buildings: created.count, photosPlaced: placed, corrections: applied)
    }

    static func normalize(_ name: String) -> String {
        name.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    static func firstYear(in text: String) -> Int {
        text.split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
            .first { $0 > 100 && $0 < 2200 } ?? 0
    }
}

private extension KeyedDecodingContainer {
    func string(_ key: Key, default fallback: String = "") -> String {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let n = try? decodeIfPresent(Double.self, forKey: key) { return n == n.rounded() ? String(Int(n)) : String(n) }
        return fallback
    }

    func strings(_ key: Key) -> [String] {
        if let list = try? decodeIfPresent([String].self, forKey: key) { return list }
        if let single = try? decodeIfPresent(String.self, forKey: key), !single.isEmpty { return [single] }
        return []
    }

    /// Accepts 1891, "1891", "12:34" (mm:ss) or null.
    func number(_ key: Key) -> Double? {
        if let n = try? decodeIfPresent(Double.self, forKey: key) { return n }
        guard let s = try? decodeIfPresent(String.self, forKey: key) else { return nil }
        let parts = s.split(separator: ":").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count >= 2 { return parts.reduce(0) { $0 * 60 + $1 } }
        if let value = Double(s.trimmingCharacters(in: .whitespaces)) { return value }
        let year = LectureAnalysis.firstYear(in: s)
        return year == 0 ? nil : Double(year)
    }
}
