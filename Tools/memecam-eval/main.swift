// Analyses a guided recording: per labelled reaction, prints how often a face / hands were
// seen, the distribution of expression scores (relative to the auto-calibrated baseline) and
// hand-shape features, then the evaluator report.
import Foundation
import CoreGraphics
import MemeCamCore

extension CGPoint { func distance(to p: CGPoint) -> Double { Double(hypot(x - p.x, y - p.y)) } }

guard CommandLine.arguments.count > 1 else {
    print("usage: memecam-eval <recording.json>")
    exit(1)
}
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
let rec = try decoder.decode(Recording.self, from: Data(contentsOf: URL(filePath: CommandLine.arguments[1])))

func pct(_ v: [Double], _ p: Double) -> Double {
    guard !v.isEmpty else { return .nan }
    let s = v.sorted()
    return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
}
func row(_ name: String, _ v: [Double]) -> String {
    String(format: "%@ p10 %6.2f  p50 %6.2f  p90 %6.2f", name.padding(toLength: 7, withPad: " ", startingAt: 0),
           pct(v, 0.1), pct(v, 0.5), pct(v, 0.9))
}

// Replay once to get the classifier's baseline after calibration, then score every frame with it.
var classifier = ReactionClassifier()
var perLabel: [Reaction: [(FrameObservation, ReactionClassifier.ExpressionScores?, Reaction)]] = [:]
for f in rec.frames {
    let est = classifier.classify(f.observation)
    guard let label = f.label else { continue }
    let m = f.observation.face.flatMap(FaceMetrics.init)
    perLabel[label, default: []].append((f.observation, m.map { classifier.scores($0) }, est.reaction))
}
print("Baseline:", classifier.baseline, "calibration:", classifier.calibration, "\n")

for label in Reaction.allCases {
    guard let frames = perLabel[label] else { continue }
    let n = Double(frames.count)
    let faces = frames.filter { $0.0.face != nil }.count
    let hands = frames.map { Double($0.0.hands.count) }
    let predicted = Dictionary(grouping: frames, by: \.2).mapValues(\.count).sorted { $0.value > $1.value }.prefix(3)
    print("== \(label.title) (\(frames.count) frames) face \(Int(Double(faces) / n * 100))%  hands avg \(String(format: "%.2f", hands.reduce(0, +) / n))")
    print("   predicted:", predicted.map { "\($0.key.title) \($0.value)" }.joined(separator: ", "))
    let sc = frames.compactMap(\.1)
    if !sc.isEmpty {
        for (name, kp) in [("open", \ReactionClassifier.ExpressionScores.open), ("smile", \.smile), ("eyesCl", \.eyesClosed),
                           ("brows", \.brows), ("sad", \.sad), ("au1", \.au1), ("au4", \.au4), ("tilt", \.tilt)] {
            print("   " + row(name, sc.map { $0[keyPath: kp] }))
        }
        let yaw = frames.compactMap { $0.0.face.map { abs($0.yaw) } }, pitch = frames.compactMap { $0.0.face.map { abs($0.pitch) } }
        print("   " + row("|yaw|", yaw) + "   " + row("|pitch|", pitch))
    }
    let shapes = frames.flatMap { f in f.0.hands.compactMap { h in HandShape(h).map { (h, $0) } } }
    if !shapes.isEmpty {
        let conf = shapes.map { $0.0.confidence }, palm = shapes.map(\.1.palmSize)
        let ext = shapes.map { Double($0.1.extendedCount) }, tv = shapes.map(\.1.thumbVertical)
        let te = shapes.map { $0.1.thumbExtended ? 1.0 : 0 }
        let g = Dictionary(grouping: shapes.map { $0.1.gesture(for: $0.0).map(\.rawValue) ?? "none" }, by: { $0 })
            .mapValues(\.count).sorted { $0.value > $1.value }.prefix(4)
        print("   " + row("conf", conf) + "   " + row("palm", palm))
        print("   " + row("ext", ext) + "   " + row("thumbV", tv) + String(format: "  thumbExt %.0f%%", te.reduce(0, +) / Double(te.count) * 100))
        let fingers = (0..<4).map { i in shapes.filter { $0.1.fingersExtended[i] }.count * 100 / shapes.count }
        print("   fingers ext% idx/mid/ring/little:", fingers, "  shapes:", g.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        // Per-finger raw ratios: tip-wrist / pip-wrist, and mcp-tip / palm.
        let chains: [(HandJoint, HandJoint, HandJoint)] = [(.indexMCP, .indexPIP, .indexTip), (.middleMCP, .middlePIP, .middleTip),
                                                          (.ringMCP, .ringPIP, .ringTip), (.littleMCP, .littlePIP, .littleTip)]
        var line = "   finger ratio p50 (far/len):"
        for (m, pp, t) in chains {
            var far: [Double] = [], len: [Double] = []
            for (h, sh) in shapes {
                guard let w = h[.wrist], let mm = h[m], let ppp = h[pp], let tt = h[t] else { continue }
                far.append(w.distance(to: tt) / max(w.distance(to: ppp), 1e-6)); len.append(mm.distance(to: tt) / sh.palmSize)
            }
            line += String(format: " %.2f/%.2f", pct(far, 0.5), pct(len, 0.5))
        }
        print(line)
        let joints = frames.flatMap(\.0.hands).map { Double($0.joints.count) }
        print("   " + row("joints", joints) + "   raw hands \(frames.flatMap(\.0.hands).count) → shaped \(shapes.count)")
        if let face = frames.first(where: { $0.0.face != nil })?.0.face?.boundingBox {
            let cy = shapes.map { Double($0.0.center.y) }
            print("   " + row("handY", cy) + String(format: "   face y %.2f…%.2f h %.2f", face.minY, face.maxY, face.height))
        }
    }
}
print("\n" + Evaluator().evaluate(rec).summary)
