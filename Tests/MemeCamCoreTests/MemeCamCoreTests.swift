import CoreGraphics
import Testing
@testable import MemeCamCore

// MARK: - Synthetic fixtures (aspect space, y up)

private func face(mouthOpen: CGFloat = 0.01, smileWiden: CGFloat = 0, cornerLift: CGFloat = 0,
                  eyeHeight: CGFloat = 0.03, browY: CGFloat = 0.64, roll: CGFloat = 0) -> FaceLandmarks {
    func eye(_ cx: CGFloat) -> [CGPoint] {
        [CGPoint(x: cx - 0.05, y: 0.6), CGPoint(x: cx, y: 0.6 + eyeHeight / 2),
         CGPoint(x: cx + 0.05, y: 0.6), CGPoint(x: cx, y: 0.6 - eyeHeight / 2)]
    }
    let w = 0.09 + smileWiden
    let outer = [CGPoint(x: 0.5 - w, y: 0.4 + cornerLift), CGPoint(x: 0.5, y: 0.43),
                 CGPoint(x: 0.5 + w, y: 0.4 + cornerLift), CGPoint(x: 0.5, y: 0.37 - mouthOpen),
                 CGPoint(x: 0.45, y: 0.42), CGPoint(x: 0.55, y: 0.38 - mouthOpen)]
    let inner = [CGPoint(x: 0.45, y: 0.4 + mouthOpen / 2), CGPoint(x: 0.55, y: 0.4 + mouthOpen / 2),
                 CGPoint(x: 0.55, y: 0.4 - mouthOpen / 2), CGPoint(x: 0.45, y: 0.4 - mouthOpen / 2)]
    var lm = FaceLandmarks(
        boundingBox: CGRect(x: 0.3, y: 0.25, width: 0.4, height: 0.5),
        leftEye: eye(0.4), rightEye: eye(0.6),
        leftBrow: [CGPoint(x: 0.37, y: browY), CGPoint(x: 0.43, y: browY)],
        rightBrow: [CGPoint(x: 0.57, y: browY), CGPoint(x: 0.63, y: browY)],
        outerLips: outer, innerLips: inner)
    if roll != 0 {
        let c = cos(roll), s = sin(roll), o = CGPoint(x: 0.5, y: 0.5)
        func r(_ p: [CGPoint]) -> [CGPoint] {
            p.map { CGPoint(x: o.x + ($0.x - o.x) * c - ($0.y - o.y) * s, y: o.y + ($0.x - o.x) * s + ($0.y - o.y) * c) }
        }
        lm.leftEye = r(lm.leftEye); lm.rightEye = r(lm.rightEye)
        lm.leftBrow = r(lm.leftBrow); lm.rightBrow = r(lm.rightBrow)
        lm.outerLips = r(lm.outerLips); lm.innerLips = r(lm.innerLips)
    }
    return lm
}

/// Hand with wrist at origin offset; `up` controls which fingers point up.
private func hand(at o: CGPoint, extended: [Bool], thumb: CGFloat? = nil, scale: CGFloat = 1.5) -> HandPose {
    let pose = unscaledHand(at: .zero, extended: extended, thumb: thumb)
    // Real palms are ~0.3–0.45 of face height; scale the unit-size fixture accordingly.
    return HandPose(joints: pose.joints.mapValues { CGPoint(x: o.x + $0.x * scale, y: o.y + $0.y * scale) },
                    confidence: pose.confidence)
}

