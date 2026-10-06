import AppKit
import CoreGraphics
import ImageIO
import MemeCamCore

enum Animal: String, Codable, CaseIterable, Identifiable, Sendable {
    case cat, hamster
    var id: String { rawValue }
}

enum AnimalFilter: String, CaseIterable, Identifiable, Sendable {
    case both, cats, hamsters
    var id: String { rawValue }
    var title: String {
        switch self {
        case .both: "Both"
        case .cats: "Cats"
        case .hamsters: "Hamsters"
        }
    }
    func allows(_ a: Animal) -> Bool {
        switch self {
        case .both: true
        case .cats: a == .cat
        case .hamsters: a == .hamster
        }
    }
}

struct Meme: Identifiable, Hashable, Sendable {
    let id: String          // file name
    let url: URL
    let reaction: Reaction
    let animal: Animal
    let title: String
}

/// Decoded meme frames, ready for Core Image compositing. Static images have one frame.
final class AnimatedImage: @unchecked Sendable {
    let frames: [CGImage]
    /// Cumulative end time of each frame, seconds.
    private let ends: [Double]
    let duration: Double

    init?(url: URL, maxPixelSize: Int = 540) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        var frames: [CGImage] = [], ends: [Double] = [], t = 0.0
        for i in 0..<min(count, 400) {
            guard let img = CGImageSourceCreateThumbnailAtIndex(src, i, opts as CFDictionary) else { continue }
            frames.append(img)
            t += Self.delay(src, i)
            ends.append(t)
        }
        guard !frames.isEmpty else { return nil }
        self.frames = frames
        self.ends = ends
        self.duration = t
    }

    func frame(at time: Double) -> CGImage {
        guard frames.count > 1, duration > 0 else { return frames[0] }
        let t = time.truncatingRemainder(dividingBy: duration)
        // Frame counts are small; linear scan is fine and branch-predictable.
        let i = ends.firstIndex { $0 > t } ?? frames.count - 1
        return frames[i]
    }

    private static func delay(_ src: CGImageSource, _ i: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] else { return 0.1 }
        let dict = (props[kCGImagePropertyGIFDictionary] ?? props[kCGImagePropertyPNGDictionary]
            ?? props[kCGImagePropertyWebPDictionary]) as? [CFString: Any]
        let d = (dict?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (dict?[kCGImagePropertyGIFDelayTime] as? Double)
            ?? (dict?[kCGImagePropertyAPNGUnclampedDelayTime] as? Double)
            ?? 0.1
        return d < 0.02 ? 0.1 : d // browsers treat tiny delays as 100 ms
    }
}

/// Loads `memes.json`, decodes lazily and keeps a small LRU of decoded memes.
final class MemeLibrary: @unchecked Sendable {
    private struct Manifest: Decodable {
        struct Entry: Decodable {
            let file: String
            let category: String
            let animal: Animal
            let title: String?
        }
        let memes: [Entry]
    }

    let directory: URL?
    let memes: [Meme]
    private let byReaction: [Reaction: [Meme]]
    private let lock = NSLock()
    private var cache: [String: AnimatedImage] = [:]
    private var cacheOrder: [String] = []
    private var lastPicked: [Reaction: String] = [:]

    init() {
        let dir = Self.locateDirectory()
        directory = dir
        var list: [Meme] = []
        if let dir, let data = try? Data(contentsOf: dir.appending(path: "memes.json")),
           let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
            for e in manifest.memes {
                guard let r = Reaction(rawValue: e.category) else { continue }
                let url = dir.appending(path: e.file)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                list.append(Meme(id: e.file, url: url, reaction: r, animal: e.animal,
                                 title: e.title ?? r.title))
            }
        }
        memes = list
        byReaction = Dictionary(grouping: list, by: \.reaction)
    }

    /// Bundled app: Contents/Resources/Memes. `swift run`: ./Resources/Memes.
    private static func locateDirectory() -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appending(path: "Memes"),
            URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "Resources/Memes"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appending(path: "memes.json").path) }
    }

    /// Closest reaction in meaning, used when a category has no memes yet.
    private static let fallback: [Reaction: Reaction] = [
        .laugh: .smile, .smile: .neutral,
        .thumbsDown: .sad, .facepalm: .sad, .sad: .neutral,
        .handsUp: .surprised, .surprised: .eyebrowsRaised,
        .headTilt: .eyebrowsRaised, .eyebrowsRaised: .neutral,
        .pointing: .thumbsUp, .peace: .thumbsUp, .thumbsUp: .smile,
        .openPalm: .peace, .heart: .smile, .thinking: .eyebrowsRaised,
        .fist: .neutral, .eyesClosed: .noFace, .noFace: .neutral,
    ]

    func memes(for r: Reaction, filter: AnimalFilter = .both) -> [Meme] {
        (byReaction[r] ?? []).filter { filter.allows($0.animal) }
    }

    /// Picks a meme for the reaction, rotating so the same one is not repeated back-to-back.
    /// Falls back to the other animal, then to `neutral`.
    func pick(for r: Reaction, filter: AnimalFilter) -> Meme? {
        var pool = memes(for: r, filter: filter)
        if pool.isEmpty { pool = memes(for: r) }
        if pool.isEmpty, r != .neutral { return pick(for: Self.fallback[r] ?? .neutral, filter: filter) }
        guard !pool.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        let last = lastPicked[r]
        let choice = pool.count > 1 ? pool.filter { $0.id != last }.randomElement()! : pool[0]
        lastPicked[r] = choice.id
        return choice
    }

    func image(for meme: Meme) -> AnimatedImage? {
        lock.lock()
        if let hit = cache[meme.id] { lock.unlock(); return hit }
        lock.unlock()
        guard let img = AnimatedImage(url: meme.url) else { return nil }
        lock.lock(); defer { lock.unlock() }
        cache[meme.id] = img
        cacheOrder.append(meme.id)
        if cacheOrder.count > 8 { cache[cacheOrder.removeFirst()] = nil } // bound memory (8 GB Mac)
        return img
    }

    /// Non-blocking cache lookup.
    func cachedImage(for meme: Meme) -> AnimatedImage? {
        lock.withLock { cache[meme.id] }
    }

    /// Decodes a meme off the main thread ahead of time so switching is instant.
    func prefetch(_ memes: [Meme]) {
        DispatchQueue.global(qos: .utility).async { [self] in
            for m in memes { _ = image(for: m) }
        }
    }
}
