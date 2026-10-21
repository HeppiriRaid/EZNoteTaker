import SwiftData
import SwiftUI

struct LectureListView: View {
    let startRecording: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings
    @Environment(RecordingSession.self) private var recorder
    @Environment(AnalysisCenter.self) private var analysis
    @Query(sort: \Lecture.date, order: .reverse) private var lectures: [Lecture]
    @Query private var buildings: [Building]
    @Query private var photos: [LecturePhoto]
    @State private var pendingDelete: [Lecture] = []
    @State private var selecting = false
    @State private var selected: Set<UUID> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if lectures.isEmpty {
                        emptyState
                    } else {
                        ForEach(lectures) { lecture in
                            if selecting {
                                Button { toggleSelection(lecture) } label: {
                                    LectureCard(lecture: lecture, week: ClassWeek.number(of: lecture, in: lectures))
                                        .overlay(alignment: .topTrailing) {
                                            Image(systemName: selected.contains(lecture.id) ? "checkmark.circle.fill" : "circle")
                                                .font(.title2)
                                                .foregroundStyle(selected.contains(lecture.id) ? Theme.recordRed : .secondary)
                                                .padding(12)
                                        }
                                        .opacity(isRecording(lecture) ? 0.4 : 1)
                                }
                                .buttonStyle(.plain)
                                .disabled(isRecording(lecture))
                            } else {
                                NavigationLink(value: lecture) {
                                    LectureCard(lecture: lecture, week: ClassWeek.number(of: lecture, in: lectures))
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    if !isRecording(lecture) {
                                        Button("Delete Class", systemImage: "trash", role: .destructive) { pendingDelete = [lecture] }
                                    }
                                }
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
            .overlay(alignment: .bottom) {
                if selecting { deleteBar } else { recordButton }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !lectures.isEmpty {
                        Button(selecting ? "Done" : "Edit") {
                            withAnimation(.snappy) {
                                selecting.toggle()
                                selected = []
                            }
                        }
                    }
                }
            }
            .confirmationDialog(
                pendingDelete.count == 1 ? "Delete this class?" : "Delete \(pendingDelete.count) classes?",
                isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }),
                titleVisibility: .visible
            ) {
                Button("Delete recording, transcript, photos and notes", role: .destructive) { deletePending() }
                Button("Cancel", role: .cancel) { pendingDelete = [] }
            } message: {
                Text("This can't be undone.")
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

    private var deleteBar: some View {
        Button(role: .destructive) {
            pendingDelete = lectures.filter { selected.contains($0.id) }
        } label: {
            Label(selected.isEmpty ? "Select classes to delete" : "Delete \(selected.count)", systemImage: "trash")
                .font(.headline)
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .foregroundStyle(.white)
                .background((selected.isEmpty ? Color.gray : Theme.recordRed).gradient, in: Capsule())
        }
        .disabled(selected.isEmpty)
        .padding(.bottom, 16)
    }

    private func isRecording(_ lecture: Lecture) -> Bool { recorder.lecture?.id == lecture.id }

    private func toggleSelection(_ lecture: Lecture) {
        if selected.contains(lecture.id) { selected.remove(lecture.id) } else { selected.insert(lecture.id) }
        Haptics.light()
    }

    private func deletePending() {
        for lecture in pendingDelete where !isRecording(lecture) {
            analysis.delete(lecture, context: context)
        }
        pendingDelete = []
        selected = []
        selecting = false
        Haptics.success()
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
    var week: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text((week.map { "Week \($0) · " } ?? "") + lecture.date.formatted(.dateTime.weekday(.wide).month().day()))
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
