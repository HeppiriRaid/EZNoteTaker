import AVFoundation
import Foundation
import SwiftData
import UIKit

/// Drives one live class recording: microphone → audio file + live transcript, photos, stop markers
/// and the on-device "now discussing" guess. Everything is saved into a `Lecture` as it happens,
/// so nothing is lost if the app is killed mid-class.
@MainActor
@Observable
final class RecordingSession {
    enum Phase: Equatable {
        case idle
        case preparing(String)
        case recording
        case paused
        case finishing
        case failed(String)
    }

    struct LiveLine: Identifiable {
        let id = UUID()
        let start: Double
        let text: String
        /// Set for photo stops shown inline in the live transcript.
        var photoFile: String? = nil
    }

    private(set) var phase: Phase = .idle
    private(set) var elapsed: Double = 0
    private(set) var level: Float = 0
    private(set) var levelHistory: [Float] = Array(repeating: 0, count: 40)
    private(set) var lines: [LiveLine] = []
    private(set) var volatileText = ""
    private(set) var photoCount = 0
    private(set) var recentPhotos: [LecturePhoto] = []
    private(set) var markerCount = 0
    private(set) var currentGuess: LiveBuildingGuess?
    private(set) var engineName = ""
    private(set) var lecture: Lecture?

    private let audio = AudioCaptureEngine()
    private var transcriber: LiveTranscriber?
    private var context: ModelContext?
    private var clock: Timer?
    private var detectionTask: Task<Void, Never>?
    private var lastSave = Date()
    private var interruptionObserver: NSObjectProtocol?

    var isActive: Bool {
        switch phase {
        case .idle, .failed: false
        default: true
        }
    }

    // MARK: Start

    func start(context: ModelContext, settings: AppSettings) async {
        guard !isActive else { return }
        self.context = context
        phase = .preparing("Checking microphone…")

        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .failed("Microphone access is off. Enable it in Settings › EZNoteTaker.")
            return
        }

        phase = .preparing("Loading speech model… (first time can take a minute)")
        let locale = Locale(identifier: settings.localeIdentifier)
        do {
            let transcriber = try await TranscriberFactory.make(locale: locale, vocabulary: settings.vocabularyList)
            transcriber.onUpdate = { [weak self] update in
                Task { @MainActor in self?.handle(update) }
            }
            self.transcriber = transcriber
            engineName = transcriber.engineName
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        let lecture = Lecture(localeIdentifier: settings.localeIdentifier)
        let fileName = FileStore.newAudioFileName()
        lecture.audioFileName = fileName
        lecture.status = .recording
        context.insert(lecture)
        try? context.save()
        self.lecture = lecture

        let transcriber = self.transcriber
        audio.onBuffer = { buffer in transcriber?.append(buffer) }
        audio.onLevel = { [weak self] value in
            Task { @MainActor in self?.pushLevel(value) }
        }

        do {
            try audio.start(writingTo: FileStore.audioDirectory.appendingPathComponent(fileName))
        } catch {
            context.delete(lecture)
            self.lecture = nil
            phase = .failed("Couldn't start recording: \(error.localizedDescription)")
            return
        }

        LocationProvider.shared.start()
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
        observeInterruptions()
        phase = .recording
        Haptics.success()

        clock = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if settings.liveDetection, LiveBuildingDetector.isAvailable {
            startLiveDetection(courseContext: settings.courseContext)
        }
    }

    // MARK: Live updates

    private func handle(_ update: TranscriptUpdate) {
        switch update {
        case .volatile(let text):
            volatileText = text
        case .final(let text, let start):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            volatileText = ""
            guard !trimmed.isEmpty else { return }
            let time = start ?? max(elapsed - 5, 0)
            lines.append(LiveLine(start: time, text: trimmed))
            if let lecture, let context {
                let segment = TranscriptSegment(start: time, text: trimmed)
                context.insert(segment)
                segment.lecture = lecture
            }
        }
    }

    private func tick() {
        elapsed = audio.activeSeconds
        // Keep recording no matter what (camera, notifications, calls): only the Pause button stops it.
        if phase == .recording { audio.ensureRunning() }
        lecture?.durationSeconds = elapsed
        if Date().timeIntervalSince(lastSave) > 20 {
            try? context?.save()
            lastSave = Date()
        }
    }

    private func pushLevel(_ value: Float) {
        level = value
        levelHistory.removeFirst()
        levelHistory.append(value)
    }

