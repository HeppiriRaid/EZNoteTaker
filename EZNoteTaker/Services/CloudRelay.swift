import Foundation
import Security
import SwiftData

/// Cloud version of the Claude relay: no Mac needed.
///
///   iPhone ──(GitHub API)──▶ private repo jobs/<id>/ ──▶ GitHub Action runs Claude Code
///   (Claude Opus 5.5 on the student's subscription via CLAUDE_CODE_OAUTH_TOKEN) ──▶ results/<id>.json ──▶ iPhone
@MainActor
enum CloudRelay {
    private static let api = URL(string: "https://api.github.com")!
    static let workflowPath = ".github/workflows/eznotetaker.yml"

    // MARK: Configuration

    static var repo: String {
        get { UserDefaults.standard.string(forKey: "cloudRelayRepo") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "cloudRelayRepo") }
    }

    static var token: String {
        get { Keychain.get("github-token") ?? "" }
        set { Keychain.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: "github-token") }
    }

    static var isConfigured: Bool { repo.contains("/") && !token.isEmpty }

    static func disconnect() {
        repo = ""
        token = ""
    }

    // MARK: Setup

    /// Checks access and installs the GitHub Action into the repo.
    static func installWorkflow() async throws {
        guard let url = Bundle.main.url(forResource: "eznotetaker-workflow", withExtension: "yml"),
              let data = try? Data(contentsOf: url) else { throw RelayError.missingWorkflow }
        try await put(path: workflowPath, data: data, message: "Install EZNoteTaker Claude relay")
    }

    // MARK: Submit

    static func submit(_ lecture: Lecture, settings: AppSettings) async throws {
        let id = lecture.id.uuidString
        let photos = lecture.sortedPhotos
        lecture.promptPhotoOrder = photos.map { $0.id.uuidString }

        // Remove any earlier result so the app doesn't import a stale one.
        try? await delete(path: "results/\(id).json")
        try? await delete(path: "results/\(id).error.txt")

        if settings.sharePhotos {
            for (i, photo) in photos.prefix(40).enumerated() {
                guard let image = ImageCache.shared.full(for: photo.fileName),
                      let jpeg = image.resized(maxPixel: 1280).jpegData(compressionQuality: 0.7) else { continue }
                try await put(path: "jobs/\(id)/P\(i + 1).jpg", data: jpeg, message: "Lecture photo")
            }
        }
        let prompt = ClaudeRelay.prompt(for: lecture, settings: settings, photosAttached: settings.sharePhotos)
        try await put(path: "jobs/\(id)/prompt.md", data: Data(prompt.utf8), message: "Lecture transcript")
        // READY is uploaded last: it is what starts the GitHub Action.
        try await put(path: "jobs/\(id)/READY", data: Data(Date().ISO8601Format().utf8), message: "Lecture \(id) ready for Claude")

        lecture.claudeJob = .waiting
        lecture.claudeJobSentAt = Date()
        lecture.claudeJobError = nil
    }

    // MARK: Collect

    static func collect(_ lecture: Lecture, context: ModelContext) async -> ClaudeRelay.CheckResult {
        let id = lecture.id.uuidString
        do {
            if case let (data, sha)? = try await get(path: "results/\(id).json") {
                let text = String(decoding: data, as: UTF8.self)
                try? await delete(path: "results/\(id).json", sha: sha)
                do {
                    let analysis = try LectureAnalysis.parse(text)
                    let summary = analysis.apply(to: lecture, photoOrder: lecture.promptPhotoOrder, source: .claude, context: context)
                    lecture.claudeJob = .done
                    return .imported(summary)
                } catch {
                    lecture.claudeJob = .failed
                    lecture.claudeJobError = error.localizedDescription
                    return .failed(error.localizedDescription)
                }
            }
            if case let (data, sha)? = try await get(path: "results/\(id).error.txt") {
                try? await delete(path: "results/\(id).error.txt", sha: sha)
                let message = String(String(decoding: data, as: UTF8.self).suffix(400))
                lecture.claudeJob = .failed
                lecture.claudeJobError = message
                return .failed(message)
            }
        } catch {
            // Network hiccup: try again on the next poll.
        }
        return .pending
    }

    // MARK: GitHub contents API

    private struct ContentResponse: Decodable {
        let sha: String
        let content: String?
        let downloadUrl: String?
    }

    private static func request(_ path: String, method: String, body: [String: Any]? = nil) throws -> URLRequest {
        guard isConfigured else { throw RelayError.notConfigured }
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        guard let url = URL(string: "\(api.absoluteString)/repos/\(repo)/contents/\(encoded)") else { throw RelayError.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    /// Returns the file's bytes and sha, or nil when it doesn't exist (yet).
    private static func get(path: String) async throws -> (Data, String)? {
        let (data, response) = try await URLSession.shared.data(for: request(path, method: "GET"))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        try check(status, data)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let file = try decoder.decode(ContentResponse.self, from: data)
        if let content = file.content, !content.isEmpty,
           let bytes = Data(base64Encoded: content.replacingOccurrences(of: "\n", with: "")) {
            return (bytes, file.sha)
        }
        // Files over 1 MB come without inline content; fetch the raw download instead.
        if let raw = file.downloadUrl, let url = URL(string: raw) {
            var rawRequest = URLRequest(url: url)
            rawRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (bytes, _) = try await URLSession.shared.data(for: rawRequest)
            return (bytes, file.sha)
        }
        return nil
    }

    private static func put(path: String, data: Data, message: String) async throws {
        var body: [String: Any] = ["message": message, "content": data.base64EncodedString()]
        if let existing = try await get(path: path) { body["sha"] = existing.1 }
        let (responseData, response) = try await URLSession.shared.data(for: request(path, method: "PUT", body: body))
        try check((response as? HTTPURLResponse)?.statusCode ?? 0, responseData)
    }

    private static func delete(path: String, sha: String? = nil) async throws {
        var fileSHA = sha
        if fileSHA == nil { fileSHA = try await get(path: path)?.1 }
        guard let fileSHA else { return }
        let (data, response) = try await URLSession.shared.data(
            for: request(path, method: "DELETE", body: ["message": "Imported by EZNoteTaker", "sha": fileSHA]))
        try check((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private static func check(_ status: Int, _ data: Data) throws {
        guard !(200..<300).contains(status) else { return }
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? ""
        switch status {
        case 401: throw RelayError.github("GitHub rejected the token (401). Create a new one in Settings.")
        case 403: throw RelayError.github("The token lacks permission (403). It needs Contents and Workflows read & write. \(message)")
        case 404: throw RelayError.github("Repository \(repo) not found, or the token can't see it.")
        default: throw RelayError.github("GitHub error \(status): \(message)")
        }
    }

    enum RelayError: LocalizedError {
        case notConfigured
        case missingWorkflow
        case github(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Connect your GitHub relay repo in Settings first."
            case .missingWorkflow: "The workflow file is missing from the app bundle."
            case .github(let message): message
            }
        }
    }
}

// MARK: - Keychain

enum Keychain {
    static func set(_ value: String, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
