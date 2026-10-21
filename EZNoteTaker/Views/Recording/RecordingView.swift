import SwiftUI

/// The live class screen: timer, live transcript, inline camera and the on-device "now discussing"
/// guess. Every photo marks a stop in the transcript. Designed for one-handed use while walking.
struct RecordingView: View {
    @Environment(RecordingSession.self) private var recorder
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var camera = CameraController()
    @State private var cameraOpen = false
    @State private var cameraDenied = false
    @State private var shutterBlink = false
    @State private var zoom: CGFloat = 1
    @State private var pinchStartZoom: CGFloat = 1
    @State private var zoomRange = CameraController.ZoomRange()
    @State private var focusPoint: CGPoint?
    @State private var confirmFinish = false
    @State private var confirmDiscard = false
    @State private var followTranscript = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch recorder.phase {
            case .preparing(let message):
                preparing(message)
            case .failed(let message):
                failed(message)
            case .finishing:
                preparing("Saving your class…")
            default:
                live
            }
        }
        .preferredColorScheme(.dark)
        .task {
            if recorder.phase == .idle {
                await recorder.start(context: context, settings: settings)
            }
        }
        .onDisappear { camera.stop() }
        .confirmationDialog("Finish this class?", isPresented: $confirmFinish, titleVisibility: .visible) {
            Button("Finish & Make Study Notes") { finish() }
            Button("Keep Recording", role: .cancel) {}
        } message: {
            Text("Your transcript and photos are saved, then the summary and cheat sheet are created automatically.")
        }
        .confirmationDialog("Discard this recording?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard Recording & Photos", role: .destructive) {
                Task {
                    await recorder.discard()
                    dismiss()
                }
            }
            Button("Keep Recording", role: .cancel) {}
        }
    }

    // MARK: Live layout

    private var live: some View {
        VStack(spacing: 12) {
            topBar
            LevelMeter(levels: recorder.levelHistory, active: recorder.phase == .recording)
                .frame(height: 34)
                .padding(.horizontal)
            if let guess = recorder.currentGuess {
                nowDiscussing(guess)
            }
            if cameraOpen {
                cameraPanel
            } else if !recorder.recentPhotos.isEmpty {
                photoStrip
            }
            transcript
            controls
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        HStack {
            Button {
                confirmDiscard = true
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .accessibilityLabel("Discard recording")

            Spacer()
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(recorder.phase == .paused ? Color.orange : Theme.recordRed)
                        .frame(width: 10, height: 10)
                        .symbolEffect(.pulse)
                        .opacity(recorder.phase == .recording ? 1 : 0.6)
                    Text(recorder.phase == .paused ? "PAUSED" : "REC")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(recorder.phase == .paused ? .orange : Theme.recordRed)
                }
                Text(TimeFormat.clock(recorder.elapsed))
                    .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Label("\(recorder.photoCount)", systemImage: "camera.fill")
                Label("\(recorder.markerCount)", systemImage: "mappin")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.7))
            .frame(width: 40)
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func nowDiscussing(_ guess: LiveBuildingGuess) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "building.columns.fill")
                .font(.title3)
                .foregroundStyle(Theme.brick)
            VStack(alignment: .leading, spacing: 1) {
                Text("NOW DISCUSSING").font(.caption2.weight(.heavy)).foregroundStyle(.white.opacity(0.6))
                Text(guess.label).font(.subheadline.weight(.semibold)).lineLimit(2)
            }
            Spacer()
        }
        .padding(12)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.spring, value: guess)
    }

    private var cameraPanel: some View {
        ZStack {
            CameraPreview(session: camera.session, onTap: { devicePoint, viewPoint in
                camera.focus(at: devicePoint)
                Haptics.light()
                withAnimation(.easeOut(duration: 0.15)) { focusPoint = viewPoint }
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    withAnimation { focusPoint = nil }
                }
            }, onPinch: { scale, began in
                if began { pinchStartZoom = zoom }
                zoom = min(max(pinchStartZoom * scale, zoomRange.min), zoomRange.max)
                camera.setZoom(zoom)
            })
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            // Subtle shutter feedback on the preview only (no full-screen flash).
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.black)
                .opacity(shutterBlink ? 0.55 : 0)
                .allowsHitTesting(false)

            if let focusPoint {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.yellow, lineWidth: 1.5)
                    .frame(width: 70, height: 70)
                    .position(focusPoint)
                    .allowsHitTesting(false)
                    .transition(.scale(scale: 1.4).combined(with: .opacity))
            }

            VStack {
                HStack {
                    Button {
                        closeCamera()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.headline)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    Spacer()
                    if let last = recorder.recentPhotos.first {
                        PhotoThumb(fileName: last.fileName, maxPixel: 200)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: 2))
                            .id(last.id)
                            .transition(.scale)
                    }
                }
                Spacer()
                zoomBar
            }
            .padding(12)
        }
        .frame(height: 320)
        .padding(.horizontal)
    }

    /// 0.5× / 1× / 2× / 5× buttons like the Camera app; shows the exact zoom while pinching.
    private var zoomBar: some View {
        HStack(spacing: 6) {
            ForEach(zoomRange.presets, id: \.self) { preset in
                let active = isActivePreset(preset)
                Button {
                    zoom = preset
                    camera.setZoom(preset, animated: true)
                    Haptics.light()
                } label: {
                    Text(active ? zoomLabel(zoom) + "×" : zoomLabel(preset))
                        .font(.system(size: active ? 13 : 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(active ? Color.yellow : .white)
                        .frame(width: active ? 40 : 32, height: active ? 40 : 32)
                        .background(.black.opacity(0.55), in: Circle())
                }
            }
        }
        .padding(4)
        .background(.black.opacity(0.25), in: Capsule())
        .animation(.snappy, value: zoom)
    }

    private func isActivePreset(_ preset: CGFloat) -> Bool {
        // The preset closest to (and not above) the current zoom is highlighted.
        let candidates = zoomRange.presets.filter { $0 <= zoom + 0.01 }
        return preset == (candidates.max() ?? zoomRange.presets.first)
    }

    private func zoomLabel(_ value: CGFloat) -> String {
        if value < 1 { return String(format: ".%d", Int((value * 10).rounded())) }   // 0.5 → ".5"
        if value.truncatingRemainder(dividingBy: 1) > 0.05 { return String(format: "%.1f", value) }
        return String(Int(value.rounded()))
    }

    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(recorder.recentPhotos) { photo in
                    PhotoThumb(fileName: photo.fileName, maxPixel: 200)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .padding(.horizontal)
        }
        .frame(height: 56)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if recorder.lines.isEmpty && recorder.volatileText.isEmpty {
                        Text(recorder.phase == .paused ? "Paused" : "Listening… the transcript appears here as the professor speaks.")
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.top, 20)
                    }
                    ForEach(recorder.lines) { line in
                        if let file = line.photoFile {
                            photoStop(line, file: file)
                        } else {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(TimeFormat.clock(line.start))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.4))
                                .frame(width: 44, alignment: .trailing)
                            Text(line.text)
                                .font(.body)
                                .foregroundStyle(line.text.hasPrefix("📍") ? Theme.brick : .white)
                        }
                        }
                    }
                    if !recorder.volatileText.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("…").frame(width: 44, alignment: .trailing).foregroundStyle(.white.opacity(0.4))
                            Text(recorder.volatileText).foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
            .onChange(of: recorder.volatileText) { _, _ in
                if followTranscript { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: recorder.lines.count) { _, _ in
                if followTranscript { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { followTranscript = false }
            }
            .overlay(alignment: .bottomTrailing) {
                if !followTranscript {
                    Button {
                        followTranscript = true
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Label("Live", systemImage: "arrow.down")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Theme.brick, in: Capsule())
                    }
                    .padding()
                }
            }
        }
    }

    /// A photo in the live transcript: it marks the stop where the class is looking at a building.
    private func photoStop(_ line: RecordingSession.LiveLine, file: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(TimeFormat.clock(line.start))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 44, alignment: .trailing)
            PhotoThumb(fileName: file, maxPixel: 300)
                .frame(width: 84, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Label("Stop", systemImage: "mappin.and.ellipse")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Theme.brick)
                Text(line.text)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(3)
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var controls: some View {
        HStack(alignment: .center) {
            ControlButton(title: cameraOpen ? "Hide Camera" : "Camera",
                          systemImage: cameraOpen ? "camera.badge.ellipsis" : "camera") {
                if cameraOpen { closeCamera() } else { openCamera() }
            }
            ControlButton(title: recorder.phase == .paused ? "Resume" : "Pause",
                          systemImage: recorder.phase == .paused ? "play.fill" : "pause.fill") {
                recorder.togglePause()
            }

            Button {
                if cameraOpen { takePhoto() } else { openCamera() }
            } label: {
                ZStack {
                    Circle().fill(.white).frame(width: 74, height: 74)
                    Circle().stroke(.black.opacity(0.2), lineWidth: 2).frame(width: 64, height: 64)
                    Image(systemName: cameraOpen ? "circle.fill" : "camera.fill")
                        .font(.system(size: cameraOpen ? 52 : 26))
                        .foregroundStyle(cameraOpen ? .white : .black)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel(cameraOpen ? "Take photo" : "Open camera")

            ControlButton(title: "Finish", systemImage: "stop.fill", tint: Theme.recordRed) {
                confirmFinish = true
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .alert("Camera access is off", isPresented: $cameraDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Allow camera access to take building photos during class.")
        }
    }

    // MARK: Other states

    private func preparing(_ message: String) -> some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large).tint(.white)
            Text(message).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
        }
        .padding()
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.slash.fill").font(.system(size: 44)).foregroundStyle(Theme.recordRed)
            Text("Couldn't start recording").font(.title3.bold()).foregroundStyle(.white)
            Text(message).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
            Button("Close") {
                recorder.dismissError()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }

    // MARK: Actions

    private func openCamera() {
        Task {
            guard await CameraController.requestAccess() else {
                cameraDenied = true
                return
            }
            camera.start { range in
                zoomRange = range
                zoom = min(max(zoom, range.min), range.max)
                camera.setZoom(zoom)
            }
            withAnimation(.spring) { cameraOpen = true }
        }
    }

    private func closeCamera() {
        camera.stop()
        withAnimation(.spring) { cameraOpen = false }
    }

    private func takePhoto() {
        withAnimation(.easeOut(duration: 0.05)) { shutterBlink = true }
        camera.capture { image in
            withAnimation(.easeIn(duration: 0.2)) { shutterBlink = false }
            if let image {
                withAnimation(.spring) { recorder.addPhoto(image) }
            }
        }
    }

    private func finish() {
        camera.stop()
        Task {
            if let lecture = await recorder.stop() {
                AnalysisCenter.shared.lectureFinished(lecture, context: context)
            }
            dismiss()
        }
    }
}

private struct ControlButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 52, height: 52)
                    .background(tint.opacity(tint == .white ? 0.14 : 0.9), in: Circle())
                    .foregroundStyle(.white)
                Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Scrolling bars that show the microphone is picking up the professor.
struct LevelMeter: View {
    let levels: [Float]
    let active: Bool

    var body: some View {
        GeometryReader { geo in
            let barWidth = geo.size.width / CGFloat(max(levels.count, 1))
            HStack(alignment: .center, spacing: 0) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(active ? Theme.brick : Color.gray)
                        .frame(width: max(barWidth - 3, 1), height: max(3, CGFloat(level) * geo.size.height))
                        .frame(width: barWidth)
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.linear(duration: 0.1), value: levels)
        }
    }
}
