import SwiftUI

/// "How do you want to start?" — three large choice cards.
struct PathStep: View {
    let onCalibrate: () -> Void
    let onMemes: () -> Void
    let onDefaults: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            StepHeader(title: String(localized: "How do you want to start?"),
                       subtitle: String(localized: "Pick one \u{2014} you can change everything later."))
                .riseIn(visible, delay: 0.05, reduceMotion: reduceMotion)
            Spacer(minLength: 24)
            GlassGroup(spacing: 16) {
                HStack(spacing: 16) {
                    card(0, symbol: "faceid", title: String(localized: "Calibrate my face"),
                         detail: String(localized: "Teach MemeCam your neutral face for sharper reactions."),
                         footnote: String(localized: "About 10 seconds"), recommended: true, key: "1", action: onCalibrate)
                    card(1, symbol: "cat.fill", title: String(localized: "Pick my memes"),
                         detail: String(localized: "Cats, hamsters or both. Peek at the library."),
                         footnote: String(localized: "Change any time"), key: "2", action: onMemes)
                    card(2, symbol: "bolt.fill", title: String(localized: "Use defaults"),
                         detail: String(localized: "Jump straight in. Everything is tuned already."),
                         footnote: String(localized: "Fastest"), key: "3", action: onDefaults)
                }
            }
            .background {
                // Return also picks the recommended card (a button can carry only one shortcut).
                Button("Calibrate my face", action: onCalibrate)
                    .keyboardShortcut(.defaultAction)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 20)
            Label("Press Return to calibrate, or 1\u{2009}\u{2013}\u{2009}3 to choose", systemImage: "keyboard")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .riseIn(visible, delay: 0.35, reduceMotion: reduceMotion)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, OnboardingStyle.contentPadding)
        .padding(.top, 20)
        .onAppear { visible = true }
    }

    private func card(_ index: Int, symbol: String, title: String, detail: String, footnote: String,
                      recommended: Bool = false, key: Character, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PathCardLabel(symbol: symbol, title: title, detail: detail, footnote: footnote, recommended: recommended)
        }
        .buttonStyle(PathCardButtonStyle(recommended: recommended))
        .keyboardShortcut(KeyEquivalent(key), modifiers: [])
        .accessibilityHint(recommended ? String(localized: "Recommended. \(footnote).") : footnote)
        .riseIn(visible, delay: 0.12 + Double(index) * 0.07, reduceMotion: reduceMotion)
    }
}

private struct PathCardLabel: View {
    let symbol: String
    let title: String
    let detail: String
    let footnote: String
    let recommended: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(recommended ? AnyShapeStyle(.white) : AnyShapeStyle(Design.brand))
                    .frame(width: 46, height: 46)
                    .background {
                        if recommended {
                            Circle().fill(OnboardingStyle.accentGradient)
                        } else {
                            Circle().fill(Design.brand.opacity(0.15))
                        }
                    }
                Spacer(minLength: 0)
                if recommended {
                    Text("Recommended")
                        .font(.caption.bold())
                        .foregroundStyle(Design.brand)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Design.brand.opacity(0.14), in: .capsule)
                }
            }
            .padding(.bottom, 4)
            Text(title)
                .font(.system(.title3, design: .rounded).bold())
                .foregroundStyle(.primary)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Label(footnote, systemImage: recommended ? "timer" : "info.circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.leading)
        .noAutomaticHyphenation()
        .padding(18)
        .frame(width: 196, height: 230, alignment: .topLeading)
    }
}

/// Hover lift, press squish, glass on macOS 26 and a brand ring for the recommended card.
private struct PathCardButtonStyle: ButtonStyle {
    let recommended: Bool

    func makeBody(configuration: Configuration) -> some View {
        PathCardBody(configuration: configuration, recommended: recommended)
    }

    private struct PathCardBody: View {
        let configuration: ButtonStyleConfiguration
        let recommended: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 22)
            configuration.label
                .contentShape(shape)
                .glassSurface(in: shape)
                .overlay {
                    shape.strokeBorder(recommended ? AnyShapeStyle(OnboardingStyle.accentGradient)
                                       : AnyShapeStyle(.white.opacity(hovering ? 0.25 : 0.1)),
                                       lineWidth: recommended ? 2 : 1)
                }
                .shadow(color: .black.opacity(hovering ? 0.2 : 0.08), radius: hovering ? 18 : 8, y: hovering ? 10 : 4)
                .scaleEffect(configuration.isPressed ? 0.97 : (hovering && !reduceMotion ? 1.03 : 1))
                .offset(y: hovering && !reduceMotion ? -4 : 0)
                .animation(reduceMotion ? .easeInOut(duration: 0.15) : .bouncy(duration: 0.35), value: hovering)
                .animation(.snappy(duration: 0.15), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}
