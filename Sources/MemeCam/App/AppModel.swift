import AppKit
import MemeCamCore
import Observation

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
    var selectedCameraID: String? { didSet { persistAndPush(); if oldValue != selectedCameraID { restartIfRunning() } } }

    // MARK: Live state (read-only for UI)

    private(set) var cameraState: CameraState = .idle
    private(set) var cameras: [CameraDevice] = []
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

    init() {
        load()
        loading = false
        pipeline.update(settings)
        pipeline.addSink(preview)
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
        refreshCameras()
        virtualCamera.refresh()
        updater.start()
        hotKeys.register(.pauseMemes) { [weak self] in self?.togglePause() }
    }

    // MARK: Actions

    func start() {
        guard cameraState != .running, cameraState != .starting else { return }
        cameraState = .starting
        Task {
            guard await CameraCapture.requestAccess() else { cameraState = .denied; return }
            refreshCameras()
            do {
                try pipeline.start(deviceID: selectedCameraID)
                cameraState = .running
            } catch {
                cameraState = .failed(error.localizedDescription)
            }
        }
    }

    func stop() {
        pipeline.stop()
        cameraState = .idle
    }

    func toggle() { cameraState == .running ? stop() : start() }

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

    func refreshCameras() {
        cameras = CameraCapture.availableDevices()
        if let id = selectedCameraID, !cameras.contains(where: { $0.id == id }) { selectedCameraID = nil }
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

    private func restartIfRunning() {
        guard !loading, cameraState == .running else { return }
        try? pipeline.start(deviceID: selectedCameraID)
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
    }
}
