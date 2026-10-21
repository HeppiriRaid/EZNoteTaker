import SwiftData
import SwiftUI

struct LectureListView: View {
    let startRecording: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings
    @Query(sort: \Lecture.date, order: .reverse) private var lectures: [Lecture]
    @Query private var buildings: [Building]
    @Query private var photos: [LecturePhoto]
    @State private var pendingDelete: Lecture?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if lectures.isEmpty {
                        emptyState
                    } else {
                        ForEach(lectures) { lecture in
                            NavigationLink(value: lecture) {
                                LectureCard(lecture: lecture)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Delete Class", systemImage: "trash", role: .destructive) { pendingDelete = lecture }
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 120)
            }
            .background(Theme.paper)
            .navigationTitle(settings.courseName.isEmpty ? "Classes" : settings.courseName)
            .navigationDestination(for: Lecture.self) { LectureDetailView(lecture: $0) }
            .overlay(alignment: .bottom) { recordButton }
            .confirmationDialog("Delete this class?", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
            ), presenting: pendingDelete) { lecture in
                Button("Delete recording, transcript and photos", role: .destructive) { delete(lecture) }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            StatTile(value: lectures.count, label: "Classes", systemImage: "calendar")
            StatTile(value: buildings.count, label: "Buildings", systemImage: "building.2")
            StatTile(value: photos.count, label: "Photos", systemImage: "camera")
        }
        .padding(.top, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "building.columns.circle")
                .font(.system(size: 64))
                .foregroundStyle(Theme.brick)
            Text("Ready for class")
                .font(.serifTitle(24))
            Text("Tap **Record Class** when the walking tour starts. EZNoteTaker transcribes the professor live, lets you snap photos of each building, and turns everything into a summary and an exam cheat sheet automatically.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .card()
    }

    private var recordButton: some View {
        Button(action: startRecording) {
            Label("Record Class", systemImage: "mic.fill")
                .font(.headline)
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .foregroundStyle(.white)
                .background(Theme.recordRed.gradient, in: Capsule())
                .shadow(color: Theme.recordRed.opacity(0.35), radius: 14, y: 6)
        }
        .padding(.bottom, 16)
        .sensoryFeedback(.impact, trigger: lectures.count)
    }

    private func delete(_ lecture: Lecture) {
        if let url = lecture.audioURL { try? FileManager.default.removeItem(at: url) }
        for photo in lecture.photos { FileStore.delete(fileName: photo.fileName, in: FileStore.photoDirectory) }
        context.delete(lecture)
        try? context.save()
        pendingDelete = nil
    }
}

private struct StatTile: View {
    let value: Int
    let label: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: systemImage).foregroundStyle(Theme.brick)
            Text("\(value)").font(.serifTitle(26)).contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
    }
}

struct LectureCard: View {
    let lecture: Lecture

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lecture.date.formatted(.dateTime.weekday(.wide).month().day()))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.brick)
                        .textCase(.uppercase)
                    Text(lecture.displayTitle)
                        .font(.serifHeadline())
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                StatusBadge(lecture: lecture)
            }

            if !lecture.overview.isEmpty {
                RichText(lecture.overview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if !lecture.buildings.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(lecture.sortedBuildings) { b in
                            Pill(text: b.name, systemImage: "building.2", color: Theme.brick)
                        }
                    }
                }
            }

            let photos = lecture.sortedPhotos
            if !photos.isEmpty {
                HStack(spacing: 6) {
                    ForEach(photos.prefix(5)) { photo in
                        PhotoThumb(fileName: photo.fileName, maxPixel: 200)
                            .frame(width: 54, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    if photos.count > 5 {
                        Text("+\(photos.count - 5)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 14) {
                Label(TimeFormat.duration(lecture.durationSeconds), systemImage: "clock")
                Label("\(lecture.buildings.count)", systemImage: "building.2")
                Label("\(lecture.photos.count)", systemImage: "camera")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct StatusBadge: View {
    let lecture: Lecture
    @Environment(AnalysisCenter.self) private var analysis

    var body: some View {
        if lecture.status == .recording {
            Pill(text: "Recording", systemImage: "record.circle", color: Theme.recordRed)
        } else if lecture.claudeJob == .waiting {
            Pill(text: "Claude is writing…", systemImage: "hourglass", color: Theme.gold)
        } else if analysis.isDrafting(lecture) {
            Pill(text: "Drafting…", systemImage: "sparkles", color: Theme.gold)
        } else if lecture.analysisSource == .claude {
            Pill(text: "Opus 5.5", systemImage: "checkmark.seal.fill", color: Theme.sage)
        } else if lecture.analysisSource == .onDevice {
            Pill(text: "Draft", systemImage: "sparkles", color: .secondary)
        } else if lecture.claudeJob == .failed {
            Pill(text: "Needs retry", systemImage: "exclamationmark.triangle", color: Theme.recordRed)
        } else {
            Pill(text: "Transcript", systemImage: "text.alignleft", color: .secondary)
        }
    }
}
