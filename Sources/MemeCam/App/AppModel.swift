import AppKit
@preconcurrency import AVFoundation
import MemeCamCore
import Observation
import os

/// Single source of truth for the UI. All UI reads/writes go through here.
@MainActor @Observable
final class AppModel {
    enum CameraState: Equatable {
        case idle, starting, running
        case denied
        case failed(String)
    }

    // MARK: Settings (persisted)

    var layout: OutputLayout = .sideBySide { didSet { persistAndPush() } }
    var animals: AnimalFilter = .both { didSet { persistAndPush() } }
    /// 0.5...1.5
    var sensitivity: Double = 1 { didSet { persistAndPush() } }
    /// 0.5 (snappy) ... 2 (calm)
    var calmness: Double = 1 { didSet { persistAndPush() } }
    var showCaption = false { didSet { persistAndPush() } }
    var mirror = true { didSet { persistAndPush() } }
    var detectHands = true { didSet { persistAndPush() } }
    var detectExpressions = true { didSet { persistAndPush() } }
    /// Memes only pop up on reactions; nothing while neutral.
    var quietMode = true { didSet { persistAndPush() } }
    /// Quiet mode: seconds a meme stays up.
    var popDuration: Double = 4 { didSet { persistAndPush() } }
    /// Panic switch (⌃⌥P anywhere): plain camera out, no memes.
    var memesPaused = false { didSet { persistAndPush() } }
    /// Reactions switched off by the user: still detected, never pop up.
    var disabledReactions: Set<Reaction> = [] { didSet { persistAndPush() } }
    /// Seconds before the same reaction may pop up again.
    var cooldown: Double = 4 { didSet { persistAndPush() } }
    /// The camera the user picked (nil = system default). It is a preference, not the device in use: when it
    /// is missing (iPhone out of range) MemeCam falls back to the default and switches back when it returns.
    var selectedCameraID: String? {
        didSet {
            persistAndPush()
            guard oldValue != selectedCameraID, !revertingSelection else { return }
            if let id = selectedCameraID, let camera = cameras.first(where: { $0.id == id }) {
                preferredCameraName = camera.name
                defaults.set(camera.name, forKey: "cameraName")
            }
            cameraSwitchError = nil
            reconcileCamera(revertTo: .some(oldValue))
        }
    }
    /// Stop the camera while the screen is locked, resume on unlock if it was running.
    var stopCameraWhenLocked = true { didSet { persistAndPush() } }

    // MARK: Live state (read-only for UI)

    private(set) var cameraState: CameraState = .idle { didSet { if oldValue != cameraState { updatePower() } } }
    private(set) var cameras: [CameraDevice] = []
    /// The device the running session captures from (may differ from `selectedCameraID` while falling back).
    private(set) var activeCamera: CameraDevice?
    /// Name of the preferred camera, remembered so the menu can show it while it is disconnected.
    private(set) var preferredCameraName: String?
    /// A camera switch the user asked for failed; the previous camera keeps running. Cleared after a few seconds.
    private(set) var cameraSwitchError: String?
    /// Idle / low-power state (see `PowerMode`), for status hints.
    private(set) var powerMode = PowerMode()

    /// The preferred camera when it isn't connected right now (shown as "… (not connected)" in the menu).
    var missingPreferredCamera: (id: String, name: String)? {
        guard let id = selectedCameraID, !cameras.contains(where: { $0.id == id }) else { return nil }
        return (id, preferredCameraName ?? "Selected camera")
    }
    private(set) var status = PipelineStatus()
    private(set) var isCalibrated = false

