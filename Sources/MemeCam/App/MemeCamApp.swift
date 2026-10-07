import MemeCamCore
import SwiftUI

@main
enum Launcher {
    static func main() {
        #if DEBUG
        PopPreviewRenderer.runIfRequested() // dev tool: renders pop-up frames and exits
        #endif
        MemeCamApp.main()
    }
}

struct MemeCamApp: App {
    @State private var model: AppModel
    @State private var ui = UIState()
    /// Floating ⌃⌥0 palette; follows `model.paletteVisible`.
    @State private var palette: TriggerPaletteController

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        _palette = State(initialValue: TriggerPaletteController(model: model))
    }

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

        MenuBarExtra("MemeCam", systemImage: model.presence.menuBarSymbol) {
            MenuBarContent()
                .environment(model)
                .environment(ui)
        }
        .menuBarExtraStyle(.window)
    }
}

extension CameraPresence {
    /// Menu bar icon: is the camera on, and what goes out.
    var menuBarSymbol: String {
        switch self {
        case .off: "video.slash"
        case .live: "face.smiling.inverse"
        case .paused: "pause.circle"
        case .away: "moon.zzz"
        }
    }

    var title: String {
        switch self {
        case .off: String(localized: "Camera off")
        case .live: String(localized: "Camera on")
        case .paused: String(localized: "Memes Paused")
        case .away: String(localized: "Away \u{2014} \u{201C}Be right back\u{201D} is showing")
        }
    }
}
