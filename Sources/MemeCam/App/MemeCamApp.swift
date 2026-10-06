import SwiftUI

@main
struct MemeCamApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("MemeCam", id: "main") {
            ContentView()
                .environment(model)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1180, height: 700)
        .commands { AppCommands(model: model) }

        MenuBarExtra("MemeCam", systemImage: "face.smiling") {
            MenuBarContent()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}
