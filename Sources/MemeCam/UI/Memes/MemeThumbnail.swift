import ImageIO
import SwiftUI
import UniformTypeIdentifiers

extension URL {
    /// Image/GIF types the meme library accepts (drag & drop filter).
    var isSupportedMemeFile: Bool { isFileURL && MemeLibrary.supportedTypes.contains(pathExtension.lowercased()) }
}

extension UTType {
    /// Types offered in the "Add…" panel.
    static let memeImports: [UTType] = [.image, .gif]
}

/// Square-filling, clipped first-frame thumbnail. Never affects its container's layout.
struct MemeThumbnail: View {
    let url: URL?
    /// Stable identity (meme id) so the image reloads when the library changes.
    let id: String?
    let symbol: String
    var maxPixelSize = 240

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
                    .foregroundStyle(Design.secondaryText)
            }
        }
        .clipped()
        .task(id: id) {
            guard let url else { image = nil; return }
            let key = "\(url.path)#\(maxPixelSize)" as NSString
            if let hit = ThumbnailCache.shared.object(forKey: key) { image = hit; return }
            let loaded = await Self.load(url, maxPixelSize: maxPixelSize)
            if let loaded { ThumbnailCache.shared.setObject(loaded, forKey: key) }
            image = loaded
        }
    }

    /// Decodes a small first-frame thumbnail off the main actor.
    private nonisolated static func load(_ url: URL, maxPixelSize: Int) async -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

/// Small bounded in-memory cache of decoded thumbnails (main actor only).
@MainActor
enum ThumbnailCache {
    static let shared: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 400
        return cache
    }()
}
