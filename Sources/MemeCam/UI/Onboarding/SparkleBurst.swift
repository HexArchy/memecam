import SwiftUI

/// A one-shot ring of tiny SF Symbols that flies outward each time `trigger` changes.
/// Renders nothing under Reduce Motion.
struct SparkleBurst: View {
    let trigger: Int
    var radius: CGFloat = 120

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let count = 14
    private static let symbols = ["sparkle", "star.fill", "circle.fill", "heart.fill", "sparkle", "star.fill", "circle.fill"]
    private static let colors: [Color] = [Design.brand, Design.brandSecondary, Color(red: 1, green: 0.38, blue: 0.56),
                                          OnboardingStyle.success]

    var body: some View {
        if !reduceMotion {
            ZStack {
                ForEach(0..<Self.count, id: \.self) { i in
                    particle(i)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func particle(_ i: Int) -> some View {
        let angle = Double(i) / Double(Self.count) * 2 * .pi + (i.isMultiple(of: 2) ? 0.18 : -0.12)
        let reach = radius * (i.isMultiple(of: 3) ? 1.0 : 0.78)
        return Image(systemName: Self.symbols[i % Self.symbols.count])
            .font(.system(size: i.isMultiple(of: 3) ? 15 : 10, weight: .bold))
            .foregroundStyle(Self.colors[i % Self.colors.count])
            .keyframeAnimator(initialValue: 0.0, trigger: trigger) { content, t in
                content
                    .offset(x: cos(angle) * reach * t, y: sin(angle) * reach * t - 18 * t * t)
                    .scaleEffect(0.4 + 0.8 * t - 0.4 * t * t)
                    .rotationEffect(.degrees(t * 120))
                    .opacity(t <= 0 || t >= 1 ? 0 : 1 - t * t)
            } keyframes: { _ in
                CubicKeyframe(1, duration: 0.95, startVelocity: 3, endVelocity: 0)
            }
    }
}
