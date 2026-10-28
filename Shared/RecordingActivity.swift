import ActivityKit
import AppIntents
import Foundation

/// The lock-screen / Dynamic Island "console" shown while a class is being recorded.
/// Shared by the app (which starts and updates it) and the widget extension (which draws it).
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var isPaused: Bool
        /// While recording: the moment the timer would have started (now − elapsed), so the
        /// lock screen can show a live, self-updating timer.
        var timerStart: Date
        /// While paused: the frozen elapsed time.
        var elapsed: Double
        var photoCount: Int
        var lastPhotoAt: Date?
        /// What the professor is talking about right now (on-device guess), if known.
        var nowDiscussing: String
    }

    var courseName: String
}

/// The app registers what the lock-screen buttons do; the widget extension never runs them.
@MainActor
enum RecordingControl {
    static var togglePause: (() -> Void)?
}

/// Pause / Resume button on the lock screen. Runs inside the app (which keeps running in the
/// background while recording), so it works without unlocking the phone.
struct ToggleRecordingPauseIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Pause or Resume Recording"
    static var isDiscoverable: Bool = false
    /// Pausing or resuming a recording is harmless, so allow it from the lock screen without Face ID.
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult {
        await MainActor.run { RecordingControl.togglePause?() }
        return .result()
    }
}

/// Deep link the lock-screen camera button opens (after Face ID): straight to the recording camera.
enum RecordingLinks {
    static let camera = URL(string: "eznotetaker://camera")!
    static let recorder = URL(string: "eznotetaker://recorder")!
}

enum ClockText {
    static func format(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
