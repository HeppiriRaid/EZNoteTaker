import LockedCameraCapture
import SwiftData
import SwiftUI

@main
struct EZNoteTakerApp: App {
    /// Set when the saved classes couldn't be opened (they are left untouched on disk).
    static var databaseError: String?

    let container: ModelContainer = {
        DataBackup.backupIfNeeded()
        let schema = Schema([Lecture.self, TranscriptSegment.self, Building.self, LecturePhoto.self, StopMarker.self])
        do {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema))
        } catch {
            // Never crash or wipe data: run with a temporary empty database and tell the student.
            EZNoteTakerApp.databaseError = error.localizedDescription
            return try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
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
    @State private var databaseError = EZNoteTakerApp.databaseError

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
        .onAppear {
            recoverInterruptedRecordings()
            LockedPhotoImporter.start(recorder: recorder, context: context)
        }
        // "Open App" in the lock-screen camera: show the class being recorded.
        .onContinueUserActivity(NSUserActivityTypeLockedCameraCapture) { _ in
            if recorder.isActive { showRecorder = true }
        }
        // "Class Photo" control used on an unlocked phone: open the recording camera.
        .onChange(of: recorder.cameraRequested) { _, requested in
            guard requested else { return }
            if recorder.isActive { showRecorder = true } else { recorder.cameraRequested = false }
        }
        .alert("Couldn't open your saved classes", isPresented: Binding(
            get: { databaseError != nil }, set: { if !$0 { databaseError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Nothing was deleted: your recordings, photos and daily backups are still on the iPhone (Files › EZNoteTaker). Please don't delete the app — send me this message instead: \(databaseError ?? "")")
        }
        // Lock-screen console: "Photo" opens the camera, tapping the console opens the recorder.
        .onOpenURL { url in
            guard url.scheme == "eznotetaker", recorder.isActive else { return }
            showRecorder = true
            if url.host == "camera" { recorder.cameraRequested = true }
        }
    }

    private func startRecording() {
        showRecorder = true
    }

    /// If the app was killed mid-class, the lecture is still saved; mark it finished so it gets processed.
    private func recoverInterruptedRecordings() {
        guard !recorder.isActive else { return }
        RecordingSession.endLeftoverConsoles()
        let raw = LectureStatus.recording.rawValue
        let descriptor = FetchDescriptor<Lecture>(predicate: #Predicate { $0.statusRaw == raw })
        for lecture in (try? context.fetch(descriptor)) ?? [] {
            lecture.status = .transcribed
            if !lecture.segments.isEmpty {
                AnalysisCenter.shared.lectureFinished(lecture, context: context)
            }
        }
        // Make sure every photo of an analyzed class sits on a building card.
        let all = (try? context.fetch(FetchDescriptor<Lecture>())) ?? []
        for lecture in all where !lecture.buildings.isEmpty {
            PhotoPlacement.fillGaps(in: lecture)
        }
        try? context.save()
        // Reference photos for buildings without the student's own photos.
        ReferenceImages.fetchMissing(in: all, context: context)
    }
}
