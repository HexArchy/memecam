import SwiftUI

/// Shared look & feel constants so every screen feels uniform.
enum Design {
    /// Warm orange from the app icon; used as the app tint.
    static let brand = Color(red: 1.0, green: 0.54, blue: 0.36)
    static let brandSecondary = Color(red: 1.0, green: 0.77, blue: 0.43)

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
