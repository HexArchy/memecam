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
///   reconnects if the sink stalls. A kCMIOHardwarePropertyDevices listener reacts to the extension
///   appearing / disappearing immediately.
final class VirtualCameraSink: FrameSink, @unchecked Sendable {
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
        let now = Self.nowNanos()
        hot.withLockUnchecked { h in
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
        let (lastFrame, lastEnqueue) = hot.withLockUnchecked { ($0.lastFrameNanos, $0.lastEnqueueNanos) }
        let framesFlowing = lastFrame > 0 && now &- lastFrame < 2_000_000_000
        if stream != 0 {
            // Frames arrive but nothing could be enqueued for 3 s: the extension stopped consuming. Reconnect.
            if framesFlowing && now &- lastEnqueue > 3_000_000_000 {
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
