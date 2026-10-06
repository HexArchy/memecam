import SwiftUI

@main
struct MemeCamApp: App {
    @State private var model = AppModel()
    @State private var ui = UIState()

    var body: some Scene {
        Window("MemeCam", id: "main") {
            ContentView()
                .environment(model)
                .environment(ui)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1240, height: 800)
        .windowResizability(.contentMinSize)
        .commands { AppCommands(model: model, ui: ui) }

        MenuBarExtra("MemeCam", systemImage: "face.smiling") {
            MenuBarContent()
                .environment(model)
                .environment(ui)
        }
        .menuBarExtraStyle(.window)
    }
}
