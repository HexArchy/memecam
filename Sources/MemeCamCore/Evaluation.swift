import Foundation

/// One recorded frame with the reaction the user was asked to perform (nil = transition).
public struct LabeledFrame: Codable, Sendable {
    public var label: Reaction?
    public var observation: FrameObservation

    public init(label: Reaction?, observation: FrameObservation) {
        self.label = label
        self.observation = observation
    }
}

/// A guided recording session: replayable ground truth for tuning thresholds.
public struct Recording: Codable, Sendable {
    public var createdAt: Date
    public var camera: String
    public var frames: [LabeledFrame]

    public init(createdAt: Date = Date(), camera: String, frames: [LabeledFrame]) {
        self.createdAt = createdAt
        self.camera = camera
        self.frames = frames
    }
}

/// Replays a recording through a fresh classifier + stabilizer and scores it.
public struct Evaluator: Sendable {
    public struct ClassScore: Sendable {
        public var reaction: Reaction
        public var precision: Double
        public var recall: Double
        public var f1: Double { precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0 }
        /// Share of the labelled segment during which the *stabilized* output showed it.
        public var shownRatio: Double
        /// Mean seconds from segment start until it was first shown (nil if never).
        public var latency: Double?
        public var support: Int
    }

    public struct Report: Sendable {
        public var classes: [ClassScore]
        public var macroF1: Double
        /// Stabilized reaction changes per minute while the user held a neutral face.
        public var falseSwitchesPerMinute: Double
        public var topConfusions: [(expected: Reaction, got: Reaction, count: Int)]

        public var summary: String {
            var lines = [String(format: "Macro F1 %.2f · false switches on neutral %.2f/min", macroF1, falseSwitchesPerMinute)]
            for c in classes.sorted(by: { $0.f1 < $1.f1 }) {
                let lat = c.latency.map { String(format: "%.2fs", $0) } ?? "never"
                lines.append(String(format: "%@  F1 %.2f  P %.2f  R %.2f  shown %.0f%%  latency %@",
                                    c.reaction.title.padding(toLength: 13, withPad: " ", startingAt: 0),
                                    c.f1, c.precision, c.recall, c.shownRatio * 100, lat))
            }
            if !topConfusions.isEmpty {
                lines.append("Confusions: " + topConfusions.map { "\($0.expected.title)→\($0.got.title) ×\($0.count)" }
                    .joined(separator: ", "))
            }
            return lines.joined(separator: "\n")
        }
    }

    public var classifierConfig: ReactionClassifier.Config
    public var calmness: Double

    public init(classifierConfig: ReactionClassifier.Config = .init(), calmness: Double = 1) {
        self.classifierConfig = classifierConfig
        self.calmness = calmness
    }

    public func evaluate(_ recording: Recording) -> Report {
        var classifier = ReactionClassifier(config: classifierConfig)
        var stabilizer = ReactionStabilizer(minHold: 1.2 * calmness, delayScale: calmness)

        var tp: [Reaction: Int] = [:], fp: [Reaction: Int] = [:], fn: [Reaction: Int] = [:]
        var confusion: [String: (Reaction, Reaction, Int)] = [:]
        var shownTime: [Reaction: Double] = [:], segmentTime: [Reaction: Double] = [:]
        var latencies: [Reaction: [Double]] = [:]
        var neutralTime = 0.0, neutralSwitches = 0

        var segmentLabel: Reaction?, segmentStart = 0.0, segmentShown = false
        var prevT: Double?

        for frame in recording.frames {
            let t = frame.observation.timestamp
            let dt = prevT.map { min(t - $0, 0.2) } ?? 0
            prevT = t
            let est = classifier.classify(frame.observation)
            let before = stabilizer.current
            _ = stabilizer.update(est.reaction, confidence: est.confidence, at: t)
            let shown = stabilizer.current

            if frame.label != segmentLabel {
                segmentLabel = frame.label
                segmentStart = t
                segmentShown = false
            }
            guard let label = frame.label else { continue }

            if est.confidence > 0 {
                if est.reaction == label {
                    tp[label, default: 0] += 1
                } else {
                    fn[label, default: 0] += 1
                    fp[est.reaction, default: 0] += 1
                    let key = "\(label.rawValue)>\(est.reaction.rawValue)"
                    confusion[key] = (label, est.reaction, (confusion[key]?.2 ?? 0) + 1)
                }
            }
            segmentTime[label, default: 0] += dt
            if shown == label {
                shownTime[label, default: 0] += dt
                if !segmentShown {
                    segmentShown = true
                    latencies[label, default: []].append(t - segmentStart)
                }
            }
            if label == .neutral {
                neutralTime += dt
                if shown != before { neutralSwitches += 1 }
            }
        }

        let labels = Set(recording.frames.compactMap(\.label))
        let classes = labels.sorted { $0.rawValue < $1.rawValue }.map { r -> ClassScore in
            let t = Double(tp[r] ?? 0), p = Double(fp[r] ?? 0), n = Double(fn[r] ?? 0)
            let lat = latencies[r].map { $0.reduce(0, +) / Double($0.count) }
            return ClassScore(reaction: r, precision: t + p > 0 ? t / (t + p) : 0, recall: t + n > 0 ? t / (t + n) : 0,
                              shownRatio: (shownTime[r] ?? 0) / max(segmentTime[r] ?? 0, 1e-6),
                              latency: lat, support: Int(t + n))
        }
        let macro = classes.isEmpty ? 0 : classes.map(\.f1).reduce(0, +) / Double(classes.count)
        let confusions = confusion.values.sorted { $0.2 > $1.2 }.prefix(5).map { (expected: $0.0, got: $0.1, count: $0.2) }
        return Report(classes: classes, macroF1: macro,
                      falseSwitchesPerMinute: neutralTime > 0 ? Double(neutralSwitches) / (neutralTime / 60) : 0,
                      topConfusions: Array(confusions))
    }
}

/// The scripted prompts of a guided recording session.
public struct GuidedScript: Sendable {
    public struct Step: Sendable, Equatable {
        public var reaction: Reaction
        public var duration: Double
    }

    /// Seconds at the start of each step that are not labelled (the user is still moving).
    public static let transition = 1.2

    public var steps: [Step]

    public init(steps: [Step]? = nil) {
        self.steps = steps ?? ([Step(reaction: .neutral, duration: 6)]
            + Reaction.allCases.filter { $0 != .neutral && $0 != .noFace }.map { Step(reaction: $0, duration: 4) }
            + [Step(reaction: .neutral, duration: 5), Step(reaction: .noFace, duration: 4)])
    }

    public var totalDuration: Double { steps.map(\.duration).reduce(0, +) }

    /// Which step is active `elapsed` seconds in, and whether its frames count as labelled.
    public func step(at elapsed: Double) -> (index: Int, step: Step, labelled: Bool, remaining: Double)? {
        var t = 0.0
        for (i, s) in steps.enumerated() {
            if elapsed < t + s.duration {
                return (i, s, elapsed - t >= Self.transition, t + s.duration - elapsed)
            }
            t += s.duration
        }
        return nil
    }
}
