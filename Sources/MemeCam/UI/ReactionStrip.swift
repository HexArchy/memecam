import MemeCamCore
import SwiftUI

/// Horizontally scrolling row of every reaction. Teaches what MemeCam recognises,
/// highlights the live one, previews on click and accepts dropped images.
struct ReactionStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(UIState.self) private var ui
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let running = model.cameraState == .running
        let live: Reaction? = running ? model.status.reaction : nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Reactions")
                    .font(.headline)
                Text(running ? "Click one to preview it, or drop images on it to add memes."
                             : "Make a face or a gesture. Drop images on a reaction to add your own.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Button("Customize Memes…", systemImage: "photo.on.rectangle.angled") { ui.editMemes() }
                    .buttonStyle(.borderless)
                    .help("Choose the pictures for each reaction (\u{21E7}\u{2318}E)")
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(Reaction.allCases) { reaction in
                            ReactionCard(reaction: reaction,
                                         thumbnail: model.memes(for: reaction).first,
                                         isLive: live == reaction,
                                         canPreview: running)
                                .id(reaction)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.never)
                .fixedSize(horizontal: false, vertical: true)
                .onHover { hovering = $0 }
                .onChange(of: live) { _, new in
                    guard let new, !hovering else { return }
                    withAnimation(reduceMotion ? nil : .smooth) { proxy.scrollTo(new, anchor: .center) }
                }
            }
        }
    }
}

private struct ReactionCard: View {
    @Environment(AppModel.self) private var model
    @Environment(UIState.self) private var ui
    let reaction: Reaction
    let thumbnail: Meme?
    let isLive: Bool
    let canPreview: Bool
    @State private var isDropTarget = false

    var body: some View {
        Button(action: primaryAction) {
            VStack(spacing: 6) {
                Color.clear
                    .frame(width: 62, height: 62)
                    .overlay { MemeThumbnail(url: thumbnail?.url, id: thumbnail?.id, symbol: reaction.displaySymbol) }
                    .clipShape(.rect(cornerRadius: Design.tileRadius))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: reaction.displaySymbol)
                            .font(.caption.bold())
                            .frame(width: 22, height: 22)
                            .background(.regularMaterial, in: .circle)
                            .padding(3)
                    }
                Text(reaction.title)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 76)
            .padding(6)
            .background(background, in: .rect(cornerRadius: Design.cardRadius))
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
            Button("Preview", systemImage: "play") { model.trigger(reaction) }
                .disabled(!canPreview)
            Button("Edit Memes…", systemImage: "photo.on.rectangle.angled") { ui.editMemes(for: reaction) }
        }
        .help(canPreview ? "Preview \(reaction.title)" : "Edit the memes for \(reaction.title)")
        .accessibilityLabel(reaction.title)
        .accessibilityValue(isLive ? "Current reaction" : "")
        .accessibilityHint(canPreview ? "Shows this reaction's meme for a few seconds" : "Opens the meme editor")
    }

    private var background: AnyShapeStyle {
        isLive ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.quaternary.opacity(0.5))
    }

    private func primaryAction() {
        if canPreview { model.trigger(reaction) } else { ui.editMemes(for: reaction) }
    }
}
