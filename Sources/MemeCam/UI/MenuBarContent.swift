import AppKit
import SwiftUI

/// Content of the menu bar extra (window style).
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(UIState.self) private var ui
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            PauseToggleRow()

            Divider()

            Label(model.cameraState == .running ? model.status.reaction.title : "Camera off",
                  systemImage: model.cameraState == .running ? model.status.reaction.symbol : "video.slash")
                .font(.headline)
                .contentTransition(.symbolEffect(.replace))

            if model.cameraState == .running, let issue = model.status.cameraIssue {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.cameraState == .running, let note = model.powerMode.note {
                Label(note, systemImage: model.powerMode.idle ? "leaf" : "thermometer.medium")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

            Button("Customize Memes…", systemImage: "photo.on.rectangle.angled") {
                ui.editMemes()
                openMainWindow()
            }
            .buttonStyle(.borderless)

            HStack {
                Button("Open MemeCam") { openMainWindow() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 280)
        .tint(Design.brand)
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The panic switch, first thing in the menu bar popover.
private struct PauseToggleRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let paused = model.memesPaused
        Toggle(isOn: Binding(get: { !paused }, set: { model.memesPaused = !$0 })) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(paused ? "Memes Paused" : "Memes On")
                        .font(.headline)
                    Text(paused ? "Camera only · \u{2303}\u{2325}P to resume" : "\u{2303}\u{2325}P pauses from any app")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: paused ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(paused ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .toggleStyle(.switch)
        .controlSize(.large)
        .accessibilityLabel("Memes")
        .accessibilityValue(paused ? "Paused" : "On")
    }
}
