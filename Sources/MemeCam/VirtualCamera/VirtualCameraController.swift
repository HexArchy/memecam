import AppKit
import CoreMedia
import CoreVideo
import Foundation
import Observation
import os
import SystemExtensions

enum VirtualCameraState: Equatable, Sendable {
    case checking
    /// Extension not activated yet (first launch).
    case notInstalled
    /// Activation requested; user must allow it in System Settings.
    case awaitingApproval
    /// Installed, waiting to connect to the extension's sink stream.
    case connecting
    /// Installed and visible to other apps, but MemeCam's own camera isn't running,
    /// so other apps see the "MemeCam is paused" frame.
    case ready
    /// Frames are flowing into the virtual camera.
    case streaming
    case failed(String)

    var title: String {
        switch self {
        case .checking: String(localized: "Checking…")
        case .notInstalled: String(localized: "Not Installed")
        case .awaitingApproval: String(localized: "Waiting for Approval")
        case .connecting: String(localized: "Connecting…")
        case .ready: String(localized: "Ready")
        case .streaming: String(localized: "Live")
        case .failed: String(localized: "Unavailable")
        }
    }
}

/// Owns the CoreMediaIO camera extension lifecycle and the app → extension frame feed.
///
/// State is derived from three inputs:
/// 1. the sink's view of the CMIO device (ground truth: the "MemeCam" device exists / frames flow),
/// 2. sysextd's answer to a properties request (installed, awaiting approval, not installed),
/// 3. the outcome of the user's last install request.
@MainActor @Observable
final class VirtualCameraController {
    private(set) var state: VirtualCameraState = .checking
    /// Add to the pipeline; forwards composited frames to the extension's sink stream.
    let sink = VirtualCameraSink()

    private enum ExtensionInfo: Equatable {
        case unknown, notFound, awaitingApproval, enabled
        case unavailable(String)
    }

    @ObservationIgnored private var sinkStatus: VirtualCameraSink.Status?
    @ObservationIgnored private var extensionInfo: ExtensionInfo = .unknown
    @ObservationIgnored private var installOutcome: VirtualCameraState?
    @ObservationIgnored private var propertiesQueryInFlight = false
    @ObservationIgnored private var activateHandler: SystemExtensionRequestHandler?
    @ObservationIgnored private var propertiesHandler: SystemExtensionRequestHandler?
    @ObservationIgnored private var activeObserver: (any NSObjectProtocol)?

    @ObservationIgnored private var replaceRequested = false
    /// Waits for the virtual camera to be idle before replacing the extension after an app update.
    @ObservationIgnored private var deferredReplace: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.hexarch.memecam", category: "virtual-camera")

    /// CFBundleVersion of the extension embedded in this app build.
    var bundledExtensionVersion: String? {
        let plist = Bundle.main.bundleURL.appending(
            path: "Contents/Library/SystemExtensions/\(VirtualCameraIDs.extensionBundleID).systemextension/Contents/Info.plist")
        return NSDictionary(contentsOf: plist)?["CFBundleVersion"] as? String
    }

    /// True when the app bundle actually carries the camera extension (signed builds from build-app.sh).
    var bundleContainsExtension: Bool {
        let url = Bundle.main.bundleURL
            .appending(path: "Contents/Library/SystemExtensions/\(VirtualCameraIDs.extensionBundleID).systemextension")
        return FileManager.default.fileExists(atPath: url.path)
    }

    var isInApplicationsFolder: Bool {
        Bundle.main.bundleURL.standardizedFileURL.path.hasPrefix("/Applications/")
    }

    init() {
        sink.setStatusHandler { [weak self] status in self?.sinkStatusChanged(status) }
        // Returning from System Settings after approving the extension: re-check automatically.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: Public API

    func refresh() {
        if case .failed = state { state = .checking }
        if case .failed = installOutcome { installOutcome = nil }
        sink.checkNow()
        queryExtensionProperties()
        recompute()
    }

    func install() {
        guard bundleContainsExtension else {
            state = Self.noExtensionFailure
            return
        }
        guard isInApplicationsFolder else {
            state = .failed(String(localized: "MemeCam must run from /Applications to install the virtual camera. Use scripts/build-app.sh --install, then open it from there."))
            return
        }
        installOutcome = .checking
        state = .checking
        let handler = SystemExtensionRequestHandler { [weak self] event in self?.handleActivation(event) }
        activateHandler = handler
        handler.activate(VirtualCameraIDs.extensionBundleID)
    }

    func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.ExtensionsPreferences",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
        NSWorkspace.shared.open(URL(filePath: "/System/Applications/System Settings.app"))
    }

