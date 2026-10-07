import MemeCamCore
import SwiftUI

extension VirtualCameraState {
    var tint: Color {
        switch self {
        case .streaming: .green
        case .ready: .blue
        case .connecting, .checking: .yellow
        case .notInstalled, .awaitingApproval: .orange
        case .failed: .red
        }
    }

    var symbol: String {
        switch self {
        case .streaming: "checkmark.circle.fill"
        case .ready: "pause.circle"
        case .connecting, .checking: "ellipsis.circle"
        case .notInstalled: "arrow.down.circle"
        case .awaitingApproval: "lock.open"
        case .failed: "exclamationmark.triangle"
        }
    }

    var detail: String {
        switch self {
        case .checking: String(localized: "Checking the MemeCam virtual camera.")
        case .notInstalled: String(localized: "Install the virtual camera so other apps can use MemeCam.")
        case .awaitingApproval: String(localized: "Allow MemeCam in System Settings > General > Login Items & Extensions > Camera Extensions.")
        case .connecting: String(localized: "Connecting to the virtual camera.")
        case .ready: String(localized: "Installed. Start the camera (⌘R) to send memes — until then other apps see “MemeCam is paused”.")
        case .streaming: String(localized: "Other apps can pick the \u{201C}MemeCam\u{201D} camera.")
        case .failed(let message): message
        }
    }

    /// Title of the one action that moves this state forward, if any.
    var actionTitle: String? {
        switch self {
        case .notInstalled: String(localized: "Install Virtual Camera")
        case .awaitingApproval: String(localized: "Open System Settings")
        case .failed: String(localized: "Retry")
        case .ready: String(localized: "Start Camera")
        case .checking, .connecting, .streaming: nil
        }
    }
}

extension VirtualCameraController {
    /// Performs `state.actionTitle`'s action.
    func performPrimaryAction(startCamera: () -> Void = {}) {
        switch state {
        case .ready: startCamera()
        case .notInstalled: install()
        case .awaitingApproval: openSystemSettings()
        case .failed: refresh()
        case .checking, .connecting, .streaming: break
        }
    }
}

/// Toolbar status of the virtual camera; doubles as the install / approve button.
struct VirtualCameraPill: View {
    @Environment(AppModel.self) private var model
    @State private var showDetail = false

    var body: some View {
        let state = model.virtualCamera.state
        let testPattern = model.virtualCamera.testPattern
        Button {
            model.virtualCamera.performPrimaryAction(startCamera: model.start)
            showDetail = true
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(testPattern ? Color.purple.gradient : state.tint.gradient)
                    .frame(width: 8, height: 8)
                Text(testPattern ? String(localized: "Test Pattern On")
                     : state == .streaming ? String(localized: "Virtual Camera On") : state.title)
                    .contentTransition(.interpolate)
            }
            .padding(.horizontal, 4)
        }
        .help(state.detail)
        .popover(isPresented: $showDetail, arrowEdge: .bottom) {
            VirtualCameraDetail()
                .frame(width: 320)
                .padding()
        }
        .accessibilityLabel("Virtual camera")
        .accessibilityValue(state.title)
        .accessibilityHint(state.detail)
    }
}

