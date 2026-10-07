import CoreGraphics
import Foundation

/// A hand plus everything the classifier knows about its shape (shared by the rules and the features).
struct SeenHand: Sendable {
    let pose: HandPose
    let shape: HandShape
    let model: HandGestureModel.Prediction?
    /// The model's probabilities in `HandGestureModel.Label.allCases` order (features), nil without a model.
    let probabilities: [Float]?

    init(pose: HandPose, shape: HandShape, model: HandGestureModel.Prediction?, labels: [HandGestureModel.Label]) {
        self.pose = pose
        self.shape = shape
        self.model = model
        probabilities = model.map { m in
            HandGestureModel.Label.allCases.map { label in
                labels.firstIndex(of: label).flatMap { $0 < m.probabilities.count ? Float(m.probabilities[$0]) : nil } ?? 0
            }
        }
    }

    /// Confident model label (p ≥ 0.8), if any.
    var label: HandGestureModel.Label? { model.flatMap { $0.probability >= 0.8 ? $0.label : nil } }
    var isOpen: Bool { label.map { $0 == .openPalm } ?? (shape.extendedCount >= 4) }
    var isHeartHalf: Bool { model != nil ? label == .heartHalf : shape.looksLikeHalfHeart }

    /// Single-hand gesture: the learned model decides when it is confident (p ≥ 0.8);
    /// otherwise the geometric rules decide, exactly as without a model.
    var gesture: HandGesture? {
        if let model, model.probability >= 0.8 { return model.label.gesture }
        return shape.gesture(for: pose)
    }
}

/// Per-frame feature vector for the personal model ("Teach MemeCam"): 36 floats, see the field list.
///
/// Face block (0–9): the expression signals relative to the user's neutral baseline, scaled so 1 ≈ the
/// rule threshold. No yaw/pitch: measured, head pose is session-specific and made the model worse.
/// Hand block (10–35): shape, HaGRID probabilities and position relative to the face. Missing parts are 0.
public enum ReactionFeatures {
    /// Bump when the layout changes: stored models are rebuilt from the saved teach sessions.
    public static let version = 1
    public static let count = 36
    public static let handPresentIndex = 10
    public static let rollIndex = 6
    static let absRollIndex = 7

    /// nil when there is neither a face nor a usable hand.
    static func make(metrics: FaceMetrics?, baseline b: FaceMetrics, faceBox: CGRect?, hands: [SeenHand]) -> [Float]? {
        guard metrics != nil || !hands.isEmpty else { return nil }
        var x = [Float](repeating: 0, count: count)
        if let m = metrics {
            x[0] = 1
            x[1] = Float((m.mouthOpen - b.mouthOpen) / 0.25)
            x[2] = Float((m.mouthWidth / max(b.mouthWidth, 1e-3) - 1) / 0.14)
            x[3] = Float((m.cornerLift - b.cornerLift) / 0.06)
            x[4] = Float((1 - m.eyeOpen / max(b.eyeOpen, 1e-3)) / 0.30)
            x[5] = Float((m.browRaise - b.browRaise) / 0.075)
            let roll = (m.rollDegrees - b.rollDegrees) / 22
            x[6] = Float(roll)
            x[7] = Float(abs(roll))
            x[8] = Float((m.innerBrowRaise - b.innerBrowRaise) / 0.05)
            x[9] = Float((1 - m.browGap / max(b.browGap, 1e-3)) / 0.10)
        }
        guard let primary = hands.max(by: { $0.pose.confidence < $1.pose.confidence }) else { return x }
        x[10] = 1
        x[11] = hands.count >= 2 ? 1 : 0
        if let probs = primary.probabilities {
            for (i, p) in probs.prefix(8).enumerated() { x[12 + i] = p }
            x[20] = 1
        }
        let shape = primary.shape
        x[21] = Float(shape.extendedCount) / 4
        x[22] = shape.thumbExtended ? 1 : 0
        x[23] = Float(shape.thumbVertical)
        for i in 0..<min(4, shape.fingerReach.count) { x[24 + i] = Float(min(shape.fingerReach[i], 2)) }
        if let face = faceBox, face.width > 1e-6, face.height > 1e-6 {
            let hb = primary.pose.boundingBox
            let c = primary.pose.center
            x[28] = 1
            x[29] = Float(abs(c.x - face.midX) / face.width)
            x[30] = Float((c.y - face.minY) / face.height)
            x[31] = Float((hb.maxY - face.minY) / face.height)
            let overlap = hb.intersection(face)
            x[32] = overlap.isNull ? 0 : Float(overlap.width * overlap.height / (face.width * face.height))
            x[33] = Float(shape.palmSize / face.height)
        }
        if hands.count >= 2 {
            let a = hands[0], c = hands[1]
            let unit = max((a.shape.palmSize + c.shape.palmSize) / 2, 1e-4)
            x[34] = Float(min(a.pose.center.distance(to: c.pose.center) / unit, 5) / 5)
            let top = faceBox?.maxY ?? 0.65
            x[35] = Float(((a.pose.center.y + c.pose.center.y) / 2 - top) / 0.2)
        }
        return x
    }
}
