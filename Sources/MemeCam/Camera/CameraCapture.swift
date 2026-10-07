@preconcurrency import AVFoundation
import CoreMedia
import os

struct CameraDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// Built-in camera with the lid closed, etc.
    let isSuspended: Bool
    let isContinuity: Bool
}

/// Thin AVCaptureSession wrapper. Frames are delivered on `queue`.
///
/// Concurrency invariant (why `@unchecked Sendable` is sound):
/// - The session, its input/output and the restart bookkeeping (`wantsRunning`, `runToken`,
///   `restartAttempt`) are only touched on `queue`, a serial queue. Configuration, `startRunning` and
///   `stopRunning` block, so they never run on the main thread; callers `await` `start`/`stop`.
/// - `onFrame` / `onProblem` are assigned once by `MemePipeline.init`, before the session can start,
///   and are read-only afterwards.
/// - The active device's id and name are readable from any queue through the `active` lock.
final class CameraCapture: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "memecam.capture", qos: .userInteractive)
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let log = Logger(subsystem: "com.hexarch.memecam", category: "camera")

    // MARK: queue-confined
    private var input: AVCaptureDeviceInput?
    /// The user wants the session running (between `start` and `stop`); runtime-error restarts check it.
    private var wantsRunning = false
    /// Bumped on every start/stop so a pending restart from an older run does nothing.
    private var runToken = 0
    private var restartAttempt = 0
    /// Capture 1080p instead of 720p (the 1080p output format); the session falls back when unsupported.
    private var fullHD = false
    private var observers: [NSObjectProtocol] = []

    /// Set once before the first `start` (see the invariant above).
    var onFrame: ((CMSampleBuffer) -> Void)?
    /// Called on the capture queue with a user-facing message when the session breaks, nil when it recovered.
    var onProblem: ((String?) -> Void)?

    /// The device the session currently captures from (nil before the first start).
    private let active = OSAllocatedUnfairLock<CameraDevice?>(initialState: nil)
    var activeDevice: CameraDevice? { active.withLock { $0 } }

    override init() {
        super.init()
        observeSession()
    }

    /// Real cameras only — never our own virtual camera (that would be a feedback loop).
    static func availableDevices() -> [CameraDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified)
        return discovery.devices
            .filter { !$0.localizedName.localizedCaseInsensitiveContains("MemeCam") }
            .map(CameraDevice.init)
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

    // MARK: Control (any thread; the work hops to `queue`)

    /// Starts capturing from `deviceID` (nil or missing: the default camera), or switches the running
    /// session to it. On failure the previous input keeps running untouched. Returns the device in use.
    func start(deviceID: String?) async throws -> CameraDevice {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do { continuation.resume(returning: try startOnQueue(deviceID: deviceID)) } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                wantsRunning = false
                runToken &+= 1
                if session.isRunning { session.stopRunning() }
                continuation.resume()
            }
        }
    }

    // MARK: queue

    private func startOnQueue(deviceID: String?) throws -> CameraDevice {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? Self.defaultDevice()
        else { throw CameraError.noCamera }
        if device.isSuspended { throw CameraError.suspended(device.localizedName) }

        let info = CameraDevice(device)
        if input?.device.uniqueID != device.uniqueID || !session.isRunning {
            if input?.device.uniqueID != device.uniqueID {
                // Open the new device before touching the session: a busy camera throws here and the
                // current input keeps running.
                let newInput = try AVCaptureDeviceInput(device: device)
                try configure(newInput)
                lockFrameRate(device)
            }
            active.withLock { $0 = info }
            wantsRunning = true
            runToken &+= 1
            restartAttempt = 0
            if !session.isRunning {
                session.startRunning() // blocks; we are on `queue`
                guard session.isRunning else {
                    wantsRunning = false
                    throw CameraError.couldNotStart(device.localizedName)
                }
            }
        }
        return info
    }

    /// Swaps the input in one configuration transaction. The old input is only removed for the
    /// `canAddInput` check and is put back when the new one is refused, so a failed switch leaves the
    /// running camera as it was.
    private func configure(_ newInput: AVCaptureDeviceInput) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        applyPreset()

        let old = input
        if let old { session.removeInput(old) }
        guard session.canAddInput(newInput) else {
            if let old, session.canAddInput(old) { session.addInput(old) }
            throw CameraError.cannotAddInput
        }
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

    private func applyPreset() {
        let wanted: AVCaptureSession.Preset = fullHD ? .hd1920x1080 : .hd1280x720
        session.sessionPreset = session.canSetSessionPreset(wanted) ? wanted
            : session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
    }

    /// Switches between 720p and 1080p capture; a running session is reconfigured in place.
    /// Ordered with `start`/`stop` on the capture queue; returns immediately.
    func setFullHD(_ value: Bool) {
        queue.async { [self] in
            guard fullHD != value else { return }
            fullHD = value
            guard let input else { return } // applied by the next configure
            session.beginConfiguration()
            applyPreset()
            session.commitConfiguration()
            lockFrameRate(input.device) // the preset resets frame durations
            log.info("capture preset \(value ? "1080p" : "720p", privacy: .public)")
        }
    }

    /// Cap at 30 FPS (plenty for calls, half the work of 60 FPS cameras). Must happen after
    /// commitConfiguration: applying the session preset resets frame durations.
    private func lockFrameRate(_ device: AVCaptureDevice) {
        let thirty = CMTime(value: 1, timescale: 30)
        guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameDuration <= thirty && thirty <= $0.maxFrameDuration
        }) else { return }
        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = thirty
            device.unlockForConfiguration()
        } catch {
            log.notice("can't cap \(device.localizedName, privacy: .public) at 30 fps: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A runtime error stops the session. Restart it with backoff (1, 2, 4 … 30 s) while the user still
    /// wants the camera, unless the device itself is gone (AppModel switches cameras then).
    private func handleRuntimeError(_ message: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        onProblem?(message)
        guard wantsRunning, input?.device.isConnected == true else { return }
        let delay = min(30, pow(2, Double(restartAttempt)))
        restartAttempt += 1
        let token = runToken
        log.notice("session runtime error; restart #\(self.restartAttempt) in \(delay) s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, wantsRunning, token == runToken, !session.isRunning else { return }
            session.startRunning()
            if session.isRunning { onProblem?(nil) }
        }
    }

    private func observeSession() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) {
            [weak self] note in
            let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let reason = err?.localizedDescription ?? String(localized: "unknown")
            let message = String(localized: "Camera error: \(reason). Trying to restart it…")
            guard let self else { return }
            queue.async { self.handleRuntimeError(message) }
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) {
            [weak self] _ in
            guard let self else { return }
            queue.async { self.onProblem?(String(localized: "The camera was interrupted — another app may be using it.")) }
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) {
            [weak self] _ in
            guard let self else { return }
            queue.async { self.onProblem?(nil) }
        })
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        restartAttempt = 0 // frames flow again: the next runtime error starts the backoff over
        onFrame?(sampleBuffer)
    }
}

extension CameraDevice {
    init(_ device: AVCaptureDevice) {
        self.init(id: device.uniqueID, name: device.localizedName, isSuspended: device.isSuspended,
                  isContinuity: device.isContinuityCamera)
    }
}

enum CameraError: LocalizedError {
    case noCamera, cannotAddInput, cannotAddOutput
    case suspended(String)
    case couldNotStart(String)
    var errorDescription: String? {
        switch self {
        case .suspended(let name): String(localized: "\(name) is unavailable (is the lid closed?). Pick another camera.")
        case .noCamera: String(localized: "No camera found.")
        case .cannotAddInput: String(localized: "The camera is busy or unavailable.")
        case .cannotAddOutput: String(localized: "Could not read frames from the camera.")
        case .couldNotStart(let name): String(localized: "\(name) didn't start. It may be in use by another app.")
        }
    }
}
