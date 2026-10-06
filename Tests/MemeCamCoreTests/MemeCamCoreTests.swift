import CoreGraphics
import Foundation
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
    #expect(classify(face(browY: 0.67), &c) == .eyebrowsRaised)
    #expect(classify(face(cornerLift: -0.025), &c) == .sad)   // strong AU15 alone
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

/// Simulates turning the head by `yaw`: horizontal distances shrink by cos(yaw).
private func turned(_ lm: FaceLandmarks, yaw: Double) -> FaceLandmarks {
    let k = CGFloat(cos(yaw)), cx: CGFloat = 0.5
    func squash(_ p: [CGPoint]) -> [CGPoint] { p.map { CGPoint(x: cx + ($0.x - cx) * k, y: $0.y) } }
    var out = lm
    out.leftEye = squash(lm.leftEye); out.rightEye = squash(lm.rightEye)
    out.leftBrow = squash(lm.leftBrow); out.rightBrow = squash(lm.rightBrow)
    out.outerLips = squash(lm.outerLips); out.innerLips = squash(lm.innerLips)
    out.yaw = yaw
    return out
}

@Test func yawForeshorteningIsCorrected() throws {
    let straight = try #require(FaceMetrics(face()))
    let side = try #require(FaceMetrics(turned(face(), yaw: 0.4)))
    #expect(abs(side.browRaise - straight.browRaise) < 1e-6)
    #expect(abs(side.mouthOpen - straight.mouthOpen) < 1e-6)
    // Without correction the ratio would be inflated by 1/cos(0.4) ≈ +8.6%.
}

