import Foundation

/// Turns noisy per-frame estimates into a calm, readable stream of reactions.
///
/// 1. Only confident frames vote: below `minConfidence` an estimate abstains (neutral and
///    "nobody here" always vote, so the display can settle back).
/// 2. Confidence-weighted vote over a sliding window (≈0.6 s). A reaction becomes the candidate
///    only with a clear majority (`majority` of the window's weight); otherwise the current
///    candidate stays, so mixed evidence never causes a switch.
/// 3. The candidate must persist for `enterDelay` (per reaction: gestures are quicker,
///    eyes-closed waits out blinks, "nobody here" waits for the person to really leave).
/// 4. The shown reaction is held at least `minHold` so memes do not flicker.
public struct ReactionStabilizer: Sendable {
    public var minHold: TimeInterval
    /// Multiplier for the window and every enter delay (UI "calm ↔ snappy" knob).
    public var delayScale: Double
    public var minConfidence: Double = 0.55
    public var majority: Double = 0.6

    public private(set) var current: Reaction = .noFace
    private var shownSince: TimeInterval = -.infinity
    private var candidate: Reaction = .noFace
    private var candidateSince: TimeInterval = 0
    private var window: [(t: TimeInterval, r: Reaction, w: Double)] = []

    public init(minHold: TimeInterval = 1.5, delayScale: Double = 1) {
        self.minHold = minHold
        self.delayScale = delayScale
    }

    var windowLength: TimeInterval { 0.6 * delayScale }

    func enterDelay(for r: Reaction) -> TimeInterval {
        let base: TimeInterval = switch r {
        case .noFace: 1.2
        case .neutral: 0.7
        case .eyesClosed: 0.7    // well past a blink (~0.1–0.4 s)
        case .thumbsUp, .thumbsDown, .peace, .pointing, .heart, .handsUp: 0.3
        default: 0.5
        }
        return base * delayScale
    }

    /// Feeds one estimate; returns the new reaction when the shown one changes.
    public mutating func update(_ r: Reaction, confidence: Double = 1, at t: TimeInterval) -> Reaction? {
        let alwaysVotes = r == .neutral || r == .noFace
        if confidence > 0, alwaysVotes || confidence >= minConfidence {
            window.append((t, r, max(confidence, 0.3)))
        }
        let length = windowLength
        window.removeAll { t - $0.t > length }
        guard !window.isEmpty else { return nil }

        var votes: [Reaction: Double] = [:]
        var total = 0.0
        for v in window {
            votes[v.r, default: 0] += v.w
            total += v.w
        }
        // Ties keep the current candidate, avoiding ping-pong.
        let (winner, weight) = votes.max { a, b in
            a.value != b.value ? a.value < b.value : b.key == candidate
        }!

        if winner != candidate, weight >= total * majority {
            candidate = winner
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
