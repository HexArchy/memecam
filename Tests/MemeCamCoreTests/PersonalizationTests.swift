import CoreGraphics
import Foundation
import Testing
@testable import MemeCamCore

// MARK: - Synthetic teach sessions (15 Hz, deterministic jitter)

/// `takes` in order: each (label, face) is held for `seconds`, after `gap` s of unlabelled transition.
private func session(_ takes: [(Reaction, (Int) -> FaceLandmarks)], seconds: Double = 3, start: Double = 0,
                     gap: Double = 1, hands: (Reaction) -> [HandPose] = { _ in [] }) -> Recording {
    var frames: [LabeledFrame] = []
    var t = start, i = 0
    for (label, make) in takes {
        for _ in 0..<Int(gap * 15) {
            frames.append(LabeledFrame(label: nil, observation: FrameObservation(timestamp: t, face: make(i), hands: hands(label))))
            t += 1.0 / 15; i += 1
        }
        for _ in 0..<Int(seconds * 15) {
            frames.append(LabeledFrame(label: label, observation: FrameObservation(timestamp: t, face: make(i), hands: hands(label))))
            t += 1.0 / 15; i += 1
        }
    }
    return Recording(camera: "test", frames: frames)
}

private func jitter(_ i: Int) -> CGFloat { CGFloat((i * 7919) % 11 - 5) / 2500 } // ±0.002

private func neutralFace(_ i: Int) -> FaceLandmarks { face(mouthOpen: 0.01 + jitter(i)) }
/// A pout too subtle for the rules (they need a much stronger corner drop without brow support).
private func subtleSad(_ i: Int) -> FaceLandmarks { face(mouthOpen: 0.01 + jitter(i), cornerLift: -0.012 + jitter(i + 3) / 2) }

private func teachRecording() -> Recording {
    session([(.neutral, neutralFace), (.sad, subtleSad), (.neutral, neutralFace), (.sad, subtleSad)])
}

// MARK: - Features

@Test func featuresHaveFixedShapeAndZeroMissingParts() {
    var c = ReactionClassifier()
    c.recordsFeatures = true
    _ = c.classify(FrameObservation(timestamp: 0, face: face(), hands: []))
    let x = try! #require(c.lastFeatures)
    #expect(x.count == ReactionFeatures.count)
    #expect(x[0] == 1)
    #expect(x[ReactionFeatures.handPresentIndex...].allSatisfy { $0 == 0 })

    _ = c.classify(FrameObservation(timestamp: 0.1, face: nil, hands: []))
    #expect(c.lastFeatures == nil) // nobody there: the personal model is never asked

    _ = c.classify(FrameObservation(timestamp: 2, face: nil,
                                    hands: [hand(at: CGPoint(x: 0.5, y: 0.3), extended: [true, true, true, true], thumb: 1)]))
    let h = try! #require(c.lastFeatures)
    #expect(h[0...9].allSatisfy { $0 == 0 })
    #expect(h[ReactionFeatures.handPresentIndex] == 1)
}

// MARK: - kNN

@Test func personalModelPredictsRejectsAndKeepsHandPartitions() {
    func x(_ a: Float, _ b: Float, hand: Bool = false) -> [Float] {
        var v = [Float](repeating: 0, count: ReactionFeatures.count)
        v[0] = 1; v[1] = a; v[3] = b
        if hand { v[ReactionFeatures.handPresentIndex] = 1 }
        return v
    }
    var ex: [([Float], Reaction)] = []
    for i in 0..<20 {
        let j = Float(i % 5) * 0.02
        ex.append((x(0 + j, 0 + j), .neutral))
        ex.append((x(1 + j, -1 + j), .sad))
    }
    let m = PersonalModel(examples: ex, enabled: [.neutral, .sad], handModelHash: "t", report: .empty)
    #expect(m.predict(x(0.03, 0.01))?.reaction == .neutral)
    #expect(m.predict(x(1.02, -0.98))?.reaction == .sad)
    #expect(m.predict(x(0.5, -0.5)) == nil || m.predict(x(0.5, -0.5))?.votes == 7)
    #expect(m.predict(x(9, 9)) == nil)            // far from everything taught
    #expect(m.predict(x(0, 0, hand: true)) == nil) // no hand-present samples were taught
}

// MARK: - Training

