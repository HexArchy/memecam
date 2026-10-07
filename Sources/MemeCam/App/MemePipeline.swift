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
    var showCaption = false
    var mirror = true
    var detectHands = true
    var detectExpressions = true
    /// Quiet mode: nothing is shown while neutral; memes pop up on a reaction and hide again.
    var quietMode = true
    /// Quiet mode: how long a meme stays up, seconds.
    var popDuration: Double = 4
    /// Panic switch: plain camera out, detection keeps running but triggers nothing.
    var paused = false
    /// Reactions switched off by the user: they never pop up.
    var disabledReactions: Set<Reaction> = []
    /// Seconds before the same reaction may pop up again.
    var cooldown: Double = 4
    /// How memes appear in quiet mode (already `.fade` when the system asks to reduce motion).
    var popStyle: PopStyle = .pop
    /// Seconds of "nobody here" before the "Be right back" card; nil = off.
    var awayAfter: TimeInterval? = AwayDelay.default.seconds
    /// Virtual camera / preview size and aspect.
    var outputFormat: OutputFormat = .default
}

/// What the UI needs to know, published at most ~10×/s.
struct PipelineStatus: Sendable {
    var reaction: Reaction = .noFace
    var confidence: Double = 0
    var meme: Meme?
    var metrics: FaceMetrics?
    var outputFPS: Double = 0
    var inferenceMs: Double = 0
    /// Something is wrong with the camera feed (user-facing text), nil when fine.
    var cameraIssue: String?
    var cameraName = ""
    /// Interactive accuracy test state (nil when not running).
    var guided: GuidedSession.Snapshot?
    /// Neutral-face calibration: progress 0...1 while measuring, and the current state.
    var calibrationProgress: Double = 1
    var calibration: ReactionClassifier.Calibration = .none
    /// True when a face is currently visible (for onboarding guidance).
    var faceVisible = false
    /// Nobody watches (window hidden, no virtual-camera client): Vision and compositing are paused.
    var idle = false
    /// Vision rate cap in effect (Hz).
    var visionHz = PowerMode.normalHz
    /// Why the pipeline runs below normal speed (idle, Low Power Mode, hot Mac), nil at full speed.
    var powerNote: String?
    /// The person left: the output shows the "Be right back" card.
    var away = false
}

/// camera → (Vision on its own queue) → classifier → meme → compositor → sinks.
///
/// Compositing runs on every camera frame using the latest known reaction, while Vision
/// runs on a separate queue at ~15 Hz (time-gated) and skips frames when busy. Output therefore
/// stays at camera FPS even if inference momentarily slows down. While idle (`PowerMode.idle`) frames
/// are dropped right after the health bookkeeping: no Vision, no compositing, nothing sent to sinks.
///
/// Concurrency: every piece of mutable state sits behind a lock — `state` (reaction/meme/classifier,
/// shared by the capture and vision queues), `feed` (camera health and pacing), `sinksLock` and
/// `callbacks`. Everything else is an immutable reference to a type that documents its own confinement
/// (`CameraCapture`: capture queue, `VisionDetector`: vision queue), so the class is checked `Sendable`.
final class MemePipeline: Sendable {
    let library = MemeLibrary()
    private let camera: CameraCapture
    private let detector = VisionDetector()
    private let compositor = Compositor()
    private let visionQueue = DispatchQueue(label: "memecam.vision", qos: .userInitiated)

    private struct State {
        var settings = PipelineSettings()
        var classifier = ReactionClassifier()
        var stabilizer = ReactionStabilizer()
        var gate = ReactionGate()
        var visionBusy = false
        var reaction: Reaction = .noFace
        var confidence = 0.0
        var metrics: FaceMetrics?
        var meme: Meme?
        var memeImage: AnimatedImage?
        var previousFrame: CGImage?
        var memeStart: TimeInterval = 0
        var forcedUntil: TimeInterval = 0
        /// What's on screen was asked for by the user (palette, hotkey, preview), not detected.
        var forcedShown = false
        /// Whether the meme is on screen (quiet mode hides it), and when that last changed.
        var visible = false
        var visibleChanged: TimeInterval = 0
        var shownAt: TimeInterval = 0
        var calibrateNext = false
        var guided: GuidedSession?
        var inferenceMs = 0.0
        /// Caps Vision at `PowerMode.visionHz` (0 while idle), lower while away.
        var visionGate = RateGate(hz: PowerMode.normalHz)
        var powerHz = PowerMode.normalHz
        /// "Be right back" after a while of "nobody here"; `awayChanged` starts its pop animation.
        var away = AwayTracker()
        var awayChanged: TimeInterval = -.infinity
        /// Rolling inference stats for the periodic log line.
        var visionRuns = 0
        var visionMsSum = 0.0
        var visionLogStart: TimeInterval = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Output sinks; `whileVisible` ones (the on-screen preview) are skipped while no window shows them.
    private let sinksLock = OSAllocatedUnfairLock(initialState: [(sink: any FrameSink, whileVisible: Bool)]())

