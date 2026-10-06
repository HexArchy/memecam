import SwiftUI

/// Shown on the stage while the camera runs but delivers no / black video.
struct CameraIssueBanner: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .symbolRenderingMode(.multicolor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Check Your Camera")
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            CameraMenu(title: "Switch Camera")
                .menuStyle(.button)
                .glassButtonStyle(prominent: true)
                .fixedSize()
            Button("Restart", systemImage: "arrow.clockwise") {
                model.stop()
                model.start()
            }
            .labelStyle(.iconOnly)
            .glassButtonStyle()
            .help("Restart the camera")
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 680)
        .glassSurface(in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Camera problem")
    }
}
