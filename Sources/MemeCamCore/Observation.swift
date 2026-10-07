import CoreGraphics
import Foundation

/// Coordinate convention for everything in MemeCamCore:
/// "aspect space" — y in [0, 1] pointing UP (Vision convention), x in [0, aspect]
/// where aspect = imageWidth / imageHeight. Distances are therefore isotropic.

/// Face landmark regions extracted from Vision, already converted to aspect space.
public struct FaceLandmarks: Sendable, Equatable, Codable {
    public var boundingBox: CGRect
    public var leftEye: [CGPoint]
    public var rightEye: [CGPoint]
    public var leftBrow: [CGPoint]
    public var rightBrow: [CGPoint]
    public var outerLips: [CGPoint]
    public var innerLips: [CGPoint]
    /// Radians. Positive roll = head tilted counter-clockwise in image.
    public var roll: Double
    public var yaw: Double
    public var pitch: Double

    public init(boundingBox: CGRect, leftEye: [CGPoint], rightEye: [CGPoint],
                leftBrow: [CGPoint], rightBrow: [CGPoint],
                outerLips: [CGPoint], innerLips: [CGPoint],
                roll: Double = 0, yaw: Double = 0, pitch: Double = 0) {
        self.boundingBox = boundingBox
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.leftBrow = leftBrow
        self.rightBrow = rightBrow
        self.outerLips = outerLips
        self.innerLips = innerLips
        self.roll = roll
        self.yaw = yaw
        self.pitch = pitch
    }
}

/// Hand joints, mirroring `VNHumanHandPoseObservation.JointName`.
public enum HandJoint: String, CaseIterable, Sendable, Codable, CodingKeyRepresentable {
    case wrist
    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip
}

public struct HandPose: Sendable, Equatable, Codable {
    /// Only joints with sufficient confidence are present. Aspect space.
    public var joints: [HandJoint: CGPoint]
    public var confidence: Double

    public init(joints: [HandJoint: CGPoint], confidence: Double = 1) {
        self.joints = joints
        self.confidence = confidence
    }

    public subscript(_ joint: HandJoint) -> CGPoint? { joints[joint] }

    public var boundingBox: CGRect {
        let pts = Array(joints.values)
        guard let first = pts.first else { return .null }
        return pts.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
            $0.union(CGRect(origin: $1, size: .zero))
        }
    }

    public var center: CGPoint {
        let b = boundingBox
        return CGPoint(x: b.midX, y: b.midY)
    }
    /// When the wrist is out of frame (a fist right in front of the lens) Vision drops it, and
    /// nothing downstream can normalise the hand. Estimate it behind the knuckle line: the
    /// palm is roughly as long as the knuckles are wide, on the side away from the fingers.
    public func withEstimatedWrist() -> HandPose {
        // The little knuckle is often missing too (peace sign: 52/58 hands), so fall back to the
        // ring knuckle, which spans ~2/3 of the knuckle line.
        guard joints[.wrist] == nil, let index = joints[.indexMCP],
              let (little, span) = joints[.littleMCP].map({ ($0, 1.0) }) ?? joints[.ringMCP].map({ ($0, 1.5) }),
              let middle = joints[.middleMCP] ?? joints[.ringMCP] else { return self }
        let knuckles = CGPoint(x: little.x - index.x, y: little.y - index.y)
        let width = hypot(knuckles.x, knuckles.y) * span
        guard width > 1e-4, hypot(knuckles.x, knuckles.y) > 1e-4 else { return self }
        let len = hypot(knuckles.x, knuckles.y)
        var n = CGPoint(x: -knuckles.y / len, y: knuckles.x / len)   // unit normal
        let fingers = [HandJoint.indexPIP, .middlePIP, .ringPIP, .littlePIP, .indexTip, .middleTip]
            .compactMap { joints[$0] }
        if !fingers.isEmpty {
            let c = fingers.centroid
            // Point the normal away from the fingers.
            if (c.x - middle.x) * n.x + (c.y - middle.y) * n.y > 0 { n = CGPoint(x: -n.x, y: -n.y) }
        }
        var copy = self
        copy.joints[.wrist] = CGPoint(x: middle.x + n.x * width * 1.1, y: middle.y + n.y * width * 1.1)
        return copy
    }
}

/// Everything the detector saw in one frame.
public struct FrameObservation: Sendable, Codable {
    public var timestamp: TimeInterval
    public var face: FaceLandmarks?
    public var hands: [HandPose]

    public init(timestamp: TimeInterval, face: FaceLandmarks?, hands: [HandPose]) {
        self.timestamp = timestamp
        self.face = face
        self.hands = hands
    }
}

extension CGPoint {
    @inlinable func distance(to p: CGPoint) -> Double {
        Double(hypot(x - p.x, y - p.y))
    }
}

extension Array where Element == CGPoint {
    var centroid: CGPoint {
        guard !isEmpty else { return .zero }
        let s = reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: s.x / CGFloat(count), y: s.y / CGFloat(count))
    }

    var bounds: CGRect {
        guard let first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in self {
            minX = Swift.min(minX, p.x); maxX = Swift.max(maxX, p.x)
            minY = Swift.min(minY, p.y); maxY = Swift.max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
