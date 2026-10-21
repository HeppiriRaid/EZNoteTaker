import Foundation

/// Safety net for app updates: once a day, before the database is opened, a copy of it is saved to
/// Documents/Backups (visible in the Files app). Recordings and photos already live in Documents.
enum DataBackup {
    private static let keep = 7

    private static var storeURL: URL {
        URL.applicationSupportDirectory.appending(path: "default.store")
    }

    static var backupsDirectory: URL {
        FileStore.documents.appending(path: "Backups", directoryHint: .isDirectory)
    }

    static var latest: Date? {
        backups().first.flatMap { try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate }
    }

    /// Copies the database (with its -wal/-shm journal files) if the last backup is older than a day.
    static func backupIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeURL.path) else { return }
        if let latest, Date().timeIntervalSince(latest) < 24 * 3600 { return }

        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        let folder = backupsDirectory.appending(path: stamp, directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: storeURL.path + suffix)
                guard fm.fileExists(atPath: source.path) else { continue }
                try fm.copyItem(at: source, to: folder.appending(path: source.lastPathComponent))
            }
        } catch {
            try? fm.removeItem(at: folder)
            return
        }
        for old in backups().dropFirst(keep) { try? fm.removeItem(at: old) }
    }

    /// Newest first.
    private static func backups() -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: backupsDirectory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return folders.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a > b
        }
    }
}
