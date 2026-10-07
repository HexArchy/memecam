import AppKit
import SwiftUI

/// Content of the menu bar extra (window style).
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(UIState.self) private var ui
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        let cameraOn = model.cameraState == .running || model.cameraState == .starting
        VStack(alignment: .leading, spacing: 12) {
            if cameraOn {
                StopCameraRow()
                Divider()
            }

            PauseToggleRow()

            Divider()

            Label(model.cameraState == .running ? model.status.reaction.title : String(localized: "Camera off"),
                  systemImage: model.cameraState == .running ? model.status.reaction.symbol : "video.slash")
                .font(.headline)
                .contentTransition(.symbolEffect(.replace))

            if model.cameraState == .running, let issue = model.status.cameraIssue {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Design.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.cameraState == .running, let note = model.powerMode.note {
                Label(note, systemImage: model.powerMode.idle ? "leaf" : "thermometer.medium")
                    .font(.callout)
                    .foregroundStyle(Design.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TriggersSection()

            if !cameraOn {
                Button { model.start() } label: {
                    Label("Start Camera", systemImage: "video.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }

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
        .tint(Design.accent)
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Manual triggers: the 3×3 slot grid and the floating palette toggle.
private struct TriggersSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Triggers")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(model.paletteVisible ? "Hide Palette" : "Show Palette",
                       systemImage: model.paletteVisible ? "rectangle.on.rectangle.slash" : "square.grid.3x3") {
                    model.togglePalette()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Floating palette over other apps (\u{2303}\u{2325}0)")
            }
            TriggerGrid(tileSize: 80, spacing: 6)
                .frame(maxWidth: .infinity)
        }
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
                        .foregroundStyle(Design.secondaryText)
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

/// While the camera runs: what goes out right now and a one-click "Stop Camera", always first.
private struct StopCameraRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Label {
                Text(model.presence.title)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: model.presence.menuBarSymbol)
                    .foregroundStyle(.red)
                    .contentTransition(.symbolEffect(.replace))
            }
            Spacer(minLength: 4)
            Button("Stop Camera", systemImage: "stop.fill") { model.stop() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .help("Turns the camera off. Apps using MemeCam see \u{201C}MemeCam is paused\u{201D}.")
        }
        .accessibilityElement(children: .contain)
    }
}
