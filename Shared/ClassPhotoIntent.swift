import AppIntents
import Foundation

/// What the lock-screen camera shows about the class (shared with it by the system, max 4 KB).
struct ClassPhotoContext: Codable, Sendable {
    var isRecording: Bool
    var className: String
}

/// "Class Photo" control for the Lock Screen, Control Center or the Action button. When the phone is
/// locked it opens EZNoteTaker's lock-screen camera (no Face ID); when unlocked it opens the app's camera.
/// Compiled into the app, the widget extension (the control) and the capture extension.
struct ClassPhotoIntent: CameraCaptureIntent {
    typealias AppContext = ClassPhotoContext

    static let title: LocalizedStringResource = "Class Photo"
    static let description = IntentDescription("Take class photos from the lock screen without unlocking.")

    @MainActor
    func perform() async throws -> some IntentResult {
        RecordingControl.openCamera?()
        return .result()
    }
}

enum LockedPhotoNaming {
    /// Photos from the lock-screen camera are named with their capture time so the app can place them
    /// at the right moment of the class.
    static func fileName(for date: Date = Date()) -> String {
        "classphoto-\(Int64(date.timeIntervalSince1970 * 1000)).jpg"
    }

    static func captureDate(fromFileName name: String) -> Date? {
        guard name.hasPrefix("classphoto-"), let ms = Int64(name.dropFirst(11).prefix { $0.isNumber }) else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }
}