private func unscaledHand(at o: CGPoint, extended: [Bool], thumb: CGFloat? = nil) -> HandPose {
    var j: [HandJoint: CGPoint] = [.wrist: o]
    let xs: [CGFloat] = [-0.03, -0.01, 0.01, 0.03]
    let names: [(HandJoint, HandJoint, HandJoint, HandJoint)] = [
        (.indexMCP, .indexPIP, .indexDIP, .indexTip), (.middleMCP, .middlePIP, .middleDIP, .middleTip),
        (.ringMCP, .ringPIP, .ringDIP, .ringTip), (.littleMCP, .littlePIP, .littleDIP, .littleTip)]
    for (i, n) in names.enumerated() {
        let x = o.x + xs[i]
        j[n.0] = CGPoint(x: x, y: o.y + 0.1)
        j[n.1] = CGPoint(x: x, y: o.y + 0.14)
        j[n.2] = CGPoint(x: x, y: extended[i] ? o.y + 0.17 : o.y + 0.12)
        j[n.3] = CGPoint(x: x, y: extended[i] ? o.y + 0.2 : o.y + 0.1)
    }
    // Thumb: nil => tucked against the index MCP, otherwise vertical direction (+1 up / -1 down).
    let base = CGPoint(x: o.x - 0.05, y: o.y + 0.05)
    j[.thumbCMC] = CGPoint(x: o.x - 0.03, y: o.y + 0.02)
    j[.thumbMP] = base
    if let d = thumb {
        j[.thumbIP] = CGPoint(x: base.x - 0.01, y: base.y + 0.07 * d)
        j[.thumbTip] = CGPoint(x: base.x - 0.015, y: base.y + 0.14 * d)
    } else {
        j[.thumbIP] = CGPoint(x: o.x - 0.04, y: o.y + 0.08)
        j[.thumbTip] = CGPoint(x: o.x - 0.025, y: o.y + 0.1)
    }
    return HandPose(joints: j, confidence: 0.9)
}

private func classify(_ lm: FaceLandmarks?, hands: [HandPose] = [], _ c: inout ReactionClassifier) -> Reaction {
    c.classify(FrameObservation(timestamp: 0, face: lm, hands: hands)).reaction
}

// MARK: - Tests

@Test func metricsAreRotationInvariant() throws {
    let a = try #require(FaceMetrics(face()))
    let b = try #require(FaceMetrics(face(roll: 0.4)))
    #expect(abs(a.mouthWidth - b.mouthWidth) < 1e-6)
    #expect(abs(a.browRaise - b.browRaise) < 1e-6)
    #expect(abs(b.rollDegrees - 0.4 * 180 / .pi) < 1e-3)
}

@Test func expressions() throws {
    var c = ReactionClassifier()
    c.calibrate(to: try #require(FaceMetrics(face())))
    #expect(classify(face(), &c) == .neutral)
    #expect(classify(face(mouthOpen: 0.07), &c) == .surprised)
    #expect(classify(face(mouthOpen: 0.07, smileWiden: 0.03), &c) == .laugh)
    #expect(classify(face(smileWiden: 0.03), &c) == .smile)
    #expect(classify(face(eyeHeight: 0.005), &c) == .eyesClosed)
    #expect(classify(face(browY: 0.66), &c) == .eyebrowsRaised)
    #expect(classify(face(cornerLift: -0.015), &c) == .sad)
    #expect(classify(face(roll: 0.45), &c) == .headTilt)
}

@Test func singleHandGestures() {
    var c = ReactionClassifier()
    let o = CGPoint(x: 1.2, y: 0.2) // far from the face
    #expect(classify(nil, hands: [hand(at: o, extended: [false, false, false, false], thumb: 1)], &c) == .thumbsUp)
    #expect(classify(nil, hands: [hand(at: o, extended: [false, false, false, false], thumb: -1)], &c) == .thumbsDown)
    #expect(classify(nil, hands: [hand(at: o, extended: [true, true, false, false])], &c) == .peace)
    #expect(classify(nil, hands: [hand(at: o, extended: [true, false, false, false])], &c) == .pointing)
    #expect(classify(nil, hands: [hand(at: o, extended: [true, true, true, true])], &c) == .openPalm)
    #expect(classify(nil, hands: [hand(at: o, extended: [false, false, false, false])], &c) == .fist)
}

@Test func faceAndTwoHandGestures() {
    var c = ReactionClassifier()
    let open = [true, true, true, true]
    #expect(classify(face(), hands: [hand(at: CGPoint(x: 0.1, y: 0.7), extended: open),
                                     hand(at: CGPoint(x: 0.9, y: 0.7), extended: open)], &c) == .handsUp)
    #expect(classify(face(), hands: [hand(at: CGPoint(x: 0.5, y: 0.45), extended: open)], &c) == .facepalm)
    #expect(classify(face(), hands: [hand(at: CGPoint(x: 0.5, y: 0.0), extended: [true, false, false, false])], &c) == .thinking)
    #expect(classify(nil, &c) == .noFace)
}

