import CoreGraphics
import Foundation

/// Coordinate convention for everything in MemeCamCore:
/// "aspect space" — y in [0, 1] pointing UP (Vision convention), x in [0, aspect]
/// where aspect = imageWidth / imageHeight. Distances are therefore isotropic.

/// Face landmark regions extracted from Vision, already converted to aspect space.
public struct FaceLandmarks: Sendable, Equatable {
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
public enum HandJoint: String, CaseIterable, Sendable {
    case wrist
    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip
}

public struct HandPose: Sendable, Equatable {
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
}

/// Everything the detector saw in one frame.
public struct FrameObservation: Sendable {
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
