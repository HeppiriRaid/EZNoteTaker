import AVKit
import LockedCameraCapture
import SwiftUI
import UIKit

/// Lock-screen camera: opened from the "Class Photo" control without Face ID. Photos are saved into the
/// session folder, which iOS hands to EZNoteTaker; the app adds them to the class at the right time.
@main
struct ClassPhotoCaptureExtension: LockedCameraCaptureExtension {
    var body: some LockedCameraCaptureExtensionScene {
        LockedCameraCaptureUIScene { session in
            LockedClassCamera(session: session)
        }
    }
}

struct LockedClassCamera: View {
    let session: LockedCameraCaptureSession

    @State private var camera = CameraController()
    @State private var zoom: CGFloat = 1
    @State private var pinchStartZoom: CGFloat = 1
    @State private var zoomRange = CameraController.ZoomRange()
    @State private var context: ClassPhotoContext?
    @State private var taken = 0
    @State private var lastPhoto: UIImage?
    @State private var blink = false
    @State private var focusPoint: CGPoint?

    private let brick = Color(red: 0.90, green: 0.49, blue: 0.38)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: camera.session, onTap: { devicePoint, viewPoint in
                camera.focus(at: devicePoint)
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
            .ignoresSafeArea()

            Color.black.opacity(blink ? 0.55 : 0).ignoresSafeArea().allowsHitTesting(false)

            if let focusPoint {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.yellow, lineWidth: 1.5)
                    .frame(width: 70, height: 70)
                    .position(focusPoint)
                    .allowsHitTesting(false)
            }

            VStack {
                header
                Spacer()
                zoomBar
                controls
            }
            .padding()
        }
        .preferredColorScheme(.dark)
        // Volume / Camera Control buttons take photos too (and keep the extension alive, as iOS requires).
        .onCameraCaptureEvent { event in
            if event.phase == .ended { takePhoto() }
        } secondaryAction: { event in
            if event.phase == .ended { takePhoto() }
        }
        .task {
            context = try? await ClassPhotoIntent.appContext
            camera.start { range in
                zoomRange = range
                camera.setZoom(zoom)
            }
        }
        .onDisappear { camera.stop() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(context?.isRecording == true ? Color.red : Color.gray)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(context?.isRecording == true ? "RECORDING · \(context?.className ?? "Class")" : "EZNoteTaker")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.white)
                Text("Photos are added to your class automatically")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            if taken > 0 {
                Label("\(taken)", systemImage: "photo.stack")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: Capsule())
            }
        }
        .padding(10)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var zoomBar: some View {
        HStack(spacing: 6) {
            ForEach(zoomRange.presets, id: \.self) { preset in
                let active = (zoomRange.presets.filter { $0 <= zoom + 0.01 }.max() ?? zoomRange.presets.first) == preset
                Button {
                    zoom = preset
                    camera.setZoom(preset, animated: true)
                } label: {
                    Text(label(active ? zoom : preset) + (active ? "×" : ""))
                        .font(.system(size: active ? 13 : 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(active ? Color.yellow : .white)
                        .frame(width: active ? 40 : 32, height: active ? 40 : 32)
                        .background(.black.opacity(0.55), in: Circle())
                }
            }
        }
        .padding(4)
        .background(.black.opacity(0.25), in: Capsule())
        .padding(.bottom, 14)
    }

    private var controls: some View {
        HStack {
            Group {
                if let lastPhoto {
                    Image(uiImage: lastPhoto)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 54, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white, lineWidth: 2))
                } else {
                    Color.clear.frame(width: 54, height: 54)
                }
            }
            .frame(maxWidth: .infinity)

            Button(action: takePhoto) {
                ZStack {
                    Circle().fill(.white).frame(width: 76, height: 76)
                    Circle().stroke(.black.opacity(0.25), lineWidth: 2).frame(width: 66, height: 66)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Take photo")

            // Opening the app needs Face ID; photos are delivered either way.
            Button {
                Task { try? await session.openApplication(for: NSUserActivity(activityType: NSUserActivityTypeLockedCameraCapture)) }
            } label: {
                Text("Open App")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(brick.opacity(0.85), in: Capsule())
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.bottom, 8)
    }

    private func label(_ value: CGFloat) -> String {
        if value < 1 { return String(format: ".%d", Int((value * 10).rounded())) }
        if value.truncatingRemainder(dividingBy: 1) > 0.05 { return String(format: "%.1f", value) }
        return String(Int(value.rounded()))
    }

    private func takePhoto() {
        withAnimation(.easeOut(duration: 0.05)) { blink = true }
        let capturedAt = Date()
        camera.capture { image in
            withAnimation(.easeIn(duration: 0.2)) { blink = false }
            guard let image, let data = image.jpegData(compressionQuality: 0.85) else { return }
            let url = session.sessionContentURL.appending(path: LockedPhotoNaming.fileName(for: capturedAt))
            if (try? data.write(to: url, options: .atomic)) != nil {
                taken += 1
                lastPhoto = image
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
    }
}
