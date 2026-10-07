import SwiftUI

/// Look & motion constants for the onboarding, layered on top of `Design`.
enum OnboardingStyle {
    static let cardSize = CGSize(width: 720, height: 520)
    static let cardRadius: CGFloat = 28
    static let contentPadding: CGFloat = 36

    /// Warm orange → pink, sampled from the app icon. Use sparingly (hero accents only).
    static let accentGradient = LinearGradient(
        colors: [Design.brandSecondary, Design.brand, Color(red: 1.0, green: 0.38, blue: 0.56)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let success = Color(red: 0.2, green: 0.78, blue: 0.45)

    static func heroTitle(_ size: CGFloat = 30) -> Font { .system(size: size, weight: .bold, design: .rounded) }

    /// Spring for step changes and selection; a plain cross-fade curve under Reduce Motion.
    static func spring(_ reduceMotion: Bool) -> Animation { reduceMotion ? .easeInOut(duration: 0.25) : .smooth(duration: 0.5) }
    static func bouncy(_ reduceMotion: Bool) -> Animation { reduceMotion ? .easeInOut(duration: 0.25) : .bouncy(duration: 0.55, extraBounce: 0.12) }
}

/// Primary (prominent glass, tinted) and secondary (plain) onboarding buttons.
extension View {
    func onboardingPrimary() -> some View {
        self
            .font(.title3.weight(.semibold))
            .controlSize(.extraLarge)
            .glassButtonStyle(prominent: true)
            .tint(Design.brand)
    }

    func onboardingSecondary() -> some View {
        self
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.callout)
    }

    /// Narrow columns in Russian get auto-hyphenated mid-word ("библио-теку"). English line breaking
    /// never hyphenates and works the same for Cyrillic, so whole words move to the next line instead.
    func noAutomaticHyphenation() -> some View {
        typesettingLanguage(Locale.Language(identifier: "en"))
    }

    /// Staggered "rise in" used by every step: offset + fade, or fade only under Reduce Motion.
    func riseIn(_ visible: Bool, delay: Double, reduceMotion: Bool) -> some View {
        self
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 14)
            .animation(OnboardingStyle.spring(reduceMotion).delay(reduceMotion ? 0 : delay), value: visible)
    }
}

/// Title + subtitle block shared by the steps.
struct StepHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(OnboardingStyle.heroTitle(28))
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 520)
    }
}

/// A key-cap style label, e.g. ⌘R.
struct KeyCap: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(.callout.monospaced().weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: .rect(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator) }
    }
}
