import AVFoundation
import Foundation
import Vision

/// One look through the front camera: is anyone sitting there?
///
/// Opened only when the idle clock has already run out, and closed again as
/// soon as it has an answer. Keeping the session running would mean the green
/// light stays on all day, which is both rude and a lie about what the app is
/// doing.
///
/// Vision finds faces, not open eyes. There is no reliable public way to tell
/// whether someone is looking at the screen, and a face in frame is the honest
/// version of the question: is there still a person in front of this Mac.
final class FaceCheck: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    private let queue = DispatchQueue(label: "com.dora.away-blur.camera")
    private var session: AVCaptureSession?
    private var answer: ((Bool) -> Void)?
    private var finished = true
    private(set) var framesSeen = 0
    private(set) var frameSize = CGSize.zero

    static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    static var isDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        return status == .denied || status == .restricted
    }

    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    /// True if a face turned up within `timeout`. False for anything else,
    /// including no camera and no permission: the camera may only hold the
    /// blur back, never cause it.
    func look(timeout: TimeInterval = 3) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { return continuation.resume(returning: false) }
                self.begin(timeout: timeout) { continuation.resume(returning: $0) }
            }
        }
    }

    private func begin(timeout: TimeInterval, then reply: @escaping (Bool) -> Void) {
        guard FaceCheck.isAuthorized,
              let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return reply(false) }

        let session = AVCaptureSession()
        // Low is 192x144 — a face across a desk lands in a dozen pixels and
        // Vision will not find it. Medium is the smallest that works.
        for preset in [AVCaptureSession.Preset.medium, .high] where session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
            break
        }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddInput(input), session.canAddOutput(output) else { return reply(false) }
        session.addInput(input)
        session.addOutput(output)

        self.session = session
        self.answer = reply
        self.finished = false
        self.framesSeen = 0
        session.startRunning()
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.end(false) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !finished, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        framesSeen += 1
        frameSize = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up, options: [:])
        try? handler.perform([request])
        if let faces = request.results, !faces.isEmpty { end(true) }
    }

    private func end(_ found: Bool) {
        guard !finished else { return }
        finished = true
        session?.stopRunning()
        session = nil
        let reply = answer
        answer = nil
        reply?(found)
    }
}
