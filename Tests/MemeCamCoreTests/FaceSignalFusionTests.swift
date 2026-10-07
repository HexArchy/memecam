import CoreGraphics
import Foundation
import Testing
@testable import MemeCamCore

private func emotions(_ e: Emotion, _ p: Float) -> [Float] {
    var v = [Float](repeating: (1 - p) / 7, count: Emotion.allCases.count)
    v[e.rawValue] = p
    return v
}

private func blendshapes(_ values: [Blendshape: Float]) -> [Float] {
    var v = [Float](repeating: 0.02, count: Blendshape.allCases.count)
    for (k, x) in values { v[k.rawValue] = x }
    return v
}

/// Calibrates on a neutral face (with neutral signals), then classifies `face` + `signals` for 1 s.
private func reaction(_ face: FaceLandmarks, _ signals: FaceSignals?) -> Reaction {
    var c = ReactionClassifier()
    let calm = FaceSignals(blendshapes: blendshapes([:]), emotions: emotions(.neutral, 0.9))
    var t = 0.0
    for _ in 0..<20 { _ = c.classify(FrameObservation(timestamp: t, face: faceFixture(), hands: [], signals: calm)); t += 1 / 15 }
    var last = Reaction.neutral
    for _ in 0..<15 { last = c.classify(FrameObservation(timestamp: t, face: face, hands: [], signals: signals)).reaction; t += 1 / 15 }
    return last
}

private func faceFixture(cornerLift: CGFloat = 0, smileWiden: CGFloat = 0) -> FaceLandmarks {
    face(smileWiden: smileWiden, cornerLift: cornerLift)
}

@Test func emotionModelCatchesASadFaceTheLandmarksMiss() {
    let subtle = faceFixture(cornerLift: -0.006)
    #expect(reaction(subtle, nil) == .neutral)
    #expect(reaction(subtle, FaceSignals(blendshapes: blendshapes([.mouthPressLeft: 0.2, .mouthPressRight: 0.2]),
                                         emotions: emotions(.sadness, 0.83))) == .sad)
}

@Test func confidentNeutralModelsKeepAWeakSmileNeutral() {
    // Rules alone see a smile just over threshold; both models say it's a resting face.
    let slight = faceFixture(smileWiden: 0.016)
    #expect(reaction(slight, nil) == .smile)
    #expect(reaction(slight, FaceSignals(blendshapes: blendshapes([:]), emotions: emotions(.neutral, 0.95))) == .neutral)
}

@Test func modelsConfirmAClearSmile() {
    let smile = faceFixture(cornerLift: 0.02, smileWiden: 0.03)
    let signals = FaceSignals(blendshapes: blendshapes([.mouthSmileLeft: 0.65, .mouthSmileRight: 0.65]),
                              emotions: emotions(.happiness, 0.93))
    #expect(reaction(smile, signals) == .smile)
}

@Test func fusionWithoutSignalsIsTheRules() {
    var s = ReactionClassifier.ExpressionScores()
    s.smile = 1.3; s.open = 0.2; s.sad = 0.4
    let f = FaceSignalFusion.fuse(s, signals: nil, blendshapeBaseline: nil, browsReliable: true)
    #expect(f.smile == s.smile && f.open == s.open && f.sad == s.sad)
    // Wrong-sized outputs are ignored rather than misread.
    let g = FaceSignalFusion.fuse(s, signals: FaceSignals(blendshapes: [0.1], emotions: [0.5]),
                                  blendshapeBaseline: nil, browsReliable: true)
    #expect(g.smile == s.smile)
}
