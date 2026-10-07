import MemeCamCore
import SwiftUI
import UniformTypeIdentifiers

/// All memes for one reaction: add (panel or drop), preview, move, hide/delete, restore.
struct MemeReactionDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(UIState.self) private var ui
    let reaction: Reaction

    @State private var importing = false
    @State private var isDropTarget = false
    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 10)]

    var body: some View {
        let memes = model.allMemes(for: reaction)
        let hidden = model.hiddenDefaultsCount(for: reaction)
        VStack(alignment: .leading, spacing: 0) {
            header(count: memes.count)
                .padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !memes.isEmpty {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(memes) { meme in
                                MemeTile(meme: meme)
                            }
                        }
                    }
                    DropZone(isEmpty: memes.isEmpty, isTargeted: isDropTarget) { importing = true }
                    footer(hidden: hidden)
                }
                .padding(14)
            }
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: Design.cardRadius)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let images = urls.filter(\.isSupportedMemeFile)
            guard !images.isEmpty else { return false }
            model.addMemes(images, to: reaction)
            return true
        } isTargeted: { isDropTarget = $0 }
        .fileImporter(isPresented: $importing, allowedContentTypes: UTType.memeImports,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, !urls.isEmpty { model.addMemes(urls, to: reaction) }
        }
        .onExitCommand { ui.editingReaction = nil }
    }

    private func header(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("All Reactions", systemImage: "chevron.backward") { ui.editingReaction = nil }
                .buttonStyle(.borderless)
                .help("Back to all reactions (Esc)")
            HStack(spacing: 12) {
                Image(systemName: reaction.displaySymbol)
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(.tint.opacity(0.15), in: .rect(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(reaction.title)
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("\(count) memes")
                        .font(.subheadline)
                        .foregroundStyle(Design.secondaryText)
                }
                Spacer(minLength: 8)
                Button("Preview", systemImage: "play.fill") { model.trigger(reaction) }
                    .labelStyle(.iconOnly)
                    .disabled(model.cameraState != .running)
                    .help("Show this reaction in the preview")
                Button("Add…", systemImage: "plus") { importing = true }
                    .buttonStyle(.borderedProminent)
                    .help("Add images or GIFs to \(reaction.title)")
            }
            .controlSize(.large)
            EnabledSwitch(reaction: reaction)
        }
    }

    @ViewBuilder
    private func footer(hidden: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if hidden > 0 {
                Button("Restore Defaults (\(hidden) hidden)", systemImage: "arrow.uturn.backward") {
                    model.restoreDefaultMemes(for: reaction)
                }
            }
            Button("Show Custom Memes in Finder", systemImage: "folder") { model.revealUserMemesFolder() }
                .buttonStyle(.link)
        }
    }
}

/// Per-reaction on/off: off = still detected, but its memes never pop up.
private struct EnabledSwitch: View {
    @Environment(AppModel.self) private var model
    let reaction: Reaction

    var body: some View {
        let enabled = model.isEnabled(reaction)
        Toggle(isOn: Binding(get: { enabled }, set: { model.setEnabled(reaction, $0) })) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Pop up memes")
                Text(enabled ? "On — shows a meme when you do this." : "Off — still detected, but nothing pops up.")
                    .font(.caption)
                    .foregroundStyle(Design.secondaryText)
            }
        }
        .toggleStyle(.switch)
        .help(enabled ? "Turn \(reaction.title) off" : "Turn \(reaction.title) on")
    }
}

/// Dashed target that invites dropping files (and opens the panel on click).
private struct DropZone: View {
    let isEmpty: Bool
    let isTargeted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: isEmpty ? "photo.badge.plus" : "plus.circle")
                    .font(isEmpty ? .largeTitle : .title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                Text(isEmpty ? "No memes yet" : "Add more")
                    .font(.headline)
                Text("Drop images or GIFs here, or click to choose files.")
                    .font(.caption)
                    .foregroundStyle(Design.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, isEmpty ? 32 : 16)
            .padding(.horizontal, 12)
            .background(isTargeted ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear),
                        in: .rect(cornerRadius: Design.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Design.cardRadius)
                    .strokeBorder(.separator, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }
            .contentShape(.rect(cornerRadius: Design.cardRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add memes")
        .accessibilityHint("Choose image or GIF files to add")
    }
}
