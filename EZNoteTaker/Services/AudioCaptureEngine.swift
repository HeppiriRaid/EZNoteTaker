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
    private var activeAccumulated: Double = 0
    private var activeSince: Date?
    private var configObserver: NSObjectProtocol?

    /// Wall-clock recording time, excluding the student's own pauses. Always moves forward while recording,
    /// even if the microphone is briefly cut off; such gaps are filled with silence so the audio,
    /// transcript and photo times stay in sync.
    var activeSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return activeAccumulated + (activeSince.map { Date().timeIntervalSince($0) } ?? 0)
    }

    static func configureSessionForRecording() throws {
        let session = AVAudioSession.sharedInstance()
        // playAndRecord + mixWithOthers: the camera and its shutter sound can't interrupt the recording.
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
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

        installTap()
        engine.prepare()
        try engine.start()
        lock.lock()
        activeSince = Date()
        lock.unlock()

        // The engine stops itself when the audio hardware is reconfigured (e.g. by the camera); restart it.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.ensureRunning()
        }
    }

    private func installTap() {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
    }

    /// Restarts the microphone if anything stopped it. Safe to call often.
    func ensureRunning() {
        guard !engine.isRunning, file != nil else { return }
        try? Self.configureSessionForRecording()
        installTap()
        engine.prepare()
        try? engine.start()
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let paused = isPaused
        lock.unlock()
        guard !paused else { return }

        // If the microphone was cut off for a moment, fill the gap with silence.
        let gap = activeSeconds - capturedSeconds
        if gap > 1.5 { writeSilence(seconds: min(gap - 0.1, 3600), format: buffer.format) }

        try? file?.write(from: buffer)
        capturedSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
        onLevel?(Self.level(of: buffer))
        onBuffer?(buffer)
    }

    private func writeSilence(seconds: Double, format: AVAudioFormat) {
        var remaining = AVAudioFrameCount(seconds * format.sampleRate)
        let chunk = AVAudioFrameCount(format.sampleRate) // one second at a time
        while remaining > 0 {
            let frames = min(chunk, remaining)
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            silence.frameLength = frames
            let buffers = UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList)
            for buffer in buffers {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            try? file?.write(from: silence)
            capturedSeconds += Double(frames) / format.sampleRate
            onBuffer?(silence)
            remaining -= frames
        }
    }

    func setPaused(_ paused: Bool) {
        lock.lock()
        isPaused = paused
        if paused {
            activeAccumulated += activeSince.map { Date().timeIntervalSince($0) } ?? 0
            activeSince = nil
        } else if activeSince == nil {
            activeSince = Date()
        }
        lock.unlock()
        onLevel?(0)
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        setPaused(true)
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
