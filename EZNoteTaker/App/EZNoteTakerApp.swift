import SwiftData
import SwiftUI

@main
struct EZNoteTakerApp: App {
    let container: ModelContainer = {
        let schema = Schema([Lecture.self, TranscriptSegment.self, Building.self, LecturePhoto.self, StopMarker.self])
        do {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema))
        } catch {
            fatalError("Could not open the database: \(error)")
        }
    }()

    @State private var recorder = RecordingSession()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(recorder)
                .environment(AppSettings.shared)
                .environment(AnalysisCenter.shared)
                .tint(Theme.brick)
        }
        .modelContainer(container)
    }
}

struct RootView: View {
    @Environment(RecordingSession.self) private var recorder
    @Environment(AnalysisCenter.self) private var analysis
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("selectedTab") private var tab = 0
    @State private var showRecorder = false

    var body: some View {
        TabView(selection: $tab) {
            Tab("Classes", systemImage: "building.columns", value: 0) {
                LectureListView(startRecording: startRecording)
            }
            Tab("Cheat Sheet", systemImage: "list.bullet.rectangle.portrait", value: 1) {
                CheatSheetView()
            }
            Tab("Study", systemImage: "graduationcap", value: 2) {
                StudyView()
            }
            Tab("Settings", systemImage: "gearshape", value: 3) {
                SettingsView()
            }
        }
        .fullScreenCover(isPresented: $showRecorder) {
            RecordingView()
        }
        .overlay(alignment: .bottom) {
            if let toast = analysis.toast {
                ToastView(text: toast)
                    .padding(.bottom, 70)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { analysis.toast = nil }
                    .task(id: toast) {
                        try? await Task.sleep(for: .seconds(5))
                        withAnimation { analysis.toast = nil }
                    }
            }
        }
        .animation(.spring, value: analysis.toast)
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                analysis.startPolling(context: context)
            } else if phase == .background {
                analysis.stopPolling()
            }
        }
        .onChange(of: recorder.isActive) { _, active in
            if active { showRecorder = true }
        }
        .onAppear(perform: recoverInterruptedRecordings)
    }

    private func startRecording() {
        showRecorder = true
    }

    /// If the app was killed mid-class, the lecture is still saved; mark it finished so it gets processed.
    private func recoverInterruptedRecordings() {
        guard !recorder.isActive else { return }
        let raw = LectureStatus.recording.rawValue
        let descriptor = FetchDescriptor<Lecture>(predicate: #Predicate { $0.statusRaw == raw })
        for lecture in (try? context.fetch(descriptor)) ?? [] {
            lecture.status = .transcribed
            if !lecture.segments.isEmpty {
                AnalysisCenter.shared.lectureFinished(lecture, context: context)
            }
        }
        try? context.save()
    }
}
