import SwiftUI

/// Floating Liquid Glass control bar at the bottom of the preview.
struct ControlBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                startButton

                Picker("Layout", selection: $model.layout) {
                    ForEach(OutputLayout.allCases) { layout in
                        Label(layout.title, systemImage: layout.symbol)
                            .help(layout.title)
                            .tag(layout)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(6)
                .glassSurface(in: .capsule)
                .help("Output layout")

                Picker("Animals", selection: $model.animals) {
                    ForEach(AnimalFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassSurface(in: .capsule)
                .help("Which memes to show")

                VirtualCameraPill()
            }
        }
        .padding(8)
    }

    private var startButton: some View {
        let running = model.cameraState == .running
        return Button { model.toggle() } label: {
            Label(running ? "Stop" : "Start",
                  systemImage: running ? "stop.fill" : "video.fill")
                .font(.headline)
                .contentTransition(.symbolEffect(.replace))
                .frame(minWidth: 70)
        }
        .glassButtonStyle(prominent: !running)
        .controlSize(.large)
        .disabled(model.cameraState == .starting)
        .help(running ? "Stop camera (\u{2318}R)" : "Start camera (\u{2318}R)")
        .accessibilityLabel(running ? "Stop camera" : "Start camera")
    }
}
