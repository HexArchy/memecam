import CoreGraphics
import Foundation

public struct ReactionEstimate: Sendable, Equatable {
    public var reaction: Reaction
    /// 0...1, how strongly the winning rule fired.
    public var confidence: Double
    public var metrics: FaceMetrics?

    public init(reaction: Reaction, confidence: Double, metrics: FaceMetrics? = nil) {
        self.reaction = reaction
        self.confidence = confidence
        self.metrics = metrics
    }
}

/// Maps one frame of observations to a single best reaction.
///
/// Face expressions are judged *relative to a per-user neutral baseline* that is learned
/// automatically (slow EMA while the user looks neutral) or explicitly via `calibrate()`.
/// This is the main accuracy win over fixed-threshold approaches.
public struct ReactionClassifier: Sendable {
    public struct Config: Sendable, Equatable {
        /// 0.5 = needs exaggerated expressions, 1.5 = very sensitive.
        public var sensitivity: Double = 1.0
        public var tiltDegrees: Double = 18
        public var enableGestures = true
        public var enableExpressions = true
        public init() {}
    }

    public var config: Config
    public private(set) var baseline: FaceMetrics = .typicalNeutral
    public private(set) var isCalibrated = false

    /// Last face box, kept briefly so a hand covering the face still reads as facepalm.
    private var lastFaceBox: CGRect?
    private var lastFaceTime: TimeInterval = -.infinity

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Snap the neutral baseline to the given metrics (user pressed "Calibrate").
    public mutating func calibrate(to metrics: FaceMetrics) {
        baseline = metrics
        baseline.rollDegrees = 0
        isCalibrated = true
    }

    public mutating func classify(_ frame: FrameObservation) -> ReactionEstimate {
        let metrics = frame.face.flatMap(FaceMetrics.init)
        if let face = frame.face {
            lastFaceBox = face.boundingBox
            lastFaceTime = frame.timestamp
        }
        let faceBox = frame.face?.boundingBox
            ?? (frame.timestamp - lastFaceTime < 1.0 ? lastFaceBox : nil)

        if config.enableGestures, let g = classifyGestures(frame.hands, faceBox: faceBox) {
            return ReactionEstimate(reaction: g.0, confidence: g.1, metrics: metrics)
        }
        guard let metrics else {
            return ReactionEstimate(reaction: frame.hands.isEmpty ? .noFace : .neutral, confidence: 1)
        }
        guard config.enableExpressions else {
            return ReactionEstimate(reaction: .neutral, confidence: 1, metrics: metrics)
        }
        let estimate = classifyExpression(metrics)
        if estimate.reaction == .neutral && frame.hands.isEmpty {
            // Slowly adapt to this user's resting face.
            baseline = baseline.blended(toward: metrics, alpha: isCalibrated ? 0.005 : 0.03)
            baseline.rollDegrees = 0
        }
        return estimate
    }

    // MARK: - Gestures

    private func classifyGestures(_ hands: [HandPose], faceBox: CGRect?) -> (Reaction, Double)? {
        let shaped = hands.compactMap { h in HandShape(h).map { (h, $0) } }
        guard !shaped.isEmpty else { return nil }

        if shaped.count >= 2 {
            let (h1, s1) = shaped[0], (h2, s2) = shaped[1]
            let unit = (s1.palmSize + s2.palmSize) / 2
            if let i1 = h1[.indexTip], let i2 = h2[.indexTip],
               let t1 = h1[.thumbTip], let t2 = h2[.thumbTip],
               i1.distance(to: i2) < unit * 0.6, t1.distance(to: t2) < unit * 0.6,
               (i1.y + i2.y) > (t1.y + t2.y) {
                return (.heart, 0.9)
            }
            let topY = faceBox.map { $0.maxY - $0.height * 0.2 } ?? 0.65
            if s1.extendedCount >= 3, s2.extendedCount >= 3,
               h1.center.y > topY, h2.center.y > topY {
                return (.handsUp, 0.9)
            }
        }

        if let face = faceBox {
            for (hand, shape) in shaped {
                let hb = hand.boundingBox
                let overlap = hb.intersection(face)
                let coverage = overlap.isNull ? 0 : (overlap.width * overlap.height) / max(face.width * face.height, 1e-6)
                // Hand over the upper face (eyes/forehead) => facepalm.
                if coverage > 0.06, face.insetBy(dx: face.width * 0.1, dy: 0).contains(hand.center),
                   hand.center.y > face.minY + face.height * 0.4 {
                    return (.facepalm, min(1, 0.5 + Double(coverage) * 2))
                }
                // Hand at the chin, not an open palm => thinking.
                let chin = CGRect(x: face.minX - face.width * 0.15, y: face.minY - face.height * 0.35,
                                  width: face.width * 1.3, height: face.height * 0.6)
                if shape.extendedCount <= 2, chin.contains(hand[.indexTip] ?? hand.center) {
                    return (.thinking, 0.8)
                }
            }
        }

        // Single-hand gesture from the most confident recognised hand.
        let best = shaped
            .compactMap { h, s in s.gesture.map { ($0, h.confidence) } }
            .max { $0.1 < $1.1 }
        return best.map { ($0.0.reaction, $0.1) }
    }

    // MARK: - Expressions

    private func classifyExpression(_ m: FaceMetrics) -> ReactionEstimate {
        let b = baseline
        let k = 1 / max(config.sensitivity, 0.1) // >1 means stricter thresholds

        let openDelta = m.mouthOpen - b.mouthOpen
        let widthRatio = m.mouthWidth / max(b.mouthWidth, 1e-3)
        let liftDelta = m.cornerLift - b.cornerLift
        let eyeRatio = m.eyeOpen / max(b.eyeOpen, 1e-3)
        let browDelta = m.browRaise - b.browRaise

        let smiling = widthRatio > 1 + 0.10 * k || liftDelta > 0.045 * k
        let smileScore = clamp(max((widthRatio - 1) / 0.25, liftDelta / 0.1))

        func est(_ r: Reaction, _ c: Double) -> ReactionEstimate {
            ReactionEstimate(reaction: r, confidence: clamp(c), metrics: m)
        }

        if openDelta > 0.18 * k {
            return smiling
                ? est(.laugh, (openDelta / 0.4 + smileScore) / 2)
                : est(.surprised, openDelta / 0.45)
        }
        if eyeRatio < 1 - 0.45 * min(k, 1.6) { return est(.eyesClosed, (1 - eyeRatio) / 0.7) }
        if browDelta > 0.07 * k { return est(.eyebrowsRaised, browDelta / 0.15) }
        if smiling { return est(.smile, smileScore) }
        if liftDelta < -0.04 * k { return est(.sad, -liftDelta / 0.1) }
        if abs(m.rollDegrees) > config.tiltDegrees * k { return est(.headTilt, abs(m.rollDegrees) / 35) }
        return est(.neutral, 1)
    }

    private func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
}
