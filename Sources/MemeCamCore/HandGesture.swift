import CoreGraphics
import Foundation

public enum HandGesture: String, Sendable, CaseIterable {
    case thumbsUp, thumbsDown, peace, openPalm, pointing, fist

    public var reaction: Reaction {
        switch self {
        case .thumbsUp: .thumbsUp
        case .thumbsDown: .thumbsDown
        case .peace: .peace
        case .openPalm: .openPalm
        case .pointing: .pointing
        case .fist: .fist
        }
    }
}

/// Finger state derived from joint geometry. Uses distance-from-wrist ratios, which are
/// invariant to hand rotation (works for sideways thumbs, tilted palms, etc.).
public struct HandShape: Sendable, Equatable {
    public var thumbExtended: Bool
    /// index, middle, ring, little
    public var fingersExtended: [Bool]
    /// Unit-ish vertical component of the thumb direction (MP -> tip); +1 = straight up.
    public var thumbVertical: Double
    /// Wrist -> middle MCP distance; the hand's own length unit.
    public var palmSize: Double

    /// tip-to-wrist / PIP-to-wrist per finger (index…little). ~0.65 curled into a fist,
    /// ~1.0–1.1 bent/curved (heart hands), ≥1.25 straight. 0 when the finger wasn't seen.
    public var fingerReach: [Double]

    public var extendedCount: Int { fingersExtended.filter { $0 }.count }

    /// Tolerates missing joints: Vision drops low-confidence joints of fingers hidden inside a
    /// fist, so an unseen finger counts as curled instead of discarding the whole hand.
    public init?(_ hand: HandPose) {
        guard let wrist = hand[.wrist], let middleMCP = hand[.middleMCP] else { return nil }
        let palm = wrist.distance(to: middleMCP)
        guard palm > 1e-4 else { return nil }
        palmSize = palm

        let chains: [(HandJoint, HandJoint, HandJoint)] = [
            (.indexMCP, .indexPIP, .indexTip),
            (.middleMCP, .middlePIP, .middleTip),
            (.ringMCP, .ringPIP, .ringTip),
            (.littleMCP, .littlePIP, .littleTip),
        ]
        var fingers: [Bool] = [], reach: [Double] = []
        for (mcpJ, pipJ, tipJ) in chains {
            guard let pip = hand[pipJ], let tip = hand[tipJ] else {
                fingers.append(false)
                reach.append(0)
                continue
            }
            let r = wrist.distance(to: tip) / max(wrist.distance(to: pip), 1e-6)
            let longEnough = hand[mcpJ].map { $0.distance(to: tip) > palm * 0.55 } ?? true
            fingers.append(r > 1.15 && longEnough)
            reach.append(r)
        }
        fingersExtended = fingers
        fingerReach = reach

        guard let tTip = hand[.thumbTip], let tMP = hand[.thumbMP] ?? hand[.thumbCMC] else {
            thumbExtended = false
            thumbVertical = 0
            return
        }
        let tIP = hand[.thumbIP] ?? tMP
        // Measured against the little-finger knuckle: stays valid when the hand rotates.
        let anchor = hand[.littleMCP] ?? hand[.ringMCP] ?? middleMCP
        thumbExtended = tTip.distance(to: anchor) > tMP.distance(to: anchor) * 1.1
            && wrist.distance(to: tTip) > wrist.distance(to: tIP) * 1.03
        let dx = Double(tTip.x - tMP.x), dy = Double(tTip.y - tMP.y)
        let len = max(hypot(dx, dy), 1e-6)
        thumbVertical = dy / len
    }

    /// Thumb down with index+middle bent in an arc (not tucked into a fist): what Vision sees
    /// when two hands form a heart — it usually merges them into one "hand".
    public var looksLikeHalfHeart: Bool {
        thumbExtended && thumbVertical < -0.5 && (fingerReach[0] + fingerReach[1]) / 2 > 0.92
            && extendedCount <= 1
    }

    /// Like `gesture`, plus checks that need the joints: a thumbs-up thumb must be the
    /// highest point of the hand (a thumbs-down the lowest), which rejects sideways fists.
    public func gesture(for hand: HandPose) -> HandGesture? {
        let g = gesture
        if g == .thumbsDown && looksLikeHalfHeart { return nil } // classifier decides (heart)
        guard g == .thumbsUp || g == .thumbsDown, let tip = hand[.thumbTip] else { return g }
        let others: [HandJoint] = [.indexTip, .middleTip, .ringTip, .littleTip, .indexPIP, .middlePIP]
        let ys = others.compactMap { hand[$0]?.y }
        guard !ys.isEmpty else { return g }
        let margin = CGFloat(palmSize * 0.15)
        if g == .thumbsUp { return tip.y > ys.max()! + margin ? .thumbsUp : .fist }
        return tip.y < ys.min()! - margin ? .thumbsDown : .fist
    }

    public var gesture: HandGesture? {
        let f = fingersExtended
        let curledFour = extendedCount == 0
        if curledFour && thumbExtended {
            if thumbVertical > 0.6 { return .thumbsUp }
            if thumbVertical < -0.6 { return .thumbsDown }
        }
        if f[0] && f[1] && !f[2] && !f[3] { return .peace }
        if f[0] && !f[1] && !f[2] && !f[3] { return .pointing }
        if extendedCount >= 4 { return .openPalm }
        if curledFour { return .fist }
        return nil
    }
}
