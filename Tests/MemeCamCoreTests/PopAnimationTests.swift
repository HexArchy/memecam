import Foundation
import Testing
@testable import MemeCamCore

private func samples(_ f: (Double) -> Double, n: Int = 1000) -> [Double] {
    (0...n).map { f(Double($0) / Double(n)) }
}

@Test func springStartsAtZeroOvershootsAndSettles() {
    #expect(PopAnimation.spring(0) == 0)
    #expect(PopAnimation.spring(1) == 1)
    #expect(PopAnimation.spring(-1) == 0)
    #expect(PopAnimation.spring(2) == 1)
    let v = samples { PopAnimation.spring($0) }
    let peak = v.max()!
    #expect(peak > 1.06 && peak < 1.10, "peak \(peak)")
    // First peak around t = 0.4.
    let peakT = Double(v.firstIndex(of: peak)!) / 1000
    #expect(abs(peakT - 0.4) < 0.05, "peak at \(peakT)")
    // Settled: within 1 % for the last 15 % of the animation.
    for (i, x) in v.enumerated() where i >= 850 { #expect(abs(x - 1) < 0.01, "t=\(Double(i) / 1000): \(x)") }
    // Continuous: no frame-to-frame jumps.
    for i in 1..<v.count { #expect(abs(v[i] - v[i - 1]) < 0.02) }
}

@Test func popScaleGoesFromPointSixThroughOneOhEightToOne() {
    let poses = (0...1000).map { PopAnimation.pose(.pop, progress: Double($0) / 1000, appearing: true) }
    #expect(abs(poses.first!.scale - 0.6) < 1e-9)
    #expect(abs(poses.first!.rotation + 6) < 1e-9)
    #expect(poses.first!.opacity == 0)
    let peak = poses.map(\.scale).max()!
    #expect(abs(peak - 1.08) < 0.01, "peak scale \(peak)")
    #expect(poses.last! == .rest)
}

@Test func posesEndAtRestOrHidden() {
    for style in PopStyle.allCases {
        let shown = PopAnimation.pose(style, progress: 1, appearing: true)
        #expect(shown == .rest, "\(style) appear end \(shown)")
        let start = PopAnimation.pose(style, progress: 0, appearing: false)
        #expect(start == .rest, "\(style) disappear start \(start)")
        let gone = PopAnimation.pose(style, progress: 1, appearing: false)
        #expect(gone.opacity == 0 || gone.travel == 1, "\(style) disappear end \(gone)")
        #expect(PopAnimation.duration(style, appearing: true) > 0)
        #expect(PopAnimation.duration(style, appearing: false) > 0)
    }
}

@Test func slideEasesOutOnEnter() {
    let a = PopAnimation.pose(.slide, progress: 0, appearing: true).travel
    let b = PopAnimation.pose(.slide, progress: 0.3, appearing: true).travel
    #expect(a == 1)
    // Ease-out: most of the distance is covered early.
    #expect(b < 0.4)
}
