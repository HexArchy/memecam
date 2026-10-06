import SwiftUI

/// Settings that have no other home in the window. The camera is chosen in the toolbar,
/// layout/animals/calibration live in the control bar, the virtual camera in its toolbar pill.
struct SettingsForm: View {
    @Environment(AppModel.self) private var model
    @AppStorage("debugExpanded") private var debugExpanded = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Facial expressions", isOn: $model.detectExpressions)
                Toggle("Hand gestures", isOn: $model.detectHands)
                LabeledContent("Sensitivity") {
                    Slider(value: $model.sensitivity, in: 0.5...1.5) {
                        Text("Sensitivity")
                    } minimumValueLabel: {
                        Text("Low")
                    } maximumValueLabel: {
                        Text("High")
                    }
                    .labelsHidden()
                }
                LabeledContent("Reaction speed") {
                    Slider(value: $model.calmness, in: 0.5...2) {
                        Text("Reaction speed")
                    } minimumValueLabel: {
                        Text("Snappy")
                    } maximumValueLabel: {
                        Text("Calm")
                    }
                    .labelsHidden()
                }
            } header: {
                Label("Detection", systemImage: "face.smiling")
            } footer: {
                Text("Calibrate from the control bar while the camera runs: relax your face and look at the camera.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Mirror camera", isOn: $model.mirror)
                Toggle("Show reaction caption", isOn: $model.showCaption)
            } header: {
                Label("Picture", systemImage: "rectangle.on.rectangle")
            }

            AccuracySection()

            Section {
                DisclosureGroup("Diagnostics", isExpanded: $debugExpanded) {
                    DebugRows(status: model.status)
                }
            } header: {
                Label("Debug", systemImage: "ladybug")
            }
        }
        .formStyle(.grouped)
    }
}

private struct DebugRows: View {
    let status: PipelineStatus

    var body: some View {
        row("Camera", status.cameraName.isEmpty ? "—" : status.cameraName)
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
            .font(.callout)
    }
}

/// Guided ~90 s test that measures how well detection works on *this* user.
private struct AccuracySection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            if let g = model.status.guided {
                LabeledContent("Step") { Text("\(g.stepIndex + 1) of \(g.stepCount)").monospacedDigit() }
                ProgressView(value: g.overallProgress)
                Button("Cancel Test", role: .cancel) { model.cancelAccuracyTest() }
            } else {
                Button("Run Accuracy Test…", systemImage: "checklist") { model.startAccuracyTest() }
                if let report = model.lastEvaluation {
                    ScrollView(.horizontal) {
                        Text(report)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize()
                    }
                    Button("Show Recordings in Finder", systemImage: "folder") { model.revealRecordings() }
                }
            }
        } header: {
            Label("Accuracy", systemImage: "scope")
        } footer: {
            Text("About 3 minutes. Each reaction: get ready, then hold it. Space pauses, → skips, ← redoes. MemeCam scores itself on your face.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
