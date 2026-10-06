import SwiftUI

/// Liquid Glass control capsule below the stage: Stop (while running), layout, animals, calibrate.
/// Starting happens from the stage's empty state, so there is exactly one Start button.
struct ControlBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let running = model.cameraState == .running
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                if running {
                    StopButton()
                        .transition(.opacity.combined(with: .scale(0.9)))
                }
                ViewThatFits(in: .horizontal) {
                    OptionsCapsule(compact: false)
                    OptionsCapsule(compact: true)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .smooth, value: running)
    }
}

private struct StopButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.stop() } label: {
            Label("Stop", systemImage: "stop.fill")
                .font(.headline)
                .frame(minWidth: 64)
        }
        .glassButtonStyle()
        .controlSize(.extraLarge)
        .help("Stop camera (\u{2318}R)")
        .accessibilityLabel("Stop camera")
    }
}

private struct OptionsCapsule: View {
    @Environment(AppModel.self) private var model
    let compact: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 12) {
            Picker("Layout", selection: $model.layout) {
                ForEach(OutputLayout.allCases) { layout in
                    Group {
                        if compact {
                            Image(systemName: layout.symbol)
                        } else {
                            Text(layout.title)
                        }
                    }
                    .help(layout.title)
                    .accessibilityLabel(layout.title)
                    .tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Output layout (\u{2318}1, \u{2318}2, \u{2318}3)")

            divider

            HStack(spacing: 4) {
                Image(systemName: "pawprint.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Picker("Animals", selection: $model.animals) {
                    ForEach(AnimalFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            .help("Which animals to show")

            if model.cameraState == .running {
                divider
                calibrateButton
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .glassSurface(in: .capsule)
        .fixedSize()
    }

    private var calibrateButton: some View {
            Button {
                model.calibrate()
            } label: {
                Label("Calibrate", systemImage: model.isCalibrated ? "checkmark.circle.fill" : "face.dashed")
                    .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
            }
            .buttonStyle(.borderless)
            .help("Relax your face, look at the camera, then calibrate (\u{2318}K)")
            .accessibilityLabel("Calibrate neutral face")
    }

    private var divider: some View {
        Divider().frame(height: 18)
    }
}

/// Type-erased label style so the style can be chosen at runtime.
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView

    init<S: LabelStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
