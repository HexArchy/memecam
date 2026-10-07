import Foundation

/// How teaching went: per reaction, how often the rules and the personal model got the user's frames right
/// on a take they didn't learn from.
public struct PersonalizationReport: Sendable, Codable, Equatable {
    public struct Row: Sendable, Codable, Equatable {
        public var reaction: Reaction
        public var rulesF1: Double
        public var personalF1: Double
        public var support: Int
        /// What the personal model mostly mistook it for (shown when it isn't enabled).
        public var confusedWith: Reaction?
        public var enabled: Bool
        /// Validated within one take (older data), so likely too optimistic.
        public var optimistic: Bool

        public init(reaction: Reaction, rulesF1: Double, personalF1: Double, support: Int, confusedWith: Reaction?,
                    enabled: Bool, optimistic: Bool) {
            self.reaction = reaction
            self.rulesF1 = rulesF1
            self.personalF1 = personalF1
            self.support = support
            self.confusedWith = confusedWith
            self.enabled = enabled
            self.optimistic = optimistic
        }
    }

    public enum Outcome: String, Sendable, Codable {
        /// The model is better and is used.
        case accepted
        /// Built-in detection is already as good for this user.
        case notBetter
        /// Not enough usable frames (face not visible, reactions skipped).
        case notEnoughData
    }

    public var rows: [Row]
    public var macroBefore: Double
    public var macroAfter: Double
    public var outcome: Outcome
    public var accepted: Bool { outcome == .accepted }

    public init(rows: [Row], macroBefore: Double, macroAfter: Double, outcome: Outcome) {
        self.rows = rows
        self.macroBefore = macroBefore
        self.macroAfter = macroAfter
        self.outcome = outcome
    }
    public var enabled: [Reaction] { rows.filter(\.enabled).map(\.reaction) }
}

/// Builds the personal model from teach sessions ("Teach MemeCam").
///
/// 1. Replays each session through a fresh classifier (rules only) to get every labelled frame's features
///    and the rules' answer.
/// 2. Groups frames into takes (one continuous hold of one reaction) and keeps the newest takes.
/// 3. Validates by take (2 folds: learn take A, test take B and back), because frames of one hold are
///    near-duplicates: validating inside a hold reported 1.00 where held-out data gave 0.89.
/// 4. Enables a reaction only if the personal model beats the rules on it (and reaches F1 0.5), and
///    accepts the model only if the macro F1 gains ≥ 0.03 without making neutral worse — neutral frames
///    predicted as reactions are what spams memes in a call.
public enum PersonalTrainer {
    public struct Example: Sendable {
        public var reaction: Reaction
        /// Unique per take across all sessions.
        public var take: Int
        public var features: [Float]
        public var rules: Reaction
        public var rulesConfidence: Double
    }

    static let minFramesPerReaction = 30
    static let minFramesPerTake = 15
    static let maxFramesPerTake = 60
    static let maxNeutralTakes = 6
    static let minMacroGain = 0.03
    static let maxNeutralDrop = 0.05
    static let minPersonalF1 = 0.5

    /// Labelled frames of `recordings` with features; sessions in order, oldest first.
    public static func examples(from recordings: [Recording], handModel: HandGestureModel?) -> [Example] {
        var out: [Example] = []
        var take = 0
        for rec in recordings {
            var classifier = ReactionClassifier(handModel: handModel)
            classifier.recordsFeatures = true
            var previous: Reaction?
            for frame in rec.frames {
                let est = classifier.classify(frame.observation)
                if frame.label != previous {
                    if frame.label != nil { take += 1 }
                    previous = frame.label
                }
                guard let label = frame.label, label != .noFace, let x = classifier.lastFeatures else { continue }
                out.append(Example(reaction: label, take: take, features: x, rules: est.reaction,
                                   rulesConfidence: est.confidence))
            }
        }
        return out
    }

