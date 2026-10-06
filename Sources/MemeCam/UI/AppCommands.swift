import SwiftUI

struct AppCommands: Commands {
    let model: AppModel
    @AppStorage("showInspector") private var showInspector = true

    var body: some Commands {
        CommandMenu("Camera") {
            Button(model.cameraState == .running ? "Stop Camera" : "Start Camera") { model.toggle() }
                .keyboardShortcut("r")
            Button("Calibrate Neutral Face") { model.calibrate() }
                .keyboardShortcut("k")
                .disabled(model.cameraState != .running)
        }
        CommandGroup(after: .toolbar) {
            Button(showInspector ? "Hide Inspector" : "Show Inspector") { showInspector.toggle() }
                .keyboardShortcut("i")
            Divider()
            ForEach(Array(OutputLayout.allCases.enumerated()), id: \.element) { index, layout in
                Button(layout.title) { model.layout = layout }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
        }
    }
}
