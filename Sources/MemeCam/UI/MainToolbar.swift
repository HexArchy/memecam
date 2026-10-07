import AppKit
import SwiftUI

/// Toolbar: app identity (leading), camera source (centre), virtual camera + inspector (trailing).
struct MainToolbar: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem(placement: .navigation) { AppIdentity() }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { AppIdentity() }
        }
        ToolbarItem(placement: .principal) {
            CameraMenu()
                .labelStyle(.titleAndIcon)
        }
        ToolbarItem(placement: .primaryAction) { UpdateButton() }
        ToolbarItem(placement: .primaryAction) { VirtualCameraPill() }
        ToolbarItem(placement: .primaryAction) { InspectorToggle() }
    }
}

private struct AppIdentity: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
            Text(verbatim: "MemeCam")
                .font(.headline)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct InspectorToggle: View {
    @Environment(UIState.self) private var ui

    var body: some View {
        Button("Inspector", systemImage: "sidebar.trailing") { ui.showInspector.toggle() }
            .help(ui.showInspector ? "Hide the inspector (\u{2318}I)" : "Show the inspector (\u{2318}I)")
    }
}