    /// Camera-feed health and output pacing. Written by frames and the watchdog (capture queue) and by
    /// start/stop/setPower (main actor), read when publishing the status.
    private struct Feed {
        var running = false
        var watchdogResumed = false
        var lastFrameTime: TimeInterval = 0
        var darkSince: TimeInterval?
        var lastBrightnessCheck: TimeInterval = 0
        var darkFeed = false
        var sessionProblem: String?
        var frameTimes: [TimeInterval] = []
        var lastStatusTime: TimeInterval = 0
        var power = PowerMode()
        var windowVisible = true
    }
    private let feed = OSAllocatedUnfairLock(initialState: Feed())

    private struct Callbacks {
        var onStatus: (@Sendable (PipelineStatus) -> Void)?
        var onRecordingFinished: (@Sendable (Recording, GuidedPurpose) -> Void)?
    }

    /// What a guided session is for: the accuracy test scores, teaching trains the personal model.
    enum GuidedPurpose: Sendable { case test, teach }
    private let callbacks = OSAllocatedUnfairLock(initialState: Callbacks())
    /// One watchdog for the pipeline's lifetime (a 1 s timer on the capture queue): resumed by `start`,
    /// suspended by `stop`, so camera switches and restarts never stack extra loops.
    /// Never cancelled or released while suspended (the pipeline lives as long as the app).
    private let watchdog: any DispatchSourceTimer
    private let log = Logger(subsystem: "com.hexarch.memecam", category: "pipeline")

    var onStatus: (@Sendable (PipelineStatus) -> Void)? {
        get { callbacks.withLock { $0.onStatus } }
        set { callbacks.withLock { $0.onStatus = newValue } }
    }
    /// Called (on a utility queue) when a guided session (accuracy test or teaching) completes.
    var onRecordingFinished: (@Sendable (Recording, GuidedPurpose) -> Void)? {
        get { callbacks.withLock { $0.onRecordingFinished } }
        set { callbacks.withLock { $0.onRecordingFinished = newValue } }
    }

    /// Starts a guided accuracy session: prompts every reaction in turn and records
    /// labelled observations for offline evaluation.
    func startGuidedSession() {
        let now = CACurrentMediaTime()
        state.withLock { $0.guided = GuidedSession(start: now) }
    }

    /// "Teach MemeCam": every reaction in `reactions` twice, recorded for the personal model.
    func startTeachSession(reactions: [Reaction]) {
        let now = CACurrentMediaTime()
        state.withLock { $0.guided = .teaching(start: now, reactions: reactions) }
    }

    /// What the user taught (nil = built-in rules only).
    func setPersonalModel(_ model: PersonalModel?) {
        state.withLock { $0.classifier.personal = model }
    }

    func cancelGuidedSession() { state.withLock { $0.guided = nil } }
    func toggleGuidedPause() { let now = CACurrentMediaTime(); state.withLock { $0.guided?.togglePause(now) } }
    func skipGuidedStep() { let now = CACurrentMediaTime(); state.withLock { $0.guided?.skip(now) } }
    func redoGuidedStep() { let now = CACurrentMediaTime(); state.withLock { $0.guided?.redoPrevious(now) } }

