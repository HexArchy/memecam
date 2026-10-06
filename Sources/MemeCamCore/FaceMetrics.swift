import CoreGraphics
import Foundation

/// Scale- and rotation-invariant face measurements. All lengths are divided by the
/// inter-ocular distance (IOD), and points are de-rotated by the eye-line angle first,
/// so tilting the head or moving closer to the camera does not change the numbers.
public struct FaceMetrics: Sendable, Equatable {
    /// Inner-lip height / outer-lip width (mouth aspect ratio).
    public var mouthOpen: Double
    /// Outer-lip width / IOD.
    public var mouthWidth: Double
    /// (mean mouth-corner y − upper-lip top y) / IOD. Higher = corners up. Anchored to the
    /// upper lip so dropping the jaw does not read as a smile.
    public var cornerLift: Double
    /// Mean eye height / eye width (eye aspect ratio).
    public var eyeOpen: Double
    /// (mean brow y − mean eye y) / IOD.
    public var browRaise: Double
    /// Head roll in degrees, from the eye line.
    public var rollDegrees: Double

    public init(mouthOpen: Double, mouthWidth: Double, cornerLift: Double,
                eyeOpen: Double, browRaise: Double, rollDegrees: Double) {
        self.mouthOpen = mouthOpen
        self.mouthWidth = mouthWidth
        self.cornerLift = cornerLift
        self.eyeOpen = eyeOpen
        self.browRaise = browRaise
        self.rollDegrees = rollDegrees
    }

    /// Typical values for a relaxed face looking at a webcam; used until calibrated.
    public static let typicalNeutral = FaceMetrics(
        mouthOpen: 0.04, mouthWidth: 0.95, cornerLift: -0.08,
        eyeOpen: 0.30, browRaise: 0.40, rollDegrees: 0
    )

    public init?(_ face: FaceLandmarks) {
        guard face.leftEye.count >= 4, face.rightEye.count >= 4,
              face.outerLips.count >= 6, face.innerLips.count >= 4,
              !face.leftBrow.isEmpty, !face.rightBrow.isEmpty else { return nil }

        let le = face.leftEye.centroid, re = face.rightEye.centroid
        let (a, b) = le.x <= re.x ? (le, re) : (re, le)
        let iod = a.distance(to: b)
        guard iod > 1e-4 else { return nil }

        let angle = atan2(Double(b.y - a.y), Double(b.x - a.x))
        let pivot = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let c = CGFloat(cos(-angle)), s = CGFloat(sin(-angle))
        func derotate(_ pts: [CGPoint]) -> [CGPoint] {
            pts.map { p in
                let dx = p.x - pivot.x, dy = p.y - pivot.y
                return CGPoint(x: pivot.x + dx * c - dy * s, y: pivot.y + dx * s + dy * c)
            }
        }

        let leftEye = derotate(face.leftEye), rightEye = derotate(face.rightEye)
        let brows = derotate(face.leftBrow + face.rightBrow)
        let outer = derotate(face.outerLips), inner = derotate(face.innerLips)

        let outerBounds = outer.bounds
        let innerBounds = inner.bounds
        guard outerBounds.width > 1e-5 else { return nil }

        // Mouth corners = extreme-x outer lip points.
        let leftCorner = outer.min { $0.x < $1.x }!
        let rightCorner = outer.max { $0.x < $1.x }!
        let cornersY = (leftCorner.y + rightCorner.y) / 2

        func ear(_ eye: [CGPoint]) -> Double {
            let b = eye.bounds
            return b.width > 1e-5 ? Double(b.height / b.width) : 0
        }

        let eyesY = (leftEye.centroid.y + rightEye.centroid.y) / 2
        let iodF = CGFloat(iod)

        self.mouthOpen = Double(innerBounds.height / outerBounds.width)
        self.mouthWidth = Double(outerBounds.width / iodF)
        self.cornerLift = Double((cornersY - outerBounds.maxY) / iodF)
        self.eyeOpen = (ear(leftEye) + ear(rightEye)) / 2
        self.browRaise = Double((brows.centroid.y - eyesY) / iodF)
        self.rollDegrees = angle * 180 / .pi
    }

    /// Linear blend used for exponential moving averages.
    public func blended(toward other: FaceMetrics, alpha: Double) -> FaceMetrics {
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * alpha }
        return FaceMetrics(
            mouthOpen: mix(mouthOpen, other.mouthOpen),
            mouthWidth: mix(mouthWidth, other.mouthWidth),
            cornerLift: mix(cornerLift, other.cornerLift),
            eyeOpen: mix(eyeOpen, other.eyeOpen),
            browRaise: mix(browRaise, other.browRaise),
            rollDegrees: mix(rollDegrees, other.rollDegrees)
        )
    }
}
