import Foundation

/// Turns noisy per-frame estimates into a calm, readable stream of reactions.
///
/// 1. Confidence-weighted vote over a short sliding window (≈0.35 s): a single misclassified
///    frame cannot reset a reaction that is building up. Zero-confidence frames abstain.
/// 2. The window winner must persist for `enterDelay` (per reaction: gestures are snappy,
///    eyes-closed waits out blinks, "nobody here" waits for the person to really leave).
/// 3. The shown reaction is held at least `minHold` so memes do not flicker.
public struct ReactionStabilizer: Sendable {
    public var minHold: TimeInterval
    /// Multiplier for the window and every enter delay (UI "calm ↔ snappy" knob).
    public var delayScale: Double

    public private(set) var current: Reaction = .noFace
    private var shownSince: TimeInterval = -.infinity
    private var candidate: Reaction = .noFace
    private var candidateSince: TimeInterval = 0
    private var window: [(t: TimeInterval, r: Reaction, w: Double)] = []

    public init(minHold: TimeInterval = 1.2, delayScale: Double = 1) {
        self.minHold = minHold
        self.delayScale = delayScale
    }

    var windowLength: TimeInterval { 0.5 * delayScale }

    func enterDelay(for r: Reaction) -> TimeInterval {
        let base: TimeInterval = switch r {
        case .noFace: 1.2
        case .neutral: 0.6
        case .eyesClosed: 0.6    // well past a blink (~0.1–0.4 s)
        case .thumbsUp, .thumbsDown, .peace, .pointing, .heart, .handsUp: 0.2
        default: 0.35
        }
        return base * delayScale
    }

    /// Feeds one estimate; returns the new reaction when the shown one changes.
    public mutating func update(_ r: Reaction, confidence: Double = 1, at t: TimeInterval) -> Reaction? {
        if confidence > 0 {
            // Floor the weight so low-confidence but consistent frames still count.
            window.append((t, r, max(confidence, 0.3)))
        }
        let length = windowLength
        window.removeAll { t - $0.t > length }
        guard !window.isEmpty else { return nil }

        var votes: [Reaction: Double] = [:]
        for v in window { votes[v.r, default: 0] += v.w }
        // Ties keep the current candidate, avoiding ping-pong.
        let winner = votes.max { a, b in
            a.value != b.value ? a.value < b.value : b.key == candidate
        }!.key

        if winner != candidate {
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
