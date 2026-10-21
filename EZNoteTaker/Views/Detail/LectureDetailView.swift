import SwiftData
import SwiftUI

struct LectureDetailView: View {
    @Bindable var lecture: Lecture
    @Environment(AnalysisCenter.self) private var analysis
    @Environment(\.modelContext) private var context
    @State private var tab: DetailTab = .summary
    @State private var renaming = false
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss
    @Environment(RecordingSession.self) private var recorder
    @State private var newTitle = ""

    enum DetailTab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case buildings = "Buildings"
        case transcript = "Transcript"
        case photos = "Photos"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                AnalysisStatusCard(lecture: lecture)
                Picker("Section", selection: $tab) {
                    ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                switch tab {
                case .summary: SummaryTab(lecture: lecture)
                case .buildings: BuildingsTab(lecture: lecture)
                case .transcript: TranscriptTab(lecture: lecture)
                case .photos: PhotosTab(lecture: lecture)
                }
            }
            .padding()
        }
        .background(Theme.paper)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Rename", systemImage: "pencil") {
                        newTitle = lecture.title
                        renaming = true
                    }
                    ShareLink(item: ShareText.lecture(lecture)) {
                        Label("Share Notes", systemImage: "square.and.arrow.up")
                    }
                    if recorder.lecture?.id != lecture.id {
                        Divider()
                        Button("Delete Class", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Delete this class?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete recording, transcript, photos and notes", role: .destructive) {
                dismiss()
                // Delete after leaving the screen so it never shows a removed class.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    analysis.delete(lecture, context: context)
                    Haptics.success()
                }
            }
        } message: {
            Text("This can't be undone.")
        }
        .alert("Rename class", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Save") { lecture.title = newTitle; try? context.save() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(lecture.date.formatted(date: .complete, time: .shortened))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.brick)
                .textCase(.uppercase)
            Text(lecture.displayTitle).font(.serifTitle())
            HStack(spacing: 14) {
                Label(TimeFormat.duration(lecture.durationSeconds), systemImage: "clock")
                Label("\(lecture.buildings.count) buildings", systemImage: "building.2")
                Label("\(lecture.photos.count) photos", systemImage: "camera")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Status

/// Shows where the study notes came from and what is happening in the background.
struct AnalysisStatusCard: View {
    let lecture: Lecture
    @Environment(AnalysisCenter.self) private var analysis
    @Environment(\.modelContext) private var context

    var body: some View {
        if analysis.sending.contains(lecture.id) {
            let upload = analysis.uploads[lecture.id]
            VStack(alignment: .leading, spacing: 8) {
                Label("Sending this class to Claude…", systemImage: "icloud.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.gold)
                ProgressView(value: Double(upload?.done ?? 0), total: Double(max(upload?.total ?? 1, 1)))
                Text(upload.map { "Uploading \($0.done) of \($0.total) files. Keep the app open until this finishes." }
                     ?? "Preparing the transcript and photos…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        } else if lecture.claudeJob == .waiting {
            ClaudeWaitingCard(lecture: lecture, heartbeat: analysis.relayHeartbeat)
        } else if let progress = analysis.drafting[lecture.id] {
            VStack(alignment: .leading, spacing: 8) {
                Label("Writing an instant on-device draft…", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
            }
            .card()
        } else if lecture.claudeJob == .failed {
            status(icon: "exclamationmark.triangle.fill", color: Theme.recordRed,
                   title: "Claude couldn't finish this class",
                   detail: lecture.claudeJobError ?? "Unknown error") {
                Button("Try Again") { analysis.sendToClaude(lecture, context: context) }
            }
        } else if lecture.analysisSource == .onDevice && lecture.claudeJob == .notSent {
            status(icon: "sparkles", color: .secondary,
                   title: "On-device draft",
                   detail: AnalysisCenter.relayConfigured
                       ? "Send it to Claude Opus 5.5 for verified names, years and architects."
                       : "Set up the Claude relay in Settings to get Opus 5.5 notes automatically.") {
                if AnalysisCenter.relayConfigured {
                    Button("Send to Claude") { analysis.sendToClaude(lecture, context: context) }
                }
            }
        } else if lecture.analysisSource == .none && lecture.status != .recording {
            status(icon: "text.alignleft", color: .secondary,
                   title: "Transcript ready",
                   detail: "Make the summary and cheat sheet for this class.") {
                HStack {
                    if AnalysisCenter.relayConfigured {
                        Button("Send to Claude") { analysis.sendToClaude(lecture, context: context) }
                    }
                    if OnDeviceAnalyzer.isAvailable {
                        Button("On-device draft") { analysis.startDraft(lecture, context: context) }
                    }
                }
            }
        }
    }


    private func status<Actions: View>(icon: String, color: Color, title: String, detail: String,
                                       @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color == .secondary ? Color.primary : color)
            Text(detail).font(.caption).foregroundStyle(.secondary)
            actions().buttonStyle(.bordered).controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// Shown while Claude works on the class. It updates by itself: the app checks for the result every
/// minute and imports it automatically, so there is nothing to tap.
struct ClaudeWaitingCard: View {
    let lecture: Lecture
    let heartbeat: Date?

    /// Rough duration from real classes: ~10 minutes for a 1 h 45 min walk with ~40 photos.
    private var expectedSeconds: Double {
        max(180, 60 + Double(lecture.photos.count) * 8 + lecture.durationSeconds * 0.05)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let started = lecture.claudeJobSentAt ?? context.date
            let elapsed = context.date.timeIntervalSince(started)
            VStack(alignment: .leading, spacing: 8) {
                Label("Claude Opus 5.5 is writing your study notes", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.gold)
                ProgressView(value: min(elapsed / expectedSeconds, 0.95))
                    .tint(Theme.gold)
                Text(statusText(elapsed: elapsed))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    private func statusText(elapsed: Double) -> String {
        let minutes = Int(elapsed / 60)
        let expected = Int((expectedSeconds / 60).rounded())
        var text = elapsed < expectedSeconds
            ? "\(minutes) of about \(expected) min. "
            : "Taking a little longer than usual (\(minutes) min). "
        text += "The notes appear here automatically — you can leave this screen or close the app."
        if let heartbeat, Date().timeIntervalSince(heartbeat) > 900 {
            text += " Your Mac relay hasn't checked in since \(heartbeat.formatted(date: .omitted, time: .shortened)) — is the Mac on?"
        }
        return text
    }
}

// MARK: - Summary

struct SummaryTab: View {
    let lecture: Lecture
    @State private var revealed: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if lecture.overview.isEmpty && lecture.summarySections.isEmpty {
                ContentUnavailableView("No summary yet", systemImage: "text.badge.star",
                                       description: Text("It's created automatically after class."))
            }

            if !lecture.overview.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(title: "Overview", systemImage: "text.quote")
                    RichText(lecture.overview).font(.body)
                }
                .card()
            }

            if !lecture.keyTakeaways.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(title: "Key takeaways", systemImage: "star")
                    BulletList(items: lecture.keyTakeaways, symbol: "checkmark.circle.fill", color: Theme.sage)
                }
                .card()
            }

            ForEach(lecture.summarySections) { section in
                VStack(alignment: .leading, spacing: 10) {
                    Text(section.heading).font(.serifHeadline())
                    if !section.body.isEmpty { RichText(section.body) }
                    if !section.bullets.isEmpty { BulletList(items: section.bullets) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }

            if !lecture.keyTerms.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(title: "Key terms", systemImage: "character.book.closed")
                    ForEach(lecture.keyTerms) { term in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(term.term).font(.subheadline.weight(.bold))
                            RichText(term.definition).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }

            if !lecture.examQuestions.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(title: "Practice questions — tap to reveal", systemImage: "questionmark.bubble")
                    ForEach(lecture.examQuestions) { q in
                        Button {
                            withAnimation(.snappy) {
                                if revealed.contains(q.id) { revealed.remove(q.id) } else { revealed.insert(q.id) }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                RichText(q.question).font(.subheadline.weight(.semibold))
                                if revealed.contains(q.id) {
                                    RichText(q.answer).font(.subheadline).foregroundStyle(Theme.sage)
                                } else {
                                    Text("Show answer").font(.caption).foregroundStyle(Theme.brick)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Theme.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .card()
            }

            if lecture.correctionsApplied > 0 {
                Label("\(lecture.correctionsApplied) misheard names were fixed in the transcript.", systemImage: "wand.and.stars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Buildings

struct BuildingsTab: View {
    let lecture: Lecture

    var body: some View {
        VStack(spacing: 12) {
            if lecture.buildings.isEmpty {
                ContentUnavailableView("No buildings yet", systemImage: "building.2",
                                       description: Text("Buildings discussed in class appear here with their photos."))
            }
            ForEach(Array(lecture.sortedBuildings.enumerated()), id: \.element.id) { index, building in
                NavigationLink {
                    BuildingDetailView(building: building)
                } label: {
                    BuildingRow(building: building, number: index + 1)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct BuildingRow: View {
    let building: Building
    var number: Int?

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let photo = building.sortedPhotos.first {
                        PhotoThumb(fileName: photo.fileName, maxPixel: 240)
                    } else {
                        Rectangle().fill(Theme.brick.opacity(0.12))
                            .overlay(Image(systemName: "building.columns").font(.title2).foregroundStyle(Theme.brick))
                    }
                }
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                if let number {
                    Text("\(number)")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Theme.brick, in: Circle())
                        .offset(x: -6, y: -6)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(building.name).font(.headline).lineLimit(2)
                    if building.isStarred { Image(systemName: "star.fill").font(.caption).foregroundStyle(Theme.gold) }
                }
                Text("\(building.architectDisplay) · \(building.yearDisplay)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if building.importance == .high {
                        Pill(text: "Likely on exam", systemImage: "flame.fill", color: Theme.recordRed)
                    }
                    if !building.photos.isEmpty {
                        Pill(text: "\(building.photos.count)", systemImage: "camera.fill")
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .card(padding: 12)
    }
}
