import AppKit
import MemeCamCore
import Observation
import SwiftUI

/// Shows / hides the floating trigger palette to match `AppModel.paletteVisible` (⌃⌥0, menus).
///
/// AppKit on purpose: a SwiftUI `Window`/`UtilityWindow` activates MemeCam when clicked (and a
/// utility window hides while MemeCam is inactive), which would pull focus away from Discord/Zoom.
/// A non-activating `NSPanel` takes clicks without becoming key, so the call keeps keyboard focus.
@MainActor
final class TriggerPaletteController {
    private let model: AppModel
    private var panel: TriggerPanel?

    init(model: AppModel) {
        self.model = model
        observe()
        // Restored state: show it once the app has finished launching (screens are known by then).
        Task { @MainActor [weak self] in self?.sync() }
    }

    private func observe() {
        withObservationTracking {
            _ = model.paletteVisible
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.sync()
                self?.observe()
            }
        }
    }

    private func sync() {
        if model.paletteVisible {
            let panel = panel ?? makePanel()
            self.panel = panel
            panel.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
        }
    }

    private func makePanel() -> TriggerPanel {
        let root = TriggerPaletteView()
            .environment(model)
            .tint(Design.brand)
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.sizingOptions = [.intrinsicContentSize]
        let panel = TriggerPanel(contentView: hosting)
        panel.setContentSize(hosting.fittingSize)
        // Remembers where the user dragged it; first time: top-right of the main screen.
        if !panel.setFrameUsingName(Self.autosaveName), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - panel.frame.width - 24, y: screen.maxY - 24))
        }
        panel.setFrameAutosaveName(Self.autosaveName)
        return panel
    }

    private static let autosaveName = "TriggerPalette"
}

/// Borderless, floating, non-activating: clicking a tile never activates MemeCam or takes keyboard
/// focus from the frontmost app. Visible on every Space and over full-screen calls.
private final class TriggerPanel: NSPanel {
    init(contentView: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        self.contentView = contentView
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        title = String(localized: "Trigger Palette")
        setAccessibilitySubrole(.floatingWindow)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The panel never becomes key, so the first click must already hit the tile.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Lets the user drag the panel by its header (SwiftUI content doesn't move borderless windows by itself).
private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

/// Content of the floating palette: a small header and the 3×3 grid on Liquid Glass.
private struct TriggerPaletteView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.3x3.fill")
                    .foregroundStyle(.tint)
                Text(statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button { model.paletteVisible = false } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .frame(width: 16, height: 16)
                        .contentShape(.circle)
                }
                .buttonStyle(.borderless)
                .help("Hide palette (\u{2303}\u{2325}0)")
                .accessibilityLabel("Hide trigger palette")
            }
            .padding(.horizontal, 2)
            .background { WindowDragHandle() }

            TriggerGrid(tileSize: 60, spacing: 6)
        }
        .padding(10)
        .glassSurface(in: .rect(cornerRadius: 20))
        .padding(1) // keep the glass edge inside the window bounds
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Trigger palette")
    }

    private var statusText: String {
        if model.memesPaused { return String(localized: "Paused · \u{2303}\u{2325}P") }
        if model.cameraState != .running { return String(localized: "Camera off") }
        return model.slotHotKeysEnabled ? "\u{2303}\u{2325}1–9" : String(localized: "Triggers")
    }
}
