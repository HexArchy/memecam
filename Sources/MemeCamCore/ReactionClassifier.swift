import CoreGraphics
import Foundation

public struct ReactionEstimate: Sendable, Equatable {
    public var reaction: Reaction
    /// 0...1, how strongly the winning rule fired. 0 = "no opinion" (unreliable frame),
    /// which the stabilizer ignores instead of treating it as a vote.
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
/// Pipeline per frame:
/// 1. Gestures (hand shape + position relative to the face) take precedence over expressions.
/// 2. Face metrics are smoothed with a One Euro filter.
/// 3. Expressions are scored *relative to the user's own neutral face* (baseline), each score
///    normalised so that 1.0 = threshold; the best score ≥ 1 wins, with hysteresis that favours
///    the reaction currently shown.
/// 4. Frames with the head turned far away are skipped (landmark geometry is unreliable there).
///
/// The baseline is the per-field median of the first calm frames (auto-calibration), can be
/// re-measured with `beginCalibration()`, and keeps adapting very slowly while neutral.
public struct ReactionClassifier: Sendable {
    public struct Config: Sendable, Equatable {
        /// 0.5 = needs exaggerated expressions, 1.5 = very sensitive.
        public var sensitivity: Double = 1.0
        public var tiltDegrees: Double = 22
        /// Beyond this head yaw/pitch (radians) expressions are not judged.
        public var maxHeadTurn: Double = 0.45
        /// Brow-based reactions (eyebrows raised, sad) are fragile under pose; stricter limit.
        public var maxHeadTurnForBrows: Double = 0.30
        public var enableGestures = true
        public var enableExpressions = true
        public init() {}
    }

    public enum Calibration: Sendable, Equatable {
        case none, automatic, manual
    }

    public var config: Config
    public private(set) var baseline: FaceMetrics = .typicalNeutral
    public private(set) var calibration: Calibration = .none
    public var isCalibrated: Bool { calibration != .none }
    /// 0...1 while collecting calibration frames.
    public var calibrationProgress: Double { collecting ? Double(samples.count) / Double(Self.calibrationFrames) : 1 }
    /// True while a user-requested calibration is measuring.
    public var isCalibratingManually: Bool { collectingManual }

    private static let calibrationFrames = 15
    private var samples: [FaceMetrics] = []
    private var collecting = true
    private var collectingManual = false
    private var filter = FaceMetricsFilter()
    private var lastExpression: Reaction = .neutral

    /// Last face box, kept briefly so a hand covering the face still reads as facepalm.
    private var lastFaceBox: CGRect?
    private var lastFaceTime: TimeInterval = -.infinity

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Re-measure the neutral face over the next frames (user pressed "Calibrate").
    public mutating func beginCalibration() {
        samples.removeAll()
        collecting = true
        collectingManual = true
    }

    /// Snap the neutral baseline to the given metrics.
    public mutating func calibrate(to metrics: FaceMetrics) {
        baseline = metrics
        baseline.rollDegrees = 0
        calibration = .manual
        collecting = false
        collectingManual = false
    }

    public mutating func classify(_ frame: FrameObservation) -> ReactionEstimate {
        let raw = frame.face.flatMap(FaceMetrics.init)
        let metrics = raw.map { filter.filter($0, at: frame.timestamp) }
        if let face = frame.face {
            lastFaceBox = face.boundingBox
            lastFaceTime = frame.timestamp
        }
        let faceBox = frame.face?.boundingBox
            ?? (frame.timestamp - lastFaceTime < 1.0 ? lastFaceBox : nil)

        if config.enableGestures, let g = classifyGestures(frame.hands, faceBox: faceBox) {
            return ReactionEstimate(reaction: g.0, confidence: g.1, metrics: metrics)
        }
        guard let face = frame.face, let metrics, let raw else {
            return ReactionEstimate(reaction: frame.hands.isEmpty ? .noFace : .neutral, confidence: 1)
        }
        guard config.enableExpressions else {
            return ReactionEstimate(reaction: .neutral, confidence: 1, metrics: metrics)
        }

        let headTurned = abs(face.yaw) > config.maxHeadTurn || abs(face.pitch) > config.maxHeadTurn
        if collecting, frame.hands.isEmpty, !headTurned {
            collectCalibrationSample(raw)
        }
        if headTurned {
            // Turned away: profile landmarks distort mouth/eye ratios. Abstain.
            return ReactionEstimate(reaction: lastExpression, confidence: 0, metrics: metrics)
        }

        let browsReliable = abs(face.yaw) <= config.maxHeadTurnForBrows && abs(face.pitch) <= config.maxHeadTurnForBrows
        let estimate = classifyExpression(metrics, browsReliable: browsReliable)
        lastExpression = estimate.reaction
        if estimate.reaction == .neutral, frame.hands.isEmpty, !collecting {
            // Track slow drift (lighting, posture) without chasing expressions.
            let roll = baseline.rollDegrees
            baseline = baseline.blended(toward: metrics, alpha: calibration == .manual ? 0.002 : 0.01)
            baseline.rollDegrees = roll
        }
        return estimate
    }

