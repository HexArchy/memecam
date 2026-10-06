import SwiftUI

struct InspectorView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case settings = "Settings", memes = "Memes"
        var id: String { rawValue }
    }

    @AppStorage("inspectorTab") private var tab = Tab.settings

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector section", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 12)
            .padding(.bottom, 4)

            switch tab {
            case .settings: SettingsForm()
            case .memes: MemeGalleryView()
            }
        }
    }
}

private struct SettingsForm: View {
    @Environment(AppModel.self) private var model
    @AppStorage("debugExpanded") private var debugExpanded = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Camera") {
                Picker("Camera", selection: $model.selectedCameraID) {
                    Text("Default").tag(String?.none)
                    ForEach(model.cameras) { Text($0.name).tag(String?.some($0.id)) }
                }
                Toggle("Mirror preview", isOn: $model.mirror)
            }

            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Slider(value: $model.sensitivity, in: 0.5...1.5) {
                        Text("Sensitivity")
                    } minimumValueLabel: {
                        Text("Low").font(.caption)
                    } maximumValueLabel: {
                        Text("High").font(.caption)
                    }
                }
                Slider(value: $model.calmness, in: 0.5...2) {
                    Text("Reaction speed")
                } minimumValueLabel: {
                    Text("Snappy").font(.caption)
                } maximumValueLabel: {
                    Text("Calm").font(.caption)
                }
                Toggle("Expressions", isOn: $model.detectExpressions)
                Toggle("Hand gestures", isOn: $model.detectHands)
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        model.calibrate()
                    } label: {
                        Label("Calibrate Neutral Face",
                              systemImage: model.isCalibrated ? "checkmark.circle.fill" : "face.dashed")
                    }
                    .disabled(model.cameraState != .running)
                    .help("Calibrate neutral face (\u{2318}K)")
                    Text("Relax your face and look at the camera, then calibrate. Expressions are measured against it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Detection")
            }

            Section("Output") {
                Toggle("Show caption", isOn: $model.showCaption)
            }

            Section("Virtual Camera") {
                let state = model.virtualCamera.state
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(state.tint).frame(width: 8, height: 8)
                        Text(state.title)
                    }
                }
                switch state {
                case .notInstalled:
                    Button("Install Virtual Camera") { model.virtualCamera.install() }
                case .awaitingApproval:
                    Button("Open System Settings") { model.virtualCamera.openSystemSettings() }
                case .failed:
                    Button("Retry") { model.virtualCamera.refresh() }
                default:
                    EmptyView()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Use MemeCam in Discord, Telegram and more").font(.caption.weight(.semibold))
                    Text("1. Install the virtual camera above.")
                    Text("2. Allow it in System Settings > Login Items & Extensions > Camera Extensions.")
                    Text("3. In the other app, choose \u{201C}MemeCam\u{201D} as your camera.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup("Debug", isExpanded: $debugExpanded) {
                    DebugRows(status: model.status)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct DebugRows: View {
    let status: PipelineStatus

    var body: some View {
        row("Output FPS", status.outputFPS.formatted(.number.precision(.fractionLength(1))))
        row("Inference", "\(status.inferenceMs.formatted(.number.precision(.fractionLength(1)))) ms")
        if let m = status.metrics {
            row("Mouth open", fmt(m.mouthOpen))
            row("Mouth width", fmt(m.mouthWidth))
            row("Corner lift", fmt(m.cornerLift))
            row("Eye open", fmt(m.eyeOpen))
            row("Brow raise", fmt(m.browRaise))
            row("Roll", "\(m.rollDegrees.formatted(.number.precision(.fractionLength(1))))\u{00B0}")
        } else {
            row("Face", "none")
        }
    }

    private func fmt(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(3))) }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(value).monospacedDigit() }
            .font(.caption)
    }
}
