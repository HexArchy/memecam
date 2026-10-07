import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import os

/// Feeds composited frames into the camera extension's sink stream.
///
/// Threading:
/// - `send` is called on the capture queue. It never blocks on IPC: it only touches the CMSimpleQueue
///   (lock-free) under a short unfair lock and drops the frame when the queue is full or not connected.
/// - Everything that talks to the CMIO server (discovery, start/stop, listeners) runs on `io`, a private
///   serial queue. A 0.5 s tick on `io` connects lazily once frames flow, retries with backoff
///   (0.5 s → 2 s, i.e. a 2 s poll while the device is missing), checks device presence every 2 s and
///   reconnects if the sink stalls. When no frames were sent for 2 s (MemeCam's camera stopped) it
///   disconnects, so the extension stops polling the sink and shows its placeholder; the next frame
///   reconnects. A kCMIOHardwarePropertyDevices listener reacts to the extension
///   appearing / disappearing immediately.
/// - Consumer monitoring (idle mode): while enabled, every tick reads how many apps have the camera
///   open and reports changes to the main actor.
/// - Health monitoring (pill popover): while enabled, every tick reports the delivered frame rate and the
///   number of apps reading the camera.
/// - Test pattern: while an override feed is active, frames from the pipeline (`send`) are dropped and
///   only `sendOverride` frames reach the extension.
///
/// `@unchecked Sendable` invariant: the hot-path state is behind `hot`; everything else is only touched
/// on `io` (serial).
final class VirtualCameraSink: FrameSink, @unchecked Sendable {
    /// Live numbers for the health checklist.
    struct Health: Equatable, Sendable {
        /// Frames per second enqueued into the extension (rounded to 0.5).
        var fps: Double = 0
        /// Apps reading the MemeCam camera; nil when unknown (device missing, older extension).
        var clients: Int?
    }

    enum Status: Equatable, Sendable {
        /// The MemeCam CMIO device is not visible (extension not installed, not approved, or restarting).
        case deviceMissing
        /// The device exists, but no frames are currently being delivered.
        case ready
        /// Frames were enqueued within the last second.
        case streaming
    }

    // MARK: Hot-path state (capture queue + io), guarded by `hot`.

    private struct Hot {
        var queue: CMSimpleQueue?
        var format: CMVideoFormatDescription?
        var lastFrameNanos: UInt64 = 0
        var lastEnqueueNanos: UInt64 = 0
        /// Frames enqueued so far (health fps).
        var enqueued: UInt64 = 0
        /// The test pattern owns the feed; pipeline frames are dropped.
        var override = false
    }

    // CMSimpleQueue / CMFormatDescription are not Sendable; they never leave the lock except on `io`
    // during connect/disconnect, which is serialized.
    private let hot = OSAllocatedUnfairLock(uncheckedState: Hot())

    // MARK: io-confined state (only touched on `io`).

    private let io = DispatchQueue(label: "com.hexarch.memecam.virtual-camera-sink", qos: .userInitiated)
    private let log = Logger(subsystem: "com.hexarch.memecam", category: "virtual-camera")
    private var device = CMIODeviceID(0)
    private var stream = CMIOStreamID(0)
    private var timer: DispatchSourceTimer?
    private var listener: CMIOObjectPropertyListenerBlock?
    private var nextAttemptNanos: UInt64 = 0
    private var backoff: Double = 0.5
    private var lastPresenceCheckNanos: UInt64 = 0
    private var devicePresent = false
    private var reported: Status?
    private var statusHandler: (@MainActor @Sendable (Status) -> Void)?
    /// The MemeCam device as of the last presence check (0 when missing).
    private var presentDevice = CMIODeviceID(0)
    private var monitorConsumers = false
    private var reportedConsumer: Bool?
    private var consumerHandler: (@MainActor @Sendable (Bool) -> Void)?
    private var healthHandler: (@MainActor @Sendable (Health) -> Void)?
    private var reportedHealth: Health?
    private var fpsSample: (count: UInt64, nanos: UInt64) = (0, 0)
    private var fps = 0.0

    init() {
        io.async { [self] in startMonitoring() }
    }

    /// `handler` runs on the main actor whenever the status changes (and once right after being set).
    func setStatusHandler(_ handler: @escaping @MainActor @Sendable (Status) -> Void) {
        io.async { [self] in
            statusHandler = handler
            reported = nil
            checkPresence(force: true)
        }
    }

