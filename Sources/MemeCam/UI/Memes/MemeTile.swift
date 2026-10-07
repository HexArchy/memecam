import MemeCamCore
import SwiftUI

/// One meme in the reaction editor, with a hover menu and the same actions in its context menu.
struct MemeTile: View {
    @Environment(AppModel.self) private var model
    let meme: Meme
    @State private var hovering = false

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { MemeThumbnail(url: meme.url, id: meme.id, symbol: meme.reaction.displaySymbol) }
            .clipShape(.rect(cornerRadius: Design.tileRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Design.tileRadius).strokeBorder(.separator)
            }
            .overlay(alignment: .bottomLeading) { badges.padding(5) }
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Menu { actions } label: {
                        Image(systemName: "ellipsis.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.55))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .padding(5)
                    .accessibilityLabel("Actions")
                }
            }
            .contentShape(.rect(cornerRadius: Design.tileRadius))
            .onHover { hovering = $0 }
            .contextMenu { actions }
            .help(meme.title)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(meme.title)
            .accessibilityValue(meme.isCustom ? "Custom meme" : "Built-in meme")
            .accessibilityActions { actions }
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            if meme.isCustom { badge("Yours", symbol: "person.fill") }
            if meme.url.pathExtension.lowercased() == "gif" { badge("GIF", symbol: nil) }
        }
    }

    private func badge(_ text: LocalizedStringKey, symbol: String?) -> some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption2.bold())
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: .capsule)
    }

    @ViewBuilder
    private var actions: some View {
        Button("Preview", systemImage: "play") { model.trigger(meme: meme) }
            .disabled(model.cameraState != .running)
        Menu("Move To") {
            ForEach(Reaction.allCases.filter { $0 != meme.reaction }) { reaction in
                Button(reaction.title, systemImage: reaction.displaySymbol) { model.moveMeme(meme, to: reaction) }
            }
        }
        Divider()
        if meme.isCustom {
            Button("Delete", systemImage: "trash", role: .destructive) { model.removeMeme(meme) }
        } else {
            Button("Hide Built-in Meme", systemImage: "eye.slash") { model.removeMeme(meme) }
        }
    }
}
