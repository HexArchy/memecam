import SwiftUI

/// Full-preview content for every non-running camera state.
struct StateOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            switch model.cameraState {
            case .running:
                EmptyView()
            case .idle:
                Image(systemName: "face.smiling")
                    .font(.system(size: 56))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                Text("MemeCam").font(.largeTitle.bold())
                Text("Make a face. Get a meme. Show it on every call.")
                    .foregroundStyle(.secondary)
                Button { model.start() } label: {
                    Label("Start Camera", systemImage: "video.fill")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 12)
                }
                .glassButtonStyle(prominent: true)
                .controlSize(.extraLarge)
                .padding(.top, 6)
            case .starting:
                ProgressView().controlSize(.large)
                Text("Starting camera…").foregroundStyle(.secondary)
            case .denied:
                Image(systemName: "lock.shield")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
                Text("Camera access is off").font(.title2.bold())
                Text("MemeCam needs your camera to recognise expressions and gestures. Video never leaves your Mac.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 360)
                HStack {
                    Button("Open Privacy Settings") { model.openCameraPrivacySettings() }
                        .glassButtonStyle(prominent: true)
                    Button("Try Again") { model.start() }
                        .glassButtonStyle()
                }
                .controlSize(.large)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48))
                    .foregroundStyle(.yellow)
                Text("Couldn't start the camera").font(.title2.bold())
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 360)
                Button { model.start() } label: { Label("Retry", systemImage: "arrow.clockwise") }
                    .glassButtonStyle(prominent: true)
                    .controlSize(.large)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}
