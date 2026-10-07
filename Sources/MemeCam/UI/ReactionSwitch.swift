import MemeCamCore
import SwiftUI

/// "Turn Off" / "Turn On" for a reaction's context menu. Off = still detected, never pops up.
struct ReactionSwitchMenuItem: View {
    @Environment(AppModel.self) private var model
    let reaction: Reaction

    var body: some View {
        let enabled = model.isEnabled(reaction)
        Button(enabled ? "Turn Off" : "Turn On", systemImage: enabled ? "eye.slash" : "eye") {
            model.setEnabled(reaction, !enabled)
        }
    }
}

/// Small "Off" capsule over a switched-off reaction's thumbnail.
struct ReactionOffBadge: View {
    var body: some View {
        Text("Off")
            .font(.caption.bold())
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.regularMaterial, in: .capsule)
            .padding(5)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Dims a switched-off reaction's thumbnail and marks it "Off".
    func reactionOff(_ off: Bool) -> some View {
        saturation(off ? 0 : 1)
            .opacity(off ? 0.45 : 1)
            .overlay(alignment: .topLeading) { if off { ReactionOffBadge() } }
    }
}