    init() {
        let camera = CameraCapture()
        self.camera = camera
        watchdog = DispatchSource.makeTimerSource(queue: camera.queue)
        // Learned hand-gesture model (HaGRID v2). Bundled app: Contents/Resources/Models;
        // `swift run`: ./Resources/Models. Rules alone are used if it can't be loaded.
        let modelURL = [Bundle.main.resourceURL?.appending(path: "Models/hand-gesture-mlp.json"),
                        URL(filePath: FileManager.default.currentDirectoryPath)
                            .appending(path: "Resources/Models/hand-gesture-mlp.json")]
            .compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
        if let modelURL, let data = try? Data(contentsOf: modelURL),
           let model = try? HandGestureModel(json: data) {
            state.withLock { $0.classifier.handModel = model }
        }
        camera.onFrame = { [weak self] in self?.handle($0) }
        camera.onProblem = { [weak self] problem in
            guard let self else { return }
            feed.withLock { $0.sessionProblem = problem }
            publishStatus(now: CACurrentMediaTime(), force: true)
        }
        watchdog.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        watchdog.setEventHandler { [weak self] in
            // Reports "no frames" while the camera is supposed to run (e.g. a sleeping iPhone).
            guard let self else { return }
            let now = CACurrentMediaTime()
            if feed.withLock({ $0.running && now - $0.lastFrameTime > 3 }) { publishStatus(now: now, force: true) }
        }
        // Prefetch the "nobody here" meme so the first frame already has something.
        library.prefetch(library.memes(for: .noFace))
    }

    // MARK: Control

    /// Starts the camera, or switches the running one to `deviceID`. Configuration runs on the capture
    /// queue; the caller just awaits. On failure the previous camera (if any) keeps running.
    func start(deviceID: String?) async throws -> CameraDevice {
        let device = try await camera.start(deviceID: deviceID)
        state.withLock { s in
            // A fresh start never begins on the "Be right back" card.
            s.away.reset()
            s.awayChanged = -.infinity
            Self.applyVisionRate(&s)
        }
        feed.withLock { f in
            f.sessionProblem = nil
            f.darkFeed = false
            f.darkSince = nil
            f.lastFrameTime = CACurrentMediaTime()
            f.running = true
            if !f.watchdogResumed {
                f.watchdogResumed = true
                watchdog.resume()
            }
        }
        return device
    }

    func stop() async {
        feed.withLock { f in
            f.running = false
            if f.watchdogResumed {
                f.watchdogResumed = false
                watchdog.suspend()
            }
        }
        await camera.stop()
    }

    /// Idle / low-power policy from AppModel. `windowVisible` also slows status updates while hidden.
    func setPower(_ mode: PowerMode, windowVisible: Bool) {
        feed.withLock { f in
            f.power = mode
            f.windowVisible = windowVisible
        }
        state.withLock { s in
            s.powerHz = mode.visionHz
            Self.applyVisionRate(&s)
        }
    }

    private static func applyVisionRate(_ s: inout State) {
        s.visionGate.hz = s.away.visionHz(power: s.powerHz)
    }

    /// Leaves away mode right away (camera restarted, paused, setting changed).
    private static func clearAway(now: TimeInterval, in s: inout State) {
        guard s.away.reset() else { return }
        s.awayChanged = now
        applyVisionRate(&s)
    }

    private func cameraIssue(_ f: Feed, now: TimeInterval) -> String? {
        if let problem = f.sessionProblem { return problem }
        let name = camera.activeDevice?.name ?? String(localized: "The camera")
        if f.running, now - f.lastFrameTime > 3 {
            return String(localized: "\(name) isn't sending video. If it's an iPhone, lock it and place it nearby in landscape, or pick another camera.")
        }
        if f.darkFeed {
            return String(localized: "\(name) shows a black picture. Check the lens cover, lighting, or that your iPhone is awake and nearby.")
        }
        return nil
    }

    func addSink(_ sink: any FrameSink, onlyWhileWindowVisible: Bool = false) {
        sinksLock.withLock { $0.append((sink, onlyWhileWindowVisible)) }
    }
    func removeSink(_ sink: any FrameSink) { sinksLock.withLock { $0.removeAll { $0.sink === sink } } }

    func update(_ settings: PipelineSettings) {
        camera.setFullHD(settings.outputFormat.resolution == .hd1080)
        state.withLock { s in
            let animalsChanged = s.settings.animals != settings.animals
            let resumed = s.settings.paused && !settings.paused
            s.settings = settings
            s.gate.disabled = settings.disabledReactions
            s.gate.cooldown = settings.cooldown
            s.classifier.config.sensitivity = settings.sensitivity
            s.classifier.config.enableGestures = settings.detectHands
            s.classifier.config.enableExpressions = settings.detectExpressions
            s.stabilizer.delayScale = settings.calmness
            s.stabilizer.minHold = 1.5 * settings.calmness
            if animalsChanged || resumed { s.meme = nil } // re-pick on next frame
            if settings.paused { Self.setVisible(false, now: CACurrentMediaTime(), in: &s) }
            // Paused means a plain camera: no away card either.
            let delay = settings.paused ? nil : settings.awayAfter
            if s.away.delay != delay {
                if delay == nil { Self.clearAway(now: CACurrentMediaTime(), in: &s) }
                s.away.delay = delay
            }
        }
    }

