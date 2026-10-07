import MemeCamCore
import SwiftUI

/// Cats / Hamsters / Both picker with a live, animated peek at the library.
struct MemesStep: View {
    let onContinue: () -> Void
    let onOpenEditor: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var preview: [Meme] = []
    @State private var total = 0

    /// Reactions sampled for the preview grid, in display order.
    private static let showcase: [Reaction] = [.smile, .thumbsUp, .surprised, .heart, .laugh, .peace,
                                               .sad, .openPalm, .facepalm, .thinking, .thumbsDown, .neutral,
                                               .eyesClosed, .fist, .noFace]

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            StepHeader(title: String(localized: "Pick your memes"),
                       subtitle: String(localized: "MemeCam shows the meme that matches your face."))
                .riseIn(visible, delay: 0.05, reduceMotion: reduceMotion)
            AnimalPicker(selection: $model.animals)
                .padding(.top, 20)
                .riseIn(visible, delay: 0.12, reduceMotion: reduceMotion)
            MemePeekGrid(memes: preview)
                .frame(height: 176)
                .padding(.top, 18)
                .riseIn(visible, delay: 0.2, reduceMotion: reduceMotion)
            HStack(spacing: 6) {
                Text("\(total) memes ready").contentTransition(.numericText(value: Double(total)))
                Text(verbatim: "\u{00B7}")
                Text("Customize anytime with")
                KeyCap(keys: "\u{21E7}\u{2318}E")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 14)
            .riseIn(visible, delay: 0.26, reduceMotion: reduceMotion)
            Spacer(minLength: 12)
            HStack(spacing: 12) {
                Button("Open Meme Editor", action: onOpenEditor)
                    .controlSize(.extraLarge)
                    .font(.title3)
                    .glassButtonStyle()
                    .help("Finish setup and open the meme editor")
                Button(action: onContinue) { Text("Continue").frame(minWidth: 120) }
                    .onboardingPrimary()
                    .keyboardShortcut(.defaultAction)
            }
            .riseIn(visible, delay: 0.32, reduceMotion: reduceMotion)
        }
        .padding(.horizontal, OnboardingStyle.contentPadding)
        .padding(.top, 26)
        .padding(.bottom, 6)
        .onAppear { visible = true }
        .task(id: model.animals) { reload() }
    }

    private func reload() {
        var picked: [Meme] = []
        for r in Self.showcase {
            guard let m = model.memes(for: r).first(where: { $0.animal != .other }) else { continue }
            picked.append(m)
            if picked.count == 10 { break }
        }
        let count = Reaction.allCases.reduce(0) { $0 + model.memes(for: $1).count }
        withAnimation(OnboardingStyle.bouncy(reduceMotion)) {
            preview = picked
            total = count
        }
    }
}

/// Custom segmented control with a sliding gradient selection (matched geometry).
private struct AnimalPicker: View {
    @Binding var selection: AnimalFilter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace

    private static let order: [AnimalFilter] = [.cats, .hamsters, .both]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.order) { option in
                let selected = option == selection
                Button {
                    withAnimation(OnboardingStyle.bouncy(reduceMotion)) { selection = option }
                } label: {
                    HStack(spacing: 6) {
                        Text(option.emoji)
                        Text(option.title)
                    }
                    .font(.headline)
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background {
                        if selected {
                            Capsule()
                                .fill(OnboardingStyle.accentGradient)
                                .shadow(color: Design.brand.opacity(0.4), radius: 8, y: 3)
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .glassSurface(in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Animals")
    }
}

private extension AnimalFilter {
    var emoji: String {
        switch self {
        case .cats: "\u{1F431}"
        case .hamsters: "\u{1F439}"
        case .both: "\u{2728}"
        }
    }
}

/// Two rows of meme thumbnails that pop in / out as the filter changes.
private struct MemePeekGrid: View {
    let memes: [Meme]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let columns = Array(repeating: GridItem(.fixed(80), spacing: 10), count: 5)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(memes) { meme in
                PeekTile(meme: meme)
                    .transition(reduceMotion ? AnyTransition.opacity : .scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meme preview")
    }
}

private struct PeekTile: View {
    let meme: Meme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        MemeThumbnail(url: meme.url, id: meme.id, symbol: meme.reaction.displaySymbol, maxPixelSize: 200)
            .frame(width: 80, height: 80)
            .clipShape(.rect(cornerRadius: 14))
            .overlay(alignment: .bottomLeading) {
                Image(systemName: meme.reaction.displaySymbol)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(.black.opacity(0.45), in: .circle)
                    .padding(5)
            }
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.14)) }
            .shadow(color: .black.opacity(hovering ? 0.25 : 0.1), radius: hovering ? 10 : 4, y: hovering ? 6 : 2)
            .scaleEffect(hovering && !reduceMotion ? 1.08 : 1)
            .animation(reduceMotion ? nil : .bouncy(duration: 0.3), value: hovering)
            .onHover { hovering = $0 }
            .help("\(meme.reaction.title): \(meme.title)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(meme.reaction.title) meme")
    }
}
