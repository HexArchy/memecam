import AppKit
import SwiftUI

/// Content of the menu bar extra (window style).
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Label(model.cameraState == .running ? model.status.reaction.title : "Camera off",
                  systemImage: model.cameraState == .running ? model.status.reaction.symbol : "video.slash")
                .font(.headline)
                .contentTransition(.symbolEffect(.replace))

            Button { model.toggle() } label: {
                Label(model.cameraState == .running ? "Stop Camera" : "Start Camera",
                      systemImage: model.cameraState == .running ? "stop.fill" : "video.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)

            Picker("Layout", selection: $model.layout) {
                ForEach(OutputLayout.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Divider()

            HStack {
                Button("Open MemeCam") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}
