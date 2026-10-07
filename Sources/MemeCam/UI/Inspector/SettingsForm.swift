import MemeCamCore
import SwiftUI

/// Settings that have no other home in the window. The camera is chosen in the toolbar,
/// layout/animals/calibration live in the control bar, the virtual camera in its toolbar pill.
struct SettingsForm: View {
    @Environment(AppModel.self) private var model
    @AppStorage("debugExpanded") private var debugExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                Toggle("Quiet mode", isOn: $model.quietMode)
                    .help("Nothing on screen while you look neutral — memes pop up on a reaction, then hide.")
                if model.quietMode {
                    LabeledContent("Meme stays") {
                        HStack {
                            Slider(value: $model.popDuration, in: 2...10, step: 1) { Text("Meme stays") }
                                .labelsHidden()
                            Text("\(Int(model.popDuration)) s").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Pop-up style") {
                        Picker("Pop-up style", selection: $model.popStyle) {
                            ForEach(PopStyle.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .disabled(reduceMotion)
                    }
                    .help(reduceMotion
                          ? "Reduce Motion is on in System Settings, so memes fade in and out."
                          : "Pop: a sticker that springs in. Slide: glides in from the nearest edge. Fade: crossfade.")
                }
                LabeledContent("Cooldown") {
                    HStack {
                        Slider(value: $model.cooldown, in: 0...10, step: 1) { Text("Cooldown") }
                            .labelsHidden()
                        Text("\(Int(model.cooldown)) s").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .help("The same reaction can't pop up again for this long after its meme went away.")
                LabeledContent("Away after") {
                    Picker("Away after", selection: $model.awayDelay) {
                        ForEach(AwayDelay.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .help("After this long with nobody in front of the camera, the call sees a blurred camera with \u{201C}Be right back\u{201D} until you return.")
                Toggle("Mirror camera", isOn: $model.mirror)
                Toggle("Show reaction caption", isOn: $model.showCaption)
            } header: {
                Label("Picture", systemImage: "rectangle.on.rectangle")
            }

            Section {
                Toggle(isOn: $model.slotHotKeysEnabled) {
                    Text("Hotkeys \u{2303}\u{2325}1 – \u{2303}\u{2325}9")
                }
                .help("Fire the nine trigger slots from any app, even while Discord or Zoom is in front.")
                Toggle("Floating palette", isOn: $model.paletteVisible)
                    .help("A small always-on-top grid of the trigger slots (\u{2303}\u{2325}0).")
            } header: {
                Label("Triggers", systemImage: "square.grid.3x3")
            } footer: {
                Text("Click a tile in the palette or the menu bar to pop its meme up. Right-click a tile to assign a reaction or one specific meme.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Stop camera when Mac locks", isOn: $model.stopCameraWhenLocked)
            } header: {
                Label("Camera", systemImage: "web.camera")
            } footer: {
                Text("The camera turns back on when you unlock, if it was running. It always pauses while the Mac sleeps.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            LanguageSection()

            UpdatesSection()

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
        row("Vision rate", status.idle ? String(localized: "paused") : "\(Int(status.visionHz)) Hz")
        if let note = status.powerNote { row("Power", note) }
        if let m = status.metrics {
            row("Mouth open", fmt(m.mouthOpen))
            row("Mouth width", fmt(m.mouthWidth))
            row("Corner lift", fmt(m.cornerLift))
            row("Eye open", fmt(m.eyeOpen))
            row("Brow raise", fmt(m.browRaise))
            row("Roll", "\(m.rollDegrees.formatted(.number.precision(.fractionLength(1))))\u{00B0}")
        } else {
            row("Face", String(localized: "none"))
        }
    }

    private func fmt(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(3))) }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
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

private struct UpdatesSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var updater = model.updater
        Section {
            PrivacyNote()
            Toggle("Check for updates automatically", isOn: $updater.automaticChecks)
            LabeledContent("Version \(updater.currentVersion)") {
                Button("Check Now") { Task { await updater.check(userInitiated: true) } }
                    .disabled(updater.state == .checking)
            }
            if updater.state == .upToDate {
                Label("You're up to date", systemImage: "checkmark.seal").foregroundStyle(.secondary)
            } else if case .failed(let message) = updater.state {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Label("Updates", systemImage: "arrow.down.circle")
        } footer: {
            Text("Updates come from GitHub Releases, are verified against MemeCam's signature and Apple notarization, then installed and relaunched.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
