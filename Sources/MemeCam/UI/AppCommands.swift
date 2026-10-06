import SwiftUI

struct AppCommands: Commands {
    let model: AppModel
    let ui: UIState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Camera") {
            Button(model.cameraState == .running ? "Stop Camera" : "Start Camera") { model.toggle() }
                .keyboardShortcut("r")
            Button("Calibrate Neutral Face") { model.calibrate() }
                .keyboardShortcut("k")
                .disabled(model.cameraState != .running)
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
        CommandGroup(after: .help) {
            Button("Show Onboarding\u{2026}") {
                openWindow(id: "main")
                ui.onboardingRequested = true
            }
        }
    }
}
