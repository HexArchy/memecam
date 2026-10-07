import MemeCamCore
import SwiftUI

/// Shared look & feel constants so every screen feels uniform.
enum Design {
    /// Warm orange from the app icon; used as the app tint.
    static let brand = Color(red: 1.0, green: 0.54, blue: 0.36)
    static let brandSecondary = Color(red: 1.0, green: 0.77, blue: 0.43)
    /// Deeper orange for fills that carry white text (prominent buttons, selection): white on it is ~4.3:1,
    /// on `brand` only ~2.3:1, which made button titles look washed out.
    static let accent = Color(red: 0.86, green: 0.30, blue: 0.10)

    /// Secondary/tertiary text a notch stronger than the system styles, which fade out on the translucent,
    /// tinted window background.
    static let secondaryText = Color.primary.opacity(0.74)
    static let tertiaryText = Color.primary.opacity(0.56)

    static let stageRadius: CGFloat = 20
    static let cardRadius: CGFloat = 14
    static let tileRadius: CGFloat = 10

    static let stagePadding: CGFloat = 28
    static let sectionSpacing: CGFloat = 16
}

/// Soft brand-coloured glow behind the content; sits on the translucent window material.
struct WindowBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let strength = colorScheme == .dark ? 0.16 : 0.12
        ZStack {
            RadialGradient(colors: [Design.brand.opacity(strength), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 760)
            RadialGradient(colors: [Color.purple.opacity(strength * 0.8), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 680)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// "Video is processed on this Mac only — nothing is uploaded" (onboarding, inspector).
struct PrivacyNote: View {
    var body: some View {
        Label("Video is processed on this Mac only \u{2014} nothing is uploaded", systemImage: "lock.shield")
            .font(.callout)
            .foregroundStyle(Design.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension AwayDelay {
    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .tenSeconds: String(localized: "10 s")
        case .thirtySeconds: String(localized: "30 s")
        case .oneMinute: String(localized: "1 min")
        }
    }
}
