import Foundation
import FoundationModels

/// While recording, Apple's free on-device model (Apple Intelligence) guesses which building is being
/// discussed right now. The recording screen shows it as "Now: Robie House · Frank Lloyd Wright · 1910",
/// and photos get it as a provisional label. Nothing leaves the phone and nothing is billed.
@Generable
struct LiveBuildingGuess: Equatable {
    @Guide(description: "True only if the professor is currently talking about one specific building.")
    var discussingABuilding: Bool

    @Guide(description: "The building's name, correctly spelled, or an empty string.")
    var name: String

    @Guide(description: "The architect if the transcript mentions one or you are sure, otherwise an empty string.")
    var architect: String

    @Guide(description: "The year built if mentioned or you are sure, otherwise an empty string.")
    var year: String

    var label: String {
        [name, architect, year].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

enum LiveBuildingDetector {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "This iPhone doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): "Turn on Apple Intelligence in iOS Settings to enable live building detection."
        case .unavailable(.modelNotReady): "Apple Intelligence is still downloading its model."
        case .unavailable: "Apple Intelligence isn't available right now."
        @unknown default: "Apple Intelligence isn't available right now."
        }
    }

    static func guess(recentTranscript: String, previous: LiveBuildingGuess?, courseContext: String) async throws -> LiveBuildingGuess {
        let session = LanguageModelSession(instructions: """
        You help a student during a walking-tour architecture history class. \(courseContext)
        The transcript is produced by speech recognition, so names may be misheard; fix them when obvious.
        """)

        var prompt = "Which building is the professor talking about right now?"
        if let previous, previous.discussingABuilding {
            prompt += " A minute ago it was: \(previous.label)."
        }
        // The on-device model has a small context window, so only the latest words are sent.
        prompt += "\n\nLatest transcript:\n\(recentTranscript.suffix(2000))"

        let response = try await session.respond(to: prompt, generating: LiveBuildingGuess.self)
        return response.content
    }
}