    private mutating func collectCalibrationSample(_ m: FaceMetrics) {
        // Auto-calibration only accepts calm-looking frames; manual trusts the user.
        if !collectingManual {
            let b = FaceMetrics.typicalNeutral
            guard m.mouthOpen < b.mouthOpen + 0.12, abs(m.rollDegrees) < 12 else { return }
        }
        samples.append(m)
        if samples.count >= Self.calibrationFrames, let med = FaceMetrics.median(samples) {
            baseline = med
            calibration = collectingManual ? .manual : .automatic
            collecting = false
            collectingManual = false
            samples.removeAll()
        }
    }

    // MARK: - Gestures

    private func classifyGestures(_ hands: [HandPose], faceBox: CGRect?) -> (Reaction, Double)? {
        // Ignore tiny "hands" (background clutter, far-away people).
        let minPalm = faceBox.map { Double($0.height) * 0.25 } ?? 0.06
        // Low Vision confidence = partial/blurred/false hands; they cause most spurious gestures.
        let shaped = hands.filter { $0.confidence >= 0.5 }
            .compactMap { h in HandShape(h).map { (h, $0) } }.filter { $0.1.palmSize >= minPalm }
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

        // Vision often merges a two-hand heart into one "hand" with the thumb pointing down
        // and index/middle bent in an arc (measured: reach ≈1.1 vs ≈0.7 for a thumbs-down fist).
        if let (hand, _) = shaped.first(where: { $0.1.looksLikeHalfHeart }),
           faceBox.map({ hand.center.y < $0.midY }) ?? true {
            return (.heart, 0.8)
        }

        if let face = faceBox {
            for (hand, shape) in shaped {
                let hb = hand.boundingBox
                let overlap = hb.intersection(face)
                let coverage = overlap.isNull ? 0 : (overlap.width * overlap.height) / max(face.width * face.height, 1e-6)
                // Open-ish hand over the upper face (eyes/forehead) => facepalm. A fist held in
                // front of the face is not a facepalm (it was the #2 fist confusion).
                if shape.extendedCount >= 2, coverage > 0.06,
                   face.insetBy(dx: face.width * 0.1, dy: 0).contains(hand.center),
                   hand.center.y > face.minY + face.height * 0.4 {
                    return (.facepalm, min(1, 0.5 + Double(coverage) * 2))
                }
                // Hand resting under the chin => thinking (fist, finger or flat hand). Measured on
                // a recording: thinking hands sit centred under the face (|dx| ≤ 0.25 face widths,
                // centre ≈ chin height, top ≈ 0.3 h), while a fist shown beside the face sits off
                // to the side (|dx| ≈ 0.4) and higher (top ≈ 0.8 h).
                let dx = abs(hand.center.x - face.midX) / face.width
                let dy = (hand.center.y - face.minY) / face.height
                let top = (hand.boundingBox.maxY - face.minY) / face.height
                if shape.extendedCount <= 3, dx < 0.3, dy > -0.6, dy < 0.2, top < 0.55 {
                    return (.thinking, 0.8)
                }
                // One open palm raised to the top of the head => hands up (Vision frequently
                // reports only one of two raised hands).
                if shape.extendedCount >= 4, hand.center.y > face.minY + face.height * 0.9,
                   coverage < 0.15 {
                    return (.handsUp, 0.75)
                }
            }
        }

        // Single-hand gesture from the most confident recognised hand.
        let best = shaped
            .compactMap { h, s in s.gesture(for: h).map { ($0, h.confidence) } }
            .max { $0.1 < $1.1 }
        return best.map { ($0.0.reaction, max($0.1, 0.5)) }
    }

