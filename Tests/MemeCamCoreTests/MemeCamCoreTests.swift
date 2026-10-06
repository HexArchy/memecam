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
private func hand(at o: CGPoint, extended: [Bool], thumb: CGFloat? = nil) -> HandPose {
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
        j[.thumbIP] = CGPoint(x: base.x - 0.01, y: base.y + 0.05 * d)
        j[.thumbTip] = CGPoint(x: base.x - 0.015, y: base.y + 0.1 * d)
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

@Test func stabilizerDebounces() {
    var s = ReactionStabilizer(minHold: 1)
    #expect(s.update(.smile, at: 0) == nil)
    #expect(s.update(.smile, at: 0.3) == .smile)
    #expect(s.update(.surprised, at: 0.4) == nil)      // still within minHold
    #expect(s.update(.surprised, at: 1.4) == .surprised)
    #expect(s.update(.eyesClosed, at: 2.5) == nil)     // blink
    #expect(s.update(.surprised, at: 2.6) == nil)
    #expect(s.current == .surprised)
}
