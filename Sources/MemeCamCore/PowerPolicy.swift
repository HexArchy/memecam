import Foundation

/// Thermal pressure, mirrored from `ProcessInfo.ThermalState` so the policy stays platform-light.
public enum ThermalLevel: Int, Sendable, Comparable, CaseIterable {
    case nominal, fair, serious, critical

    public static func < (a: ThermalLevel, b: ThermalLevel) -> Bool { a.rawValue < b.rawValue }
}

/// How hard the pipeline works right now, decided from what the user can see and what the Mac allows.
///
/// - Idle: no MemeCam window is visible and no app reads the "MemeCam" virtual camera. Nobody can
///   see the output, so Vision, compositing and the virtual-camera feed pause (the camera keeps running
///   so resuming is instant).
/// - Otherwise Vision runs at 15 Hz (the stabilizer needs ~0.5 s of votes; 15 Hz is plenty),
///   10 Hz in Low Power Mode and 8 Hz when the Mac is hot (`.serious` / `.critical`).
public struct PowerMode: Sendable, Equatable {
    public static let normalHz = 15.0
    public static let lowPowerHz = 10.0
    public static let hotHz = 8.0

    public var idle: Bool
    /// Vision rate cap; 0 while idle.
    public var visionHz: Double
    /// Why the pipeline runs below normal (short user-facing text), nil at full speed.
    public var note: String?

    public init(idle: Bool = false, visionHz: Double = PowerMode.normalHz, note: String? = nil) {
        self.idle = idle
        self.visionHz = visionHz
        self.note = note
    }

    /// - Parameters:
    ///   - windowVisible: a MemeCam window is on screen (not closed, minimised, hidden or fully covered).
    ///   - consumerActive: another app has the MemeCam virtual camera open.
    public static func decide(windowVisible: Bool, consumerActive: Bool,
                              thermal: ThermalLevel, lowPowerMode: Bool) -> PowerMode {
        if !windowVisible && !consumerActive {
            return PowerMode(idle: true, visionHz: 0, note: String(localized: "Idle — saving power", bundle: .main))
        }
        if thermal >= .serious {
            return PowerMode(visionHz: hotHz, note: String(localized: "Mac is hot — detection slowed down", bundle: .main))
        }
        if lowPowerMode {
            return PowerMode(visionHz: lowPowerHz, note: String(localized: "Low Power Mode — detection slowed down", bundle: .main))
        }
        return PowerMode()
    }
}

/// Time-based rate limiter: lets at most `hz` events per second through, phase-locked to a
/// schedule so a 30 fps source yields exactly 15, 10 or 8 Hz on average (not "every other frame
/// that happens to be late enough"). `hz <= 0` blocks everything.
public struct RateGate: Sendable {
    public var hz: Double
    private var next: TimeInterval = -.infinity
    /// Frames arrive with a few ms of jitter; accept them slightly early instead of skipping a slot.
    private let slack: TimeInterval = 0.004

    public init(hz: Double) { self.hz = hz }

    /// True when an event at `t` may run; it then consumes the slot.
    public mutating func tryFire(at t: TimeInterval) -> Bool {
        guard hz > 0 else { return false }
        guard t >= next - slack else { return false }
        let interval = 1 / hz
        // Late by more than a whole interval (busy, paused, idle): restart the schedule from now
        // instead of bursting to catch up.
        next = t - next > interval ? t + interval : next + interval
        return true
    }

    /// Forget the schedule (e.g. after a pause) so the next event fires immediately.
    public mutating func reset() { next = -.infinity }
}

/// Which camera to open, given the user's preference and what is connected.
///
/// The preference is never cleared just because the camera is missing (an iPhone in another room at
/// launch): MemeCam falls back to the system default at runtime and switches back once it returns.
public enum CameraSelection {
    public struct Device: Sendable, Equatable {
        public var id: String
        public var isSuspended: Bool
        public init(id: String, isSuspended: Bool = false) {
            self.id = id
            self.isSuspended = isSuspended
        }
    }

    /// The preferred camera when it is connected and usable, otherwise nil ("use the default").
    public static func preferredIfAvailable(_ preferred: String?, in available: [Device]) -> String? {
        guard let preferred, let d = available.first(where: { $0.id == preferred }), !d.isSuspended else { return nil }
        return preferred
    }

    /// Whether a running camera should switch: the active device left, or the preferred one is
    /// available and is not the active one.
    public static func shouldSwitch(active: String?, preferred: String?, available: [Device]) -> Bool {
        guard let active else { return true }
        if !available.contains(where: { $0.id == active }) { return true }
        if let p = preferredIfAvailable(preferred, in: available) { return p != active }
        return false
    }
}
