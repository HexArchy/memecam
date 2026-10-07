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
    /// Learned hand-shape classifier; rules are used when nil.
    public var handModel: HandGestureModel?
    /// What the user taught ("Teach MemeCam"): overrides the rules for its enabled reactions when sure.
    public var personal: PersonalModel?
    /// Keep `lastFeatures` up to date even without a personal model (teaching replays).
    public var recordsFeatures = false
    /// The last frame's `ReactionFeatures` (when `personal` or `recordsFeatures` is set).
    public private(set) var lastFeatures: [Float]?
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
    private var lastHands: [HandPose] = []
    private var lastHandsTime: TimeInterval = -.infinity

    public init(config: Config = Config(), handModel: HandGestureModel? = nil) {
        self.config = config
        self.handModel = handModel
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

        // Vision drops hands that overlap the face (thinking, facepalm) for several frames at a
        // time — recorded: a chin hand was seen in only 20% of frames. Hold the last hands briefly.
        var hands = frame.hands
        if hands.isEmpty, frame.timestamp - lastHandsTime < 0.4 {
            hands = lastHands
        } else if !hands.isEmpty {
            lastHands = hands
            lastHandsTime = frame.timestamp
        }
        let seen = config.enableGestures ? seenHands(hands, faceBox: faceBox) : []
        let wantsFeatures = personal != nil || recordsFeatures
        lastFeatures = nil

        if config.enableGestures, let g = classifyGestures(seen, faceBox: faceBox) {
            let rules = ReactionEstimate(reaction: g.0, confidence: g.1, metrics: metrics)
            return wantsFeatures ? personalized(rules, metrics: metrics, faceBox: faceBox, seen: seen) : rules
        }
        guard let face = frame.face, let metrics, let raw else {
            let rules = ReactionEstimate(reaction: hands.isEmpty ? .noFace : .neutral, confidence: 1)
            return wantsFeatures ? personalized(rules, metrics: nil, faceBox: faceBox, seen: seen) : rules
        }
        guard config.enableExpressions else {
            return ReactionEstimate(reaction: .neutral, confidence: 1, metrics: metrics)
        }

        let headTurned = abs(face.yaw) > config.maxHeadTurn || abs(face.pitch) > config.maxHeadTurn
        if collecting, hands.isEmpty, !headTurned {
            collectCalibrationSample(raw)
        }
        if headTurned {
            // Turned away: profile landmarks distort mouth/eye ratios. Abstain (a taught hand pose may
            // still decide).
            let rules = ReactionEstimate(reaction: lastExpression, confidence: 0, metrics: metrics)
            return wantsFeatures && !seen.isEmpty ? personalized(rules, metrics: metrics, faceBox: faceBox, seen: seen)
                                                  : rules
        }

        let browsReliable = abs(face.yaw) <= config.maxHeadTurnForBrows && abs(face.pitch) <= config.maxHeadTurnForBrows
        let rules = classifyExpression(metrics, browsReliable: browsReliable)
        let estimate = wantsFeatures ? personalized(rules, metrics: metrics, faceBox: faceBox, seen: seen) : rules
        // Hysteresis follows what is shown; a taught gesture doesn't count as the shown expression.
        lastExpression = estimate.reaction.isGesture ? rules.reaction : estimate.reaction
        if estimate.reaction == .neutral, hands.isEmpty, !collecting {
            // Track slow drift (lighting, posture) without chasing expressions.
            let roll = baseline.rollDegrees
            baseline = baseline.blended(toward: metrics, alpha: calibration == .manual ? 0.002 : 0.01)
            baseline.rollDegrees = roll
        }
        return estimate
    }

    /// The personal model's answer when it is sure and the reaction is enabled for it, else `rules`.
    private mutating func personalized(_ rules: ReactionEstimate, metrics: FaceMetrics?, faceBox: CGRect?,
                                       seen: [SeenHand]) -> ReactionEstimate {
        guard rules.reaction != .noFace,
              let x = ReactionFeatures.make(metrics: metrics, baseline: baseline, faceBox: faceBox, hands: seen)
        else { return rules }
        lastFeatures = x
        guard let personal, let p = personal.predict(x), personal.enabled.contains(p.reaction) else { return rules }
        return ReactionEstimate(reaction: p.reaction, confidence: Double(p.votes) / Double(personal.k), metrics: metrics)
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

    private func seenHands(_ hands: [HandPose], faceBox: CGRect?) -> [SeenHand] {
        // Ignore tiny "hands" (background clutter, far-away people) and low-confidence ones.
        // Recorded: hands angled toward the lens project palms as short as 0.07 face heights
        // (chin rest). Confidence and joint-count filters already reject clutter.
        let minPalm = faceBox.map { Double($0.height) * 0.05 } ?? 0.03
        return hands.filter { $0.confidence >= 0.5 }.compactMap { raw -> SeenHand? in
            let h = raw.withEstimatedWrist()
            guard let shape = HandShape(h), shape.palmSize >= minPalm else { return nil }
            // The model was trained on real wrists; with a guessed wrist its features are off and
            // it answers confidently wrong (recorded on peace signs), so leave those to the rules.
            let wristSeen = raw[.wrist] != nil
            return SeenHand(pose: h, shape: shape, model: wristSeen ? handModel?.predict(h) : nil,
                            labels: handModel?.labels ?? [])
        }
    }

    private func classifyGestures(_ seen: [SeenHand], faceBox: CGRect?) -> (Reaction, Double)? {
        guard !seen.isEmpty else { return nil }

        if seen.count >= 2 {
            let a = seen[0], b = seen[1]
            let unit = (a.shape.palmSize + b.shape.palmSize) / 2
            let close = a.pose.center.distance(to: b.pose.center) < unit * 2.2
            if a.isHeartHalf && b.isHeartHalf && close { return (.heart, 0.95) }
            if handModel == nil, let i1 = a.pose[.indexTip], let i2 = b.pose[.indexTip],
               let t1 = a.pose[.thumbTip], let t2 = b.pose[.thumbTip],
               i1.distance(to: i2) < unit * 0.6, t1.distance(to: t2) < unit * 0.6, (i1.y + i2.y) > (t1.y + t2.y) {
                return (.heart, 0.9)
            }
            let topY = faceBox.map { $0.maxY - $0.height * 0.2 } ?? 0.65
            if a.isOpen, b.isOpen, a.pose.center.y > topY, b.pose.center.y > topY {
                return (.handsUp, 0.9)
            }
        }

        // Vision often merges a two-hand heart into a single "hand".
        if let h = seen.first(where: \.isHeartHalf), faceBox.map({ h.pose.center.y < $0.midY }) ?? true {
            return (.heart, 0.85)
        }

        if let face = faceBox {
            for h in seen {
                let hb = h.pose.boundingBox
                let overlap = hb.intersection(face)
                let coverage = overlap.isNull ? 0 : (overlap.width * overlap.height) / max(face.width * face.height, 1e-6)
                // Open-ish hand over the upper face (eyes/forehead) => facepalm. A fist held in
                // front of the face is not a facepalm.
                let openish = h.label.map { $0 == .openPalm || $0 == .none } ?? (h.shape.extendedCount >= 2)
                // Recorded facepalm hands: centred (|dx| ≈ 0.08), centre at ≈0.40 face heights.
                let fdx = abs(h.pose.center.x - face.midX) / face.width
                if openish, coverage > 0.06, fdx < 0.35,
                   h.pose.center.y > face.minY + face.height * 0.2 {
                    return (.facepalm, min(1, 0.5 + Double(coverage) * 2))
                }
                // Hand resting under the chin => thinking (fist, finger or flat hand). Measured:
                // thinking hands sit centred under the face (|dx| ≤ 0.25 face widths, centre ≈ chin,
                // top ≈ 0.3 h); a fist shown beside the face sits to the side (|dx| ≈ 0.4), higher.
                let dx = abs(h.pose.center.x - face.midX) / face.width
                let dy = (h.pose.center.y - face.minY) / face.height
                let top = (hb.maxY - face.minY) / face.height
                if !h.isOpen, dx < 0.3, dy > -0.6, dy < 0.2, top < 0.55 {
                    return (.thinking, 0.8)
                }
                // One open palm raised to the top of the head => hands up (Vision frequently
                // reports only one of two raised hands).
                if h.isOpen, h.pose.center.y > face.minY + face.height * 0.9, coverage < 0.15 {
                    return (.handsUp, 0.75)
                }
            }
        }

        // Single-hand gesture from the most confident hand.
        let best = seen
            .compactMap { h in h.gesture.map { ($0, h.model?.probability ?? h.pose.confidence) } }
            .max { $0.1 < $1.1 }
        return best.map { ($0.0.reaction, max($0.1, 0.5)) }
    }

    // MARK: - Expressions

    /// Scores are normalised: 1.0 == "just at threshold".
    public struct ExpressionScores: Sendable {
        public var open = 0.0, smile = 0.0, eyesClosed = 0.0, brows = 0.0, sad = 0.0, tilt = 0.0
        /// FACS AU1 (inner brow raiser) and AU4 (brow lowerer) intensities, 1 = threshold.
        public var au1 = 0.0, au4 = 0.0
        /// AU15 lip-corner depressor alone (1 = threshold).
        public var corners = 0.0
    }

    public func scores(_ m: FaceMetrics) -> ExpressionScores {
        let b = baseline
        let k = 1 / max(config.sensitivity, 0.1) // >1 means stricter thresholds
        let widthRatio = m.mouthWidth / max(b.mouthWidth, 1e-3)
        let eyeRatio = m.eyeOpen / max(b.eyeOpen, 1e-3)
        var s = ExpressionScores()
        s.open = (m.mouthOpen - b.mouthOpen) / (0.25 * k)
        s.smile = max((widthRatio - 1) / (0.14 * k), (m.cornerLift - b.cornerLift) / (0.06 * k))
        s.eyesClosed = (1 - eyeRatio) / (0.30 * min(k, 1.4))
        s.brows = (m.browRaise - b.browRaise) / (0.075 * k)
        s.au1 = (m.innerBrowRaise - b.innerBrowRaise) / (0.05 * k)
        s.au4 = (1 - m.browGap / max(b.browGap, 1e-3)) / (0.10 * k)
        // Sadness = lip-corner depressor (AU15) with AU1 or AU4 — corners alone are too often
        // just a resting mouth or talking. A very strong AU15 alone still counts.
        let corners = -(m.cornerLift - b.cornerLift) / (0.055 * k)
        s.corners = corners
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
        // Surprise (FACS AU1+AU2+AU26): raised brows with a dropped jaw — the mouth needn't be
        // wide open, and a dropped jaw widens the mouth enough to look like a smile, so the
        // brows decide. Recorded: surprise brows ≈1.3, open ≈0.6; laugh brows ≈−0.1.
        let surprisedByBrows = s.brows >= 0.9 && s.open >= 0.4
        let laughing = !surprisedByBrows && s.smile >= 1 && s.open >= 0.7
        if surprisedByBrows {
            candidates.append((.surprised, max(s.open / 0.6, s.brows)))
        } else if laughing {
            candidates.append((.laugh, (s.open / 0.7 + s.smile) / 2))
        } else if s.open >= 1 {
            // Open mouth without a smile = surprise. Raised brows are part of surprise.
            candidates.append((.surprised, s.open))
        } else {
            candidates.append((.smile, s.smile))
            candidates.append((.sad, s.smile < 0.5 ? s.sad : 0))
        }
        candidates.append((.eyesClosed, s.eyesClosed))
        candidates.append((.eyebrowsRaised, s.open >= 1 || laughing || surprisedByBrows ? 0 : s.brows))
        candidates.append((.headTilt, s.tilt))

        // Hysteresis: the reaction already shown needs only 80% of its threshold to stay.
        // Closed eyes beat a smile: squeezing the eyes lifts the cheeks and mouth corners.
        let best = candidates
            .map { r, v in (r, r == .eyesClosed && v >= 1 && s.smile < 1 ? v * 1.5 : v) }
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
