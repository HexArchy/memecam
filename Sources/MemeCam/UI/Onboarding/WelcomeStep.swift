import AppKit
import SwiftUI

struct WelcomeStep: View {
    let onStart: () -> Void
    let onSkip: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            AppIconHero()
                .padding(.bottom, 14)
            Text(verbatim: "MemeCam")
                .font(OnboardingStyle.heroTitle(40))
                .accessibilityAddTraits(.isHeader)
                .riseIn(visible, delay: 0.15, reduceMotion: reduceMotion)
            Text("Make a face. Get a meme. Live in every call.")
                .font(.title3)
                .foregroundStyle(Design.secondaryText)
                .padding(.top, 6)
                .riseIn(visible, delay: 0.22, reduceMotion: reduceMotion)
            ReactionDemo()
                .padding(.top, 26)
                .riseIn(visible, delay: 0.32, reduceMotion: reduceMotion)
            PrivacyNote()
                .padding(.top, 14)
                .riseIn(visible, delay: 0.38, reduceMotion: reduceMotion)
            Spacer(minLength: 16)
            Button(action: onStart) {
                Text("Get Started")
                    .frame(minWidth: 180)
            }
            .onboardingPrimary()
            .keyboardShortcut(.defaultAction)
            .riseIn(visible, delay: 0.42, reduceMotion: reduceMotion)
            Button("Skip \u{2014} use defaults", action: onSkip)
                .onboardingSecondary()
                .keyboardShortcut(.cancelAction)
                .help("Skip setup (Esc)")
                .padding(.top, 12)
                .riseIn(visible, delay: 0.48, reduceMotion: reduceMotion)
        }
        .padding(.horizontal, OnboardingStyle.contentPadding)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .onAppear { visible = true }
    }
}

/// The app icon with a springy entrance and a gentle floating loop.
private struct AppIconHero: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entered = false

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 112, height: 112)
            .shadow(color: Design.brand.opacity(0.45), radius: 22, y: 10)
            .phaseAnimator([false, true]) { content, up in
                content.offset(y: reduceMotion || !entered ? 0 : (up ? -5 : 3))
            } animation: { _ in
                .easeInOut(duration: 2.2)
            }
            .scaleEffect(entered || reduceMotion ? 1 : 0.35)
            .rotationEffect(.degrees(entered || reduceMotion ? 0 : -14))
            .opacity(entered ? 1 : 0)
            .animation(reduceMotion ? .easeInOut(duration: 0.3) : .spring(duration: 0.7, bounce: 0.45), value: entered)
            .onAppear { entered = true }
            .accessibilityHidden(true)
    }
}
