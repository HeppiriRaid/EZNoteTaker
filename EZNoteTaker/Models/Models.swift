import Foundation
import SwiftData

// MARK: - Lecture

enum LectureStatus: String, Codable {
    case recording
    case transcribed      // recorded, no study notes yet
    case ready            // has study notes (on-device draft or Claude)
}

/// Who wrote the study notes currently shown.
enum AnalysisSource: String, Codable {
    case none
    case onDevice   // Apple Intelligence draft, generated right after class
    case claude     // Claude Opus 5.5 via Claude Code on the Mac relay
}

/// Progress of the Claude job for a lecture.
enum ClaudeJobState: String, Codable {
    case notSent
    case waiting    // job is in the relay folder, waiting for the Mac
    case done
    case failed
}

@Model
final class Lecture {
    var id: UUID = UUID()
    var date: Date = Date()
    var title: String = ""
    var durationSeconds: Double = 0
    var audioFileName: String?
    var localeIdentifier: String = "en-US"
    var statusRaw: String = LectureStatus.recording.rawValue

    var analysisSourceRaw: String = AnalysisSource.none.rawValue
    var claudeJobRaw: String = ClaudeJobState.notSent.rawValue
    var claudeJobSentAt: Date?
    var claudeJobError: String?

    // Study notes
    var overview: String = ""
    var keyTakeaways: [String] = []
    var summarySectionsData: Data?
    var keyTermsData: Data?
    var examQuestionsData: Data?
    var analyzedAt: Date?
    var correctionsApplied: Int = 0
    /// Photo ids in the order they were labeled P1, P2… in the last Claude job.
    var promptPhotoOrder: [String] = []

    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.lecture)
    var segments: [TranscriptSegment] = []

    @Relationship(deleteRule: .cascade, inverse: \Building.lecture)
    var buildings: [Building] = []

    @Relationship(deleteRule: .cascade, inverse: \LecturePhoto.lecture)
    var photos: [LecturePhoto] = []

    @Relationship(deleteRule: .cascade, inverse: \StopMarker.lecture)
    var markers: [StopMarker] = []

    init(date: Date = Date(), title: String = "", localeIdentifier: String = "en-US") {
        self.id = UUID()
        self.date = date
        self.title = title
        self.localeIdentifier = localeIdentifier
    }

    var status: LectureStatus {
        get { LectureStatus(rawValue: statusRaw) ?? .transcribed }
        set { statusRaw = newValue.rawValue }
    }

    var analysisSource: AnalysisSource {
        get { AnalysisSource(rawValue: analysisSourceRaw) ?? .none }
        set { analysisSourceRaw = newValue.rawValue }
    }

    var claudeJob: ClaudeJobState {
        get { ClaudeJobState(rawValue: claudeJobRaw) ?? .notSent }
        set { claudeJobRaw = newValue.rawValue }
    }

    var displayTitle: String {
        title.isEmpty ? "Class — \(date.formatted(date: .abbreviated, time: .omitted))" : title
    }

    var sortedSegments: [TranscriptSegment] { segments.sorted { $0.start < $1.start } }
    var sortedPhotos: [LecturePhoto] { photos.sorted { $0.takenAt < $1.takenAt } }
    var sortedMarkers: [StopMarker] { markers.sorted { $0.time < $1.time } }
    var sortedBuildings: [Building] {
        buildings.sorted { ($0.order, $0.firstMentioned) < ($1.order, $1.firstMentioned) }
    }

    var fullTranscript: String { sortedSegments.map(\.text).joined(separator: " ") }

    var summarySections: [SummarySection] {
        get { Self.decode(summarySectionsData) ?? [] }
        set { summarySectionsData = try? JSONEncoder().encode(newValue) }
    }

    var keyTerms: [KeyTerm] {
        get { Self.decode(keyTermsData) ?? [] }
        set { keyTermsData = try? JSONEncoder().encode(newValue) }
    }

    var examQuestions: [ExamQuestion] {
        get { Self.decode(examQuestionsData) ?? [] }
        set { examQuestionsData = try? JSONEncoder().encode(newValue) }
    }

    var audioURL: URL? {
        audioFileName.map { FileStore.audioDirectory.appendingPathComponent($0) }
    }

    private static func decode<T: Decodable>(_ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

struct SummarySection: Codable, Hashable, Identifiable {
    var heading: String
    var body: String
    var bullets: [String]
    var id: String { heading + body.prefix(16) }
}

struct KeyTerm: Codable, Hashable, Identifiable {
    var term: String
    var definition: String
    var id: String { term }
}

struct ExamQuestion: Codable, Hashable, Identifiable {
    var question: String
    var answer: String
    var id: String { question }
}

// MARK: - Transcript

@Model
final class TranscriptSegment {
    /// Seconds from the start of the recording (pauses excluded).
    var start: Double = 0
    var text: String = ""
    var lecture: Lecture?

    init(start: Double, text: String) {
        self.start = start
        self.text = text
    }
}

// MARK: - Building

enum ExamImportance: String, Codable, CaseIterable {
    case high, medium, low

    var label: String {
        switch self {
        case .high: "Likely on exam"
        case .medium: "Good to know"
        case .low: "Background"
        }
    }
}

@Model
final class Building {
    var id: UUID = UUID()
    var name: String = ""
    var architect: String = ""
    var yearBuilt: String = ""
    /// Single representative year for sorting / timelines (0 = unknown).
    var yearSort: Int = 0
    var style: String = ""
    var location: String = ""
    var significance: String = ""
    var keyFacts: [String] = []
    var trivia: [String] = []
    var professorEmphasis: [String] = []
    var verificationNote: String = ""
    var importanceRaw: String = ExamImportance.medium.rawValue
    var firstMentioned: Double = 0
    var latitude: Double?
    var longitude: Double?
    var order: Int = 0
    var userNotes: String = ""
    var isStarred: Bool = false
    var studyCorrect: Int = 0
    var studyMissed: Int = 0
    var lecture: Lecture?

    @Relationship(deleteRule: .nullify, inverse: \LecturePhoto.building)
    var photos: [LecturePhoto] = []

    init(name: String) {
        self.id = UUID()
        self.name = name
    }

    var importance: ExamImportance {
        get { ExamImportance(rawValue: importanceRaw) ?? .medium }
        set { importanceRaw = newValue.rawValue }
    }

    var sortedPhotos: [LecturePhoto] { photos.sorted { $0.takenAt < $1.takenAt } }

    var architectDisplay: String { architect.isEmpty ? "Architect unknown" : architect }
    var yearDisplay: String { yearBuilt.isEmpty ? "Year unknown" : yearBuilt }

    /// Lower = needs more practice. Used to put weak cards first.
    var masteryScore: Int { studyCorrect - 2 * studyMissed }

    /// Coordinates from Claude, falling back to the average GPS of attached photos.
    var coordinate: (lat: Double, lon: Double)? {
        if let latitude, let longitude { return (latitude, longitude) }
        let located = photos.compactMap { p -> (Double, Double)? in
            guard let la = p.latitude, let lo = p.longitude else { return nil }
            return (la, lo)
        }
        guard !located.isEmpty else { return nil }
        let lat = located.map { $0.0 }.reduce(0, +) / Double(located.count)
        let lon = located.map { $0.1 }.reduce(0, +) / Double(located.count)
        return (lat, lon)
    }
}

// MARK: - Photo

@Model
final class LecturePhoto {
    var id: UUID = UUID()
    var fileName: String = ""
    /// Seconds into the recording when the photo was taken (pauses excluded).
    var takenAt: Double = 0
    var capturedDate: Date = Date()
    var latitude: Double?
    var longitude: Double?
    /// What the live detector thought was being discussed when the photo was taken.
    var liveHint: String = ""
    var caption: String = ""
    /// True when the user assigned the building manually (re-analysis keeps it).
    var manuallyAssigned: Bool = false
    var lecture: Lecture?
    var building: Building?

    init(fileName: String, takenAt: Double) {
        self.id = UUID()
        self.fileName = fileName
        self.takenAt = takenAt
        self.capturedDate = Date()
    }

    var fileURL: URL { FileStore.photoDirectory.appendingPathComponent(fileName) }
}

// MARK: - Stop marker

/// A "we're at a new building" marker the student drops while walking.
@Model
final class StopMarker {
    var time: Double = 0
    var label: String = ""
    var latitude: Double?
    var longitude: Double?
    var lecture: Lecture?

    init(time: Double, label: String) {
        self.time = time
        self.label = label
    }
}

// MARK: - Photo stops

/// Groups photos into "stops": the student takes a few photos of each building while the class stands
/// in front of it, so photos close together in time and place belong to the same stop.
enum PhotoStops {
    /// A new stop starts after this many seconds without photos…
    static let maxGap: Double = 150
    /// …or when the student has walked further than this many meters.
    static let maxDistance: Double = 40

    static func group(_ photos: [LecturePhoto]) -> [[LecturePhoto]] {
        var stops: [[LecturePhoto]] = []
        for photo in photos.sorted(by: { $0.takenAt < $1.takenAt }) {
            if let previous = stops.last?.last,
               photo.takenAt - previous.takenAt <= maxGap,
               distance(previous, photo).map({ $0 <= maxDistance }) ?? true {
                stops[stops.count - 1].append(photo)
            } else {
                stops.append([photo])
            }
        }
        return stops
    }

    private static func distance(_ a: LecturePhoto, _ b: LecturePhoto) -> Double? {
        guard let la = a.latitude, let lo = a.longitude, let lb = b.latitude, let lob = b.longitude else { return nil }
        let metersPerDegree = 111_320.0
        let dx = (lob - lo) * metersPerDegree * cos(la * .pi / 180)
        let dy = (lb - la) * metersPerDegree
        return (dx * dx + dy * dy).squareRoot()
    }
}

// MARK: - Class weeks

/// One class week. The class meets once a week, so every recording in the same calendar week
/// (e.g. a recording that was stopped and restarted) belongs to the same class; only a new week
/// starts a new folder. Weeks are numbered from the first class, so a skipped week (holiday)
/// keeps the numbering true to the calendar.
struct ClassWeek: Identifiable {
    struct Entry: Identifiable {
        let building: Building
        /// Later class weeks where the same building came up again.
        var revisitedOn: [Int] = []
        var id: UUID { building.id }
    }

    let number: Int
    /// Start of the calendar week (used as a stable id).
    let weekStart: Date
    /// Date of the class itself (first recording that week).
    let date: Date
    let lectures: [Lecture]
    /// Buildings introduced this week, in the order visited (duplicates merged).
    var entries: [Entry]
    var id: Date { weekStart }

    var title: String {
        let titles = lectures.map(\.displayTitle).filter { !$0.hasPrefix("Class —") }
        return titles.isEmpty ? date.formatted(date: .complete, time: .omitted) : titles.joined(separator: " · ")
    }

    var label: String { "WEEK \(number) · \(date.formatted(.dateTime.weekday(.abbreviated).month().day()))" }
    var overview: String { lectures.map(\.overview).filter { !$0.isEmpty }.joined(separator: "\n\n") }

    static func weekStart(of date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    static func group(_ lectures: [Lecture], calendar: Calendar = .current) -> [ClassWeek] {
        let byWeek = Dictionary(grouping: lectures) { weekStart(of: $0.date, calendar: calendar) }
        let starts = byWeek.keys.sorted()
        guard let firstWeek = starts.first else { return [] }
        var weeks: [ClassWeek] = []
        var introducedIn: [String: (week: Int, index: Int)] = [:]

        for (offset, start) in starts.enumerated() {
            let recordings = (byWeek[start] ?? []).sorted { $0.date < $1.date }
            let number = (calendar.dateComponents([.weekOfYear], from: firstWeek, to: start).weekOfYear ?? offset) + 1
            var week = ClassWeek(number: number, weekStart: start, date: recordings.first?.date ?? start,
                                 lectures: recordings, entries: [])
            for building in recordings.flatMap(\.sortedBuildings) {
                let key = LectureAnalysis.normalize(building.name)
                if let first = introducedIn[key] {
                    // Introduced in an earlier week: note the revisit. Same week: a duplicate.
                    if first.week != offset, !weeks[first.week].entries[first.index].revisitedOn.contains(number) {
                        weeks[first.week].entries[first.index].revisitedOn.append(number)
                    }
                    continue
                }
                introducedIn[key] = (offset, week.entries.count)
                week.entries.append(Entry(building: building))
            }
            weeks.append(week)
        }
        return weeks
    }

    /// Week number for a lecture, matching `group`.
    static func number(of lecture: Lecture, in lectures: [Lecture], calendar: Calendar = .current) -> Int {
        guard let first = lectures.map(\.date).min() else { return 1 }
        let from = weekStart(of: first, calendar: calendar), to = weekStart(of: lecture.date, calendar: calendar)
        return (calendar.dateComponents([.weekOfYear], from: from, to: to).weekOfYear ?? 0) + 1
    }
}

// MARK: - Photo placement

enum PhotoPlacement {
    /// Puts every photo that has no building on one: the building another photo of the same stop
    /// shows, otherwise the building being discussed when the photo was taken. Photos the student
    /// explicitly set to "No building" are left alone.
    @discardableResult
    static func fillGaps(in lecture: Lecture) -> Int {
        let buildings = lecture.buildings.filter { !$0.isDeleted }
        guard !buildings.isEmpty else { return 0 }
        let valid = Set(buildings.map(\.id))
        let byTime = buildings.sorted { $0.firstMentioned < $1.firstMentioned }
        var filled = 0
        for stop in PhotoStops.group(lecture.photos) {
            let stopBuilding = stop.lazy.compactMap(\.building).first { valid.contains($0.id) && !$0.isDeleted }
            for photo in stop {
                if let current = photo.building, valid.contains(current.id), !current.isDeleted { continue }
                if photo.manuallyAssigned && photo.building == nil { continue }
                photo.building = stopBuilding
                    ?? byTime.last { $0.firstMentioned <= photo.takenAt + 30 }
                    ?? byTime.first
                filled += 1
            }
        }
        return filled
    }
}
