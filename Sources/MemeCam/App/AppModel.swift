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
    var showCaption = true { didSet { persistAndPush() } }
    var mirror = true { didSet { persistAndPush() } }
    var detectHands = true { didSet { persistAndPush() } }
    var detectExpressions = true { didSet { persistAndPush() } }
    var selectedCameraID: String? { didSet { persistAndPush(); if oldValue != selectedCameraID { restartIfRunning() } } }

    // MARK: Live state (read-only for UI)

    private(set) var cameraState: CameraState = .idle
    private(set) var cameras: [CameraDevice] = []
    private(set) var status = PipelineStatus()
    private(set) var isCalibrated = false

    var memes: [Meme] { pipeline.library.memes }
    func memes(for r: Reaction) -> [Meme] { pipeline.library.memes(for: r, filter: animals) }

    let preview = PreviewSink()
    let virtualCamera = VirtualCameraController()
    private let pipeline = MemePipeline()
    private let defaults = UserDefaults.standard
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
        refreshCameras()
        virtualCamera.refresh()
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

    /// Use the current face as "neutral" — makes expression detection personal.
    func calibrate() {
        pipeline.calibrate()
        isCalibrated = true
    }

    /// Show a specific reaction for 3 seconds (e.g. clicked in the gallery).
    func trigger(_ reaction: Reaction) { pipeline.force(reaction) }

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
                         detectExpressions: detectExpressions)
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
        defaults.set(showCaption, forKey: "showCaption")
        defaults.set(mirror, forKey: "mirror")
        defaults.set(detectHands, forKey: "detectHands")
        defaults.set(detectExpressions, forKey: "detectExpressions")
        defaults.set(selectedCameraID, forKey: "cameraID")
    }

    private func load() {
        if let v = defaults.string(forKey: "layout").flatMap(OutputLayout.init) { layout = v }
        if let v = defaults.string(forKey: "animals").flatMap(AnimalFilter.init) { animals = v }
        if defaults.object(forKey: "sensitivity") != nil { sensitivity = defaults.double(forKey: "sensitivity") }
        if defaults.object(forKey: "calmness") != nil { calmness = defaults.double(forKey: "calmness") }
        if defaults.object(forKey: "showCaption") != nil { showCaption = defaults.bool(forKey: "showCaption") }
        if defaults.object(forKey: "mirror") != nil { mirror = defaults.bool(forKey: "mirror") }
        if defaults.object(forKey: "detectHands") != nil { detectHands = defaults.bool(forKey: "detectHands") }
        if defaults.object(forKey: "detectExpressions") != nil { detectExpressions = defaults.bool(forKey: "detectExpressions") }
        selectedCameraID = defaults.string(forKey: "cameraID")
    }
}
