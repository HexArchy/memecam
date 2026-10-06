@preconcurrency import AVFoundation
import CoreMedia

struct CameraDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// Built-in camera with the lid closed, etc.
    let isSuspended: Bool
    let isContinuity: Bool
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
            .map { CameraDevice(id: $0.uniqueID, name: $0.localizedName, isSuspended: $0.isSuspended,
                                isContinuity: $0.isContinuityCamera) }
    }

    /// The camera to use when the user picked "Default": the system's preferred camera,
    /// otherwise the first one that is not suspended (closed lid), otherwise anything.
    static func defaultDevice() -> AVCaptureDevice? {
        let real = availableDevices().compactMap { AVCaptureDevice(uniqueID: $0.id) }
        if let preferred = AVCaptureDevice.systemPreferredCamera,
           real.contains(where: { $0.uniqueID == preferred.uniqueID }), !preferred.isSuspended {
            return preferred
        }
        return real.first { !$0.isSuspended } ?? real.first
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    func start(deviceID: String?) throws {
        guard let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? Self.defaultDevice()
        else { throw CameraError.noCamera }
        if device.isSuspended { throw CameraError.suspended(device.localizedName) }
        observeSession()

        try configure(device)

        // Cap at 30 FPS (plenty for calls, half the work of 60 FPS cameras). Must happen after
        // commitConfiguration: applying the session preset resets frame durations.
        let thirty = CMTime(value: 1, timescale: 30)
        if device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameDuration <= thirty && thirty <= $0.maxFrameDuration
        }), (try? device.lockForConfiguration()) != nil {
            device.activeVideoMinFrameDuration = thirty
            device.unlockForConfiguration()
        }
        currentDeviceName = device.localizedName

        if !session.isRunning {
            // startRunning blocks; keep it off the main thread.
            queue.async { [session] in session.startRunning() }
        }
    }

    private func configure(_ device: AVCaptureDevice) throws {
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
    }

    private(set) var currentDeviceName = ""
    /// Called on the capture queue with a user-facing message when the session breaks.
    var onProblem: ((String?) -> Void)?
    private var observers: [NSObjectProtocol] = []

    private func observeSession() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) {
            [weak self] note in
            let err = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            self?.onProblem?("Camera error: \(err?.localizedDescription ?? "unknown"). Try another camera.")
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) {
            [weak self] _ in
            self?.onProblem?("The camera was interrupted — another app may be using it.")
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) {
            [weak self] _ in self?.onProblem?(nil)
        })
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
    case suspended(String)
    var errorDescription: String? {
        switch self {
        case .suspended(let name): "\(name) is unavailable (is the lid closed?). Pick another camera."
        case .noCamera: "No camera found."
        case .cannotAddInput: "The camera is busy or unavailable."
        case .cannotAddOutput: "Could not read frames from the camera."
        }
    }
}
