import CoreGraphics
import Foundation

/// Scale- and rotation-invariant face measurements. All lengths are divided by the
/// inter-ocular distance (IOD), and points are de-rotated by the eye-line angle first,
/// so tilting the head or moving closer to the camera does not change the numbers.
/// Vertical measures are also corrected for head yaw/pitch (foreshortening): turning the head
/// shrinks the IOD by cos(yaw), which would otherwise inflate every vertical/IOD ratio.
public struct FaceMetrics: Sendable, Equatable, Codable {
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
    /// (mean inner-brow-end y − mean eye y) / IOD — FACS AU1 "inner brow raiser" (sadness, worry).
    public var innerBrowRaise: Double
    /// Distance between the inner brow ends / IOD — shrinks with AU4 "brow lowerer" (frown).
    public var browGap: Double

    public init(mouthOpen: Double, mouthWidth: Double, cornerLift: Double,
                eyeOpen: Double, browRaise: Double, rollDegrees: Double,
                innerBrowRaise: Double = 0.38, browGap: Double = 0.55) {
        self.mouthOpen = mouthOpen
        self.mouthWidth = mouthWidth
        self.cornerLift = cornerLift
        self.eyeOpen = eyeOpen
        self.browRaise = browRaise
        self.rollDegrees = rollDegrees
        self.innerBrowRaise = innerBrowRaise
        self.browGap = browGap
    }

    /// Typical values for a relaxed face looking at a webcam; used until calibrated.
    public static let typicalNeutral = FaceMetrics(
        mouthOpen: 0.04, mouthWidth: 0.95, cornerLift: -0.08,
        eyeOpen: 0.30, browRaise: 0.40, rollDegrees: 0
    )

    /// All fields as a vector (for filtering / statistics); order matches `init(vector:)`.
    public var vector: [Double] {
        [mouthOpen, mouthWidth, cornerLift, eyeOpen, browRaise, rollDegrees, innerBrowRaise, browGap]
    }

    public init(vector v: [Double]) {
        self.init(mouthOpen: v[0], mouthWidth: v[1], cornerLift: v[2], eyeOpen: v[3], browRaise: v[4],
                  rollDegrees: v[5], innerBrowRaise: v[6], browGap: v[7])
    }

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
        let leftBrow = derotate(face.leftBrow), rightBrow = derotate(face.rightBrow)
        let brows = leftBrow + rightBrow
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

        // Inner brow end = the brow point closest to the face midline.
        func innerEnd(_ brow: [CGPoint]) -> CGPoint { brow.min { abs($0.x - pivot.x) < abs($1.x - pivot.x) }! }
        let innerL = innerEnd(leftBrow), innerR = innerEnd(rightBrow)

        // Foreshortening: yaw shrinks horizontal lengths (IOD, widths) by cos(yaw); pitch shrinks
        // vertical ones by cos(pitch). Clamp so extreme poses don't explode the correction.
        let yawCos = cos(min(abs(face.yaw), 0.7)), pitchCos = cos(min(abs(face.pitch), 0.7))
        let vertical = yawCos / pitchCos   // for vertical / horizontal ratios

        self.mouthOpen = Double(innerBounds.height / outerBounds.width) * vertical
        self.mouthWidth = Double(outerBounds.width / iodF)
        self.cornerLift = Double((cornersY - outerBounds.maxY) / iodF) * vertical
        self.eyeOpen = (ear(leftEye) + ear(rightEye)) / 2 * vertical
        self.browRaise = Double((brows.centroid.y - eyesY) / iodF) * vertical
        self.rollDegrees = angle * 180 / .pi
        self.innerBrowRaise = Double(((innerL.y + innerR.y) / 2 - eyesY) / iodF) * vertical
        self.browGap = Double(abs(innerR.x - innerL.x) / iodF)
    }

    /// Linear blend used for exponential moving averages.
    public func blended(toward other: FaceMetrics, alpha: Double) -> FaceMetrics {
        FaceMetrics(vector: zip(vector, other.vector).map { $0 + ($1 - $0) * alpha })
    }
}