    /// Bumped whenever the meme library changes, so views re-read it.
    private(set) var libraryRevision = 0
    var memes: [Meme] { _ = libraryRevision; return pipeline.library.memes }
    /// Memes for a reaction, respecting the animal filter.
    func memes(for r: Reaction) -> [Meme] { _ = libraryRevision; return pipeline.library.memes(for: r, filter: animals) }
    /// All memes for a reaction regardless of the filter (for editing).
    func allMemes(for r: Reaction) -> [Meme] { _ = libraryRevision; return pipeline.library.memes(for: r) }
    func hiddenDefaultsCount(for r: Reaction) -> Int { _ = libraryRevision; return pipeline.library.hiddenCount(for: r) }
    /// Report of the last guided accuracy test (multi-line text).
    private(set) var lastEvaluation: String?
    private(set) var lastRecordingURL: URL?
    /// The test just finished: the stage shows the result card until dismissed.
    var showEvaluationResult = false
    var isGuidedSessionRunning: Bool { status.guided != nil }

    /// ~3 min interactive test: prompts every reaction (get ready → hold), records, then scores
    /// the detector on this user.
    func startAccuracyTest() {
        if cameraState != .running { start() }
        lastEvaluation = nil
        pipeline.startGuidedSession()
    }

    func cancelAccuracyTest() { pipeline.cancelGuidedSession() }
    func togglePauseAccuracyTest() { pipeline.toggleGuidedPause() }
    func skipAccuracyStep() { pipeline.skipGuidedStep() }
    func redoAccuracyStep() { pipeline.redoGuidedStep() }

    func revealRecordings() {
        let dir = Self.recordingsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    /// Same model the pipeline uses, for scoring accuracy tests.
    nonisolated static let handModel: HandGestureModel? = {
        let url = Bundle.main.resourceURL?.appending(path: "Models/hand-gesture-mlp.json")
        return url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? HandGestureModel(json: $0) }
    }()

    nonisolated static let recordingsDirectory = URL.applicationSupportDirectory.appending(path: "MemeCam/Recordings")

