import MemeCamCore
import SwiftUI

/// 3×3 grid of the manual trigger slots. Click = pop that meme up; right-click = reassign.
/// Used in the menu bar extra and the floating palette.
struct TriggerGrid: View {
    @Environment(AppModel.self) private var model
    var tileSize: CGFloat = 64
    var spacing: CGFloat = 6

    var body: some View {
        let columns = Array(repeating: GridItem(.fixed(tileSize), spacing: spacing), count: 3)
        LazyVGrid(columns: columns, spacing: spacing) {
            ForEach(0..<TriggerPalette.slotCount, id: \.self) { index in
                TriggerTile(index: index,
                            slot: model.triggerPalette[index],
                            size: tileSize,
                            showsHotKey: model.slotHotKeysEnabled,
                            enabled: model.canTrigger)
            }
        }
        .fixedSize()
    }
}

private struct TriggerTile: View {
    @Environment(AppModel.self) private var model
    let index: Int
    let slot: TriggerSlot
    let size: CGFloat
    let showsHotKey: Bool
    let enabled: Bool

    var body: some View {
        let meme = model.thumbnailMeme(for: slot)
        Button { model.fireSlot(index) } label: {
            Color.clear
                .frame(width: size, height: size)
                .overlay { MemeThumbnail(url: meme?.url, id: meme?.id, symbol: slot.reaction.displaySymbol) }
                .clipShape(.rect(cornerRadius: Design.tileRadius))
                .overlay(alignment: .bottomLeading) {
                    if showsHotKey { KeyHint(text: TriggerPalette.hotKeyLabel(forSlot: index)) }
                }
                .overlay(alignment: .topTrailing) {
                    if slot.memeID != nil {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8, weight: .bold))
                            .padding(4)
                            .background(.regularMaterial, in: .circle)
                            .padding(3)
                            .accessibilityHidden(true)
                    }
                }
                .saturation(enabled ? 1 : 0.2)
                .opacity(enabled ? 1 : 0.6)
                .contentShape(.rect(cornerRadius: Design.tileRadius))
        }
        .buttonStyle(TileButtonStyle())
        .contextMenu { TriggerSlotMenu(index: index, slot: slot) }
        .help(help)
        .accessibilityLabel(slot.memeID.flatMap { _ in meme?.title } ?? slot.reaction.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
    }

    /// "Random meme, Control Option 1" — what fires and the hotkey (the pin and key cap are hidden).
    private var accessibilityValue: String {
        var parts = [slot.memeID == nil ? String(localized: "Random meme") : String(localized: "Pinned meme")]
        if showsHotKey { parts.append(String(localized: "Control Option \(index + 1)")) }
        return parts.joined(separator: ", ")
    }

    /// Says why nothing happens while the tile is dimmed, instead of a silent click.
    private var accessibilityHint: String {
        if model.memesPaused { return String(localized: "Memes are paused. Press Control Option P to resume.") }
        if !enabled { return String(localized: "Start the camera to trigger memes.") }
        return String(localized: "Pops this meme up in your camera. Right-click to assign another.")
    }

    private var help: String {
        let what = model.specificMeme(for: slot).map { "\u{201C}\($0.title)\u{201D}" }
            ?? String(localized: "a random \(slot.reaction.title) meme")
        let key = showsHotKey ? " (\(TriggerPalette.hotKeyLabel(forSlot: index)))" : ""
        if model.memesPaused { return String(localized: "Memes are paused (\u{2303}\u{2325}P)") }
        if model.cameraState != .running { return String(localized: "Start the camera to trigger \(what)") }
        return String(localized: "Show \(what)\(key) · right-click to assign")
    }
}

/// Tiny "⌃⌥1" capsule in a tile's corner.
private struct KeyHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(.black.opacity(0.55), in: .capsule)
            .foregroundStyle(.white)
            .padding(3)
            .accessibilityHidden(true)
    }
}

/// Shrinks a tile slightly while pressed.
private struct TileButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.93 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Right-click menu of a slot: trigger it, assign a reaction or one specific meme, reset.
struct TriggerSlotMenu: View {
    @Environment(AppModel.self) private var model
    let index: Int
    let slot: TriggerSlot

    var body: some View {
        Button("Trigger", systemImage: "sparkles") { model.fireSlot(index) }
            .disabled(!model.canTrigger)
        Divider()
        Menu("Assign Reaction") {
            ForEach(Reaction.allCases) { reaction in
                Toggle(isOn: Binding(get: { slot.reaction == reaction },
                                     set: { _ in model.assignSlot(index, TriggerSlot(reaction: reaction)) })) {
                    Label(reaction.title, systemImage: reaction.displaySymbol)
                }
            }
        }
        Menu("Assign Meme") {
            Toggle("Random \(slot.reaction.title)", isOn: Binding(
                get: { slot.memeID == nil },
                set: { _ in model.assignSlot(index, TriggerSlot(reaction: slot.reaction)) }))
            let memes = model.allMemes(for: slot.reaction)
            if !memes.isEmpty { Divider() }
            ForEach(memes) { meme in
                Toggle(meme.title, isOn: Binding(
                    get: { slot.memeID == meme.id },
                    set: { _ in model.assignSlot(index, TriggerSlot(reaction: slot.reaction, memeID: meme.id)) }))
            }
        }
        Divider()
        Button("Reset to \(TriggerPalette.default[index].reaction.title)") {
            model.assignSlot(index, TriggerPalette.default[index])
        }
        .disabled(slot == TriggerPalette.default[index])
    }
}
