import Foundation

/// Path rules for the user meme library (`~/Library/Application Support/MemeCam/Memes`).
public enum LibraryPaths {
    /// A manifest entry must name a plain file directly inside the library: no path separators,
    /// no `..`, no hidden or empty names. Anything else (a tampered or corrupted `user.json`) is rejected.
    public static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty
            && !name.hasPrefix(".")
            && !name.contains("/")
            && !name.contains("\\")
            && !name.contains(":")
            && !name.contains("..")
            && !name.contains("\0")
            && name == (name as NSString).lastPathComponent
    }

    /// True when `url`, after standardizing and resolving symlinks, lies strictly inside `directory`.
    public static func isContained(_ url: URL, in directory: URL) -> Bool {
        let dir = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = dir.hasSuffix("/") ? dir : dir + "/"
        return path.hasPrefix(prefix) && path.count > prefix.count
    }
}

/// Which frames of a long animation to decode, so a huge GIF can't take hundreds of MB.
public enum FrameSampling {
    /// A frame to decode and how long it stays on screen.
    public struct Pick: Equatable, Sendable {
        public let index: Int
        public let duration: Double
        public init(index: Int, duration: Double) {
            self.index = index
            self.duration = duration
        }
    }

    /// Keeps at most `maxFrames` frames spread evenly over the animation. Each kept frame absorbs the
    /// delays of the frames dropped after it, so the total duration (and the playback speed) is unchanged.
    public static func plan(delays: [Double], maxFrames: Int) -> [Pick] {
        let count = delays.count
        guard count > 0, maxFrames > 0 else { return [] }
        guard count > maxFrames else {
            return delays.enumerated().map { Pick(index: $0.offset, duration: $0.element) }
        }
        // Evenly spaced, strictly increasing indices starting at 0.
        let kept = (0..<maxFrames).map { $0 * count / maxFrames }
        return kept.enumerated().map { i, start in
            let end = i + 1 < kept.count ? kept[i + 1] : count
            return Pick(index: start, duration: delays[start..<end].reduce(0, +))
        }
    }
}

/// Least-recently-used cache bounded by a total cost (bytes) instead of an entry count.
/// Not thread-safe: the owner guards it with its own lock.
public struct CostLRUCache<Key: Hashable, Value> {
    public let budget: Int
    public private(set) var totalCost = 0
    private var entries: [Key: (value: Value, cost: Int)] = [:]
    /// Oldest first. Entry counts are small (a handful of memes), so linear updates are fine.
    private var order: [Key] = []

    public init(budget: Int) { self.budget = budget }

    public var count: Int { entries.count }
    public var keys: [Key] { order }

    /// Returns the value and marks it as most recently used.
    public mutating func value(for key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        touch(key)
        return entry.value
    }

    /// Inserts (or replaces) a value, then evicts the least recently used entries until the total fits the
    /// budget. The newest entry is always kept, even if it alone is over budget.
    public mutating func insert(_ value: Value, cost: Int, for key: Key) {
        if let old = entries[key] { totalCost -= old.cost }
        entries[key] = (value, max(0, cost))
        totalCost += max(0, cost)
        touch(key)
        while totalCost > budget, order.count > 1 {
            let victim = order.removeFirst()
            if let gone = entries.removeValue(forKey: victim) { totalCost -= gone.cost }
        }
    }

    public mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
        totalCost = 0
    }

    private mutating func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

/// Upper bounds for images added to the user library: a huge file or a decompression bomb must not
/// stall the import or eat the memory budget (memes are decoded to ≤540 px anyway).
public enum ImportLimits {
    public static let maxFileBytes = 50 * 1024 * 1024
    public static let maxPixels = 100_000_000

    /// Unknown values (nil) pass; the decoder still bounds what it decodes.
    public static func allows(fileBytes: Int?, width: Int?, height: Int?) -> Bool {
        if let fileBytes, fileBytes > maxFileBytes { return false }
        if let width, let height, width > 0, height > 0, width.multipliedReportingOverflow(by: height).overflow
            || width * height > maxPixels { return false }
        return true
    }
}
