import SwiftUI

struct AppCommands: Commands {
    let model: AppModel
    let ui: UIState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates\u{2026}") {
                openWindow(id: "main")
                Task { await model.updater.check(userInitiated: true) }
            }
        }
        CommandMenu("Camera") {
            Button(model.cameraState == .running ? "Stop Camera" : "Start Camera") { model.toggle() }
                .keyboardShortcut("r")
            Button("Calibrate Neutral Face") { model.calibrate() }
                .keyboardShortcut("k")
                .disabled(model.cameraState != .running)
            Button(model.memesPaused ? "Resume Memes" : "Pause Memes") { model.togglePause() }
                .keyboardShortcut("p", modifiers: [.control, .option]) // also a global hotkey
            Divider()
            Button("Customize Memes…") { ui.editMemes() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }
        CommandGroup(after: .toolbar) {
            Button(ui.showInspector ? "Hide Inspector" : "Show Inspector") { ui.showInspector.toggle() }
                .keyboardShortcut("i")
            Divider()
            ForEach(Array(OutputLayout.allCases.enumerated()), id: \.element) { index, layout in
                Button(layout.title) { model.layout = layout }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
        }
        CommandGroup(before: .windowList) {
            Button(model.paletteVisible ? "Hide Trigger Palette" : "Show Trigger Palette") { model.togglePalette() }
                .keyboardShortcut("0", modifiers: [.control, .option]) // also a global hotkey
            Divider()
        }
        CommandGroup(after: .help) {
            Button("Show Onboarding\u{2026}") {
                openWindow(id: "main")
                ui.onboardingRequested = true
            }
        }
    }
}
