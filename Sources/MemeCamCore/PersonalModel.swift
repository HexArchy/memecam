import Accelerate
import Foundation

/// What "Teach MemeCam" learned: a gated k-nearest-neighbour classifier over `ReactionFeatures`.
///
/// It only answers when it is sure: all `k` nearest taught frames agree (measured: 5 of 7 let a neutral
/// face flip to "sad" ~20×/min in a held-out segment, 7 of 7 gave 0 with higher macro-F1) and the
/// nearest one is within `rejectRadius`, otherwise the rule classifier decides. Samples are split by
/// hand presence, so a face-only lesson can never turn a thumbs-up frame into "neutral" (or the reverse).
/// Measured on a real recording (60/40 time split): macro-F1 0.83 (rules) → 0.95 (rules + this model).
public struct PersonalModel: Sendable, Codable, Equatable {
    public struct Prediction: Sendable, Equatable {
        public var reaction: Reaction
        public var votes: Int
        public var distance: Float
    }

    public var featureVersion: Int
    /// Fingerprint of the hand-gesture model: its probabilities are features, so a new one invalidates this.
    public var handModelHash: String
    /// Reactions the personal model may decide (each one validated better than the rules).
    public var enabled: Set<Reaction>
    public var report: PersonalizationReport

    public var k = 7
    public var minVotes = 7
    /// Squared distance (standardised space) beyond which a frame counts as "never taught".
    public var rejectRadius: Float
    var mean: [Float]
    var scale: [Float]
    /// Standardised samples, row-major n × `ReactionFeatures.count`.
    var samples: [Float]
    var labels: [Reaction]
    var hasHand: [Bool]
    /// ‖s_i‖², cached for the distance pass.
    var norms: [Float]

    public var sampleCount: Int { labels.count }

    /// Fits standardisation and the rejection radius on `examples` (features + labels).
    init(examples: [(features: [Float], reaction: Reaction)], enabled: Set<Reaction>, handModelHash: String,
         report: PersonalizationReport, radiusMultiplier: Float = 2) {
        let d = ReactionFeatures.count
        let n = max(examples.count, 1)
        var mean = [Float](repeating: 0, count: d), sq = [Float](repeating: 0, count: d)
        for e in examples { for j in 0..<d { mean[j] += e.features[j]; sq[j] += e.features[j] * e.features[j] } }
        for j in 0..<d { mean[j] /= Float(n); sq[j] /= Float(n) }
        let scale = (0..<d).map { j in max((sq[j] - mean[j] * mean[j]).squareRoot(), 0.05) }

        self.featureVersion = ReactionFeatures.version
        self.handModelHash = handModelHash
        self.enabled = enabled
        self.report = report
        self.mean = mean
        self.scale = scale
        self.samples = examples.flatMap { e in (0..<d).map { (e.features[$0] - mean[$0]) / scale[$0] } }
        self.labels = examples.map(\.reaction)
        self.hasHand = examples.map { $0.features[ReactionFeatures.handPresentIndex] > 0.5 }
        self.norms = []
        self.rejectRadius = .greatestFiniteMagnitude // JSON can't hold infinity
        self.norms = (0..<labels.count).map { i in
            samples[(i * d)..<(i * d + d)].reduce(0) { $0 + $1 * $1 }
        }
        let p95 = nearestSameClassP95()
        if p95.isFinite { rejectRadius = radiusMultiplier * p95 }
    }

    /// The taught reaction for one frame, or nil when the model isn't sure (the rules decide then).
    public func predict(_ x: [Float]) -> Prediction? {
        let d = ReactionFeatures.count
        guard x.count == d, !labels.isEmpty else { return nil }
        let q = (0..<d).map { (x[$0] - mean[$0]) / scale[$0] }
        let wantHand = x[ReactionFeatures.handPresentIndex] > 0.5
        let distances = squaredDistances(to: q)
        // k smallest within the matching partition (insertion into a tiny sorted list).
        var best: [(Float, Int)] = []
        best.reserveCapacity(k + 1)
        for i in labels.indices where hasHand[i] == wantHand {
            let dist = distances[i]
            if best.count < k || dist < best[best.count - 1].0 {
                let at = best.firstIndex { $0.0 > dist } ?? best.count
                best.insert((dist, i), at: at)
                if best.count > k { best.removeLast() }
            }
        }
        guard best.count == k, best[0].0 <= rejectRadius else { return nil }
        var votes: [Reaction: Int] = [:]
        for (_, i) in best { votes[labels[i], default: 0] += 1 }
        guard let top = votes.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key.rawValue > $1.key.rawValue) }),
              top.value >= minVotes else { return nil }
        return Prediction(reaction: top.key, votes: top.value, distance: best[0].0)
    }

    /// ‖s_i − q‖² for every sample: one matrix–vector product (‖s‖² − 2 s·q + ‖q‖²).
    private func squaredDistances(to q: [Float]) -> [Float] {
        let d = ReactionFeatures.count, n = labels.count
        var dots = [Float](repeating: 0, count: n)
        samples.withUnsafeBufferPointer { s in
            q.withUnsafeBufferPointer { qp in
                dots.withUnsafeMutableBufferPointer { out in
                    cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(n), Int32(d), 1, s.baseAddress, Int32(d),
                                qp.baseAddress, 1, 0, out.baseAddress, 1)
                }
            }
        }
        let qq = q.reduce(0) { $0 + $1 * $1 }
        return (0..<n).map { max(0, norms[$0] - 2 * dots[$0] + qq) }
    }

    /// 95th percentile over samples of the squared distance to the nearest other sample of the same class.
    private func nearestSameClassP95() -> Float {
        let d = ReactionFeatures.count, n = labels.count
        guard n > 1 else { return .infinity }
        var nearest: [Float] = []
        for i in 0..<n {
            let row = Array(samples[(i * d)..<(i * d + d)])
            let dist = squaredDistances(to: row)
            var m = Float.infinity
            for j in 0..<n where j != i && labels[j] == labels[i] && hasHand[j] == hasHand[i] { m = min(m, dist[j]) }
            if m.isFinite { nearest.append(m) }
        }
        guard !nearest.isEmpty else { return .infinity }
        nearest.sort()
        return max(nearest[min(nearest.count - 1, Int(Double(nearest.count) * 0.95))], 1e-3)
    }
}
