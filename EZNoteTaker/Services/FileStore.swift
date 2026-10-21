import Foundation
import UIKit

/// Where audio recordings and photos live on disk (Documents, so they are included in device backups).
enum FileStore {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var audioDirectory: URL { ensure(documents.appendingPathComponent("Audio", isDirectory: true)) }
    static var photoDirectory: URL { ensure(documents.appendingPathComponent("Photos", isDirectory: true)) }

    private static func ensure(_ url: URL) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// Saves a JPEG and returns the file name (relative to `photoDirectory`).
    static func savePhoto(_ image: UIImage) throws -> String {
        let name = "\(UUID().uuidString).jpg"
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: photoDirectory.appendingPathComponent(name), options: .atomic)
        return name
    }

    static func savePhotoData(_ data: Data) throws -> String {
        guard let image = UIImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
        return try savePhoto(image)
    }

    static func delete(fileName: String, in directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
    }

    static func newAudioFileName() -> String { "\(UUID().uuidString).m4a" }

    static func storageUsed() -> Int64 {
        [audioDirectory, photoDirectory].reduce(0) { total, dir in
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return total + files.reduce(0) { sum, url in
                sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
    }
}

/// Small in-memory cache so scrolling through photo grids stays smooth.
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()

    func thumbnail(for fileName: String, maxPixel: CGFloat = 600) -> UIImage? {
        let key = "\(fileName)-\(Int(maxPixel))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let url = FileStore.photoDirectory.appendingPathComponent(fileName)
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        let thumb = image.resized(maxPixel: maxPixel)
        cache.setObject(thumb, forKey: key)
        return thumb
    }

    func full(for fileName: String) -> UIImage? {
        UIImage(contentsOfFile: FileStore.photoDirectory.appendingPathComponent(fileName).path)
    }
}

extension UIImage {
    func resized(maxPixel: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxPixel else { return self }
        let scale = maxPixel / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
