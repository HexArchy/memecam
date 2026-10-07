import Foundation

/// One manual trigger slot: a reaction (a random meme of it) or one specific meme of that reaction.
public struct TriggerSlot: Codable, Hashable, Sendable {
    public var reaction: Reaction
    /// A specific meme id (`MemeLibrary` id); nil = a random meme of `reaction`.
    public var memeID: String?

    public init(reaction: Reaction, memeID: String? = nil) {
        self.reaction = reaction
        self.memeID = memeID
    }

    private enum CodingKeys: String, CodingKey { case reaction, meme }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reaction = try c.decode(Reaction.self, forKey: .reaction)
        memeID = try c.decodeIfPresent(String.self, forKey: .meme)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(reaction, forKey: .reaction)
        try c.encodeIfPresent(memeID, forKey: .meme)
    }
}

/// The nine manual trigger slots (⌃⌥1 … ⌃⌥9). Always exactly `slotCount` slots.
public struct TriggerPalette: Codable, Equatable, Sendable {
    public static let slotCount = 9

    public static let defaultReactions: [Reaction] = [
        .smile, .laugh, .surprised, .thumbsUp, .thumbsDown, .heart, .facepalm, .thinking, .handsUp,
    ]

    public static let `default` = TriggerPalette(slots: defaultReactions.map { TriggerSlot(reaction: $0) })

    public private(set) var slots: [TriggerSlot]

    /// Missing slots are filled from the defaults, extra ones dropped.
    public init(slots: [TriggerSlot]) {
        self.slots = Self.normalized(slots.map(Optional.some))
    }

    public subscript(index: Int) -> TriggerSlot { slots[index] }

    /// Replaces slot `index` (0-based); out-of-range indices are ignored.
    public mutating func assign(_ slot: TriggerSlot, at index: Int) {
        guard slots.indices.contains(index) else { return }
        slots[index] = slot
    }

    /// "⌃⌥1" for index 0.
    public static func hotKeyLabel(forSlot index: Int) -> String { "\u{2303}\u{2325}\(index + 1)" }

    // MARK: Persistence

    /// Decodes stored data; a slot that can't be read (e.g. a reaction removed in a later version)
    /// falls back to its default, and unreadable data gives the defaults.
    public static func decode(_ data: Data?) -> TriggerPalette {
        guard let data, let palette = try? JSONDecoder().decode(TriggerPalette.self, from: data) else { return .default }
        return palette
    }

    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    private init(lossy: [TriggerSlot?]) {
        slots = Self.normalized(lossy)
    }

    private static func normalized(_ slots: [TriggerSlot?]) -> [TriggerSlot] {
        (0..<slotCount).map { i in
            (i < slots.count ? slots[i] : nil) ?? TriggerSlot(reaction: defaultReactions[i])
        }
    }

    private enum CodingKeys: String, CodingKey { case slots }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(lossy: try c.decode([Lossy].self, forKey: .slots).map(\.value))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(slots, forKey: .slots)
    }

    private struct Lossy: Decodable {
        let value: TriggerSlot?
        init(from decoder: any Decoder) throws { value = try? TriggerSlot(from: decoder) }
    }
}