    /// `handler` runs on the main actor with "another app reads the MemeCam camera" whenever that
    /// changes while monitoring is on (and once right after monitoring is switched on).
    func setConsumerHandler(_ handler: @escaping @MainActor @Sendable (Bool) -> Void) {
        io.async { [self] in consumerHandler = handler }
    }

    /// `handler` runs on the main actor with fresh numbers every 0.5 s while it is set; nil stops it.
    func monitorHealth(_ handler: (@MainActor @Sendable (Health) -> Void)?) {
        io.async { [self] in
            healthHandler = handler
            reportedHealth = nil
            if handler != nil { checkHealth(now: Self.nowNanos()) }
        }
    }

    /// While on, pipeline frames are ignored and only `sendOverride` feeds the camera.
    func setOverride(_ on: Bool) {
        hot.withLockUnchecked { $0.override = on }
    }

    /// Consumer monitoring costs one CMIO property read per tick, so it only runs while the answer
    /// matters (MemeCam's window is hidden and its camera runs).
    func monitorConsumers(_ on: Bool) {
        io.async { [self] in
            guard monitorConsumers != on else { return }
            monitorConsumers = on
            reportedConsumer = nil
            if on { checkConsumers() }
        }
    }

    /// Whether some process has the MemeCam device running (another app reading it, or our own sink feed).
    /// False when the device is missing. Talks to the CMIO server, so it hops to `io`.
    func isDeviceRunningSomewhere() async -> Bool {
        await withCheckedContinuation { continuation in
            io.async {
                let running = CMIO.findVirtualCamera().flatMap(CMIO.isRunningSomewhere) ?? false
                continuation.resume(returning: running)
            }
        }
    }

    /// Re-checks device presence now (e.g. after the extension was approved).
    func checkNow() {
        io.async { [self] in
            nextAttemptNanos = 0
            backoff = 0.5
            checkPresence(force: true)
        }
    }

    // MARK: FrameSink (capture queue)

    func send(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        enqueue(pixelBuffer, override: false)
    }

    /// Test-pattern frames (any thread).
    func sendOverride(_ pixelBuffer: CVPixelBuffer) {
        enqueue(pixelBuffer, override: true)
    }

