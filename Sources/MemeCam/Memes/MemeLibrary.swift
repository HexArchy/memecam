import AppKit
import CoreGraphics
import ImageIO
import MemeCamCore

enum Animal: String, Codable, CaseIterable, Identifiable, Sendable {
    case cat, hamster
    /// User-added picture of anything; shown regardless of the animal filter.
    case other
    var id: String { rawValue }
}

enum AnimalFilter: String, CaseIterable, Identifiable, Sendable {
    case both, cats, hamsters
    var id: String { rawValue }
    var title: String {
        switch self {
        case .both: String(localized: "Both")
        case .cats: String(localized: "Cats")
        case .hamsters: String(localized: "Hamsters")
        }
    }
    func allows(_ a: Animal) -> Bool {
        switch self {
        case .both: true
        case .cats: a == .cat || a == .other
        case .hamsters: a == .hamster || a == .other
        }
    }
}

struct Meme: Identifiable, Hashable, Sendable {
    let id: String          // file name; "user/<name>" for user-added memes
    let url: URL
    let reaction: Reaction
    let animal: Animal
    let title: String
    var isCustom: Bool { id.hasPrefix("user/") }
}

/// Decoded meme frames, ready for Core Image compositing. Static images have one frame.
/// Immutable after init, hence safe to share between the pipeline queues.
final class AnimatedImage: @unchecked Sendable {
    /// Longer animations are subsampled evenly (timing kept) so one huge GIF can't take hundreds of MB:
    /// 120 frames at 540 px are at most ~140 MB, typical memes far less.
    static let maxFrames = 120
    /// Source frames whose delays are read at all; beyond this the GIF is treated as truncated.
    private static let maxSourceFrames = 5_000

    let frames: [CGImage]
    /// Cumulative end time of each frame, seconds.
    private let ends: [Double]
    let duration: Double
    /// Estimated decoded size (width × height × 4 bytes per frame), used by the cache's byte budget.
    let byteCost: Int

    init?(url: URL, maxPixelSize: Int = 540) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = min(CGImageSourceGetCount(src), Self.maxSourceFrames)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        // Reading delays is cheap (metadata only); only the picked frames are decoded.
        let picks = FrameSampling.plan(delays: (0..<count).map { Self.delay(src, $0) }, maxFrames: Self.maxFrames)
        var frames: [CGImage] = [], ends: [Double] = [], t = 0.0, bytes = 0
        for pick in picks {
            t += pick.duration
            guard let img = CGImageSourceCreateThumbnailAtIndex(src, pick.index, opts as CFDictionary) else {
                // Undecodable frame: the previous one stays up for its time instead.
                if !ends.isEmpty { ends[ends.count - 1] = t }
                continue
            }
            frames.append(img)
            ends.append(t)
            bytes += img.width * img.height * 4
        }
        guard !frames.isEmpty else { return nil }
        self.frames = frames
        self.ends = ends
        self.duration = t
        self.byteCost = bytes
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

/// Bundled memes (`memes.json`) merged with the user's own library in
/// ~/Library/Application Support/MemeCam/Memes (`user.json`: added memes + hidden bundled ones).
/// Thread-safe: read from the pipeline queues, mutated from the UI.
final class MemeLibrary: @unchecked Sendable {
    private struct Entry: Codable {
        let file: String
        let category: String
        let animal: Animal
        let title: String?
    }
    private struct Manifest: Decodable { let memes: [Entry] }
    private struct UserManifest: Codable {
        var added: [Entry] = []
        var hidden: [String] = []
    }

    let directory: URL?
    let userDirectory: URL
    private let lock = NSLock()
    private var bundled: [Meme] = []
    private var user = UserManifest()
    private var all: [Meme] = []
    private var byReaction: [Reaction: [Meme]] = [:]
    /// Decoded memes by id, bounded by bytes (8 GB Macs): a few large GIFs or many small stills.
    private var cache = CostLRUCache<String, AnimatedImage>(budget: MemeLibrary.cacheBudgetBytes)
    private var lastPicked: [Reaction: String] = [:]

    static let cacheBudgetBytes = 150 * 1024 * 1024
    static let supportedTypes = ["gif", "png", "jpg", "jpeg", "heic", "webp", "tiff", "bmp"]

    var memes: [Meme] { lock.withLock { all } }

    init() {
        let dir = Self.locateDirectory()
        directory = dir
        userDirectory = URL.applicationSupportDirectory.appending(path: "MemeCam/Memes")
        if let dir, let data = try? Data(contentsOf: dir.appending(path: "memes.json")),
           let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
            bundled = manifest.memes.compactMap { e in
                guard let r = Reaction(rawValue: e.category) else { return nil }
                let url = dir.appending(path: e.file)
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return Meme(id: e.file, url: url, reaction: r, animal: e.animal, title: e.title ?? r.title)
            }
        }
        if let data = try? Data(contentsOf: userDirectory.appending(path: "user.json")),
           var manifest = try? JSONDecoder().decode(UserManifest.self, from: data) {
            // A tampered or corrupted manifest must never point outside the library (see `userFileURL`).
            manifest.added.removeAll { !LibraryPaths.isSafeFileName($0.file) }
            user = manifest
        }
        rebuild()
    }

    // MARK: Customisation

