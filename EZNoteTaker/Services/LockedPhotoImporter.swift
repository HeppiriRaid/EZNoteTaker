import Foundation
import LockedCameraCapture
import SwiftData

/// Receives photos taken with the lock-screen camera (capture extension) and adds them to the class.
/// iOS delivers each lock-screen camera session as a folder once that camera is closed.
@MainActor
enum LockedPhotoImporter {
    private static var task: Task<Void, Never>?

    static func start(recorder: RecordingSession, context: ModelContext) {
        guard task == nil else { return }
        task = Task {
            for await update in LockedCameraCaptureManager.shared.sessionContentUpdates {
                switch update {
                case .initial(let urls):
                    for url in urls { await importFolder(url, recorder: recorder, context: context) }
                case .added(let url):
                    await importFolder(url, recorder: recorder, context: context)
                case .removed:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    private static func importFolder(_ folder: URL, recorder: RecordingSession, context: ModelContext) async {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let photos = files
            .filter { ["jpg", "jpeg", "heic"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in photos {
            guard let data = try? Data(contentsOf: file) else { continue }
            let capturedAt = LockedPhotoNaming.captureDate(fromFileName: file.lastPathComponent)
                ?? (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate)
                ?? Date()
            recorder.importLockedPhoto(data: data, capturedAt: capturedAt, context: context)
        }
        // Everything is copied into the app; let iOS delete the folder.
        try? await LockedCameraCaptureManager.shared.invalidateSessionContent(at: folder)
    }
}
