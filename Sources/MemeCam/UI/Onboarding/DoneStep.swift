import SwiftUI

/// Short celebration + three tips, then "Start MemeCam".
struct DoneStep: View {
    let calibrated: Bool
    let onStart: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var burst = 0
    @State private var bounce = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            ZStack {
                SparkleBurst(trigger: burst, radius: 110)
                Image(systemName: "party.popper.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(OnboardingStyle.accentGradient)
                    .symbolEffect(.bounce, options: .nonRepeating, value: bounce)
                    .frame(width: 92, height: 92)
                    .background(Design.brand.opacity(0.14), in: .circle)
                    .accessibilityHidden(true)
            }
            .scaleEffect(visible || reduceMotion ? 1 : 0.5)
            .opacity(visible ? 1 : 0)
            .animation(OnboardingStyle.bouncy(reduceMotion), value: visible)
            StepHeader(title: String(localized: "You're all set!"),
                       subtitle: calibrated ? String(localized: "MemeCam knows your face. Time to make some faces.")
                                            : String(localized: "Everything is ready. Time to make some faces."))
                .padding(.top, 14)
                .riseIn(visible, delay: 0.12, reduceMotion: reduceMotion)
            VStack(alignment: .leading, spacing: 12) {
                TipRow(keys: "\u{2318}R", text: "Start or stop the camera")
                    .riseIn(visible, delay: 0.2, reduceMotion: reduceMotion)
                TipRow(keys: "\u{2318}K", text: "Recalibrate your neutral face")
                    .riseIn(visible, delay: 0.26, reduceMotion: reduceMotion)
                TipRow(symbol: "video.badge.checkmark",
                       text: "Turn on Virtual Camera in the toolbar, then pick \u{201C}MemeCam\u{201D} in Discord or Telegram")
                    .riseIn(visible, delay: 0.32, reduceMotion: reduceMotion)
            }
            .padding(18)
            .frame(maxWidth: 470, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 18))
            .padding(.top, 20)
            Spacer(minLength: 14)
            Button(action: onStart) { Label("Start MemeCam", systemImage: "video.fill").frame(minWidth: 180) }
                .labelStyle(.titleAndIcon)
                .onboardingPrimary()
                .keyboardShortcut(.defaultAction)
                .riseIn(visible, delay: 0.4, reduceMotion: reduceMotion)
        }
        .padding(.horizontal, OnboardingStyle.contentPadding)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .task {
            visible = true
            try? await Task.sleep(for: .milliseconds(250))
            burst += 1
            bounce = true
        }
    }
}

private struct TipRow: View {
    var keys: String?
    var symbol: String?
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let keys {
                    KeyCap(keys: keys)
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.title3)
                        .foregroundStyle(Design.brand)
                }
            }
            .frame(width: 56)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
