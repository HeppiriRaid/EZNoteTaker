import AVFoundation
import SwiftUI
import UIKit

/// Inline camera for the recording screen, so photos can be taken without leaving the live transcript.
/// Photo-only (no audio input), so it never interferes with the microphone recording.
/// Uses the multi-lens virtual camera when available, so zoom goes from 0.5× (ultra-wide) to telephoto.
final class CameraController: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    /// Zoom levels as shown to the user (1 = main camera, 0.5 = ultra-wide).
    struct ZoomRange: Equatable {
        var min: CGFloat = 1
        var max: CGFloat = 5
        var presets: [CGFloat] = [1, 2]
    }

    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "camera.session")
    private var device: AVCaptureDevice?
    /// Device zoom factor that corresponds to "1×" (2 on phones with an ultra-wide lens).
    private var oneXFactor: CGFloat = 1
    private var configured = false
    private var trackingOrientation = false
    private var completion: ((UIImage?) -> Void)?

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Starts the camera; `onReady` gets the zoom range on the main thread.
    func start(onReady: @escaping (ZoomRange) -> Void = { _ in }) {
        if !trackingOrientation {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            trackingOrientation = true
        }
        queue.async { [self] in
            if !configured { configure() }
            if !session.isRunning { session.startRunning() }
            let range = zoomRange()
            DispatchQueue.main.async { onReady(range) }
        }
    }

    func stop() {
        if trackingOrientation {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            trackingOrientation = false
        }
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        // Never touch the audio session – the lecture recording owns it.
        session.automaticallyConfiguresApplicationAudioSession = false

        let camera = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        if let camera, let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) {
            session.addInput(input)
            device = camera
            // On virtual cameras that include the ultra-wide lens, the first switch-over point is the main lens.
            let hasUltraWide = camera.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
            if hasUltraWide, let first = camera.virtualDeviceSwitchOverVideoZoomFactors.first {
                oneXFactor = CGFloat(first.doubleValue)
            }
            if (try? camera.lockForConfiguration()) != nil {
                camera.videoZoomFactor = oneXFactor
                if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
                camera.isSubjectAreaChangeMonitoringEnabled = true
                camera.unlockForConfiguration()
            }
        }
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.maxPhotoQualityPrioritization = .balanced
        }
        session.commitConfiguration()
        configured = true
    }

    private func zoomRange() -> ZoomRange {
        guard let device else { return ZoomRange() }
        let minZoom = device.minAvailableVideoZoomFactor / oneXFactor
        // Digital zoom beyond ~10× the main lens is too blurry to be useful.
        let maxZoom = min(device.maxAvailableVideoZoomFactor, oneXFactor * 10) / oneXFactor
        var presets: [CGFloat] = []
        if minZoom < 0.9 { presets.append(0.5) }
        presets.append(1)
        presets.append(2)
        // Telephoto lens, if the phone has one (e.g. 3× or 5×).
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) / oneXFactor }
        if let tele = switchOvers.last, tele > 2.5 { presets.append(tele.rounded()) } else if maxZoom >= 5 { presets.append(5) }
        return ZoomRange(min: minZoom, max: maxZoom, presets: presets.filter { $0 <= maxZoom + 0.01 })
    }

    /// Sets zoom as shown to the user (0.5×, 1×, 2×…).
    func setZoom(_ zoom: CGFloat, animated: Bool = false) {
        queue.async { [self] in
            guard let device, (try? device.lockForConfiguration()) != nil else { return }
            let factor = min(max(zoom * oneXFactor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            if animated {
                device.ramp(toVideoZoomFactor: factor, withRate: 12)
            } else {
                device.videoZoomFactor = factor
            }
            device.unlockForConfiguration()
        }
    }

    /// Focuses and exposes on a point in device coordinates (0…1), e.g. from a tap on the preview.
    func focus(at point: CGPoint) {
        queue.async { [self] in
            guard let device, (try? device.lockForConfiguration()) != nil else { return }
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = point
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = point
                device.exposureMode = .autoExpose
            }
            device.unlockForConfiguration()
        }
    }

    /// Call on the main thread.
    func capture(_ completion: @escaping (UIImage?) -> Void) {
        let angle = Self.currentRotationAngle()
        queue.async { [self] in
            guard session.isRunning else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.completion = completion
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .balanced
            settings.flashMode = .off
            if let connection = output.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            }
            output.capturePhoto(with: settings, delegate: self)
        }
    }

    private static func currentRotationAngle() -> CGFloat {
        switch UIDevice.current.orientation {
        case .landscapeLeft: 0
        case .landscapeRight: 180
        case .portraitUpsideDown: 270
        default: 90
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = photo.fileDataRepresentation().flatMap(UIImage.init(data:))
        let done = completion
        completion = nil
        DispatchQueue.main.async { done?(image) }
    }
}

/// SwiftUI wrapper around the camera preview layer, with tap-to-focus and pinch-to-zoom.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// Device point (0…1) for the camera, and view point for drawing the focus ring.
    var onTap: (CGPoint, CGPoint) -> Void = { _, _ in }
    /// Pinch scale relative to the start of the gesture; `began` is true for the first event.
    var onPinch: (CGFloat, Bool) -> Void = { _, _ in }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Coordinator: NSObject {
        var parent: CameraPreview
        init(_ parent: CameraPreview) { self.parent = parent }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view as? PreviewView else { return }
            let point = recognizer.location(in: view)
            parent.onTap(view.previewLayer.captureDevicePointConverted(fromLayerPoint: point), point)
        }

        @objc func pinched(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began: parent.onPinch(recognizer.scale, true)
            case .changed: parent.onPinch(recognizer.scale, false)
            default: break
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinched(_:))))
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.parent = self
    }
}
