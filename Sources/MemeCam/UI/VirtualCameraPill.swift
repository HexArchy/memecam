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
        Button {
            model.virtualCamera.performPrimaryAction(startCamera: model.start)
            showDetail = true
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(state.tint.gradient)
                    .frame(width: 8, height: 8)
                Text(state == .streaming ? String(localized: "Virtual Camera On") : state.title)
                    .contentTransition(.interpolate)
            }
            .padding(.horizontal, 4)
        }
        .help(state.detail)
        .popover(isPresented: $showDetail, arrowEdge: .bottom) {
            VirtualCameraDetail()
                .frame(width: 280)
                .padding()
        }
        .accessibilityLabel("Virtual camera")
        .accessibilityValue(state.title)
        .accessibilityHint(state.detail)
    }
}

/// Status, explanation and next step for the virtual camera (popover + inspector).
struct VirtualCameraDetail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.virtualCamera.state
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(state == .streaming ? String(localized: "Virtual camera is on") : state.title).font(.headline)
            } icon: {
                Image(systemName: state.symbol).foregroundStyle(state.tint)
            }
            Text(state.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let action = state.actionTitle {
                Button(action) { model.virtualCamera.performPrimaryAction(startCamera: model.start) }
                    .buttonStyle(.borderedProminent)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Use MemeCam in other apps").font(.subheadline.bold())
                Text("1. Install the virtual camera.")
                Text("2. Allow it in System Settings \u{203A} General \u{203A} Login Items & Extensions \u{203A} Camera Extensions.")
                Text("3. In Discord, Telegram, Zoom or FaceTime choose \u{201C}MemeCam\u{201D} as the camera.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