    // MARK: - Expressions

    /// Scores are normalised: 1.0 == "just at threshold".
    public struct ExpressionScores: Sendable {
        public var open = 0.0, smile = 0.0, eyesClosed = 0.0, brows = 0.0, sad = 0.0, tilt = 0.0
        /// FACS AU1 (inner brow raiser) and AU4 (brow lowerer) intensities, 1 = threshold.
        public var au1 = 0.0, au4 = 0.0
    }

    public func scores(_ m: FaceMetrics) -> ExpressionScores {
        let b = baseline
        let k = 1 / max(config.sensitivity, 0.1) // >1 means stricter thresholds
        let widthRatio = m.mouthWidth / max(b.mouthWidth, 1e-3)
        let eyeRatio = m.eyeOpen / max(b.eyeOpen, 1e-3)
        var s = ExpressionScores()
        s.open = (m.mouthOpen - b.mouthOpen) / (0.25 * k)
        s.smile = max((widthRatio - 1) / (0.14 * k), (m.cornerLift - b.cornerLift) / (0.06 * k))
        s.eyesClosed = (1 - eyeRatio) / (0.55 * min(k, 1.4))
        s.brows = (m.browRaise - b.browRaise) / (0.075 * k)
        s.au1 = (m.innerBrowRaise - b.innerBrowRaise) / (0.05 * k)
        s.au4 = (1 - m.browGap / max(b.browGap, 1e-3)) / (0.10 * k)
        // Sadness = lip-corner depressor (AU15) with AU1 or AU4 — corners alone are too often
        // just a resting mouth or talking. A very strong AU15 alone still counts.
        let corners = -(m.cornerLift - b.cornerLift) / (0.055 * k)
        let browSupport = max(s.au1, s.au4)
        s.sad = corners >= 1 && browSupport >= 0.6 ? (corners + browSupport) / 2
            : corners >= 1.8 ? corners * 0.75 : 0
        s.tilt = abs(m.rollDegrees - b.rollDegrees) / (config.tiltDegrees * k)
        return s
    }

    private func classifyExpression(_ m: FaceMetrics, browsReliable: Bool = true) -> ReactionEstimate {
        var s = scores(m)
        if !browsReliable { s.brows = 0; s.sad = 0 }
        var candidates: [(Reaction, Double)] = []
        // Smiling widens the mouth, which lowers the (height / width) open ratio — so a laugh
        // needs only 70% of the open threshold when the smile is clear.
        let laughing = s.smile >= 1 && s.open >= 0.7
        if laughing {
            candidates.append((.laugh, (s.open / 0.7 + s.smile) / 2))
        } else if s.open >= 1 {
            // Open mouth without a smile = surprise. Raised brows are part of surprise.
            candidates.append((.surprised, s.open))
        } else {
            candidates.append((.smile, s.smile))
            candidates.append((.sad, s.smile < 0.5 ? s.sad : 0))
        }
        candidates.append((.eyesClosed, s.eyesClosed))
        candidates.append((.eyebrowsRaised, s.open >= 1 || laughing ? 0 : s.brows))
        candidates.append((.headTilt, s.tilt))

        // Hysteresis: the reaction already shown needs only 80% of its threshold to stay.
        // Closed eyes beat a smile: squeezing the eyes lifts the cheeks and mouth corners.
        let best = candidates
            .map { r, v in (r, r == .eyesClosed && v >= 1 ? v * 1.5 : v) }
            .map { r, v in (r, r == lastExpression ? v * 1.25 : v) }
            .filter { $0.1 >= 1 }
            .max { $0.1 < $1.1 }
        guard let (reaction, score) = best else {
            return ReactionEstimate(reaction: .neutral, confidence: 1, metrics: m)
        }
        // Map score 1 → 0.5 confidence, 2+ → 1.0.
        return ReactionEstimate(reaction: reaction, confidence: min(1, score / 2), metrics: m)
    }
}
