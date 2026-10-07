import Foundation

/// Decides whether a detected reaction may pop up its meme.
///
/// - Reactions the user switched off never pop up (detection still runs).
/// - Cooldown: a reaction that was just on screen can't come back within `cooldown` seconds
///   of leaving it. Neutral and "nobody here" are exempt, and so is re-showing the reaction
///   that is current (e.g. re-picking a meme after the library changed).
public struct ReactionGate: Sendable {
    public var disabled: Set<Reaction>
    public var cooldown: TimeInterval
    private var lastOnScreen: [Reaction: TimeInterval] = [:]

    public init(disabled: Set<Reaction> = [], cooldown: TimeInterval = 4) {
        self.disabled = disabled
        self.cooldown = cooldown
    }

    /// Call on every frame where `reaction`'s meme is visible; the cooldown counts from the last one.
    public mutating func noteOnScreen(_ reaction: Reaction, at t: TimeInterval) {
        lastOnScreen[reaction] = t
    }

    public func allows(_ reaction: Reaction, at t: TimeInterval, current: Reaction? = nil) -> Bool {
        if disabled.contains(reaction) { return false }
        guard reaction != .neutral, reaction != .noFace, reaction != current,
              let last = lastOnScreen[reaction] else { return true }
        return t - last >= cooldown
    }
}
