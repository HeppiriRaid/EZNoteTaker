import AVFoundation
import CoreMedia
import Foundation
import Speech

enum TranscriptUpdate {
    /// In-progress words that may still change (shown in gray).
    case volatile(String)
    /// Finished text. `start` is seconds into the recording when known.
    case final(text: String, start: Double?)
}

/// Common interface for the two on-device speech engines.
protocol LiveTranscriber: AnyObject, Sendable {
    /// May be called from any thread.
    var onUpdate: (@Sendable (TranscriptUpdate) -> Void)? { get set }
    var engineName: String { get }
    func prepare(locale: Locale, vocabulary: [String]) async throws
    /// Called on the audio thread.
    func append(_ buffer: AVAudioPCMBuffer)
    func finish() async
}

enum TranscriberFactory {
    /// Prefers Apple's new long-form SpeechAnalyzer (iOS 26), which is built for lectures and meetings.
    /// Falls back to SFSpeechRecognizer when the locale or device isn't supported.
    static func make(locale: Locale, vocabulary: [String]) async throws -> LiveTranscriber {
        await requestSpeechAuthorization()
        if await AnalyzerTranscriber.supports(locale: locale) {
            let analyzer = AnalyzerTranscriber()
            do {
                try await analyzer.prepare(locale: locale, vocabulary: vocabulary)
                return analyzer
            } catch {
                print("SpeechAnalyzer unavailable, falling back: \(error)")
            }
        }
        let legacy = LegacyTranscriber()
        try await legacy.prepare(locale: locale, vocabulary: vocabulary)
        return legacy
    }

    static func requestSpeechAuthorization() async {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
        }
    }
}

// MARK: - SpeechAnalyzer (iOS 26+)

final class AnalyzerTranscriber: LiveTranscriber, @unchecked Sendable {
    var onUpdate: (@Sendable (TranscriptUpdate) -> Void)?
    let engineName = "Apple SpeechAnalyzer (on-device, long-form)"

    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var resultsTask: Task<Void, Never>?

    static func supports(locale: Locale) async -> Bool {
        let wanted = locale.identifier(.bcp47).lowercased()
        let supported = await SpeechTranscriber.supportedLocales
        return supported.contains { $0.identifier(.bcp47).lowercased() == wanted }
    }

    func prepare(locale: Locale, vocabulary: [String]) async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )

        // Downloads the on-device language model the first time (a few hundred MB, once).
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        let start = result.range.start.seconds
                        self?.onUpdate?(.final(text: text, start: start.isFinite ? start : nil))
                    } else {
                        self?.onUpdate?(.volatile(text))
                    }
                }
            } catch {
                print("Transcription results ended with error: \(error)")
            }
        }

        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let inputContinuation, let analyzerFormat else { return }
        // Always convert: it both matches the analyzer's format and copies the buffer,
        // which the audio engine reuses after the tap returns.
        guard let converted = AudioConversion.convert(buffer, to: analyzerFormat, using: &converter) else { return }
        inputContinuation.yield(AnalyzerInput(buffer: converted))
    }

    func finish() async {
        inputContinuation?.finish()
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            print("Finalize failed: \(error)")
        }
        // Let the last results drain, but never hang the UI for long.
        let drain = resultsTask
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await drain?.value }
            group.addTask { try? await Task.sleep(for: .seconds(6)) }
            await group.next()
            group.cancelAll()
        }
    }
}

// MARK: - SFSpeechRecognizer fallback

/// Fallback engine. SFSpeechRecognizer isn't designed for hour-long audio, so the stream is
/// split into ~50 second requests; each finished request becomes one transcript segment.
final class LegacyTranscriber: LiveTranscriber, @unchecked Sendable {
    var onUpdate: (@Sendable (TranscriptUpdate) -> Void)?
    let engineName = "Apple Speech (on-device)"

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var vocabulary: [String] = []
    private var fedSeconds: Double = 0
    private var requestStart: Double = 0
    private var finishing = false
    private let lock = NSLock()
    private let chunkLength: Double = 50

    func prepare(locale: Locale, vocabulary: [String]) async throws {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw NSError(domain: "EZNoteTaker", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Speech recognition permission is off. Enable it in Settings › EZNoteTaker.",
            ])
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw NSError(domain: "EZNoteTaker", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Speech recognition isn't available for \(locale.identifier) on this device.",
            ])
        }
        self.recognizer = recognizer
        self.vocabulary = Array(vocabulary.prefix(100))
        startRequest()
    }

    private func startRequest() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.contextualStrings = vocabulary
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        let offset = fedSeconds
        requestStart = fedSeconds
        let state = RequestState()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    if !state.delivered, !text.isEmpty {
                        state.delivered = true
                        self.onUpdate?(.final(text: text, start: offset))
                    }
                } else {
                    state.lastPartial = text
                    self.onUpdate?(.volatile(text))
                }
            } else if error != nil, !state.delivered, !state.lastPartial.isEmpty {
                state.delivered = true
                self.onUpdate?(.final(text: state.lastPartial, start: offset))
            }
        }
        self.request = request
    }

    private final class RequestState: @unchecked Sendable {
        var lastPartial = ""
        var delivered = false
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !finishing else { return }
        request?.append(buffer)
        fedSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
        if fedSeconds - requestStart > chunkLength {
            request?.endAudio()
            startRequest()
        }
    }

    func finish() async {
        lock.lock()
        finishing = true
        request?.endAudio()
        lock.unlock()
        try? await Task.sleep(for: .seconds(2))
        task?.cancel()
    }
}

// MARK: - Conversion helper

enum AudioConversion {
    static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat,
                        using converter: inout AVAudioConverter?) -> AVAudioPCMBuffer? {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        final class Once: @unchecked Sendable { var consumed = false }
        let once = Once()
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if once.consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            once.consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
