import SwiftUI

@main
struct MemeCamApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("MemeCam") {
            ContentView()
                .environment(model)
        }
    }
}