@Test func turnedNeutralFaceStaysNeutral() throws {
    var c = ReactionClassifier()
    c.calibrate(to: try #require(FaceMetrics(face())))
    #expect(c.classify(FrameObservation(timestamp: 0, face: turned(face(), yaw: 0.4), hands: [])).reaction == .neutral)
}

@Test func sadnessNeedsBrowSupportUnlessStrong() throws {
    var c = ReactionClassifier()
    c.calibrate(to: try #require(FaceMetrics(face())))
    // Mild corner drop alone (resting / talking mouth) is not sad.
    #expect(classify(face(cornerLift: -0.013), &c) == .neutral)
    // Same drop with inner brows raised (AU1) is sad.
    var lm = face(cornerLift: -0.013)
    lm.leftBrow = [CGPoint(x: 0.37, y: 0.64), CGPoint(x: 0.43, y: 0.655)]
    lm.rightBrow = [CGPoint(x: 0.57, y: 0.655), CGPoint(x: 0.63, y: 0.64)]
    #expect(classify(lm, &c) == .sad)
}

@Test func evaluatorScoresAGuidedRecording() throws {
    var session = GuidedSession(start: 0, reactions: [.neutral, .surprised, .neutral], prepare: 1, hold: 3)
    var t = 0.0
    while let snap = session.tick(t) {
        let lm = snap.reaction == .surprised && snap.phase == .hold ? face(mouthOpen: 0.09) : face()
        session.record(FrameObservation(timestamp: t, face: lm, hands: []), at: t)
        t += 1.0 / 30
    }
    let report = Evaluator().evaluate(session.recording(camera: "test"))
    #expect(report.macroF1 > 0.9)
    #expect(report.falseSwitchesPerMinute < 1)
    let surprised = try #require(report.classes.first { $0.reaction == .surprised })
    #expect(surprised.shownRatio > 0.6)
}

@Test func guidedSessionPhasesPauseSkipRedo() throws {
    var s = GuidedSession(start: 0, reactions: [.smile, .thumbsUp, .peace], prepare: 2, hold: 4, settle: 0.5)
    #expect(s.tick(1)?.phase == .prepare)
    #expect(s.tick(2.1)?.phase == .hold)
    #expect(s.tick(2.1)?.reaction == .smile)
    // Pause freezes time.
    s.togglePause(3)
    #expect(s.tick(20)?.reaction == .smile)
    s.togglePause(20)
    #expect(s.tick(21)?.phase == .hold)      // 3 + (21-20) = 4 s in → still holding smile (hold 4 s + 3 s first-step bonus)
    // Skip moves to the next reaction's prepare.
    s.skip(21)
    #expect(s.tick(21.5)?.reaction == .thumbsUp)
    #expect(s.tick(21.5)?.phase == .prepare)
    // Redo during prepare goes back one reaction.
    s.redoPrevious(22)
    #expect(s.tick(22.5)?.reaction == .smile)
    // Frames recorded during prepare are never labelled.
    s.record(FrameObservation(timestamp: 22.5, face: nil, hands: []), at: 22.5)
    #expect(s.recording(camera: "x").frames.last?.label == nil)
}

/// Replays real recordings dropped into Tests/Fixtures (skipped when none exist).
@Test func realRecordingsMeetQualityBar() throws {
    let dir = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures")
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    for file in files where file.pathExtension == "json" {
        let rec = try decoder.decode(Recording.self, from: Data(contentsOf: file))
        let report = Evaluator().evaluate(rec)
        print("\(file.lastPathComponent):\n\(report.summary)")
        #expect(report.macroF1 >= 0.75, "\(file.lastPathComponent)")
        #expect(report.falseSwitchesPerMinute <= 1, "\(file.lastPathComponent)")
    }
}

@Test func fistBesideFaceIsNotThinking() {
    var c = ReactionClassifier()
    let fist = [false, false, false, false]
    // face box: x 0.3…0.7, y 0.25…0.75. Fist to the side at cheek height.
    #expect(classify(face(), hands: [hand(at: CGPoint(x: 0.82, y: 0.3), extended: fist)], &c) == .fist)
    // Fist centred right under the chin.
    #expect(classify(face(), hands: [hand(at: CGPoint(x: 0.5, y: 0.02), extended: fist)], &c) == .thinking)
}

private func loadModel() throws -> HandGestureModel {
    let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Resources/Models/hand-gesture-mlp.json")
    return try HandGestureModel(json: Data(contentsOf: url))
}

/// The Swift port must reproduce the Python reference within 1e-4 (golden vectors).
@Test func handModelMatchesGoldenVectors() throws {
    let model = try loadModel()
    let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Resources/Models/hand-gesture-mlp.golden.json")
    struct Golden: Decodable {
        struct Case: Decodable {
            let expectedLabel: String
            let joints: [String: [Double]?]
            let features: [Double]
            let probabilities: [Double]
        }
        let cases: [Case]
    }
    let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    for c in golden.cases {
        var joints: [HandJoint: CGPoint] = [:]
        for (name, xy) in c.joints {
            if let xy, let j = HandJoint(rawValue: name) { joints[j] = CGPoint(x: xy[0], y: xy[1]) }
        }
        let hand = HandPose(joints: joints)
        let f = try #require(HandGestureModel.features(hand))
        for (a, b) in zip(f, c.features) { #expect(abs(Double(a) - b) < 1e-4) }
        let p = try #require(model.predict(hand))
        #expect(p.label.rawValue == c.expectedLabel)
        for (a, b) in zip(p.probabilities, c.probabilities) { #expect(abs(a - b) < 1e-4, "\(c.expectedLabel)") }
    }
}

@Test func onlyAFistInFrame() throws {
    let fist = [false, false, false, false]
    for model in [nil, try loadModel()] as [HandGestureModel?] {
        var c = ReactionClassifier(handModel: model)
        // No face at all, a normal-size fist.
        #expect(classify(nil, hands: [hand(at: CGPoint(x: 0.9, y: 0.3), extended: fist)], &c) == .fist)
        // A huge fist filling the frame (held right in front of the lens).
        var c2 = ReactionClassifier(handModel: model)
        #expect(classify(nil, hands: [hand(at: CGPoint(x: 0.7, y: -0.1), extended: fist, scale: 5)], &c2) == .fist)
        // The fist just covered the face: the face was seen a moment ago, now only the fist.
        var c3 = ReactionClassifier(handModel: model)
        _ = c3.classify(FrameObservation(timestamp: 0, face: face(), hands: []))
        let r = c3.classify(FrameObservation(timestamp: 0.3, face: nil,
                                             hands: [hand(at: CGPoint(x: 0.5, y: 0.2), extended: fist, scale: 3)])).reaction
        #expect(r == .fist, "model: \(model != nil)")
    }
}

@Test func fistWithWristOutOfFrame() throws {
    for model in [nil, try loadModel()] as [HandGestureModel?] {
        var c = ReactionClassifier(handModel: model)
        var h = hand(at: CGPoint(x: 0.7, y: -0.3), extended: [false, false, false, false], scale: 5)
        h.joints[.wrist] = nil
        h.joints[.thumbCMC] = nil
        #expect(classify(nil, hands: [h], &c) == .fist, "model: \(model != nil)")
    }
}
