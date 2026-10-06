import MemeCamCore
import SwiftUI

/// Current reaction + a tiny confidence meter, floating over the preview.
struct ReactionChip: View {
    let reaction: Reaction
    let confidence: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: reaction.symbol)
                .font(.title3)
                .frame(width: 26)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 4) {
                Text(reaction.title)
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.interpolate)
                ConfidenceMeter(value: confidence)
                    .frame(width: 56, height: 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassSurface(in: .capsule)
        .animation(reduceMotion ? nil : .snappy, value: reaction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Current reaction: \(reaction.title)")
        .accessibilityValue("Confidence \(Int(confidence * 100)) percent")
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
