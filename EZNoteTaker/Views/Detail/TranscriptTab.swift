import AVFoundation
import SwiftUI

/// Full transcript with timestamps, interleaved with building headers, stop markers and photos.
/// Tap any timestamp to re-listen to the professor from that moment.
struct TranscriptTab: View {
    let lecture: Lecture
    @State private var player = LecturePlayer()
    @State private var query = ""

    private enum Item: Identifiable {
        case building(Building)
        case marker(StopMarker)
        case photo(LecturePhoto)
        case text(TranscriptSegment)

        var id: String {
            switch self {
            case .building(let b): "b-\(b.id)"
            case .marker(let m): "m-\(m.time)-\(m.label)"
            case .photo(let p): "p-\(p.id)"
            case .text(let s): "t-\(s.start)-\(s.text.hashValue)"
            }
        }
    }

    private struct Entry: Identifiable {
        let time: Double
        let item: Item
        var id: String { item.id }
    }

    private var items: [Entry] {
        var all: [(Double, Item)] = []
        let q = query.trimmingCharacters(in: .whitespaces)
        for s in lecture.sortedSegments where q.isEmpty || s.text.localizedCaseInsensitiveContains(q) {
            all.append((s.start, .text(s)))
        }
        if q.isEmpty {
            all += lecture.buildings.map { ($0.firstMentioned - 0.01, .building($0)) }
            all += lecture.markers.map { ($0.time - 0.005, .marker($0)) }
            all += lecture.photos.map { ($0.takenAt, .photo($0)) }
        }
        return all.sorted { $0.0 < $1.0 }.map { Entry(time: $0.0, item: $0.1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search the transcript", text: $query)
                    .textInputAutocapitalization(.never)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                }
            }
            .padding(10)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if lecture.audioURL != nil {
                PlayerBar(player: player, duration: lecture.durationSeconds)
            }

            if lecture.segments.isEmpty {
                ContentUnavailableView("No transcript", systemImage: "waveform", description: Text("Nothing was transcribed for this class."))
            }

            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(items) { entry in
                    row(entry.item)
                }
            }
            .card()
        }
        .onAppear { if let url = lecture.audioURL { player.load(url) } }
        .onDisappear { player.stop() }
    }

    @ViewBuilder
    private func row(_ item: Item) -> some View {
        switch item {
        case .building(let b):
            HStack(spacing: 8) {
                Image(systemName: "building.columns.fill").foregroundStyle(Theme.brick)
                Text(b.name).font(.serifHeadline(17))
                Spacer()
            }
            .padding(.top, 10)
        case .marker(let m):
            Label(m.label.isEmpty ? "New stop" : "New stop: \(m.label)", systemImage: "mappin.and.ellipse")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.brick)
        case .photo(let p):
            HStack(alignment: .bottom, spacing: 10) {
                PhotoThumb(fileName: p.fileName, maxPixel: 500)
                    .frame(width: 140, height: 105)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(TimeFormat.clock(p.takenAt)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if let b = p.building { Text(b.name).font(.caption.weight(.semibold)) }
                    if !p.caption.isEmpty { Text(p.caption).font(.caption).foregroundStyle(.secondary) }
                }
            }
        case .text(let s):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button {
                    player.play(from: s.start)
                } label: {
                    Text(TimeFormat.clock(s.start))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(player.isNear(s.start) ? Theme.brick : .secondary)
                        .frame(width: 48, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .disabled(lecture.audioURL == nil)
                highlighted(s.text)
                    .textSelection(.enabled)
            }
        }
    }

    private func highlighted(_ text: String) -> Text {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Text(text) }
        var attributed = AttributedString(text)
        var searchStart = attributed.startIndex
        while let range = attributed[searchStart...].range(of: q, options: .caseInsensitive) {
            attributed[range].backgroundColor = Theme.gold.opacity(0.35)
            searchStart = range.upperBound
        }
        return Text(attributed)
    }
}

// MARK: - Player

@MainActor
@Observable
final class LecturePlayer {
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    var rate: Float = 1.0 { didSet { player?.rate = rate } }

    func load(_ url: URL) {
        guard player == nil, FileManager.default.fileExists(atPath: url.path) else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.enableRate = true
        player?.prepareToPlay()
    }

    func play(from time: Double) {
        guard let player else { return }
        player.currentTime = max(time - 1, 0)
        startPlayback()
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying { pause() } else { startPlayback() }
    }

    func skip(_ seconds: Double) {
        guard let player else { return }
        player.currentTime = min(max(player.currentTime + seconds, 0), player.duration)
        currentTime = player.currentTime
    }

    func seek(to time: Double) {
        player?.currentTime = time
        currentTime = time
    }

    func isNear(_ time: Double) -> Bool { isPlaying && abs(currentTime - time) < 8 && currentTime >= time - 1 }

    private func startPlayback() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        player?.rate = rate
        player?.play()
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying { self.isPlaying = false; self.timer?.invalidate() }
            }
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
    }

    func stop() {
        pause()
        player = nil
    }
}

struct PlayerBar: View {
    let player: LecturePlayer
    let duration: Double

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 18) {
                Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 40))
                }
                Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
                Spacer()
                Menu {
                    ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                        Button("\(speed, specifier: "%g")×") { player.rate = Float(speed) }
                    }
                } label: {
                    Text("\(Double(player.rate), specifier: "%g")×")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.brick.opacity(0.12), in: Capsule())
                }
            }
            .font(.title3)
            Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                   in: 0...max(duration, 1))
            HStack {
                Text(TimeFormat.clock(player.currentTime))
                Spacer()
                Text(TimeFormat.clock(duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .card(padding: 12)
    }
}