    nonisolated private static func save(_ rec: Recording) -> URL? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(rec) else { return nil }
        try? FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        let name = ISO8601DateFormatter().string(from: rec.createdAt).replacingOccurrences(of: ":", with: "-")
        let url = recordingsDirectory.appending(path: "\(name).json")
        return (try? data.write(to: url)) != nil ? url : nil
    }

    /// Last library error, for an alert.
    var libraryError: String?

    // MARK: Meme customisation

    /// Adds images/GIFs (from a file picker or drag & drop) to a reaction.
    func addMemes(_ urls: [URL], to reaction: Reaction) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { try pipeline.library.add(fileAt: url, to: reaction) } catch { libraryError = error.localizedDescription }
        }
        libraryChanged(showing: reaction)
    }

    func removeMeme(_ meme: Meme) {
        do { try pipeline.library.remove(meme) } catch { libraryError = error.localizedDescription }
        libraryChanged()
    }

    func moveMeme(_ meme: Meme, to reaction: Reaction) {
        do { try pipeline.library.reassign(meme, to: reaction) } catch { libraryError = error.localizedDescription }
        libraryChanged()
    }

    func restoreDefaultMemes(for reaction: Reaction) {
        do { try pipeline.library.restoreDefaults(for: reaction) } catch { libraryError = error.localizedDescription }
        libraryChanged()
    }

    func revealUserMemesFolder() {
        let dir = pipeline.library.userDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    private func libraryChanged(showing reaction: Reaction? = nil) {
        libraryRevision += 1
        pipeline.libraryChanged()
        if let reaction, cameraState == .running { pipeline.force(reaction) } // instant preview of the new meme
    }

    let updater = Updater()
    let preview = PreviewSink()
    let virtualCamera = VirtualCameraController()
    private let pipeline = MemePipeline()
    private let defaults = UserDefaults.standard
    private let hotKeys = GlobalHotKeys()
    private var loading = true
    private let log = Logger(subsystem: "com.hexarch.memecam", category: "app")

    // MARK: Camera lifecycle bookkeeping (not observed by views)

    /// Camera operations (start / stop / switch) run one after another in this chain, so a quick
    /// stop-start or two camera picks can't interleave. Each op awaits the capture queue; the UI never blocks.
    @ObservationIgnored private var cameraOp: Task<Void, Never>?
    /// Bumped by every start/stop; an op that finds a newer generation leaves `cameraState` alone.
    @ObservationIgnored private var cameraGeneration = 0
    /// The user wants the camera on (Start until Stop). Recovery (camera reconnected, wake, unlock) only
    /// restarts it then.
    @ObservationIgnored private var wantsCamera = false
    private enum SuspendReason { case sleep, screenLocked }
    /// Why the camera is temporarily off; it resumes when the set is empty again.
    @ObservationIgnored private var suspendReasons: Set<SuspendReason> = []
    @ObservationIgnored private var resumeAfterSuspend = false
    @ObservationIgnored private var revertingSelection = false
    @ObservationIgnored private var switchErrorTask: Task<Void, Never>?

    // MARK: Power inputs

    @ObservationIgnored private var windowVisible = true
    @ObservationIgnored private var consumerActive = false
    @ObservationIgnored private var monitoringConsumers = false
    /// Keeps App Nap from throttling the capture → virtual camera path while it feeds a call.
    @ObservationIgnored private var activity: (any NSObjectProtocol)?
    @ObservationIgnored private var observers: [(NotificationCenter, any NSObjectProtocol)] = []

    init() {
        load()
        loading = false
        pipeline.update(settings)
        pipeline.addSink(preview, onlyWhileWindowVisible: true)
        pipeline.addSink(virtualCamera.sink)
        pipeline.onStatus = { [weak self] status in
            Task { @MainActor in self?.status = status }
        }
        pipeline.onRecordingFinished = { [weak self] rec in
            let url = AppModel.save(rec)
            let report = Evaluator(handModel: AppModel.handModel).evaluate(rec).summary
            Task { @MainActor in
                self?.lastRecordingURL = url
                self?.lastEvaluation = report
                self?.showEvaluationResult = true
            }
        }
        virtualCamera.sink.setConsumerHandler { [weak self] active in self?.consumerChanged(active) }
        refreshCameras()
        virtualCamera.refresh()
        updater.start()
        hotKeys.register(.pauseMemes) { [weak self] in self?.togglePause() }
        observeSystem()
        updatePower()
    }

    // MARK: Actions

    func start() {
        guard cameraState != .running, cameraState != .starting else { return }
        wantsCamera = true
        suspendReasons = []
        resumeAfterSuspend = false
        beginStart()
    }

    func stop() {
        wantsCamera = false
        stopCamera()
    }

    func toggle() { cameraState == .running || cameraState == .starting ? stop() : start() }

    func togglePause() { memesPaused.toggle() }

    func isEnabled(_ reaction: Reaction) -> Bool { !disabledReactions.contains(reaction) }

    func setEnabled(_ reaction: Reaction, _ enabled: Bool) {
        if enabled { disabledReactions.remove(reaction) } else { disabledReactions.insert(reaction) }
    }

    /// Use the current face as "neutral" — makes expression detection personal.
    func calibrate() {
        pipeline.calibrate()
        isCalibrated = true
    }

    /// Show a specific reaction for 3 seconds (e.g. clicked in the gallery).
    func trigger(_ reaction: Reaction) { pipeline.force(reaction) }

    /// Show this exact meme for 3 seconds.
    func trigger(meme: Meme) { pipeline.force(meme: meme) }

    /// Re-reads the camera list. Never clears the preference when the preferred camera is missing.
    func refreshCameras() {
        let list = CameraCapture.availableDevices()
        if list != cameras { cameras = list }
        if let id = selectedCameraID, let camera = list.first(where: { $0.id == id }), camera.name != preferredCameraName {
            preferredCameraName = camera.name
            defaults.set(camera.name, forKey: "cameraName")
        }
    }

    func openCameraPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
    }

    // MARK: Private

    private var settings: PipelineSettings {
        PipelineSettings(layout: layout, animals: animals, sensitivity: sensitivity, calmness: calmness,
                         showCaption: showCaption, mirror: mirror, detectHands: detectHands,
                         detectExpressions: detectExpressions, quietMode: quietMode, popDuration: popDuration,
                         paused: memesPaused, disabledReactions: disabledReactions, cooldown: cooldown)
    }

    // MARK: Camera lifecycle

    private func enqueueCamera(_ op: @escaping @MainActor () async -> Void) {
        let previous = cameraOp
        cameraOp = Task { await previous?.value; await op() }
    }

    private func beginStart() {
        cameraState = .starting
        cameraSwitchError = nil
        cameraGeneration += 1
        let generation = cameraGeneration
        enqueueCamera { [weak self] in await self?.performStart(generation) }
    }

    private func performStart(_ generation: Int) async {
        guard generation == cameraGeneration else { return }
        guard await CameraCapture.requestAccess() else {
            if generation == cameraGeneration { cameraState = .denied }
            return
        }
        guard generation == cameraGeneration else { return }
        refreshCameras()
        do {
            let device = try await pipeline.start(deviceID: preferredDeviceID(userPick: false))
            // A stop() that arrived meanwhile is queued right behind us and stops the session.
            guard generation == cameraGeneration else { return }
            activeCamera = device
            recomputeWindowVisibility() // started from the menu bar with the window closed: maybe idle right away
            cameraState = .running
        } catch {
            guard generation == cameraGeneration else { return }
            log.error("camera start failed: \(error.localizedDescription, privacy: .public)")
            cameraState = .failed(error.localizedDescription)
        }
    }

    private func stopCamera() {
        cameraGeneration += 1
        cameraState = .idle
        activeCamera = nil
        enqueueCamera { [pipeline] in await pipeline.stop() }
    }

    /// The preferred camera when it is connected (a suspended one only when the user just picked it, so
    /// the "lid closed" error is shown), otherwise nil: the capture side then opens the system default.
    private func preferredDeviceID(userPick: Bool) -> String? {
        if userPick, let id = selectedCameraID, cameras.contains(where: { $0.id == id }) { return id }
        return CameraSelection.preferredIfAvailable(selectedCameraID, in: selectionDevices)
    }

    private var selectionDevices: [CameraSelection.Device] {
        cameras.map { CameraSelection.Device(id: $0.id, isSuspended: $0.isSuspended) }
    }

    /// Makes the running camera match the preference: a user pick (`revertTo` = the previous pick), a
    /// camera that was unplugged (fall back) or the preferred one coming back (switch back).
    private func reconcileCamera(revertTo: String?? = nil) {
        guard !loading, cameraState == .running || cameraState == .starting else { return }
        let generation = cameraGeneration
        enqueueCamera { [weak self] in await self?.performReconcile(generation, revertTo: revertTo) }
    }

    private func performReconcile(_ generation: Int, revertTo: String??) async {
        guard generation == cameraGeneration, cameraState == .running else { return }
        refreshCameras()
        let userPick = revertTo != nil
        guard userPick || CameraSelection.shouldSwitch(active: activeCamera?.id, preferred: selectedCameraID,
                                                       available: selectionDevices) else { return }
        do {
            let device = try await pipeline.start(deviceID: preferredDeviceID(userPick: userPick))
            guard generation == cameraGeneration else { return }
            if device != activeCamera { log.notice("camera now \(device.name, privacy: .public)") }
            activeCamera = device
        } catch {
            guard generation == cameraGeneration else { return }
            log.error("camera switch failed: \(error.localizedDescription, privacy: .public)")
            if let active = activeCamera, cameras.contains(where: { $0.id == active.id }) {
                // The current camera is untouched and still running: say why the switch didn't happen.
                if case .some(let previous) = revertTo {
                    revertingSelection = true
                    selectedCameraID = previous
                    revertingSelection = false
                }
                showSwitchError(error.localizedDescription)
            } else {
                // The active camera is gone and nothing else works. `wantsCamera` stays set, so a camera
                // being connected restarts it.
                await pipeline.stop()
                guard generation == cameraGeneration else { return }
                activeCamera = nil
                cameraState = .failed(error.localizedDescription)
            }
        }
    }

    private func showSwitchError(_ message: String) {
        cameraSwitchError = message
        switchErrorTask?.cancel()
        switchErrorTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, self?.cameraSwitchError == message else { return }
            self?.cameraSwitchError = nil
        }
    }

    private func camerasChanged() {
        refreshCameras()
        switch cameraState {
        case .running:
            reconcileCamera()
        case .failed where wantsCamera && suspendReasons.isEmpty:
            beginStart() // a camera came back after the last one vanished
        default:
            break
        }
    }

    private func suspendCamera(_ reason: SuspendReason) {
        let active = cameraState == .running || cameraState == .starting
        suspendReasons.insert(reason)
        guard active else { return }
        log.notice("camera paused: \(String(describing: reason), privacy: .public)")
        resumeAfterSuspend = true
        stopCamera()
    }

    private func resumeCamera(_ reason: SuspendReason) {
        guard suspendReasons.remove(reason) != nil, suspendReasons.isEmpty, resumeAfterSuspend else { return }
        resumeAfterSuspend = false
        guard wantsCamera, cameraState == .idle else { return }
        log.notice("camera resumed after \(String(describing: reason), privacy: .public)")
        beginStart()
    }

    // MARK: System events

    private func observeSystem() {
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (AppModel) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
            }
            observers.append((center, token))
        }
        let nc = NotificationCenter.default
        // Cameras plugged in / out, Continuity iPhone coming and going.
        on(nc, AVCaptureDevice.wasConnectedNotification) { $0.camerasChanged() }
        on(nc, AVCaptureDevice.wasDisconnectedNotification) { $0.camerasChanged() }
        // Sleep / wake: a sleeping Mac can't capture, and sessions often come back stale.
        let ws = NSWorkspace.shared.notificationCenter
        on(ws, NSWorkspace.willSleepNotification) { $0.suspendCamera(.sleep) }
        on(ws, NSWorkspace.didWakeNotification) { $0.resumeCamera(.sleep) }
        // Screen lock (optional): nobody is at the Mac, so don't keep the camera light on.
        let dnc = DistributedNotificationCenter.default()
        on(dnc, Notification.Name("com.apple.screenIsLocked")) { if $0.stopCameraWhenLocked { $0.suspendCamera(.screenLocked) } }
        on(dnc, Notification.Name("com.apple.screenIsUnlocked")) { $0.resumeCamera(.screenLocked) }
        // Window visibility for idle mode. willClose fires while the window is still on screen,
        // so re-check on the next main-actor turn.
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            on(nc, name) { $0.recomputeWindowVisibility() }
        }
        on(nc, NSApplication.didFinishLaunchingNotification) { $0.recomputeWindowVisibility() }
        on(nc, NSWindow.willCloseNotification) { model in
            Task { @MainActor [weak model] in model?.recomputeWindowVisibility() }
        }
        // Thermal pressure and Low Power Mode slow Vision down.
        on(nc, ProcessInfo.thermalStateDidChangeNotification) { $0.updatePower() }
        on(nc, Notification.Name.NSProcessInfoPowerStateDidChange) { $0.updatePower() }
    }

    // MARK: Idle / low-power

    /// A MemeCam window (not the menu bar extra) is on screen: open, not minimised, not hidden, not fully covered.
    private func recomputeWindowVisibility() {
        let visible = !NSApp.isHidden && NSApp.windows.contains { w in
            w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible)
                && w.styleMask.contains(.titled) && !(w is NSPanel)
        }
        guard visible != windowVisible else { return }
        windowVisible = visible
        log.info("main window visible: \(visible)")
        updatePower()
    }

    private func consumerChanged(_ active: Bool) {
        guard monitoringConsumers, active != consumerActive else { return }
        consumerActive = active
        updatePower()
    }

    private var thermalLevel: ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
    }

    /// Recomputes the power mode and pushes it to the pipeline, the consumer monitor and App Nap.
    private func updatePower() {
        let running = cameraState == .running
        // Who reads the virtual camera only matters while the window is hidden. Until the first answer
        // arrives, assume someone does: never cut a call's video on a guess.
        let monitor = running && !windowVisible
        if monitor != monitoringConsumers {
            monitoringConsumers = monitor
            consumerActive = true
            virtualCamera.sink.monitorConsumers(monitor)
        }
        let mode = PowerMode.decide(windowVisible: windowVisible, consumerActive: consumerActive,
                                    thermal: thermalLevel, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
        if mode != powerMode {
            if mode.idle != powerMode.idle { log.notice("idle mode \(mode.idle ? "on" : "off", privacy: .public)") }
            powerMode = mode
        }
        pipeline.setPower(mode, windowVisible: windowVisible)
        let busy = running && !mode.idle
        if busy, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "MemeCam feeds the virtual camera")
        } else if !busy, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    private func persistAndPush() {
        guard !loading else { return }
        pipeline.update(settings)
        defaults.set(layout.rawValue, forKey: "layout")
        defaults.set(animals.rawValue, forKey: "animals")
        defaults.set(sensitivity, forKey: "sensitivity")
        defaults.set(calmness, forKey: "calmness")
        defaults.set(showCaption, forKey: "showCaptionV2")
        defaults.set(mirror, forKey: "mirror")
        defaults.set(detectHands, forKey: "detectHands")
        defaults.set(detectExpressions, forKey: "detectExpressions")
        defaults.set(quietMode, forKey: "quietMode")
        defaults.set(popDuration, forKey: "popDuration")
        defaults.set(memesPaused, forKey: "memesPaused")
        defaults.set(disabledReactions.map(\.rawValue).sorted(), forKey: "disabledReactions")
        defaults.set(cooldown, forKey: "cooldown")
        defaults.set(selectedCameraID, forKey: "cameraID")
        defaults.set(stopCameraWhenLocked, forKey: "stopCameraWhenLocked")
    }

    private func load() {
        if let v = defaults.string(forKey: "layout").flatMap(OutputLayout.init) { layout = v }
        if let v = defaults.string(forKey: "animals").flatMap(AnimalFilter.init) { animals = v }
        if defaults.object(forKey: "sensitivity") != nil { sensitivity = defaults.double(forKey: "sensitivity") }
        if defaults.object(forKey: "calmness") != nil { calmness = defaults.double(forKey: "calmness") }
        if defaults.object(forKey: "showCaptionV2") != nil { showCaption = defaults.bool(forKey: "showCaptionV2") }
        if defaults.object(forKey: "mirror") != nil { mirror = defaults.bool(forKey: "mirror") }
        if defaults.object(forKey: "detectHands") != nil { detectHands = defaults.bool(forKey: "detectHands") }
        if defaults.object(forKey: "detectExpressions") != nil { detectExpressions = defaults.bool(forKey: "detectExpressions") }
        if defaults.object(forKey: "quietMode") != nil { quietMode = defaults.bool(forKey: "quietMode") }
        if defaults.object(forKey: "popDuration") != nil { popDuration = defaults.double(forKey: "popDuration") }
        memesPaused = defaults.bool(forKey: "memesPaused")
        if let v = defaults.stringArray(forKey: "disabledReactions") { disabledReactions = Set(v.compactMap(Reaction.init)) }
        if defaults.object(forKey: "cooldown") != nil { cooldown = defaults.double(forKey: "cooldown") }
        selectedCameraID = defaults.string(forKey: "cameraID")
        preferredCameraName = defaults.string(forKey: "cameraName")
        if defaults.object(forKey: "stopCameraWhenLocked") != nil { stopCameraWhenLocked = defaults.bool(forKey: "stopCameraWhenLocked") }
    }
}
