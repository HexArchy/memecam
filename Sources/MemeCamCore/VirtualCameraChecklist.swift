import Foundation

/// The virtual-camera health checklist (pill popover): one row per thing that must work for Discord /
/// Telegram to show MemeCam, each with its status and the one action that fixes it.
public enum VirtualCameraChecklist {
    public enum ExtensionStatus: Sendable, Equatable {
        case unknown, notInstalled, awaitingApproval, enabled, failed
    }

    public enum Status: Sendable, Equatable {
        /// Works.
        case ok
        /// Needs the user (fix button).
        case warning
        /// Broken.
        case failed
        /// Can't tell yet, or blocked by an earlier row.
        case pending
        /// Nothing wrong, just not happening right now (no app reads the camera).
        case info
    }

    public enum Fix: Sendable, Equatable {
        case install, openSettings, startCamera, retry, relaunch
    }

    public enum Kind: Sendable, Equatable, CaseIterable {
        case extensionEnabled, deviceVisible, framesFlowing, appsUsing
    }

    public struct Input: Sendable, Equatable {
        public var extensionStatus: ExtensionStatus
        /// The "MemeCam" CMIO device exists.
        public var deviceVisible: Bool
        /// Frames per second MemeCam delivers into the extension.
        public var fps: Double
        public var cameraRunning: Bool
        public var testPattern: Bool
        /// Apps reading the camera; nil when unknown (device missing, older extension).
        public var clients: Int?
        /// The extension is enabled but the device has stayed invisible to MemeCam for a while.
        public var deviceStuck: Bool

        public init(extensionStatus: ExtensionStatus, deviceVisible: Bool, fps: Double, cameraRunning: Bool,
                    testPattern: Bool, clients: Int?, deviceStuck: Bool = true) {
            self.deviceStuck = deviceStuck
            self.extensionStatus = extensionStatus
            self.deviceVisible = deviceVisible
            self.fps = fps
            self.cameraRunning = cameraRunning
            self.testPattern = testPattern
            self.clients = clients
        }
    }

    public struct Item: Sendable, Equatable {
        public var kind: Kind
        public var status: Status
        public var fix: Fix?

        public init(_ kind: Kind, _ status: Status, fix: Fix? = nil) {
            self.kind = kind
            self.status = status
            self.fix = fix
        }
    }

    /// Below this many frames per second the feed counts as not flowing.
    public static let minFPS = 1.0

    public static func evaluate(_ i: Input) -> [Item] {
        // A visible device proves the extension is installed and enabled, whatever sysextd said last.
        let ext: Item = switch i.deviceVisible ? .enabled : i.extensionStatus {
        case .enabled: Item(.extensionEnabled, .ok)
        case .notInstalled: Item(.extensionEnabled, .failed, fix: .install)
        case .awaitingApproval: Item(.extensionEnabled, .warning, fix: .openSettings)
        case .failed: Item(.extensionEnabled, .failed, fix: .retry)
        case .unknown: Item(.extensionEnabled, .pending)
        }

        let device: Item
        if i.deviceVisible {
            device = Item(.deviceVisible, .ok)
        } else if ext.status == .ok {
            // Enabled but no device: still starting, or macOS didn't hand the new device to this process
            // (after installing / updating the extension only a relaunch helps), or switched off in Camera
            // Extensions. A relaunch fixes the common case; the detail text mentions the setting.
            device = i.deviceStuck ? Item(.deviceVisible, .warning, fix: .relaunch) : Item(.deviceVisible, .pending)
        } else {
            device = Item(.deviceVisible, .pending)
        }

        let frames: Item
        if i.fps >= minFPS, i.deviceVisible {
            frames = Item(.framesFlowing, .ok)
        } else if !i.deviceVisible {
            frames = Item(.framesFlowing, .pending)
        } else if !i.cameraRunning && !i.testPattern {
            frames = Item(.framesFlowing, .warning, fix: .startCamera)
        } else {
            frames = Item(.framesFlowing, .pending) // starting up / reconnecting
        }

        let apps: Item = switch i.clients {
        case .some(let n) where n > 0 && i.deviceVisible: Item(.appsUsing, .ok)
        case .some where i.deviceVisible: Item(.appsUsing, .info)
        default: Item(.appsUsing, .pending)
        }
        return [ext, device, frames, apps]
    }
}