/// Status, live health checklist with one-click fixes, and the test-pattern switch.
struct VirtualCameraDetail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var virtualCamera = model.virtualCamera
        let state = virtualCamera.state
        let items = VirtualCameraChecklist.evaluate(
            virtualCamera.checklistInput(cameraRunning: model.cameraState == .running))
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(state == .streaming ? String(localized: "Virtual camera is on") : state.title).font(.headline)
            } icon: {
                Image(systemName: state.symbol).foregroundStyle(state.tint)
            }
            if case .failed(let message) = state {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(items, id: \.kind) { item in
                    HealthRow(item: item, detail: detail(for: item)) { perform(item.fix) }
                }
            }
            Divider()
            Toggle(isOn: $virtualCamera.testPattern) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send test pattern")
                    Text("Colour bars and a clock instead of your camera — check that Discord or Telegram see MemeCam.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .disabled(!virtualCamera.deviceVisible && !virtualCamera.testPattern)
            Text("In Discord, Telegram, Zoom or FaceTime choose \u{201C}MemeCam\u{201D} as the camera.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { model.virtualCamera.beginHealthMonitoring() }
        .onDisappear { model.virtualCamera.endHealthMonitoring() }
    }

    private func perform(_ fix: VirtualCameraChecklist.Fix?) {
        switch fix {
        case .install: model.virtualCamera.install()
        case .openSettings: model.virtualCamera.openSystemSettings()
        case .startCamera: model.start()
        case .retry: model.virtualCamera.refresh()
        case nil: break
        }
    }

    private func detail(for item: VirtualCameraChecklist.Item) -> String {
        let health = model.virtualCamera.health
        switch (item.kind, item.status) {
        case (.extensionEnabled, .ok): return String(localized: "The camera extension is on.")
        case (.extensionEnabled, .warning): return String(localized: "Allow it in Login Items & Extensions \u{203A} Camera Extensions.")
        case (.extensionEnabled, .failed): return item.fix == .install ? String(localized: "Not installed yet.")
                                                                       : String(localized: "Couldn't install it.")
        case (.deviceVisible, .ok): return String(localized: "Discord, Telegram and Zoom can pick \u{201C}MemeCam\u{201D}.")
        case (.deviceVisible, .warning): return String(localized: "Switch MemeCam on in Camera Extensions.")
        case (.framesFlowing, .ok):
            let fps = health.fps.formatted(.number.precision(.fractionLength(0)))
            return model.virtualCamera.testPattern ? String(localized: "Test pattern \u{00B7} \(fps) fps")
                                                   : String(localized: "\(fps) fps")
        case (.framesFlowing, .warning): return String(localized: "The camera is off. Start it, or send the test pattern.")
        case (.appsUsing, .ok): return String(localized: "\(health.clients ?? 0) apps")
        case (.appsUsing, .info): return String(localized: "None right now.")
        case (_, .pending): return item.kind == .extensionEnabled ? String(localized: "Checking…") : String(localized: "Waiting…")
        default: return ""
        }
    }
}

/// One checklist row: status icon, title, live detail and its fix button.
private struct HealthRow: View {
    let item: VirtualCameraChecklist.Item
    let detail: String
    let fix: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // One element per check: "Frames flowing, Needs attention, The camera is off…" (the colour
            // of the icon is the only other place the status shows).
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue([statusText, detail].filter { !$0.isEmpty }.joined(separator: ", "))
            Spacer(minLength: 4)
            if let fixTitle {
                // Its own element, right after its check, so VoiceOver can press it.
                Button(fixTitle, action: fix)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint(title)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var statusText: String {
        switch item.status {
        case .ok: String(localized: "OK")
        case .warning: String(localized: "Needs attention")
        case .failed: String(localized: "Failed")
        case .pending: String(localized: "Checking")
        case .info: ""
        }
    }

    private var title: String {
        switch item.kind {
        case .extensionEnabled: String(localized: "Extension installed & enabled")
        case .deviceVisible: String(localized: "MemeCam camera visible to apps")
        case .framesFlowing: String(localized: "Frames flowing")
        case .appsUsing: String(localized: "Apps using the camera right now")
        }
    }

    private var fixTitle: String? {
        switch item.fix {
        case .install: String(localized: "Install")
        case .openSettings: String(localized: "Open System Settings")
        case .startCamera: String(localized: "Start Camera")
        case .retry: String(localized: "Retry")
        case nil: nil
        }
    }

    private var symbol: String {
        switch item.status {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .pending: "circle.dotted"
        case .info: "circle"
        }
    }

    private var tint: Color {
        switch item.status {
        case .ok: .green
        case .warning: .orange
        case .failed: .red
        case .pending, .info: .secondary
        }
    }
}
