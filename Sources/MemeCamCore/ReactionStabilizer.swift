import Foundation

/// Debounces per-frame estimates into a calm, readable stream of reactions:
/// a new reaction must persist for `enterDelay` before it is shown, and the shown
/// reaction stays at least `minHold` so memes do not flicker.
public struct ReactionStabilizer: Sendable {
    public var minHold: TimeInterval
    /// Multiplier for every enter delay (UI "responsiveness" knob).
    public var delayScale: Double

    public private(set) var current: Reaction = .noFace
    private var shownSince: TimeInterval = -.infinity
    private var candidate: Reaction = .noFace
    private var candidateSince: TimeInterval = 0

    public init(minHold: TimeInterval = 0.9, delayScale: Double = 1) {
        self.minHold = minHold
        self.delayScale = delayScale
    }

    func enterDelay(for r: Reaction) -> TimeInterval {
        let base: TimeInterval = switch r {
        case .noFace: 1.2
        case .neutral: 0.6
        case .eyesClosed: 0.5   // ignore blinks
        case .thumbsUp, .thumbsDown, .peace, .pointing, .heart, .handsUp: 0.15
        default: 0.25
        }
        return base * delayScale
    }

    /// Feeds one estimate; returns the new reaction when the shown one changes.
    public mutating func update(_ r: Reaction, at t: TimeInterval) -> Reaction? {
        if r != candidate {
            candidate = r
            candidateSince = t
        }
        guard candidate != current,
              t - candidateSince >= enterDelay(for: candidate),
              t - shownSince >= minHold else { return nil }
        current = candidate
        shownSince = t
        return current
    }
}
