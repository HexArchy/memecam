import Foundation

/// One Euro filter (Casiez et al., CHI 2012): adaptive low-pass that removes jitter when the
/// signal is steady and follows quickly when it moves. Better than a fixed EMA for landmarks:
/// an EMA either jitters (high alpha) or lags behind real expressions (low alpha).
public struct OneEuroFilter: Sendable {
    public var minCutoff: Double
    public var beta: Double
    public var derivativeCutoff: Double

    private var x: Double?
    private var dx = 0.0
    private var lastTime: TimeInterval?

    public init(minCutoff: Double = 1.5, beta: Double = 0.5, derivativeCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    public mutating func filter(_ value: Double, at t: TimeInterval) -> Double {
        guard let prev = x, let last = lastTime, t > last else {
            x = value
            lastTime = t
            return value
        }
        let dt = min(t - last, 0.5)
        let rawDx = (value - prev) / dt
        dx += Self.alpha(cutoff: derivativeCutoff, dt: dt) * (rawDx - dx)
        let cutoff = minCutoff + beta * abs(dx)
        let next = prev + Self.alpha(cutoff: cutoff, dt: dt) * (value - prev)
        x = next
        lastTime = t
        return next
    }

    public mutating func reset() {
        x = nil
        lastTime = nil
        dx = 0
    }
}

/// Smooths every field of `FaceMetrics` independently.
public struct FaceMetricsFilter: Sendable {
    private var f = Array(repeating: OneEuroFilter(), count: FaceMetrics.typicalNeutral.vector.count)
    private var lastTime: TimeInterval = -.infinity

    public init() {}

    public mutating func filter(_ m: FaceMetrics, at t: TimeInterval) -> FaceMetrics {
        // Face lost for a while: start fresh instead of gliding from stale values.
        if t - lastTime > 0.5 { for i in f.indices { f[i].reset() } }
        lastTime = t
        return FaceMetrics(vector: m.vector.enumerated().map { i, v in f[i].filter(v, at: t) })
    }
}

extension FaceMetrics {
    /// Per-field median — robust baseline from a handful of frames (ignores blinks, twitches).
    public static func median(_ samples: [FaceMetrics]) -> FaceMetrics? {
        guard !samples.isEmpty else { return nil }
        let n = samples[0].vector.count
        var out = (0..<n).map { i -> Double in
            let v = samples.map { $0.vector[i] }.sorted()
            return v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
        }
        out[5] = 0 // roll baseline: upright
        return FaceMetrics(vector: out)
    }
}
