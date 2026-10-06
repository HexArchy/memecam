import SwiftUI

extension VirtualCameraState {
    var tint: Color {
        switch self {
        case .streaming: .green
        case .connecting, .checking: .yellow
        case .notInstalled, .awaitingApproval: .orange
        case .failed: .red
        }
    }

    var symbol: String {
        switch self {
        case .streaming: "checkmark.circle.fill"
        case .connecting, .checking: "ellipsis.circle"
        case .notInstalled: "arrow.down.circle"
        case .awaitingApproval: "lock.open"
        case .failed: "exclamationmark.triangle"
        }
    }

    var detail: String {
        switch self {
        case .checking: "Checking the MemeCam virtual camera."
        case .notInstalled: "Install the virtual camera so other apps can use MemeCam."
        case .awaitingApproval: "Allow MemeCam in System Settings > General > Login Items & Extensions > Camera Extensions."
        case .connecting: "Connecting to the virtual camera."
        case .streaming: "Other apps can pick the \"MemeCam\" camera."
        case .failed(let message): message
        }
    }
}

/// Status pill for the virtual camera; doubles as the install / approve button.
struct VirtualCameraPill: View {
    @Environment(AppModel.self) private var model
    @State private var showHint = false

    var body: some View {
        let state = model.virtualCamera.state
        Button { act(on: state) } label: {
            HStack(spacing: 7) {
                Circle().fill(state.tint).frame(width: 8, height: 8)
                Text(state == .streaming ? "Live" : state.title)
                    .font(.subheadline.weight(.medium))
                    .contentTransition(.interpolate)
            }
            .padding(.horizontal, 6)
        }
        .glassButtonStyle()
        .controlSize(.large)
        .help(state.detail)
        .popover(isPresented: $showHint, arrowEdge: .top) {
            Text(model.virtualCamera.state.detail)
                .font(.callout)
                .frame(width: 240, alignment: .leading)
                .padding()
        }
        .accessibilityLabel("Virtual camera")
        .accessibilityValue(state.title)
        .accessibilityHint(state.detail)
    }

    private func act(on state: VirtualCameraState) {
        switch state {
        case .notInstalled:
            model.virtualCamera.install()
        case .awaitingApproval:
            model.virtualCamera.openSystemSettings()
            showHint = true
        case .failed:
            model.virtualCamera.refresh()
            showHint = true
        case .checking, .connecting, .streaming:
            showHint = true
        }
    }
}