/// Feeds `r` at 30 FPS from `t0` to `t1`; returns every change the stabilizer emitted.
private func feed(_ s: inout ReactionStabilizer, _ r: Reaction, _ t0: Double, _ t1: Double,
                  confidence: Double = 1) -> [Reaction] {
    var out: [Reaction] = []
    var t = t0
    while t < t1 {
        if let c = s.update(r, confidence: confidence, at: t) { out.append(c) }
        t += 1.0 / 30
    }
    return out
}

@Test func stabilizerDebounces() {
    var s = ReactionStabilizer(minHold: 1)
    #expect(feed(&s, .smile, 0, 0.5) == [.smile])
    #expect(feed(&s, .surprised, 0.5, 0.9).isEmpty)          // still within minHold
    #expect(feed(&s, .surprised, 0.9, 1.6) == [.surprised])
    #expect(feed(&s, .eyesClosed, 2.6, 2.8).isEmpty)          // a blink
    #expect(feed(&s, .surprised, 2.8, 3.5).isEmpty)
    #expect(s.current == .surprised)
}

@Test func stabilizerIgnoresSingleFrameGlitches() {
    var s = ReactionStabilizer(minHold: 0.2)
    _ = feed(&s, .thumbsUp, 0, 1)
    // Every 4th frame misclassified as fist: the vote keeps thumbs up.
    var t = 1.0, changes: [Reaction] = []
    for i in 0..<60 {
        if let c = s.update(i % 4 == 0 ? .fist : .thumbsUp, at: t) { changes.append(c) }
        t += 1.0 / 30
    }
    #expect(changes.isEmpty)
    #expect(s.current == .thumbsUp)
}

@Test func stabilizerAbstainsOnZeroConfidence() {
    var s = ReactionStabilizer(minHold: 0.2)
    _ = feed(&s, .smile, 0, 1)
    #expect(feed(&s, .neutral, 1, 2, confidence: 0).isEmpty)
    #expect(s.current == .smile)
}

@Test func oneEuroSmoothsJitterButFollowsSteps() {
    var f = OneEuroFilter()
    var t = 0.0, out = 0.0
    for i in 0..<60 { out = f.filter(i % 2 == 0 ? 0.49 : 0.51, at: t); t += 1.0 / 30 }
    #expect(abs(out - 0.5) < 0.006)                            // jitter attenuated
    for _ in 0..<9 { out = f.filter(1.0, at: t); t += 1.0 / 30 } // 0.3 s after a step
    #expect(out > 0.9)
}

@Test func autoCalibrationUsesMedianOfCalmFrames() throws {
    var c = ReactionClassifier()
    var t = 0.0
    let calm = face(smileWiden: 0.012) // this user's resting mouth is a bit wider than typical
    for _ in 0..<20 { _ = c.classify(FrameObservation(timestamp: t, face: calm, hands: [])); t += 1.0 / 30 }
    #expect(c.calibration == .automatic)
    // Their resting face must read as neutral, not smile.
    #expect(c.classify(FrameObservation(timestamp: t, face: calm, hands: [])).reaction == .neutral)
}

@Test func headTurnAbstains() {
    var c = ReactionClassifier()
    var lm = face(mouthOpen: 0.07)
    lm.yaw = 0.8
    #expect(c.classify(FrameObservation(timestamp: 0, face: lm, hands: [])).confidence == 0)
}

@Test func sidewaysFistIsNotThumbsUp() {
    var c = ReactionClassifier()
    // Thumb "up" relative to its base but index knuckles higher than the thumb tip.
    var h = hand(at: CGPoint(x: 1.2, y: 0.2), extended: [false, false, false, false], thumb: 1)
    h.joints[.indexPIP] = CGPoint(x: 1.2, y: 0.2 + 0.5)
    #expect(classify(nil, hands: [h], &c) == .fist)
}
