import Foundation

/// "Away after" setting: how long the "nobody here" reaction stays before the output switches to the
/// "Be right back" card.
public enum AwayDelay: Int, Sendable, CaseIterable, Identifiable {
    case off = 0
    case tenSeconds = 10
    case thirtySeconds = 30
    case oneMinute = 60

    public static let `default` = AwayDelay.thirtySeconds

    public var id: Int { rawValue }

    /// nil when away mode is off.
    public var seconds: TimeInterval? { self == .off ? nil : TimeInterval(rawValue) }
}

/// Decides when the person has left (show "Be right back") and when they are back.
///
/// - Away starts once the stabilized reaction has been "nobody here" for `delay` seconds.
/// - It ends as soon as Vision sees a face in `returnConfirmations` consecutive runs (one stray false
///   positive must not flash the camera back), or when the setting is switched off.
/// - While away, Vision only needs to notice a face, so it runs at `visionHz`.
public struct AwayTracker: Sendable, Equatable {
    /// Vision rate cap while away.
    public static let visionHz = 4.0

    /// nil = away mode off.
    public var delay: TimeInterval? {
        didSet { if delay == nil { reset() } }
    }
    public var returnConfirmations: Int
    public private(set) var isAway = false
    private var nobodySince: TimeInterval?
    private var facesInARow = 0

    public init(delay: TimeInterval? = AwayDelay.default.seconds, returnConfirmations: Int = 2) {
        self.delay = delay
        self.returnConfirmations = max(1, returnConfirmations)
    }

    /// Feed one Vision result. `nobodyHere`: the current (stabilized) reaction is "nobody here";
    /// `faceDetected`: this very frame had a face. Returns true when `isAway` changed.
    @discardableResult
    public mutating func update(nobodyHere: Bool, faceDetected: Bool, at t: TimeInterval) -> Bool {
        if isAway {
            facesInARow = faceDetected ? facesInARow + 1 : 0
            guard facesInARow >= returnConfirmations || delay == nil else { return false }
            reset()
            return true
        }
        guard let delay, nobodyHere else {
            nobodySince = nil
            return false
        }
        let since = nobodySince ?? t
        nobodySince = since
        guard t - since >= delay else { return false }
        isAway = true
        facesInARow = 0
        return true
    }

    /// Forget everything (paused, settings changed, camera restarted). Returns true when it was away.
    @discardableResult
    public mutating func reset() -> Bool {
        let was = isAway
        isAway = false
        nobodySince = nil
        facesInARow = 0
        return was
    }

    /// Vision rate cap given the power policy's cap.
    public func visionHz(power: Double) -> Double {
        isAway ? min(power, Self.visionHz) : power
    }
}

/// What the menu bar icon shows: is the camera on, and what goes out.
public enum CameraPresence: Sendable, Equatable {
    case off, live, paused, away

    /// The camera state wins: memes paused with the camera off is still "off".
    public static func decide(cameraOn: Bool, memesPaused: Bool, away: Bool) -> CameraPresence {
        guard cameraOn else { return .off }
        if away { return .away }
        return memesPaused ? .paused : .live
    }
}
