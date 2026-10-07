import SwiftUI

/// Empty / progress / error state inside the stage for every non-running camera state.
struct StateOverlay: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 14) {
            switch model.cameraState {
            case .running:
                EmptyView()
            case .idle:
                hero("face.smiling.inverse", tint: Design.brand)
                Text("Make a face. Get a meme.")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text("MemeCam picks a cat or hamster meme for your expression and sends it to Discord, Telegram and every other call app.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Design.secondaryText)
                    .frame(maxWidth: 440)
                actions(primary: "Start Camera", symbol: "video.fill") { model.start() }
            case .starting:
                ProgressView().controlSize(.large)
                Text("Starting camera…")
                    .font(.title3)
                    .foregroundStyle(Design.secondaryText)
            case .denied:
                hero("lock.shield", tint: .orange)
                Text("Camera Access Is Off").font(.title.bold())
                Text("MemeCam needs your camera to recognise expressions and gestures. Video never leaves your Mac.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Design.secondaryText)
                    .frame(maxWidth: 420)
                HStack(spacing: 12) {
                    Button("Open Privacy Settings") { model.openCameraPrivacySettings() }
                        .glassButtonStyle(prominent: true)
                    Button("Try Again") { model.start() }
                        .glassButtonStyle()
                }
                .controlSize(.large)
                .padding(.top, 4)
            case .failed(let message):
                hero("video.slash", tint: .red)
                Text("Couldn't Start the Camera").font(.title.bold())
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Design.secondaryText)
                    .frame(maxWidth: 420)
                actions(primary: "Try Again", symbol: "arrow.clockwise") { model.start() }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func hero(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 64, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .symbolEffect(.breathe, isActive: !reduceMotion)
            .padding(.bottom, 4)
            .accessibilityHidden(true)
    }

    /// The single primary action of the state (the camera itself is chosen in the toolbar).
    private func actions(primary: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(primary, systemImage: symbol)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 8)
        }
        .glassButtonStyle(prominent: true)
        .keyboardShortcut(.defaultAction)
        .controlSize(.extraLarge)
        .padding(.top, 8)
    }
}