    /// Copies an image/GIF into the user library and assigns it to `reaction`.
    @discardableResult
    func add(fileAt source: URL, to reaction: Reaction, animal: Animal = .other) throws -> Meme {
        let ext = source.pathExtension.lowercased()
        guard Self.supportedTypes.contains(ext),
              let src = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(src) > 0
        else { throw LibraryError.notAnImage(source.lastPathComponent) }
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        let name = "\(reaction.rawValue)-\(UUID().uuidString.prefix(8)).\(ext)"
        try FileManager.default.copyItem(at: source, to: userDirectory.appending(path: name))
        let title = source.deletingPathExtension().lastPathComponent
        lock.withLock {
            user.added.append(Entry(file: name, category: reaction.rawValue, animal: animal, title: title))
        }
        try save()
        return memes.first { $0.id == "user/\(name)" }!
    }

    /// The file of a user meme, or nil unless it is a plain file name that resolves inside `userDirectory`.
    /// Every file operation on user memes goes through this, so nothing outside the library is touched.
    private func userFileURL(_ name: String) -> URL? {
        guard LibraryPaths.isSafeFileName(name) else { return nil }
        let url = userDirectory.appending(path: name)
        return LibraryPaths.isContained(url, in: userDirectory) ? url : nil
    }

    /// User memes are deleted; bundled ones are hidden (restorable).
    func remove(_ meme: Meme) throws {
        if meme.isCustom {
            let name = String(meme.id.dropFirst("user/".count))
            if let url = userFileURL(name) { try? FileManager.default.removeItem(at: url) }
            lock.withLock { user.added.removeAll { $0.file == name } }
        } else {
            lock.withLock { if !user.hidden.contains(meme.id) { user.hidden.append(meme.id) } }
        }
        try save()
    }

    /// Moves a meme to another reaction (bundled memes are copied into the user library).
    func reassign(_ meme: Meme, to reaction: Reaction) throws {
        if meme.isCustom {
            let name = String(meme.id.dropFirst("user/".count))
            guard userFileURL(name) != nil else { return }
            lock.withLock {
                if let i = user.added.firstIndex(where: { $0.file == name }) {
                    let e = user.added[i]
                    user.added[i] = Entry(file: e.file, category: reaction.rawValue, animal: e.animal, title: e.title)
                }
            }
            try save()
        } else {
            try add(fileAt: meme.url, to: reaction, animal: meme.animal)
            try remove(meme)
        }
    }

    /// Bundled memes hidden for this reaction (for a "Restore defaults" button).
    func hiddenCount(for r: Reaction) -> Int {
        lock.withLock { bundled.filter { $0.reaction == r && user.hidden.contains($0.id) }.count }
    }

    func restoreDefaults(for r: Reaction) throws {
        lock.withLock {
            let ids = Set(bundled.filter { $0.reaction == r }.map(\.id))
            user.hidden.removeAll { ids.contains($0) }
        }
        try save()
    }

    private func save() throws {
        let data = lock.withLock { try? JSONEncoder().encode(user) }
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        try data?.write(to: userDirectory.appending(path: "user.json"), options: .atomic)
        rebuild()
    }

    private func rebuild() {
        lock.withLock {
            let hidden = Set(user.hidden)
            let custom: [Meme] = user.added.compactMap { e in
                guard let r = Reaction(rawValue: e.category), let url = userFileURL(e.file) else { return nil }
                return Meme(id: "user/\(e.file)", url: url, reaction: r,
                            animal: e.animal, title: e.title ?? r.title)
            }
            // User memes first: they are what people expect to see.
            all = custom + bundled.filter { !hidden.contains($0.id) }
            byReaction = Dictionary(grouping: all, by: \.reaction)
        }
    }

    enum LibraryError: LocalizedError {
        case notAnImage(String)
        var errorDescription: String? {
            switch self {
            case .notAnImage(let name): String(localized: "“\(name)” isn't an image or GIF MemeCam can use.")
            }
        }
    }

    /// Bundled app: Contents/Resources/Memes. `swift run`: ./Resources/Memes.
    private static func locateDirectory() -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appending(path: "Memes"),
            URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "Resources/Memes"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appending(path: "memes.json").path) }
    }

    func memes(for r: Reaction, filter: AnimalFilter = .both) -> [Meme] {
        lock.withLock { byReaction[r] ?? [] }.filter { filter.allows($0.animal) }
    }

    /// Picks a meme for the reaction, rotating so the same one is not repeated back-to-back.
    /// Falls back to the other animal; nil when the reaction has no memes (it is then not shown).
    func pick(for r: Reaction, filter: AnimalFilter) -> Meme? {
        var pool = memes(for: r, filter: filter)
        if pool.isEmpty { pool = memes(for: r) }   // other animal rather than nothing
        // No memes at all (the user removed them all): the reaction is effectively switched off.
        guard !pool.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        let last = lastPicked[r]
        let choice = pool.count > 1 ? pool.filter { $0.id != last }.randomElement()! : pool[0]
        lastPicked[r] = choice.id
        return choice
    }

    func image(for meme: Meme) -> AnimatedImage? {
        if let hit = lock.withLock({ cache.value(for: meme.id) }) { return hit }
        // Decode outside the lock. Two concurrent decodes of one meme just replace each other's entry.
        guard let img = AnimatedImage(url: meme.url) else { return nil }
        lock.withLock { cache.insert(img, cost: img.byteCost, for: meme.id) }
        return img
    }

    /// Non-blocking cache lookup (a hit counts as a use for the LRU order).
    func cachedImage(for meme: Meme) -> AnimatedImage? {
        lock.withLock { cache.value(for: meme.id) }
    }

    /// Decodes a meme off the main thread ahead of time so switching is instant.
    func prefetch(_ memes: [Meme]) {
        DispatchQueue.global(qos: .utility).async { [self] in
            for m in memes { _ = image(for: m) }
        }
    }
}
