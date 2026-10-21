import AVFoundation
import Foundation

/// Owns the microphone. Every captured buffer is written to an .m4a file (so you can re-listen later)
/// and handed to the transcriber. Deliberately *not* main-actor isolated: the tap runs on an audio thread.
final class AudioCaptureEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private let lock = NSLock()
    private var isPaused = false

    /// Called on the audio thread for every buffer while not paused.
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// Called on the audio thread with a 0...1 loudness value for the level meter.
    var onLevel: (@Sendable (Float) -> Void)?

    private(set) var inputFormat: AVAudioFormat?
    /// Seconds of audio captured so far (pauses excluded) — the shared clock for transcript and photos.
    private(set) var capturedSeconds: Double = 0

    static func configureSessionForRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [])
        try session.setActive(true, options: [])
    }

    func start(writingTo url: URL) throws {
        try Self.configureSessionForRecording()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "EZNoteTaker", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No microphone input is available."])
        }
        inputFormat = format

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let paused = isPaused
        lock.unlock()
        guard !paused else { return }

        try? file?.write(from: buffer)
        capturedSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
        onLevel?(Self.level(of: buffer))
        onBuffer?(buffer)
    }

    func setPaused(_ paused: Bool) {
        lock.lock()
        isPaused = paused
        lock.unlock()
        onLevel?(0)
    }

    /// Restarts the engine after an interruption such as a phone call.
    func resumeAfterInterruption() {
        guard !engine.isRunning else { return }
        try? Self.configureSessionForRecording()
        try? engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil // closes and finalizes the m4a
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(count))
        let db = 20 * log10(max(rms, 0.000_01))
        // Map -55 dB...-5 dB to 0...1
        return min(max((db + 55) / 50, 0), 1)
    }
}
