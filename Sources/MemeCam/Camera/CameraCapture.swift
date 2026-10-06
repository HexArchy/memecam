@preconcurrency import AVFoundation
import CoreMedia

struct CameraDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

/// Thin AVCaptureSession wrapper. Frames are delivered on `queue`.
final class CameraCapture: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "memecam.capture", qos: .userInteractive)
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    var onFrame: ((CMSampleBuffer) -> Void)?

    /// Real cameras only — never our own virtual camera (that would be a feedback loop).
    static func availableDevices() -> [CameraDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified)
        return discovery.devices
            .filter { !$0.localizedName.localizedCaseInsensitiveContains("MemeCam") }
            .map { CameraDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    func start(deviceID: String?) throws {
        let devices = Self.availableDevices()
        guard let id = deviceID ?? devices.first?.id,
              let device = AVCaptureDevice(uniqueID: id) else { throw CameraError.noCamera }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high

        if let input { session.removeInput(input) }
        let newInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(newInput) else { throw CameraError.cannotAddInput }
        session.addInput(newInput)
        input = newInput

        if session.outputs.isEmpty {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { throw CameraError.cannotAddOutput }
            session.addOutput(output)
        }

        // Cap at 30 FPS: plenty for video calls and halves the work of 60 FPS cameras.
        if let range = device.activeFormat.videoSupportedFrameRateRanges.first(where: { $0.maxFrameRate >= 30 }) {
            try? device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(min(30, range.maxFrameRate)))
            device.unlockForConfiguration()
        }

        if !session.isRunning {
            // startRunning blocks; keep it off the main thread.
            queue.async { [session] in session.startRunning() }
        }
    }

    func stop() {
        queue.async { [session] in session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        onFrame?(sampleBuffer)
    }
}

enum CameraError: LocalizedError {
    case noCamera, cannotAddInput, cannotAddOutput
    var errorDescription: String? {
        switch self {
        case .noCamera: "No camera found."
        case .cannotAddInput: "The camera is busy or unavailable."
        case .cannotAddOutput: "Could not read frames from the camera."
        }
    }
}