@Test func teachingLearnsAnExpressionTheRulesMiss() throws {
    let (model, report) = PersonalTrainer.build([teachRecording()], handModel: nil, handModelHash: "t")
    #expect(report.outcome == .accepted)
    let m = try #require(model)
    #expect(m.enabled.contains(.sad))

    // A later, separate session.
    let test = session([(.neutral, neutralFace), (.sad, subtleSad), (.neutral, neutralFace)], start: 100)
    let rules = Evaluator().evaluate(test)
    let taught = Evaluator(personal: m).evaluate(test)
    let f1 = { (r: Evaluator.Report, x: Reaction) in r.classes.first { $0.reaction == x }?.f1 ?? 0 }
    #expect(f1(rules, .sad) == 0)
    #expect(f1(taught, .sad) > 0.8)
    #expect(f1(taught, .neutral) >= f1(rules, .neutral) - 0.05)
    #expect(taught.falseSwitchesPerMinute == 0)
}

@Test func indistinguishableReactionIsNotEnabled() {
    let rec = session([(.neutral, neutralFace), (.sad, neutralFace), (.neutral, neutralFace), (.sad, neutralFace)])
    let (model, report) = PersonalTrainer.build([rec], handModel: nil, handModelHash: "t")
    #expect(model == nil)
    #expect(report.outcome != .accepted)
    #expect(report.rows.first { $0.reaction == .sad }?.enabled == false)
}

@Test func tooLittleDataIsReported() {
    let rec = session([(.neutral, neutralFace), (.sad, subtleSad)], seconds: 1)
    let (model, report) = PersonalTrainer.build([rec], handModel: nil, handModelHash: "t")
    #expect(model == nil)
    #expect(report.outcome == .notEnoughData)
}

@Test func trainingIsDeterministicAndCodable() throws {
    let a = try #require(PersonalTrainer.build([teachRecording()], handModel: nil, handModelHash: "t").model)
    let b = try #require(PersonalTrainer.build([teachRecording()], handModel: nil, handModelHash: "t").model)
    #expect(a == b)
    let decoded = try JSONDecoder().decode(PersonalModel.self, from: JSONEncoder().encode(a))
    #expect(decoded == a)
}

@Test func personalModelNeverAnswersForAnEmptyFrame() throws {
    var c = ReactionClassifier()
    c.personal = try #require(PersonalTrainer.build([teachRecording()], handModel: nil, handModelHash: "t").model)
    #expect(c.classify(FrameObservation(timestamp: 0, face: nil, hands: [])).reaction == .noFace)
}

// MARK: - Store and plan

@Test func storeRoundTripsSessionsModelAndReset() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "memecam-store-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = PersonalStore(directory: dir)
    #expect(!store.hasSessions)
    let rec = teachRecording()
    try store.saveSession(rec)
    let loaded = store.sessions()
    #expect(loaded.count == 1)
    #expect(loaded[0].frames.filter { $0.label != nil }.count == rec.frames.filter { $0.label != nil }.count)

    let (model, report) = PersonalTrainer.build(loaded, handModel: nil, handModelHash: "h1")
    try store.save(model: model, report: report)
    #expect(store.loadModel(handModelHash: "h1") == model)
    #expect(store.loadModel(handModelHash: "other") == nil) // new hand model: rebuild
    #expect(store.loadReport() == report)

    try store.reset()
    #expect(!store.hasSessions)
    #expect(store.loadModel(handModelHash: "h1") == nil)
}

@Test func trimmingKeepsLabelledRunsAndALeadIn() {
    let rec = session([(.neutral, neutralFace), (.sad, subtleSad)], gap: 2.5)
    let trimmed = PersonalStore.trimmed(rec)
    #expect(trimmed.frames.count < rec.frames.count)
    #expect(trimmed.frames.filter { $0.label != nil }.count == rec.frames.filter { $0.label != nil }.count)
    #expect(trimmed.frames.first?.label == nil) // the lead-in before the first take
}

@Test func teachPlanRunsTwoPassesWithTakeNumbers() {
    var g = GuidedSession.teaching(start: 0, reactions: [.smile, .sad])
    #expect(g.reactions == [.neutral, .smile, .sad, .neutral, .smile, .sad, .neutral])
    var takes: [Reaction: [Int]] = [:]
    var t = 0.0
    var last = -1
    while let s = g.tick(t) {
        if s.stepIndex != last {
            takes[s.reaction, default: []].append(s.take)
            #expect(s.teaching)
            last = s.stepIndex
        }
        t += 0.25
    }
    #expect(takes[.smile] == [0, 1])
    #expect(takes[.neutral] == [0, 1, 2])
    #expect(Reaction.smile.teachHint(take: 0) == nil)
    #expect(Reaction.smile.teachHint(take: 1) != nil)
}
