import UniformTypeIdentifiers
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AnalysisCenter.self) private var analysis
    @Environment(\.modelContext) private var context
    @State private var confirmUpdateAll = false

    private let languages: [(String, String)] = [
        ("en-US", "English (US)"), ("en-GB", "English (UK)"), ("en-AU", "English (Australia)"),
        ("en-CA", "English (Canada)"), ("ko-KR", "한국어"), ("ja-JP", "日本語"), ("zh-CN", "中文 (简体)"),
        ("es-ES", "Español"), ("fr-FR", "Français"), ("de-DE", "Deutsch"), ("it-IT", "Italiano"),
    ]

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    TextField("Course name", text: $settings.courseName)
                    TextField("City of the walking tours", text: $settings.city)
                    TextField("Professor (optional)", text: $settings.professorName)
                } header: {
                    Text("Your class")
                } footer: {
                    Text("Gives the AI context so it recognizes the buildings you visit.")
                }

                Section {
                    TextField("e.g. Louis Sullivan, Burnham & Root, Rookery, Monadnock", text: $settings.customVocabulary, axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    Text("Names the professor uses")
                } footer: {
                    Text("Architects and buildings separated by commas. Improves transcription and helps Claude fix misheard names.")
                }

                Section("Recording") {
                    Picker("Lecture language", selection: $settings.localeIdentifier) {
                        ForEach(languages.indices, id: \.self) { i in
                            Text(languages[i].1).tag(languages[i].0)
                        }
                    }
                    Toggle("Keep screen on while recording", isOn: $settings.keepScreenOn)
                    Toggle(isOn: $settings.liveDetection) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Live “Now discussing” building")
                            Text(LiveBuildingDetector.unavailableReason ?? "Free, on-device (Apple Intelligence)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!LiveBuildingDetector.isAvailable)
                }

                Section {
                    NavigationLink {
                        RelaySetupView()
                    } label: {
                        HStack {
                            Label("Claude Opus 5.5 relay", systemImage: "sparkles")
                            Spacer()
                            Text(relayStatus).foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Send class photos to Claude", isOn: $settings.sharePhotos)
                } header: {
                    Text("Study notes")
                } footer: {
                    Text("After each class, Claude Opus 5.5 writes the summary and cheat sheet automatically using your Claude subscription, through Claude Code. Meanwhile an instant draft is made on your iPhone.")
                }

                if AnalysisCenter.relayConfigured {
                    let outdated = analysis.outdatedLectures(context: context)
                    Section {
                        Button {
                            confirmUpdateAll = true
                        } label: {
                            Label(outdated.isEmpty ? "All classes use the latest style"
                                                   : "Update \(outdated.count) \(outdated.count == 1 ? "class" : "classes") to the latest style",
                                  systemImage: "arrow.clockwise")
                        }
                        .disabled(outdated.isEmpty)
                    } footer: {
                        Text("After an app update, re-runs Claude on classes made with older instructions. Recordings, transcripts and photos are never changed; your stars, notes and photo choices are kept.")
                    }
                    .confirmationDialog("Update \(outdated.count) classes with Claude?", isPresented: $confirmUpdateAll, titleVisibility: .visible) {
                        Button("Update All") { analysis.updateAll(context: context) }
                    } message: {
                        Text("They're sent one after another; each takes about 10 minutes and uses your Claude subscription.")
                    }
                }

                Section {
                    LabeledContent("Recordings & photos",
                                   value: ByteCountFormatter.string(fromByteCount: FileStore.storageUsed(), countStyle: .file))
                    if let last = DataBackup.latest {
                        LabeledContent("Last backup", value: last.formatted(date: .abbreviated, time: .shortened))
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Everything stays on this iPhone across app updates. A daily backup of your classes is kept in the Files app › On My iPhone › EZNoteTaker › Backups.")
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var relayStatus: String {
        if CloudRelay.isConfigured { return "Cloud" }
        if ClaudeRelay.isConfigured { return "Mac" }
        return "Not set up"
    }
}

/// Guided setup for the two ways of running Claude on the student's subscription.
struct RelaySetupView: View {
    @Environment(AnalysisCenter.self) private var analysis
    @State private var mode = CloudRelay.isConfigured || !ClaudeRelay.isConfigured ? 0 : 1
    @State private var repo = CloudRelay.repo
    @State private var token = ""
    @State private var working = false
    @State private var message: String?
    @State private var pickingFolder = false
    @State private var refresh = 0

    var body: some View {
        Form {
            Section {
                Picker("Where Claude runs", selection: $mode) {
                    Text("Cloud (GitHub)").tag(0)
                    Text("My Mac").tag(1)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(mode == 0
                     ? "No computer needs to stay on. A GitHub Action in your private repo runs Claude Code on your Claude subscription."
                     : "Your Mac runs Claude Code on your Claude subscription whenever a new class appears in a shared iCloud Drive folder.")
            }

            if mode == 0 { cloud } else { mac }

            if let message {
                Section { Text(message).font(.callout) }
            }
        }
        .navigationTitle("Claude Relay")
        .navigationBarTitleDisplayMode(.inline)
        .id(refresh)
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                do {
                    try ClaudeRelay.setFolder(url)
                    message = "Folder connected. Now open it on your Mac and double-click “install-relay.command”."
                } catch {
                    message = error.localizedDescription
                }
                refresh += 1
            case .failure(let error):
                message = error.localizedDescription
            }
        }
    }

    // MARK: Cloud

    @ViewBuilder
    private var cloud: some View {
        Section("One-time setup") {
            StepRow(n: 1, text: "On github.com, create a **private** repository, e.g. `eznotetaker-relay` (tick “Add a README”).")
            StepRow(n: 2, text: "On any computer with Claude Code, run `claude setup-token` and sign in with your Claude subscription. In the repo, go to Settings › Secrets and variables › Actions and add the secret **CLAUDE_CODE_OAUTH_TOKEN** with that token.")
            StepRow(n: 3, text: "Create a fine-grained GitHub token (Settings › Developer settings) for **only that repo** with **Contents** and **Workflows** set to *Read and write*.")
            StepRow(n: 4, text: "Enter the repo and token below and tap Connect. The app installs the GitHub Action for you.")
        }

        Section("Connection") {
            TextField("owner/repository", text: $repo)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField(CloudRelay.isConfigured ? "Token saved — paste to replace" : "GitHub token", text: $token)
            Button {
                connectCloud()
            } label: {
                if working { ProgressView() } else { Text(CloudRelay.isConfigured ? "Reinstall Action" : "Connect") }
            }
            .disabled(working || !repo.contains("/") || (token.isEmpty && !CloudRelay.isConfigured))
            if CloudRelay.isConfigured {
                Label("Connected to \(CloudRelay.repo)", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.sage)
                Button("Disconnect", role: .destructive) {
                    CloudRelay.disconnect()
                    token = ""
                    refresh += 1
                }
            }
        }
    }

    private func connectCloud() {
        working = true
        message = nil
        let previousRepo = CloudRelay.repo
        let previousToken = CloudRelay.token
        CloudRelay.repo = repo
        if !token.isEmpty { CloudRelay.token = token }
        Task {
            do {
                try await CloudRelay.installWorkflow()
                message = "Connected! New classes are sent to Claude automatically when you tap Finish."
                token = ""
            } catch {
                CloudRelay.repo = previousRepo
                CloudRelay.token = previousToken
                message = error.localizedDescription
            }
            working = false
            refresh += 1
        }
    }

    // MARK: Mac

    @ViewBuilder
    private var mac: some View {
        Section("One-time setup") {
            StepRow(n: 1, text: "Tap **Choose Folder** and create/select a folder in **iCloud Drive**, e.g. `EZNoteTaker`. The app puts the Mac installer inside it.")
            StepRow(n: 2, text: "On your Mac, open that folder in Finder and double-click **install-relay.command**. It installs Claude Code if needed and asks you to sign in with your Claude subscription.")
            StepRow(n: 3, text: "Done. Keep the Mac on and signed in to iCloud; classes are processed within a minute or two.")
        }
        Section("Shared folder") {
            Button(ClaudeRelay.isConfigured ? "Change Folder" : "Choose Folder") { pickingFolder = true }
            if let name = ClaudeRelay.folderName {
                Label("Using “\(name)”", systemImage: "folder.fill")
                if let beat = analysis.relayHeartbeat ?? ClaudeRelay.lastHeartbeat() {
                    Label("Mac relay last active \(beat.formatted(.relative(presentation: .named)))", systemImage: "desktopcomputer")
                        .foregroundStyle(Date().timeIntervalSince(beat) < 600 ? Theme.sage : .secondary)
                } else {
                    Label("Mac relay hasn't run yet", systemImage: "desktopcomputer").foregroundStyle(.secondary)
                }
                Button("Disconnect", role: .destructive) {
                    ClaudeRelay.clearFolder()
                    refresh += 1
                }
            }
        }
    }
}

private struct StepRow: View {
    let n: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.caption.weight(.heavy))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Theme.brick, in: Circle())
            RichText(text).font(.subheadline)
        }
    }
}
