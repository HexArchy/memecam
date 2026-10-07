import CoreMediaIO
import CoreVideo
import Foundation
import os

/// The "MemeCam" device: a source stream for camera clients plus a sink stream fed by the app.
///
/// Frame policy:
/// - App frames consumed from the sink are forwarded to the source immediately (lowest latency).
/// - A 30 fps timer runs while any source client is connected. If the app has not delivered a frame for
///   more than 0.5 s it emits the "paused" placeholder; if the app is live but slower than 30 fps it
///   re-sends the latest app frame, so clients always see a steady stream instead of a frozen frame.
final class DeviceSource: NSObject, CMIOExtensionDeviceSource, @unchecked Sendable {
    // Invariant: everything below `queue` is only touched on `queue` (serial), except the immutable
    // `device`, `source`, `sink` set in init.
    private(set) var device: CMIOExtensionDevice!
    private var source: SourceStreamSource!
    private var sink: SinkStreamSource!

    private let queue = DispatchQueue(label: "com.hexarch.memecam.camera-extension.device", qos: .userInteractive)
    private let log = Logger(subsystem: "com.hexarch.memecam.camera-extension", category: "device")

    private var sourceClients = 0
    private var sinkClient: CMIOExtensionClient?
    /// Incremented on every sink start/stop so stale consume callbacks stop their loop.
    private var sinkGeneration = 0
    private var timer: DispatchSourceTimer?
    /// Delay before re-polling an empty sink queue: doubles from 5 ms up to one frame (33 ms) while the
    /// app sends nothing, and drops back to 5 ms on the next buffer. Keeps an idle-but-connected sink from
    /// waking the extension 200 times a second.
    private var idleRetryMs = DeviceSource.minIdleRetryMs
    private static let minIdleRetryMs = 5
    private static let maxIdleRetryMs = 33

    private var latestAppFrame: CVPixelBuffer?
    private var latestAppFrameNanos: UInt64 = 0
    private var lastSentNanos: UInt64 = 0
    private var formatDescription: CMVideoFormatDescription?
    private lazy var placeholder: CVPixelBuffer? = PlaceholderRenderer.render(
        width: Int(Config.width), height: Int(Config.height))

    override init() {
        super.init()
        var desc: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                       width: Config.width, height: Config.height, extensions: nil,
                                       formatDescriptionOut: &desc)
        guard let desc else { fatalError("MemeCam: cannot create format description") }
        let format = CMIOExtensionStreamFormat(formatDescription: desc, maxFrameDuration: Config.frameDuration,
                                               minFrameDuration: Config.frameDuration, validFrameDurations: nil)
        device = CMIOExtensionDevice(localizedName: Config.deviceName, deviceID: Config.deviceID,
                                     legacyDeviceID: Config.deviceUID, source: self)
        source = SourceStreamSource(format: format, owner: self)
        sink = SinkStreamSource(format: format, owner: self)
        do {
            try device.addStream(source.stream)
            try device.addStream(sink.stream)
        } catch {
            fatalError("MemeCam: failed to add streams: \(error)")
        }
    }

    // MARK: CMIOExtensionDeviceSource

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { result.transportType = 0x7669_7274 } // 'virt'
        if properties.contains(.deviceModel) { result.model = Config.deviceName }
        return result
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: Stream lifecycle (called from CMIO's client queue; hop to `queue`)

    func sourceDidStart() {
        queue.async { [self] in
            sourceClients += 1
            log.info("source started, clients=\(self.sourceClients)")
            startTimerIfNeeded()
        }
    }

    func sourceDidStop() {
        queue.async { [self] in
            sourceClients = max(0, sourceClients - 1)
            log.info("source stopped, clients=\(self.sourceClients)")
            if sourceClients == 0 { stopTimer() }
        }
    }

    func sinkDidStart(client: CMIOExtensionClient) {
        // Immutable handle from CMIO; it is only stored and used on `queue` afterwards.
        nonisolated(unsafe) let client = client
        queue.async { [self] in
            sinkGeneration += 1
            sinkClient = client
            idleRetryMs = Self.minIdleRetryMs
            log.info("sink started")
            consume(generation: sinkGeneration)
        }
    }

    func sinkDidStop() {
        queue.async { [self] in
            sinkGeneration += 1
            sinkClient = nil
            latestAppFrame = nil
            log.info("sink stopped")
        }
    }

    // MARK: Sink -> source

    private func consume(generation: Int) {
        guard generation == sinkGeneration, let client = sinkClient else { return }
        sink.stream.consumeSampleBuffer(from: client) { [weak self] buffer, sequence, _, _, error in
            guard let self else { return }
            // Not Sendable, but we only read the image buffer from it on `queue`.
            nonisolated(unsafe) let buffer = buffer
            queue.async {
                guard generation == self.sinkGeneration else { return }
                if let buffer {
                    self.idleRetryMs = Self.minIdleRetryMs
                    let now = HostClock.nowNanos()
                    self.sink.stream.notifyScheduledOutputChanged(
                        CMIOExtensionScheduledOutput(sequenceNumber: sequence, hostTimeInNanoseconds: now))
                    if let pixels = CMSampleBufferGetImageBuffer(buffer) {
                        self.latestAppFrame = pixels
                        self.latestAppFrameNanos = now
                        self.emit(pixels, at: now)
                    }
                    self.consume(generation: generation)
                } else {
                    // Nothing queued (or a transient error): back off instead of spinning.
                    if let error { self.log.debug("consume: \(error.localizedDescription)") }
                    let delay = self.idleRetryMs
                    self.idleRetryMs = min(delay * 2, Self.maxIdleRetryMs)
                    self.queue.asyncAfter(deadline: .now() + .milliseconds(delay)) {
                        self.consume(generation: generation)
                    }
                }
            }
        }
    }

    // MARK: Pacing timer

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        let interval = 1_000_000_000 / UInt64(Config.fps)
        t.schedule(deadline: .now(), repeating: .nanoseconds(Int(interval)), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let now = HostClock.nowNanos()
        let interval = 1_000_000_000 / UInt64(Config.fps)
        if let frame = latestAppFrame, now &- latestAppFrameNanos <= Config.staleAfterNanos {
            // App is live: only fill gaps when it runs slower than our output rate.
            if now &- lastSentNanos >= interval + interval / 3 { emit(frame, at: now) }
        } else {
            latestAppFrame = nil
            if let placeholder { emit(placeholder, at: now) }
        }
    }

    /// Wraps the pixel buffer into a fresh sample buffer stamped with the current host time and sends it.
    private func emit(_ pixels: CVPixelBuffer, at now: UInt64) {
        guard sourceClients > 0 else { return }
        if formatDescription == nil || !CMVideoFormatDescriptionMatchesImageBuffer(formatDescription!, imageBuffer: pixels) {
            formatDescription = nil
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                         formatDescriptionOut: &formatDescription)
        }
        guard let formatDescription else { return }
        var timing = CMSampleTimingInfo(duration: Config.frameDuration,
                                        presentationTimeStamp: CMTime(value: CMTimeValue(now), timescale: 1_000_000_000),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescription: formatDescription,
            sampleTiming: &timing, sampleBufferOut: &sample)
        guard status == noErr, let sample else { return }
        source.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: now)
        lastSentNanos = now
    }
}