    /// Re-pick the current meme (it may have been removed or a new one added).
    func libraryChanged() { state.withLock { $0.meme = nil } }

    /// Next face frame becomes the user's neutral baseline.
    func calibrate() { state.withLock { $0.calibrateNext = true } }

    /// Show a specific reaction for a few seconds (clicking a reaction in the UI).
    /// Show exactly this meme for a few seconds (Preview in the meme editor).
    func force(meme: Meme, seconds: TimeInterval = 3) {
        let now = CACurrentMediaTime()
        state.withLock { s in
            s.forcedUntil = now + seconds
            setReaction(meme.reaction, confidence: 1, now: now, in: &s, meme: meme, forced: true)
        }
    }

    func force(_ reaction: Reaction, seconds: TimeInterval = 3) {
        let now = CACurrentMediaTime()
        state.withLock { s in
            s.forcedUntil = now + seconds
            setReaction(reaction, confidence: 1, now: now, in: &s, forced: true)
        }
    }

    // MARK: Frame path (capture queue)

    private func handle(_ sample: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let now = CACurrentMediaTime()
        let (idle, checkBrightness) = feed.withLock { f in
            f.lastFrameTime = now
            let check = !f.power.idle && now - f.lastBrightnessCheck > 1
            if check { f.lastBrightnessCheck = now }
            return (f.power.idle, check)
        }
        // Nobody watches: keep the camera warm (instant resume) but skip all per-frame work.
        guard !idle else { return publishStatus(now: now) }
        runVisionIfIdle(pixelBuffer, now: now)

        let cameraImage = CIImage(cvPixelBuffer: pixelBuffer)
        if checkBrightness {
            let dark = compositor.averageBrightness(
                cameraImage.transformed(by: CGAffineTransform(scaleX: 0.05, y: 0.05))) < 0.03
            feed.withLock { f in
                f.darkSince = dark ? (f.darkSince ?? now) : nil
                f.darkFeed = f.darkSince.map { now - $0 > 2.5 } ?? false
            }
        }
        let input: CompositorInput = state.withLock { s in
            if s.meme == nil, !s.settings.quietMode { setReaction(s.reaction, confidence: s.confidence, now: now, in: &s) }
            // Quiet mode: a meme pops up for `popDuration`, then the camera has the stage again
            // ("nobody here" stays while the person is away).
            if s.settings.quietMode, s.visible, s.reaction != .noFace || s.forcedShown, now >= s.forcedUntil,
               now - s.shownAt > s.settings.popDuration {
                Self.setVisible(false, now: now, in: &s)
            }
            // Quiet mode animates the pop-up in the chosen style; otherwise appearing is a plain crossfade.
            let style = s.settings.quietMode ? s.settings.popStyle : .fade
            let phase = min(1, (now - s.visibleChanged) / PopAnimation.duration(style, appearing: s.visible))
            // Paused cuts the meme instantly (panic switch), no fade-out.
            let presence = s.settings.paused ? 0 : s.visible ? phase : 1 - phase
            if s.visible { s.gate.noteOnScreen(s.reaction, at: now) } // cooldown starts when it leaves
            let t = now - s.memeStart
            let transition = min(1, t / 0.18)
            // "Be right back" pops in like a sticker (fades with Reduce motion).
            let awayStyle: PopStyle = s.settings.popStyle == .fade ? .fade : .pop
            let awayPhase = min(1, (now - s.awayChanged) / PopAnimation.duration(awayStyle, appearing: s.away.isAway))
            let awayPresence = s.away.isAway ? awayPhase : 1 - awayPhase
            return CompositorInput(
                camera: cameraImage,
                meme: presence > 0 && awayPresence < 1 ? s.memeImage?.frame(at: t) : nil,
                previousMeme: transition < 1 ? s.previousFrame : nil,
                transition: transition,
                caption: s.guided == nil && s.settings.showCaption && !s.settings.paused ? s.meme?.title : nil,
                layout: s.settings.layout,
                mirror: s.settings.mirror,
                presence: presence,
                appearing: s.visible,
                popStyle: style,
                quietMode: s.settings.quietMode,
                awayPresence: awayPresence,
                awayAppearing: s.away.isAway,
                awayStyle: awayStyle,
                format: s.settings.outputFormat)
        }
        guard let out = compositor.render(input) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        let windowVisible = feed.withLock { $0.windowVisible }
        for entry in sinksLock.withLock({ $0 }) where windowVisible || !entry.whileVisible {
            entry.sink.send(out, time: time)
        }
        publishStatus(now: now)
    }

