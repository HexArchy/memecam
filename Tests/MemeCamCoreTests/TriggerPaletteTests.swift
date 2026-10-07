import Foundation
import Testing
@testable import MemeCamCore

@Test func defaultPaletteHasNineSlotsInOrder() {
    let p = TriggerPalette.default
    #expect(p.slots.count == 9)
    #expect(p.slots.map(\.reaction) == [.smile, .laugh, .surprised, .thumbsUp, .thumbsDown,
                                        .heart, .facepalm, .thinking, .handsUp])
    #expect(p.slots.allSatisfy { $0.memeID == nil })
}

@Test func missingOrUnreadableDataGivesDefaults() {
    #expect(TriggerPalette.decode(nil) == .default)
    #expect(TriggerPalette.decode(Data("garbage".utf8)) == .default)
    #expect(TriggerPalette.decode(Data("{}".utf8)) == .default)
}

@Test func roundTripKeepsReactionsAndMemeIDs() {
    var p = TriggerPalette.default
    p.assign(TriggerSlot(reaction: .peace), at: 0)
    p.assign(TriggerSlot(reaction: .heart, memeID: "user/love.gif"), at: 8)
    let back = TriggerPalette.decode(p.encoded())
    #expect(back == p)
    #expect(back[0] == TriggerSlot(reaction: .peace))
    #expect(back[8].memeID == "user/love.gif")
    #expect(back[8].reaction == .heart)
}

@Test func assignOutOfRangeIsIgnored() {
    var p = TriggerPalette.default
    p.assign(TriggerSlot(reaction: .fist), at: 9)
    p.assign(TriggerSlot(reaction: .fist), at: -1)
    #expect(p == .default)
}

@Test func shortListsArePaddedWithDefaultsAndLongOnesTrimmed() {
    let short = TriggerPalette(slots: [TriggerSlot(reaction: .sad)])
    #expect(short.slots.count == 9)
    #expect(short[0].reaction == .sad)
    #expect(short[1].reaction == .laugh)
    let long = TriggerPalette(slots: Array(repeating: TriggerSlot(reaction: .fist), count: 12))
    #expect(long.slots.count == 9)
    #expect(long.slots.allSatisfy { $0.reaction == .fist })
}

@Test func unknownReactionFallsBackToThatSlotsDefault() throws {
    let json = #"{"slots":[{"reaction":"peace"},{"reaction":"dabbing","meme":"x.gif"},{"reaction":"sad","meme":"s.png"}]}"#
    let p = TriggerPalette.decode(Data(json.utf8))
    #expect(p[0] == TriggerSlot(reaction: .peace))
    #expect(p[1] == TriggerSlot(reaction: .laugh)) // default for slot 2
    #expect(p[2] == TriggerSlot(reaction: .sad, memeID: "s.png"))
    #expect(p[3].reaction == .thumbsUp)
}

@Test func storedFormatIsStable() throws {
    let p = TriggerPalette(slots: [TriggerSlot(reaction: .smile, memeID: "cat.gif"), TriggerSlot(reaction: .laugh)])
    let obj = try #require(JSONSerialization.jsonObject(with: p.encoded()) as? [String: Any])
    let slots = try #require(obj["slots"] as? [[String: String]])
    #expect(slots[0] == ["reaction": "smile", "meme": "cat.gif"])
    #expect(slots[1] == ["reaction": "laugh"])
}

@Test func hotKeyLabels() {
    #expect(TriggerPalette.hotKeyLabel(forSlot: 0) == "\u{2303}\u{2325}1")
    #expect(TriggerPalette.hotKeyLabel(forSlot: 8) == "\u{2303}\u{2325}9")
}
