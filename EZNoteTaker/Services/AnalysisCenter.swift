import Foundation
import SwiftData
import SwiftUI
import UIKit

/// Runs everything that happens automatically after class:
/// 1. sends the lecture to Claude through the Mac relay (Claude Opus 5.5 on the student's subscription),
/// 2. writes an instant on-device draft with Apple Intelligence meanwhile,
/// 3. watches for Claude's result and imports it the moment it arrives.
@MainActor
@Observable
final class AnalysisCenter {
    static let shared = AnalysisCenter()

    struct Progress: Equatable { var done: Int; var total: Int }

    private(set) var drafting: [UUID: Progress] = [:]
    private(set) var relayHeartbeat: Date?
    var toast: String?

    private var draftTasks: [UUID: Task<Void, Never>] = [:]
    private var pollTimer: Timer?

    func isDrafting(_ lecture: Lecture) -> Bool { drafting[lecture.id] != nil }

    private(set) var sending: Set<UUID> = []
    /// Upload progress while sending a class to the cloud relay.
    private(set) var uploads: [UUID: Progress] = [:]
    private var lastCloudPoll = Date.distantPast

    static var relayConfigured: Bool { CloudRelay.isConfigured || ClaudeRelay.isConfigured }

    /// Called when a recording stops.
    func lectureFinished(_ lecture: Lecture, context: ModelContext) {
        if Self.relayConfigured { sendToClaude(lecture, context: context) }
        startDraft(lecture, context: context)
    }

    /// Uploads run one at a time: GitHub rejects simultaneous commits to the same branch.
    private var uploadQueue: Task<Void, Never>?

    /// Hands the lecture to Claude through the cloud (GitHub) relay if set up, otherwise the Mac relay.
    func sendToClaude(_ lecture: Lecture, context: ModelContext) {
        guard !sending.contains(lecture.id) else { return }
        sending.insert(lecture.id)
        let previous = uploadQueue
        uploadQueue = Task {
            await previous?.value
            await upload(lecture, context: context)
        }
    }

    private func upload(_ lecture: Lecture, context: ModelContext) async {
        // Extra time to finish uploading if the phone is locked right after class.
        let background = BackgroundTask(name: "Upload lecture")
        defer { background.end() }
        do {
            if CloudRelay.isConfigured {
                try await CloudRelay.submit(lecture, settings: AppSettings.shared) { done, total in
                    AnalysisCenter.shared.uploads[lecture.id] = Progress(done: done, total: total)
                }
            } else {
                try ClaudeRelay.submit(lecture, settings: AppSettings.shared)
            }
        } catch {
            lecture.claudeJob = .failed
            lecture.claudeJobError = error.localizedDescription
        }
        try? context.save()
        sending.remove(lecture.id)
        uploads[lecture.id] = nil
    }

    /// Classes whose Claude notes were made with older instructions than this version of the app.
    func outdatedLectures(context: ModelContext) -> [Lecture] {
        let lectures = (try? context.fetch(FetchDescriptor<Lecture>(sortBy: [SortDescriptor(\.date)]))) ?? []
        return lectures.filter { $0.isOutdated }
    }

    /// Re-runs Claude on every outdated class, one after another. Notes, stars, study stats and
    /// manual photo choices are kept; the recording, transcript and photos are never touched.
    func updateAll(context: ModelContext) {
        for lecture in outdatedLectures(context: context) { sendToClaude(lecture, context: context) }
    }

    func startDraft(_ lecture: Lecture, context: ModelContext) {
        guard OnDeviceAnalyzer.isAvailable, lecture.analysisSource != .claude, drafting[lecture.id] == nil else { return }
        let id = lecture.id
        let segments = lecture.sortedSegments.map { (start: $0.start, text: $0.text) }
        guard !segments.isEmpty else { return }
        let sorted = lecture.sortedPhotos
        let photos = sorted.enumerated().map { (id: "P\($0.offset + 1)", takenAt: $0.element.takenAt, hint: $0.element.liveHint) }
        let photoOrder = sorted.map { $0.id.uuidString }
        let courseContext = AppSettings.shared.courseContext
        drafting[id] = Progress(done: 0, total: 1)

        draftTasks[id] = Task {
            do {
                let analysis = try await OnDeviceAnalyzer.analyze(segments: segments, photos: photos, courseContext: courseContext) { done, total in
                    if AnalysisCenter.shared.drafting[id] != nil {
                        AnalysisCenter.shared.drafting[id] = Progress(done: done, total: total)
                    }
                }
                // Claude may have finished first — never overwrite its notes with the draft.
                if lecture.modelContext != nil, !lecture.isDeleted, lecture.analysisSource != .claude, !Task.isCancelled {
                    analysis.apply(to: lecture, photoOrder: photoOrder, source: .onDevice, context: context)
                }
            } catch {
                print("On-device draft failed: \(error)")
            }
            drafting[id] = nil
            draftTasks[id] = nil
        }
    }

    /// Imports any finished Claude results. Safe to call often.
    func checkRelay(context: ModelContext, force: Bool = false) {
        guard Self.relayConfigured else { return }
        let waitingRaw = ClaudeJobState.waiting.rawValue
        let descriptor = FetchDescriptor<Lecture>(predicate: #Predicate { $0.claudeJobRaw == waitingRaw })
        guard let waiting = try? context.fetch(descriptor), !waiting.isEmpty else { return }

        if CloudRelay.isConfigured {
            // GitHub is polled at most once a minute (API rate limits).
            guard force || Date().timeIntervalSince(lastCloudPoll) > 55 else { return }
            lastCloudPoll = Date()
            Task {
                for lecture in waiting {
                    handle(await CloudRelay.collect(lecture, context: context), for: lecture, context: context)
                }
                try? context.save()
            }
            return
        }

        relayHeartbeat = ClaudeRelay.lastHeartbeat()
        for lecture in waiting {
            handle(ClaudeRelay.collect(lecture, context: context), for: lecture, context: context)
        }
        try? context.save()
    }

    private func handle(_ result: ClaudeRelay.CheckResult, for lecture: Lecture, context: ModelContext) {
        switch result {
        case .imported(let summary):
            ReferenceImages.fetchMissing(in: [lecture], context: context)
            draftTasks[lecture.id]?.cancel()
            drafting[lecture.id] = nil
            toast = "Claude finished “\(lecture.displayTitle)” — \(summary.buildings) buildings, \(summary.photosPlaced) photos placed"
            Haptics.success()
        case .failed(let message):
            toast = "Claude couldn't process “\(lecture.displayTitle)”: \(message)"
            Haptics.error()
        case .pending:
            break
        }
    }

    /// Deletes a class: its recording, transcript, photos and study notes.
    func delete(_ lecture: Lecture, context: ModelContext) {
        draftTasks[lecture.id]?.cancel()
        draftTasks[lecture.id] = nil
        drafting[lecture.id] = nil
        if let url = lecture.audioURL { try? FileManager.default.removeItem(at: url) }
        for photo in lecture.photos { FileStore.delete(fileName: photo.fileName, in: FileStore.photoDirectory) }
        context.delete(lecture)
        try? context.save()
    }

    func startPolling(context: ModelContext) {
        checkRelay(context: context)
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            Task { @MainActor in AnalysisCenter.shared.checkRelay(context: context) }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

/// Asks iOS for extra running time (e.g. to finish an upload after the phone is locked).
@MainActor
final class BackgroundTask {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

extension Lecture {
    /// True when Claude made these notes with older instructions than this version of the app.
    var isOutdated: Bool {
        analysisSource == .claude && analysisVersion < ClaudeRelay.promptVersion && claudeJob != .waiting
    }
}
