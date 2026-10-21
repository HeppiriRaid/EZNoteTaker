import AVFoundation
import SwiftUI
import UIKit

/// Inline camera for the recording screen, so photos can be taken without leaving the live transcript.
/// Photo-only (no audio input), so it never interferes with the microphone recording.
final class CameraController: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "camera.session")
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

    func start() {
        if !trackingOrientation {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            trackingOrientation = true
        }
        queue.async { [self] in
            if !configured { configure() }
            if !session.isRunning { session.startRunning() }
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
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.maxPhotoQualityPrioritization = .balanced
        }
        session.commitConfiguration()
        configured = true
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

/// SwiftUI wrapper around the camera preview layer.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
