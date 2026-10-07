import MemeCamCore
import SwiftUI

/// Looping "reaction → meme" mini-demo: the reaction symbol morphs while the meme cross-fades.
struct ReactionDemo: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let reactions: [Reaction] = [.smile, .thumbsUp, .surprised, .heart]

    @State private var pairs: [DemoPair] = []
    @State private var index = 0

    var body: some View {
        let current = pairs.isEmpty ? Self.reactions[0] : pairs[index].reaction
        HStack(spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: current.displaySymbol)
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Design.brand)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 52, height: 52)
                    .background(Design.brand.opacity(0.16), in: .circle)
                Text(current.title)
                    .font(.title3.bold())
                    .contentTransition(.opacity)
                    .frame(width: 108, alignment: .leading)
            }
            Image(systemName: "arrow.right")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Design.tertiaryText)
            ZStack {
                ForEach(pairs) { pair in
                    let shown = pair.reaction == current
                    MemeThumbnail(url: pair.meme?.url, id: pair.meme?.id, symbol: pair.reaction.displaySymbol,
                                  maxPixelSize: 200)
                        .opacity(shown ? 1 : 0)
                        .scaleEffect(shown || reduceMotion ? 1 : 0.9)
                }
            }
            .frame(width: 92, height: 92)
            .clipShape(.rect(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.15)) }
            .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .padding(.vertical, 12)
        .glassSurface(in: .rect(cornerRadius: 26))
        .animation(reduceMotion ? .easeInOut(duration: 0.3) : .smooth(duration: 0.45), value: index)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example: a \(current.title.lowercased()) shows a matching meme")
        .task {
            pairs = Self.reactions.map { r in DemoPair(reaction: r, meme: model.memes(for: r).first ?? model.allMemes(for: r).first) }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.6))
                guard !Task.isCancelled, !pairs.isEmpty else { return }
                index = (index + 1) % pairs.count
            }
        }
    }
}

private struct DemoPair: Identifiable {
    let reaction: Reaction
    let meme: Meme?
    var id: Reaction { reaction }
}