    /// Validates on `recordings` and returns the model (nil unless accepted) with its report.
    public static func build(_ recordings: [Recording], handModel: HandGestureModel?,
                             handModelHash: String) -> (model: PersonalModel?, report: PersonalizationReport) {
        let all = select(examples(from: recordings, handModel: handModel))
        let trainable = Set(Dictionary(grouping: all, by: \.reaction)
            .filter { $0.value.count >= minFramesPerReaction }.keys)
        let data = all.filter { trainable.contains($0.reaction) }
        guard trainable.count >= 2 else {
            return (nil, PersonalizationReport(rows: [], macroBefore: 0, macroAfter: 0, outcome: .notEnoughData))
        }

        // Folds by take: per reaction, takes alternate between fold 0 and 1.
        var foldOfTake: [Int: Int] = [:]
        var optimistic: Set<Reaction> = []
        for (reaction, group) in Dictionary(grouping: data, by: \.reaction) {
            let takes = Array(Set(group.map(\.take))).sorted()
            if takes.count >= 2 {
                for (i, t) in takes.enumerated() { foldOfTake[t] = i % 2 }
            } else {
                optimistic.insert(reaction)
            }
        }
        // Single-take reactions: split the take in time (first half / second half).
        var fold = [Int](repeating: 0, count: data.count)
        var seenInTake: [Int: Int] = [:]
        let takeSizes = Dictionary(grouping: data, by: \.take).mapValues(\.count)
        for (i, e) in data.enumerated() {
            if let f = foldOfTake[e.take] {
                fold[i] = f
            } else {
                let k = seenInTake[e.take, default: 0]
                seenInTake[e.take] = k + 1
                fold[i] = k < (takeSizes[e.take] ?? 0) / 2 ? 0 : 1
            }
        }

        // Out-of-fold personal predictions for every frame.
        var predicted = [Reaction?](repeating: nil, count: data.count)
        for f in 0...1 {
            let train = data.indices.filter { fold[$0] != f }.map { (data[$0].features, data[$0].reaction) }
            guard !train.isEmpty else { continue }
            let model = PersonalModel(examples: train, enabled: trainable, handModelHash: handModelHash,
                                      report: .empty)
            for i in data.indices where fold[i] == f {
                predicted[i] = model.predict(data[i].features)?.reaction
            }
        }

        // Enable per reaction; disabling one changes what falls through, so iterate.
        var enabled = trainable
        var rows: [PersonalizationReport.Row] = []
        var macroAfter = 0.0
        for _ in 0..<3 {
            let gated = data.indices.map { i -> Reaction? in
                if let p = predicted[i], enabled.contains(p) { return p }
                return data[i].rulesConfidence > 0 ? data[i].rules : nil
            }
            let rulesF1 = f1Scores(data.map(\.reaction), data.map { $0.rulesConfidence > 0 ? $0.rules : nil })
            let personalF1 = f1Scores(data.map(\.reaction), gated)
            let confusions = topConfusions(data.map(\.reaction), gated)
            let next = Set(trainable.filter { r in
                (personalF1[r] ?? 0) >= (rulesF1[r] ?? 0) && (personalF1[r] ?? 0) >= minPersonalF1
            })
            rows = trainable.sorted { $0.rawValue < $1.rawValue }.map { r in
                PersonalizationReport.Row(reaction: r, rulesF1: rulesF1[r] ?? 0, personalF1: personalF1[r] ?? 0,
                                          support: data.filter { $0.reaction == r }.count,
                                          confusedWith: confusions[r], enabled: next.contains(r),
                                          optimistic: optimistic.contains(r))
            }
            macroAfter = mean(trainable.map { next.contains($0) ? personalF1[$0] ?? 0 : rulesF1[$0] ?? 0 })
            if next == enabled { break }
            enabled = next
        }
        let macroBefore = mean(rows.map(\.rulesF1))
        let neutral = rows.first { $0.reaction == .neutral }
        let neutralOK = neutral.map { !$0.enabled || $0.personalF1 >= $0.rulesF1 - maxNeutralDrop } ?? true
        let accepted = !enabled.isEmpty && macroAfter >= macroBefore + minMacroGain && neutralOK
        let report = PersonalizationReport(rows: rows, macroBefore: macroBefore, macroAfter: macroAfter,
                                           outcome: accepted ? .accepted : .notBetter)
        guard accepted else { return (nil, report) }
        return (fit(data, enabled: enabled, handModelHash: handModelHash, report: report), report)
    }

    /// The final model on all selected examples; head tilts are mirrored so either side works.
    public static func fit(_ data: [Example], enabled: Set<Reaction>, handModelHash: String,
                    report: PersonalizationReport) -> PersonalModel {
        var examples = data.map { ($0.features, $0.reaction) }
        for e in data where e.reaction == .headTilt {
            var x = e.features
            x[ReactionFeatures.rollIndex] = -x[ReactionFeatures.rollIndex]
            examples.append((x, e.reaction))
        }
        return PersonalModel(examples: examples, enabled: enabled, handModelHash: handModelHash, report: report)
    }

    /// Newest takes per reaction (all takes of its newest session; neutral: the newest few), short takes
    /// dropped, long ones evenly thinned.
    public static func select(_ examples: [Example]) -> [Example] {
        let byTake = Dictionary(grouping: examples, by: \.take)
        var keep: Set<Int> = []
        for (reaction, group) in Dictionary(grouping: examples, by: \.reaction) {
            let takes = Array(Set(group.map(\.take))).filter { (byTake[$0]?.count ?? 0) >= minFramesPerTake }.sorted()
            keep.formUnion(takes.suffix(reaction == .neutral ? maxNeutralTakes : 2))
        }
        return byTake.keys.sorted().filter(keep.contains).flatMap { t -> [Example] in
            let frames = byTake[t]!
            guard frames.count > maxFramesPerTake else { return frames }
            let step = Double(frames.count) / Double(maxFramesPerTake)
            return (0..<maxFramesPerTake).map { frames[Int(Double($0) * step)] }
        }
    }

    /// Per-class F1 counted like `Evaluator` (nil predictions = no opinion, skipped).
    static func f1Scores(_ truth: [Reaction], _ predicted: [Reaction?]) -> [Reaction: Double] {
        var tp: [Reaction: Int] = [:], fp: [Reaction: Int] = [:], fn: [Reaction: Int] = [:]
        for (t, p) in zip(truth, predicted) {
            guard let p else { continue }
            if p == t { tp[t, default: 0] += 1 } else { fn[t, default: 0] += 1; fp[p, default: 0] += 1 }
        }
        var out: [Reaction: Double] = [:]
        for r in Set(truth) {
            let t = Double(tp[r] ?? 0), p = Double(fp[r] ?? 0), n = Double(fn[r] ?? 0)
            out[r] = t > 0 ? 2 * t / (2 * t + p + n) : 0
        }
        return out
    }

    static func topConfusions(_ truth: [Reaction], _ predicted: [Reaction?]) -> [Reaction: Reaction] {
        var counts: [Reaction: [Reaction: Int]] = [:]
        for (t, p) in zip(truth, predicted) where p != nil && p != t { counts[t, default: [:]][p!, default: 0] += 1 }
        return counts.compactMapValues { $0.max { $0.value < $1.value }?.key }
    }

    private static func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
}

extension PersonalizationReport {
    static let empty = PersonalizationReport(rows: [], macroBefore: 0, macroAfter: 0, outcome: .notBetter)
}
