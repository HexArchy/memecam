import MemeCamCore
import SwiftUI

/// "Memes" inspector tab: reaction grid → per-reaction editor.
struct MemeLibraryView: View {
    @Environment(UIState.self) private var ui
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let reaction = ui.editingReaction {
                MemeReactionDetail(reaction: reaction)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                MemeReactionGrid()
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: ui.editingReaction)
    }
}

/// Every reaction as a fixed square tile with its meme count; drop images on a tile to add them.
private struct MemeReactionGrid: View {
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.adaptive(minimum: 88), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Pick a reaction to choose its pictures. You can also drop images or GIFs from Finder onto a reaction.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                section("Expressions", reactions: Reaction.allCases.filter { !$0.isGesture })
                section("Gestures", reactions: Reaction.allCases.filter(\.isGesture))

                Button("Show Custom Memes in Finder", systemImage: "folder") { model.revealUserMemesFolder() }
                    .buttonStyle(.link)
            }
            .padding(14)
        }
    }

    private func section(_ title: String, reactions: [Reaction]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(reactions) { reaction in
                    ReactionTile(reaction: reaction, memes: model.allMemes(for: reaction),
                                 isLive: model.cameraState == .running && model.status.reaction == reaction,
                                 isOff: model.disabledReactions.contains(reaction))
                }
            }
        }
    }
}

private struct ReactionTile: View {
    @Environment(AppModel.self) private var model
    @Environment(UIState.self) private var ui
    let reaction: Reaction
    let memes: [Meme]
    let isLive: Bool
    let isOff: Bool
    @State private var isDropTarget = false

    var body: some View {
        Button { ui.editingReaction = reaction } label: {
            VStack(spacing: 6) {
                // Square sized by the column only; the image never affects layout.
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { MemeThumbnail(url: memes.first?.url, id: memes.first?.id, symbol: reaction.displaySymbol) }
                    .clipShape(.rect(cornerRadius: Design.tileRadius))
                    .reactionOff(isOff)
                    .overlay(alignment: .topTrailing) {
                        Text(memes.count, format: .number)
                            .font(.caption.bold().monospacedDigit())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.regularMaterial, in: .capsule)
                            .padding(5)
                    }
                Label(reaction.title, systemImage: reaction.displaySymbol)
                    .font(.caption)
                    .labelStyle(.titleOnly)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
            }
            .padding(6)
            .frame(maxWidth: .infinity)
            .background(isLive ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                        in: .rect(cornerRadius: Design.cardRadius))
            .overlay {
                if isLive || isDropTarget {
                    RoundedRectangle(cornerRadius: Design.cardRadius)
                        .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: isDropTarget ? [5, 3] : []))
                }
            }
            .contentShape(.rect(cornerRadius: Design.cardRadius))
        }
        .buttonStyle(.plain)
        .dropDestination(for: URL.self) { urls, _ in
            let images = urls.filter(\.isSupportedMemeFile)
            guard !images.isEmpty else { return false }
            model.addMemes(images, to: reaction)
            return true
        } isTargeted: { isDropTarget = $0 }
        .contextMenu {
            Button("Edit Memes…", systemImage: "photo.on.rectangle.angled") { ui.editingReaction = reaction }
            ReactionSwitchMenuItem(reaction: reaction)
        }
        .help("Edit the memes for \(reaction.title)")
        .accessibilityLabel(reaction.title)
        .accessibilityValue(isOff ? "Off, \(memes.count) memes" : "\(memes.count) memes")
        .accessibilityHint("Opens the memes for this reaction")
    }
}