    private func runVisionIfIdle(_ pixelBuffer: CVPixelBuffer, now: TimeInterval) {
        // One job in flight, at most `visionGate.hz` per second.
        let detectHands: Bool? = state.withLock { s in
            guard !s.visionBusy, s.visionGate.tryFire(at: now) else { return nil }
            s.visionBusy = true
            return s.settings.detectHands
        }
        guard let detectHands else { return }
        // CVPixelBuffer is immutable once captured; reading it from another queue is safe.
        nonisolated(unsafe) let pixelBuffer = pixelBuffer
        visionQueue.async { [self] in
            let t0 = CACurrentMediaTime()
            let obs = detector.detect(pixelBuffer, timestamp: now, detectHands: detectHands)
            let ms = (CACurrentMediaTime() - t0) * 1000
            let cameraName = camera.activeDevice?.name ?? ""
            let stats: (runs: Int, ms: Double, seconds: Double)? = state.withLock { s in
                s.visionRuns += 1
                s.visionMsSum += ms
                guard now - s.visionLogStart >= 10 else { return nil }
                defer { s.visionRuns = 0; s.visionMsSum = 0; s.visionLogStart = now }
                return s.visionLogStart > 0 ? (s.visionRuns, s.visionMsSum, now - s.visionLogStart) : nil
            }
            if let stats {
                log.info("vision: \(stats.runs) runs in \(stats.seconds, format: .fixed(precision: 1)) s, avg \(stats.ms / Double(stats.runs), format: .fixed(precision: 2)) ms")
            }
            state.withLock { s in
                s.visionBusy = false
                s.inferenceMs = s.inferenceMs * 0.9 + ms * 0.1
                if s.calibrateNext {
                    s.classifier.beginCalibration() // median of the next 15 face frames
                    s.calibrateNext = false
                }
                if s.guided != nil {
                    if s.guided?.tick(now) != nil {
                        s.guided?.record(obs, at: now)
                    } else if let g = s.guided {
                        let rec = g.recording(camera: cameraName)
                        let purpose: GuidedPurpose = g.teaching ? .teach : .test
                        s.guided = nil
                        let done = callbacks.withLock { $0.onRecordingFinished }
                        DispatchQueue.global(qos: .utility).async { done?(rec, purpose) }
                    }
                }
                let est = s.classifier.classify(obs)
                s.metrics = est.metrics
                // The stabilized detection, not `s.reaction`: a triggered "Nobody here" stays in `s.reaction`
                // (quiet mode keeps it after hiding) and must not put up "Be right back" while someone is there.
                if s.guided == nil,
                   s.away.update(nobodyHere: s.stabilizer.current == .noFace, faceDetected: obs.face != nil, at: now) {
                    s.awayChanged = now
                    Self.applyVisionRate(&s)
                    let away = s.away.isAway
                    log.info("away \(away ? "on" : "off", privacy: .public)")
                }
                guard now >= s.forcedUntil else { return }
                if let changed = s.stabilizer.update(est.reaction, confidence: est.confidence, at: now) {
                    setReaction(changed, confidence: est.confidence, now: now, in: &s)
                } else if s.forcedShown, !s.settings.quietMode {
                    // A triggered meme ran out: back to what the person is doing (quiet mode just hides it).
                    setReaction(s.stabilizer.current, confidence: est.confidence, now: now, in: &s)
                } else if s.forcedShown, !s.visible {
                    // Quiet mode: the triggered meme has gone away. The chip shows what is
                    // detected now instead of the triggered reaction; nothing pops up for it.
                    s.forcedShown = false
                    s.reaction = s.stabilizer.current
                    s.confidence = est.confidence
                } else if est.reaction == s.reaction {
                    s.confidence = est.confidence
                }
            }
        }
    }

