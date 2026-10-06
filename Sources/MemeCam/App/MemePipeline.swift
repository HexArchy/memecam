@preconcurrency import AVFoundation
import CoreImage
import MemeCamCore
import os

struct PipelineSettings: Sendable, Equatable {
    var layout: OutputLayout = .sideBySide
    var animals: AnimalFilter = .both
    var sensitivity: Double = 1
    /// 0.5 = snappy, 2 = calm.
    var calmness: Double = 1
    var showCaption = true
    var mirror = true
    var detectHands = true
    var detectExpressions = true
}

/// What the UI needs to know, published at most ~10×/s.
struct PipelineStatus: Sendable {
    var reaction: Reaction = .noFace
    var confidence: Double = 0
    var meme: Meme?
    var metrics: FaceMetrics?
    var outputFPS: Double = 0
    var inferenceMs: Double = 0
}

/// camera → (Vision on its own queue) → classifier → meme → compositor → sinks.
///
/// Compositing runs on every camera frame using the latest known reaction, while Vision
/// runs on a separate queue and simply skips frames when busy. Output therefore stays at
/// camera FPS even if inference momentarily slows down.
final class MemePipeline: @unchecked Sendable {
    let library = MemeLibrary()
    private let camera = CameraCapture()
    private let detector = VisionDetector()
    private let compositor = Compositor()
    private let visionQueue = DispatchQueue(label: "memecam.vision", qos: .userInitiated)

    private struct State {
        var settings = PipelineSettings()
        var classifier = ReactionClassifier()
        var stabilizer = ReactionStabilizer()
        var visionBusy = false
        var reaction: Reaction = .noFace
        var confidence = 0.0
        var metrics: FaceMetrics?
        var meme: Meme?
        var memeImage: AnimatedImage?
        var previousFrame: CGImage?
        var memeStart: TimeInterval = 0
        var forcedUntil: TimeInterval = 0
        var calibrateNext = false
        var inferenceMs = 0.0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let sinksLock = OSAllocatedUnfairLock(initialState: [any FrameSink]())

    var onStatus: (@Sendable (PipelineStatus) -> Void)?
    private var lastStatusTime: TimeInterval = 0
    private var frameTimes: [TimeInterval] = []

    init() {
        camera.onFrame = { [weak self] in self?.handle($0) }
        // Prefetch the "nobody here" meme so the first frame already has something.
        library.prefetch(library.memes(for: .noFace))
    }

    // MARK: Control

    func start(deviceID: String?) throws { try camera.start(deviceID: deviceID) }
    func stop() { camera.stop() }

    func addSink(_ sink: any FrameSink) { sinksLock.withLock { $0.append(sink) } }
    func removeSink(_ sink: any FrameSink) { sinksLock.withLock { $0.removeAll { $0 === sink } } }

    func update(_ settings: PipelineSettings) {
        state.withLock { s in
            let animalsChanged = s.settings.animals != settings.animals
            s.settings = settings
            s.classifier.config.sensitivity = settings.sensitivity
            s.classifier.config.enableGestures = settings.detectHands
            s.classifier.config.enableExpressions = settings.detectExpressions
            s.stabilizer.delayScale = settings.calmness
            s.stabilizer.minHold = 0.9 * settings.calmness
            if animalsChanged { s.meme = nil } // re-pick on next frame
        }
        detector.detectHands = settings.detectHands
    }

    /// Next face frame becomes the user's neutral baseline.
    func calibrate() { state.withLock { $0.calibrateNext = true } }

    /// Show a specific reaction for a few seconds (clicking a reaction in the UI).
    func force(_ reaction: Reaction, seconds: TimeInterval = 3) {
        let now = CACurrentMediaTime()
        state.withLock { s in
            s.forcedUntil = now + seconds
            setReaction(reaction, confidence: 1, now: now, in: &s)
        }
    }

    // MARK: Frame path (capture queue)

    private func handle(_ sample: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let now = CACurrentMediaTime()
        runVisionIfIdle(pixelBuffer, now: now)

        let cameraImage = CIImage(cvPixelBuffer: pixelBuffer)
        let input: CompositorInput = state.withLock { s in
            if s.meme == nil { setReaction(s.reaction, confidence: s.confidence, now: now, in: &s) }
            let t = now - s.memeStart
            let transition = min(1, t / 0.18)
            return CompositorInput(
                camera: cameraImage,
                meme: s.memeImage?.frame(at: t),
                previousMeme: transition < 1 ? s.previousFrame : nil,
                transition: transition,
                caption: s.settings.showCaption ? s.meme?.title : nil,
                layout: s.settings.layout,
                mirror: s.settings.mirror)
        }
        guard let out = compositor.render(input) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        for sink in sinksLock.withLock({ $0 }) { sink.send(out, time: time) }
        publishStatus(now: now)
    }

    private func runVisionIfIdle(_ pixelBuffer: CVPixelBuffer, now: TimeInterval) {
        let busy = state.withLock { s in
            if s.visionBusy { return true }
            s.visionBusy = true
            return false
        }
        guard !busy else { return }
        // CVPixelBuffer is immutable once captured; reading it from another queue is safe.
        nonisolated(unsafe) let pixelBuffer = pixelBuffer
        visionQueue.async { [self] in
            let t0 = CACurrentMediaTime()
            let obs = detector.detect(pixelBuffer, timestamp: now)
            let ms = (CACurrentMediaTime() - t0) * 1000
            state.withLock { s in
                s.visionBusy = false
                s.inferenceMs = s.inferenceMs * 0.9 + ms * 0.1
                if s.calibrateNext, let m = obs.face.flatMap(FaceMetrics.init) {
                    s.classifier.calibrate(to: m)
                    s.calibrateNext = false
                }
                let est = s.classifier.classify(obs)
                s.metrics = est.metrics
                guard now >= s.forcedUntil else { return }
                if let changed = s.stabilizer.update(est.reaction, at: now) {
                    setReaction(changed, confidence: est.confidence, now: now, in: &s)
                } else if est.reaction == s.reaction {
                    s.confidence = est.confidence
                }
            }
        }
    }

    private func setReaction(_ r: Reaction, confidence: Double, now: TimeInterval, in s: inout State) {
        let t = now - s.memeStart
        s.previousFrame = s.memeImage?.frame(at: t)
        s.reaction = r
        s.confidence = confidence
        s.meme = library.pick(for: r, filter: s.settings.animals)
        s.memeStart = now
        guard let meme = s.meme else { s.memeImage = nil; return }
        if let img = library.cachedImage(for: meme) {
            s.memeImage = img
            return
        }
        // Cold decode off the hot path; keep showing the previous meme until it is ready.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let img = library.image(for: meme)
            state.withLock { s in
                guard s.meme == meme else { return }
                s.previousFrame = s.memeImage?.frame(at: CACurrentMediaTime() - s.memeStart)
                s.memeImage = img
                s.memeStart = CACurrentMediaTime()
            }
        }
    }

    private func publishStatus(now: TimeInterval) {
        frameTimes.append(now)
        if frameTimes.count > 30 { frameTimes.removeFirst(frameTimes.count - 30) }
        guard now - lastStatusTime > 0.1, let onStatus else { return }
        lastStatusTime = now
        let fps = frameTimes.count > 1 ? Double(frameTimes.count - 1) / (frameTimes.last! - frameTimes.first!) : 0
        let status = state.withLock { s in
            PipelineStatus(reaction: s.reaction, confidence: s.confidence, meme: s.meme,
                           metrics: s.metrics, outputFPS: fps, inferenceMs: s.inferenceMs)
        }
        onStatus(status)
    }
}