    private func startLiveDetection(courseContext: String) {
        detectionTask = Task { [weak self] in
            var lastLength = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(40))
                guard let self, !Task.isCancelled else { return }
                guard self.phase == .recording else { continue }
                let recent = self.recentTranscript(characters: 2000)
                let length = self.lines.reduce(0) { $0 + $1.text.count } + self.volatileText.count
                guard recent.count > 200, length - lastLength > 150 else { continue }
                lastLength = length
                if let guess = try? await LiveBuildingDetector.guess(recentTranscript: recent, previous: self.currentGuess,
                                                                     courseContext: courseContext) {
                    if guess.discussingABuilding, !guess.name.isEmpty {
                        if guess.name != self.currentGuess?.name { Haptics.light() }
                        self.currentGuess = guess
                    }
                }
            }
        }
    }

    func recentTranscript(characters: Int) -> String {
        var text = ""
        for line in lines.reversed() {
            text = line.text + " " + text
            if text.count > characters { break }
        }
        return String((text + volatileText).suffix(characters))
    }

    // MARK: Actions

    func addPhoto(_ image: UIImage) {
        guard let lecture, let context else { return }
        do {
            let name = try FileStore.savePhoto(image)
            let photo = LecturePhoto(fileName: name, takenAt: elapsed)
            if let coordinate = LocationProvider.shared.current {
                photo.latitude = coordinate.latitude
                photo.longitude = coordinate.longitude
            }
            photo.liveHint = currentGuess?.label ?? ""
            context.insert(photo)
            photo.lecture = lecture
            try? context.save()
            photoCount += 1
            recentPhotos.insert(photo, at: 0)
            // The photo marks a stop in the live transcript, with what was being discussed.
            let about = currentGuess.map { "Now discussing: \($0.label)" }
                ?? "“…\(recentTranscript(characters: 140).trimmingCharacters(in: .whitespaces))”"
            lines.append(LiveLine(start: elapsed, text: about, photoFile: name))
            if recentPhotos.count > 8 { recentPhotos.removeLast() }
            Haptics.tap()
        } catch {
            Haptics.error()
        }
    }

    func addMarker(label: String) {
        guard let lecture, let context else { return }
        let marker = StopMarker(time: elapsed, label: label.trimmingCharacters(in: .whitespaces))
        if let coordinate = LocationProvider.shared.current {
            marker.latitude = coordinate.latitude
            marker.longitude = coordinate.longitude
        }
        context.insert(marker)
        marker.lecture = lecture
        markerCount += 1
        lines.append(LiveLine(start: elapsed, text: "📍 New stop\(label.isEmpty ? "" : ": \(label)")"))
        try? context.save()
        Haptics.tap()
    }

    func togglePause() {
        switch phase {
        case .recording:
            audio.setPaused(true)
            phase = .paused
        case .paused:
            audio.ensureRunning()
            audio.setPaused(false)
            phase = .recording
        default:
            return
        }
        Haptics.light()
    }

    /// Stops and saves. Returns the finished lecture.
    @discardableResult
    func stop() async -> Lecture? {
        guard isActive, phase != .finishing else { return nil }
        phase = .finishing
        clock?.invalidate()
        detectionTask?.cancel()
        audio.stop()
        await transcriber?.finish()

        if !volatileText.trimmingCharacters(in: .whitespaces).isEmpty {
            handle(.final(text: volatileText, start: max(elapsed - 10, 0)))
        }
        cleanUp()

        guard let lecture else { phase = .idle; return nil }
        lecture.durationSeconds = elapsed
        lecture.status = .transcribed
        try? context?.save()
        let finished = lecture
        reset()
        Haptics.success()
        return finished
    }

    /// Stops and deletes everything recorded in this session.
    func discard() async {
        clock?.invalidate()
        detectionTask?.cancel()
        audio.stop()
        await transcriber?.finish()
        cleanUp()
        if let lecture, let context {
            if let url = lecture.audioURL { try? FileManager.default.removeItem(at: url) }
            for photo in lecture.photos { FileStore.delete(fileName: photo.fileName, in: FileStore.photoDirectory) }
            context.delete(lecture)
            try? context.save()
        }
        reset()
    }

    func dismissError() { if case .failed = phase { phase = .idle } }

    private func cleanUp() {
        LocationProvider.shared.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
    }

    private func reset() {
        phase = .idle
        lecture = nil
        transcriber = nil
        lines = []
        volatileText = ""
        elapsed = 0
        photoCount = 0
        recentPhotos = []
        markerCount = 0
        currentGuess = nil
        levelHistory = Array(repeating: 0, count: 40)
    }

    /// Phone calls, Siri etc. can cut off the microphone. The recording keeps going (only the Pause
    /// button pauses it); the microphone is reconnected as soon as the interruption ends, and the
    /// gap is filled with silence so the timeline stays correct.
    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            Task { @MainActor in
                guard let self, self.phase == .recording else { return }
                self.audio.ensureRunning()
            }
        }
    }
}