    private func enqueue(_ pixelBuffer: CVPixelBuffer, override: Bool) {
        let now = Self.nowNanos()
        hot.withLockUnchecked { h in
            guard h.override == override else { return }
            h.lastFrameNanos = now
            guard let queue = h.queue,
                  CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { return } // drop
            if h.format == nil || !CMVideoFormatDescriptionMatchesImageBuffer(h.format!, imageBuffer: pixelBuffer) {
                h.format = nil
                CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                             formatDescriptionOut: &h.format)
            }
            guard let format = h.format else { return }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                            decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: format,
                sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
            // The extension takes ownership of the +1 retain.
            let element = Unmanaged.passRetained(sample)
            if CMSimpleQueueEnqueue(queue, element: element.toOpaque()) == noErr {
                h.lastEnqueueNanos = now
                h.enqueued &+= 1
            } else {
                element.release()
            }
        }
    }

    // MARK: io

    private func startMonitoring() {
        listener = CMIO.addDevicesListener(queue: io) { [weak self] in
            // Listener runs on `io`.
            guard let self else { return }
            nextAttemptNanos = 0
            backoff = 0.5
            checkPresence(force: true)
        }
        let t = DispatchSource.makeTimerSource(queue: io)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        let now = Self.nowNanos()
        checkPresence(force: false)
        if monitorConsumers { checkConsumers() }
        if healthHandler != nil { checkHealth(now: now) }
        let (lastFrame, lastEnqueue) = hot.withLockUnchecked { ($0.lastFrameNanos, $0.lastEnqueueNanos) }
        let framesFlowing = lastFrame > 0 && now &- lastFrame < 2_000_000_000
        if stream != 0 {
            if !framesFlowing {
                // Camera stopped: release the sink so the extension idles on its placeholder instead of
                // polling an empty queue. Connecting is lazy, so frames resuming reconnect on the next tick.
                log.info("no frames for 2 s, disconnecting sink")
                disconnect()
            } else if now &- lastEnqueue > 3_000_000_000 {
                // Frames arrive but nothing could be enqueued for 3 s: the extension stopped consuming. Reconnect.
                log.notice("sink stalled, reconnecting")
                disconnect()
                scheduleRetry(now: now)
            }
        } else if framesFlowing && devicePresent && now >= nextAttemptNanos {
            connect(now: now)
        }
        report()
    }

    private func checkPresence(force: Bool) {
        let now = Self.nowNanos()
        guard force || now &- lastPresenceCheckNanos >= 2_000_000_000 else { return }
        lastPresenceCheckNanos = now
        let found = CMIO.findVirtualCamera()
        devicePresent = found != nil
        presentDevice = found ?? 0
        if stream != 0 && found != device {
            log.notice("virtual camera device went away")
            disconnect()
        }
        report()
    }

    private func connect(now: UInt64) {
        guard let dev = CMIO.findVirtualCamera() else {
            devicePresent = false
            scheduleRetry(now: now)
            return
        }
        guard let sinkStream = CMIO.sinkStream(of: dev) else {
            log.error("MemeCam device has no sink stream")
            scheduleRetry(now: now)
            return
        }
        var unmanaged: Unmanaged<CMSimpleQueue>?
        // The queue-altered proc must be non-nil, otherwise CMIO returns noErr but no queue.
        let status = CMIOStreamCopyBufferQueue(sinkStream, { _, _, _ in }, nil, &unmanaged)
        guard status == noErr, let unmanaged else {
            log.error("CMIOStreamCopyBufferQueue failed: \(status)")
            scheduleRetry(now: now)
            return
        }
        let queue = unmanaged.takeRetainedValue()
        let start = CMIODeviceStartStream(dev, sinkStream)
        guard start == noErr else {
            log.error("CMIODeviceStartStream failed: \(start)")
            CMIOStreamCopyBufferQueue(sinkStream, nil, nil, nil)
            scheduleRetry(now: now)
            return
        }
        device = dev
        stream = sinkStream
        backoff = 0.5
        hot.withLockUnchecked { h in
            h.queue = queue
            h.lastEnqueueNanos = now // grace period for stall detection
        }
        log.info("connected to MemeCam sink stream")
    }

    private func disconnect() {
        let queue = hot.withLockUnchecked { h -> CMSimpleQueue? in
            defer { h.queue = nil }
            return h.queue
        }
        if stream != 0 {
            CMIODeviceStopStream(device, stream)
            CMIOStreamCopyBufferQueue(stream, nil, nil, nil) // release our queue registration
        }
        if let queue {
            // Samples still queued were never handed to the extension: drop our +1.
            while let element = CMSimpleQueueDequeue(queue) {
                Unmanaged<CMSampleBuffer>.fromOpaque(element).release()
            }
        }
        device = 0
        stream = 0
        report()
    }

    /// Another app (Discord, Zoom…) reads the MemeCam camera. The extension publishes its source-client
    /// count; an older extension without that property only offers kCMIODevicePropertyDeviceIsRunningSomewhere,
    /// which our own sink feed also sets, so while connected the answer is "assume yes" (never idle wrongly).
    private func checkConsumers() {
        let active: Bool
        if presentDevice == 0 {
            active = false // no device: nobody can be watching
        } else if let clients = CMIO.sourceClients(presentDevice) {
            active = clients > 0
        } else if stream == 0 {
            active = CMIO.isRunningSomewhere(presentDevice) ?? false
        } else {
            active = true
        }
        guard active != reportedConsumer, let handler = consumerHandler else { return }
        reportedConsumer = active
        log.info("virtual camera consumer active: \(active)")
        Task { @MainActor in handler(active) }
    }

    private func checkHealth(now: UInt64) {
        let count = hot.withLockUnchecked { $0.enqueued }
        if fpsSample.nanos > 0, now > fpsSample.nanos {
            let instant = Double(count &- fpsSample.count) / (Double(now - fpsSample.nanos) / 1e9)
            fps = fps * 0.5 + instant * 0.5
            if instant == 0 { fps = 0 }
        }
        fpsSample = (count, now)
        let clients = presentDevice == 0 ? nil : CMIO.sourceClients(presentDevice)
        let health = Health(fps: (fps * 2).rounded() / 2, clients: clients)
        guard health != reportedHealth, let handler = healthHandler else { return }
        reportedHealth = health
        Task { @MainActor in handler(health) }
    }

    private func scheduleRetry(now: UInt64) {
        nextAttemptNanos = now + UInt64(backoff * 1_000_000_000)
        backoff = min(backoff * 2, 2)
    }

    private func report() {
        let now = Self.nowNanos()
        let status: Status
        if stream != 0, now &- hot.withLockUnchecked({ $0.lastEnqueueNanos }) < 1_000_000_000 {
            status = .streaming
        } else {
            status = devicePresent ? .ready : .deviceMissing
        }
        guard status != reported, let handler = statusHandler else { return }
        reported = status
        Task { @MainActor in handler(status) }
    }

    private static func nowNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
}
