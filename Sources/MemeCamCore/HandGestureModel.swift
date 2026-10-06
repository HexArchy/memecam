import CoreGraphics
import Foundation

/// Learned static hand-gesture classifier: a 44→128→64→8 MLP trained on ~1.3 M hand-landmark
/// samples from HaGRID v2 (subject-independent test macro-F1 0.987). Pure Swift inference —
/// ~14 k multiply-adds per hand, microseconds on any Mac; no Core ML needed.
/// Weights: Resources/Models/hand-gesture-mlp.json (HaGRID licence: personal, non-commercial).
public struct HandGestureModel: Sendable {
    public enum Label: String, Sendable, CaseIterable {
        case thumbsUp, thumbsDown, peace, openPalm, pointing, fist, heartHalf, none

        public var gesture: HandGesture? {
            switch self {
            case .thumbsUp: .thumbsUp
            case .thumbsDown: .thumbsDown
            case .peace: .peace
            case .openPalm: .openPalm
            case .pointing: .pointing
            case .fist: .fist
            case .heartHalf, .none: nil
            }
        }
    }

    public struct Prediction: Sendable, Equatable {
        public var label: Label
        public var probability: Double
        public var probabilities: [Double]
    }

    struct Layer: Sendable {
        var weights: [Float]   // row-major [out][in]
        var bias: [Float]
        var inputs: Int
        var softmax: Bool
    }

    let layers: [Layer]
    public let labels: [Label]

    /// Joint order of the model input (= MediaPipe order = `HandJoint.allCases`).
    static let order = HandJoint.allCases
    static let parent = [-1, 0, 1, 2, 3, 0, 5, 6, 7, 0, 9, 10, 11, 0, 13, 14, 15, 0, 17, 18, 19]

    public init(json data: Data) throws {
        struct File: Decodable {
            struct L: Decodable { let weights: [[Float]]; let bias: [Float]; let activation: String }
            let labels: [String]
            let layers: [L]
        }
        let f = try JSONDecoder().decode(File.self, from: data)
        labels = try f.labels.map {
            guard let l = Label(rawValue: $0) else { throw CocoaError(.coderInvalidValue) }
            return l
        }
        layers = f.layers.map { l in
            Layer(weights: l.weights.flatMap { $0 }, bias: l.bias, inputs: l.weights.first?.count ?? 0,
                  softmax: l.activation == "softmax")
        }
    }

    /// 44 features: 21 joints rotated so wrist→middleMCP points up with unit length, plus the
    /// original direction (ux, uy) of that vector (distinguishes up from down).
    public static func features(_ hand: HandPose) -> [Float]? {
        guard let wrist = hand[.wrist], hand[.middleMCP] != nil else { return nil }
        var p = [CGPoint](repeating: wrist, count: 21)
        for (j, joint) in order.enumerated() where j > 0 {
            p[j] = hand[joint] ?? p[parent[j]]
        }
        let q = p.map { CGPoint(x: $0.x - wrist.x, y: $0.y - wrist.y) }
        let v = q[9]
        let s = max(Double(hypot(v.x, v.y)), 1e-6)
        let ux = Double(v.x) / s, uy = Double(v.y) / s
        var out = [Float]()
        out.reserveCapacity(44)
        for pt in q {
            let x = Double(pt.x), y = Double(pt.y)
            out.append(Float((uy * x - ux * y) / s))
            out.append(Float((ux * x + uy * y) / s))
        }
        out.append(Float(ux))
        out.append(Float(uy))
        return out
    }

    public func logits(_ x: [Float]) -> [Float] {
        var h = x
        for (li, layer) in layers.enumerated() {
            let n = layer.bias.count
            var next = [Float](repeating: 0, count: n)
            layer.weights.withUnsafeBufferPointer { w in
                h.withUnsafeBufferPointer { inp in
                    for o in 0..<n {
                        var acc = layer.bias[o]
                        let row = o * layer.inputs
                        for i in 0..<layer.inputs { acc += w[row + i] * inp[i] }
                        next[o] = acc
                    }
                }
            }
            if li < layers.count - 1 { for i in next.indices { next[i] = max(0, next[i]) } }
            h = next
        }
        return h
    }

    public func predict(_ hand: HandPose) -> Prediction? {
        guard let x = Self.features(hand) else { return nil }
        let z = logits(x).map(Double.init)
        let m = z.max() ?? 0
        let e = z.map { exp($0 - m) }
        let sum = e.reduce(0, +)
        let probs = e.map { $0 / sum }
        let best = probs.indices.max { probs[$0] < probs[$1] }!
        return Prediction(label: labels[best], probability: probs[best], probabilities: probs)
    }
}
