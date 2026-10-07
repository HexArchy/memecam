import MemeCamCore
import SwiftUI

/// Current reaction with a confidence meter, floating over the preview; a "Paused" badge
/// while memes are paused (detection keeps running, nothing pops up).
struct ReactionChip: View {
    let reaction: Reaction
    let confidence: Double
    var paused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: reaction.displaySymbol)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 42, height: 42)
                .background(.tint.opacity(0.2), in: .circle)
            VStack(alignment: .leading, spacing: 5) {
                Text(reaction.title)
                    .font(.title3.bold())
                    .contentTransition(.interpolate)
                HStack(spacing: 8) {
                    ConfidenceMeter(value: confidence)
                        .frame(width: 84, height: 5)
                    Text(confidence, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if paused {
                PausedBadge()
                    .transition(.opacity.combined(with: .scale(0.8)))
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 18)
        .padding(.vertical, 7)
        .glassSurface(in: .capsule)
        .animation(reduceMotion ? nil : .snappy, value: reaction)
        .animation(reduceMotion ? nil : .snappy, value: paused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(paused ? "Memes paused. Current reaction: \(reaction.title)"
                                   : "Current reaction: \(reaction.title)")
        .accessibilityValue("Confidence \(Int(confidence * 100)) percent")
    }
}

private struct PausedBadge: View {
    var body: some View {
        Label("Paused", systemImage: "pause.fill")
            .font(.callout.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.orange, in: .capsule)
            .help("Memes are paused — the camera goes out plain. \u{2303}\u{2325}P resumes.")
    }
}

struct ConfidenceMeter: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.15))
                Capsule().fill(.tint)
                    .frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .animation(.linear(duration: 0.12), value: value)
        .accessibilityHidden(true)
    }
}
