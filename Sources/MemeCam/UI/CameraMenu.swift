import SwiftUI

/// Menu for choosing the input camera. Used in the toolbar, the stage empty state and the issue banner.
struct CameraMenu: View {
    @Environment(AppModel.self) private var model
    /// Fixed title (e.g. "Switch Camera"); nil shows the current camera's name.
    var title: String?

    var body: some View {
        @Bindable var model = model
        Menu {
            Picker("Camera", selection: $model.selectedCameraID) {
                Label("Default Camera", systemImage: "web.camera").tag(String?.none)
                ForEach(model.cameras) { camera in
                    Label(camera.isSuspended ? "\(camera.name) (unavailable)" : camera.name,
                          systemImage: camera.isContinuity ? "iphone" : "web.camera")
                        .tag(String?.some(camera.id))
                }
                // The preferred camera is remembered while it is away; MemeCam uses the default meanwhile
                // and switches back when it reconnects.
                if let missing = model.missingPreferredCamera {
                    Label("\(missing.name) (not connected)", systemImage: "web.camera")
                        .tag(String?.some(missing.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("Refresh Camera List", systemImage: "arrow.clockwise") { model.refreshCameras() }
        } label: {
            Label(title ?? currentName, systemImage: hasIssue ? "exclamationmark.triangle.fill" : "web.camera")
        }
        .help("Choose which camera MemeCam uses")
        .accessibilityLabel("Camera")
        .accessibilityValue(currentName)
    }

    private var hasIssue: Bool { model.cameraState == .running && model.status.cameraIssue != nil }

    private var currentName: String {
        if model.cameraState == .running, !model.status.cameraName.isEmpty { return model.status.cameraName }
        if let id = model.selectedCameraID, let camera = model.cameras.first(where: { $0.id == id }) {
            return camera.name
        }
        if let missing = model.missingPreferredCamera { return missing.name }
        return "Default Camera"
    }
}
