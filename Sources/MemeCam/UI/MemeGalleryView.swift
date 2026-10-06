import ImageIO
import MemeCamCore
import SwiftUI

/// Grid of every reaction with its first meme; click to preview it in the output.
struct MemeGalleryView: View {
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Reaction.allCases) { reaction in
                    GalleryCell(reaction: reaction,
                                memes: model.memes(for: reaction),
                                isCurrent: model.status.reaction == reaction)
                }
            }
            .padding(12)
        }
    }
}

private struct GalleryCell: View {
    @Environment(AppModel.self) private var model
    let reaction: Reaction
    let memes: [Meme]
    let isCurrent: Bool

    var body: some View {
        Button { model.trigger(reaction) } label: {
            VStack(spacing: 6) {
                // Square sized by the column only; the image never affects layout.
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { MemeThumbnail(url: memes.first?.url, symbol: reaction.symbol) }
                    .clipShape(.rect(cornerRadius: 10))
                    .overlay(alignment: .topTrailing) {
                        if memes.count > 1 {
                            Text("\(memes.count)")
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.regularMaterial, in: .capsule)
                                .padding(5)
                        }
                    }
                Text(reaction.title)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
            }
            .padding(6)
            .frame(maxWidth: .infinity)
            .background(isCurrent ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.4)),
                        in: .rect(cornerRadius: 14))
            .overlay {
                if isCurrent { RoundedRectangle(cornerRadius: 14).strokeBorder(.tint, lineWidth: 2) }
            }
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(memes.isEmpty)
        .opacity(memes.isEmpty ? 0.4 : 1)
        .help(memes.isEmpty ? "No memes for \(reaction.title)" : "Show \(reaction.title) meme")
        .accessibilityLabel(reaction.title)
        .accessibilityValue("\(memes.count) memes")
    }
}

private struct MemeThumbnail: View {
    let url: URL?
    let symbol: String
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Color.clear.overlay {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
            } else {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await Self.load(url)
        }
    }

    /// Decodes a small first-frame thumbnail off the main actor.
    private nonisolated static func load(_ url: URL) async -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
