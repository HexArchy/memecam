import Foundation

/// MediaPipe Face Blendshapes V2 output order (52 ARKit-style coefficients).
public enum Blendshape: Int, CaseIterable, Sendable {
    case neutral, browDownLeft, browDownRight, browInnerUp, browOuterUpLeft, browOuterUpRight, cheekPuff,
         cheekSquintLeft, cheekSquintRight, eyeBlinkLeft, eyeBlinkRight, eyeLookDownLeft, eyeLookDownRight,
         eyeLookInLeft, eyeLookInRight, eyeLookOutLeft, eyeLookOutRight, eyeLookUpLeft, eyeLookUpRight,
         eyeSquintLeft, eyeSquintRight, eyeWideLeft, eyeWideRight, jawForward, jawLeft, jawOpen, jawRight,
         mouthClose, mouthDimpleLeft, mouthDimpleRight, mouthFrownLeft, mouthFrownRight, mouthFunnel,
         mouthLeft, mouthLowerDownLeft, mouthLowerDownRight, mouthPressLeft, mouthPressRight, mouthPucker,
         mouthRight, mouthRollLower, mouthRollUpper, mouthShrugLower, mouthShrugUpper, mouthSmileLeft,
         mouthSmileRight, mouthStretchLeft, mouthStretchRight, mouthUpperUpLeft, mouthUpperUpRight,
         noseSneerLeft, noseSneerRight
}

/// HSEmotion 8-class (AffectNet) output order.
public enum Emotion: Int, CaseIterable, Sendable {
    case anger, contempt, disgust, fear, happiness, neutral, sadness, surprise
}

/// Votes of the learned face models on the classifier's expression components.
///
/// The rules turn Vision landmarks into components (`ExpressionScores`: mouth open, smile, eyes closed,
/// brows up, sad, tilt; 1.0 = threshold). The blendshape and emotion models are turned into the same
/// components, and each fused component is a weighted mean over the sources that saw this frame. The
/// rules' decision logic (laugh = smile + open, surprise = brows + open, hysteresis) then runs unchanged
/// on the fused components, so without the models the classifier behaves exactly as before.
///
/// Weights and scales are set from what each source is good at (to be re-fitted on labelled recordings):
/// - Blendshapes: trained on 3D captures, robust to pose and light; strongest for jaw, blink, smile, brows.
/// - Emotions (AffectNet): whole-face appearance; the only source that sees a subtle sad face, and a
///   decent second opinion on smiles. It has no notion of closed eyes or raised brows, so no vote there.
/// - Rules: tuned on the user's own recordings; keep a real say everywhere and own head tilt.
public enum FaceSignalFusion {
    struct Weights { var rules: Double, blendshapes: Double, emotions: Double }

    static let open = Weights(rules: 0.4, blendshapes: 0.6, emotions: 0)
    static let smile = Weights(rules: 0.35, blendshapes: 0.45, emotions: 0.2)
    static let eyesClosed = Weights(rules: 0.35, blendshapes: 0.65, emotions: 0)
    static let brows = Weights(rules: 0.45, blendshapes: 0.55, emotions: 0)
    // Measured on a public-domain sad face: HSEmotion said Sadness 0.77, while mouthFrown and browInnerUp
    // stayed near 0, so the emotion model carries "sad".
    static let sad = Weights(rules: 0.15, blendshapes: 0.25, emotions: 0.6)

    /// Components from blendshapes, relative to the user's neutral blendshapes (1.0 = threshold).
    /// Scales: the change from a relaxed face that a clear, deliberate expression reaches.
    static func components(blendshapes b: [Float], baseline n: [Float]?) -> ReactionClassifier.ExpressionScores? {
        guard b.count == Blendshape.allCases.count else { return nil }
        func d(_ s: Blendshape...) -> Double {
            let v = s.map { Double(b[$0.rawValue]) }.reduce(0, +) / Double(s.count)
            let base = n.map { nb in s.map { Double(nb[$0.rawValue]) }.reduce(0, +) / Double(s.count) } ?? 0
            return max(0, v - base)
        }
        var c = ReactionClassifier.ExpressionScores()
        c.open = d(.jawOpen) / 0.30
        c.smile = d(.mouthSmileLeft, .mouthSmileRight) / 0.30
        c.eyesClosed = d(.eyeBlinkLeft, .eyeBlinkRight) / 0.45
        c.brows = (d(.browInnerUp) + d(.browOuterUpLeft, .browOuterUpRight)) / 2 / 0.25
        // Sad: lip-corner depressor first, then the inner-brow raise and a pressed / pushed-up lower lip.
        let sad = 0.5 * d(.mouthFrownLeft, .mouthFrownRight) / 0.12 + 0.3 * d(.browInnerUp) / 0.20
            + 0.2 * max(d(.mouthPressLeft, .mouthPressRight), d(.mouthShrugLower)) / 0.20
        c.sad = c.smile < 0.5 ? sad : 0
        return c
    }

    /// Components from expression probabilities (absolute: the model already compares against neutral).
    static func components(emotions e: [Float]) -> ReactionClassifier.ExpressionScores? {
        guard e.count == Emotion.allCases.count else { return nil }
        var c = ReactionClassifier.ExpressionScores()
        c.smile = Double(e[Emotion.happiness.rawValue]) / 0.5
        c.sad = Double(e[Emotion.sadness.rawValue]) / 0.4
        return c
    }

    /// Probability of a neutral face (nil without the emotion model): damps all components a little, so
    /// talking and resting faces trigger less.
    static func neutralDamping(emotions e: [Float]?) -> Double {
        guard let e, e.count == Emotion.allCases.count else { return 1 }
        let pn = Double(e[Emotion.neutral.rawValue])
        return 1 - 0.3 * min(1, max(0, (pn - 0.5) / 0.5))
    }

    /// Fuses `rules` with whatever learned signals this frame has. Head tilt and the FACS helper scores
    /// stay the rules' own.
    static func fuse(_ rules: ReactionClassifier.ExpressionScores, signals: FaceSignals?,
                     blendshapeBaseline: [Float]?, browsReliable: Bool) -> ReactionClassifier.ExpressionScores {
        guard let signals else { return rules }
        let bs = signals.blendshapes.flatMap { components(blendshapes: $0, baseline: blendshapeBaseline) }
        let em = signals.emotions.flatMap { components(emotions: $0) }
        guard bs != nil || em != nil else { return rules }
        func mix(_ w: Weights, _ key: KeyPath<ReactionClassifier.ExpressionScores, Double>) -> Double {
            var sum = w.rules * rules[keyPath: key], total = w.rules
            if let bs, w.blendshapes > 0 { sum += w.blendshapes * bs[keyPath: key]; total += w.blendshapes }
            if let em, w.emotions > 0 { sum += w.emotions * em[keyPath: key]; total += w.emotions }
            return sum / total
        }
        let damp = neutralDamping(emotions: signals.emotions)
        var out = rules
        out.open = mix(open, \.open) * damp
        out.smile = mix(smile, \.smile) * damp
        out.eyesClosed = mix(eyesClosed, \.eyesClosed) // blinking isn't an expression: no damping
        out.brows = browsReliable ? mix(brows, \.brows) * damp : 0
        out.sad = browsReliable || em != nil ? mix(sad, \.sad) * damp : 0
        return out
    }
}