    // MARK: Events

    private func sinkStatusChanged(_ status: VirtualCameraSink.Status) {
        sinkStatus = status
        if status != .deviceMissing {
            // The device exists, so the extension is installed and enabled.
            extensionInfo = .enabled
            installOutcome = nil
        }
        recompute()
    }

    private func handleActivation(_ event: SystemExtensionRequestHandler.Event) {
        switch event {
        case .needsUserApproval:
            installOutcome = .awaitingApproval
        case .completed:
            installOutcome = nil
            extensionInfo = .enabled
            activateHandler = nil
            sink.checkNow()
        case .willCompleteAfterReboot:
            installOutcome = .failed(String(localized: "Restart your Mac to finish installing the MemeCam virtual camera."))
            activateHandler = nil
        case .failed(let error):
            installOutcome = .failed(SystemExtensionRequestHandler.message(for: error))
            activateHandler = nil
        case .properties:
            break
        }
        recompute()
    }

    private func queryExtensionProperties() {
        guard !propertiesQueryInFlight else { return }
        // Unsigned / `swift run` builds can't talk to sysextd; rely on CMIO device detection only.
        guard bundleContainsExtension else {
            if extensionInfo == .unknown { extensionInfo = .notFound }
            return
        }
        propertiesQueryInFlight = true
        let handler = SystemExtensionRequestHandler { [weak self] event in self?.handleProperties(event) }
        propertiesHandler = handler
        handler.queryProperties(VirtualCameraIDs.extensionBundleID)
    }

    private func handleProperties(_ event: SystemExtensionRequestHandler.Event) {
        propertiesQueryInFlight = false
        propertiesHandler = nil
        switch event {
        case .properties(let list):
            let live = list.filter { !$0.isUninstalling }
            if live.contains(where: \.isEnabled) {
                extensionInfo = .enabled
                // After an app update the system still runs the previous extension build;
                // re-activating replaces it (same team, no new approval needed).
                if let bundled = bundledExtensionVersion, !replaceRequested,
                   !live.contains(where: { $0.isEnabled && $0.bundleVersion == bundled }) {
                    replaceExtensionWhenIdle()
                }
            } else if live.contains(where: \.isAwaitingUserApproval) {
                extensionInfo = .awaitingApproval
            } else {
                extensionInfo = .notFound
            }
        case .failed(let error):
            if let e = error as? OSSystemExtensionError, e.code == .extensionNotFound {
                extensionInfo = .notFound
            } else {
                extensionInfo = .unavailable(SystemExtensionRequestHandler.message(for: error))
            }
        default:
            break
        }
        recompute()
    }

    /// Replacing the extension removes the "MemeCam" device for a moment, which would cut the video of a
    /// call in progress. So wait until no process runs the device and retry every 30 s until then.
    /// MemeCam's own sink feed also counts as running; it disconnects 2 s after the camera stops, so
    /// with the camera on the replacement waits for the camera to stop (or the next launch).
    private func replaceExtensionWhenIdle() {
        guard deferredReplace == nil else { return }
        deferredReplace = Task { [weak self, sink, log] in
            while !Task.isCancelled {
                if await !sink.isDeviceRunningSomewhere() {
                    self?.performDeferredReplace()
                    return
                }
                log.notice("virtual camera in use; deferring the extension update")
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func performDeferredReplace() {
        deferredReplace = nil
        guard !replaceRequested else { return }
        replaceRequested = true
        log.notice("replacing the camera extension with the bundled build")
        install()
    }

    private func recompute() {
        let next: VirtualCameraState
        switch sinkStatus {
        case .streaming:
            next = .streaming
        case .ready:
            // Device present, sink not fed: the camera is off (or about to connect).
            next = .ready
        case .deviceMissing, nil:
            if let installOutcome {
                next = installOutcome
            } else {
                switch extensionInfo {
                case .enabled:
                    next = .connecting // device shows up a moment after activation
                case .awaitingApproval:
                    next = .awaitingApproval
                case .notFound:
                    next = bundleContainsExtension ? .notInstalled : Self.noExtensionFailure
                case .unavailable(let message):
                    next = bundleContainsExtension ? .failed(message) : Self.noExtensionFailure
                case .unknown:
                    next = sinkStatus == nil ? .checking : (bundleContainsExtension ? .checking : Self.noExtensionFailure)
                }
            }
        }
        if next != state { state = next }
    }

    private static var noExtensionFailure: VirtualCameraState {
        .failed(String(localized: "This build has no camera extension. Run `uv run --script scripts/setup-signing.py`, then rebuild with scripts/build-app.sh --install."))
    }
}