    private static func setVisible(_ v: Bool, now: TimeInterval, in s: inout State) {
        guard s.visible != v else { return }
        s.visible = v
        s.visibleChanged = now
    }

    /// `forced`: the user asked for it (preview) — skips the per-reaction switches and the cooldown.
    private func setReaction(_ r: Reaction, confidence: Double, now: TimeInterval, in s: inout State,
                             meme: Meme? = nil, forced: Bool = false) {
        let quiet = s.settings.quietMode
        s.forcedShown = forced
        if s.settings.paused || (quiet && r == .neutral && meme == nil && !forced) {
            // Paused: track the reaction, show nothing. Neutral = conversation: show nothing.
            s.reaction = r
            s.confidence = confidence
            Self.setVisible(false, now: now, in: &s)
            return
        }
        let allowed = forced || s.gate.allows(r, at: now, current: s.visible ? s.reaction : nil)
        let picked = allowed ? meme ?? library.pick(for: r, filter: s.settings.animals) : nil
        if picked == nil {
            // Switched off, cooling down, or all its memes were removed: treat as "no memes".
            if quiet {
                s.reaction = r
                Self.setVisible(false, now: now, in: &s)
                return
            }
            if s.meme != nil { return }   // keep what's on screen
        }
        let appearing = !s.visible && picked != nil
        Self.setVisible(picked != nil, now: now, in: &s)
        s.shownAt = now
        let t = now - s.memeStart
        // Popping up from hidden: no crossfade from the meme that was hidden before.
        s.previousFrame = appearing ? nil : s.memeImage?.frame(at: t)
        s.reaction = r
        s.confidence = confidence
        s.meme = picked
        s.memeStart = now
        guard let meme = s.meme else { s.memeImage = nil; return }
        if let img = library.cachedImage(for: meme) {
            s.memeImage = img
            return
        }
        // Cold decode off the hot path; keep showing the previous meme until it is ready. A pop-up from
        // hidden shows nothing meanwhile (not the stale meme) and starts its animation once decoded.
        if appearing { s.memeImage = nil }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let img = library.image(for: meme)
            state.withLock { s in
                guard s.meme == meme else { return }
                let now = CACurrentMediaTime()
                if s.memeImage == nil, s.visible { s.visibleChanged = now }
                s.previousFrame = s.memeImage?.frame(at: now - s.memeStart)
                s.memeImage = img
                s.memeStart = now
            }
        }
    }

    /// Called on the capture queue (frames, watchdog, session problems). At most 10×/s while the window
    /// is visible, 2×/s while hidden and 1×/s while idle, so a hidden app doesn't keep invalidating views.
    private func publishStatus(now: TimeInterval, force: Bool = false) {
        let snapshot: (fps: Double, issue: String?, power: PowerMode)? = feed.withLock { f in
            if !force && !f.power.idle {
                f.frameTimes.append(now)
                if f.frameTimes.count > 30 { f.frameTimes.removeFirst(f.frameTimes.count - 30) }
            }
            let interval = f.power.idle ? 1 : f.windowVisible ? 0.1 : 0.5
            guard force || now - f.lastStatusTime > interval else { return nil }
            f.lastStatusTime = now
            let t = f.frameTimes
            let fps = force || f.power.idle || t.count < 2 ? 0 : Double(t.count - 1) / (t[t.count - 1] - t[0])
            return (fps, cameraIssue(f, now: now), f.power)
        }
        guard let snapshot, let onStatus = callbacks.withLock({ $0.onStatus }) else { return }
        var status = state.withLock { s in
            var st = PipelineStatus(reaction: s.reaction, confidence: s.confidence, meme: s.meme,
                                    metrics: s.metrics, outputFPS: snapshot.fps, inferenceMs: s.inferenceMs)
            st.calibrationProgress = s.calibrateNext ? 0 : s.classifier.calibrationProgress
            st.calibration = s.classifier.calibration
            st.faceVisible = s.metrics != nil
            st.away = s.away.isAway
            return st
        }
        status.guided = state.withLock { $0.guided?.tick(now) }
        status.cameraIssue = snapshot.issue
        status.cameraName = camera.activeDevice?.name ?? ""
        status.idle = snapshot.power.idle
        status.visionHz = snapshot.power.visionHz
        status.powerNote = snapshot.power.note
        onStatus(status)
    }
}
