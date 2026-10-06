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

    public var extendedCount: Int { fingersExtended.filter { $0 }.count }

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
        var fingers: [Bool] = []
        for (mcpJ, pipJ, tipJ) in chains {
            guard let mcp = hand[mcpJ], let pip = hand[pipJ], let tip = hand[tipJ] else { return nil }
            let tipFar = wrist.distance(to: tip) > wrist.distance(to: pip) * 1.15
            let longEnough = mcp.distance(to: tip) > palm * 0.55
            fingers.append(tipFar && longEnough)
        }
        fingersExtended = fingers

        guard let tTip = hand[.thumbTip], let tIP = hand[.thumbIP], let tMP = hand[.thumbMP],
              let littleMCP = hand[.littleMCP] else { return nil }
        // Measured against the little-finger knuckle: stays valid when the hand rotates.
        thumbExtended = tTip.distance(to: littleMCP) > tMP.distance(to: littleMCP) * 1.1
            && wrist.distance(to: tTip) > wrist.distance(to: tIP) * 1.03
        let dx = Double(tTip.x - tMP.x), dy = Double(tTip.y - tMP.y)
        let len = max(hypot(dx, dy), 1e-6)
        thumbVertical = dy / len
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
