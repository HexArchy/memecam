import SwiftUI

/// The 16:9 output preview, framed like a screen. Overlays: reaction chip (top-left),
/// camera issue banner (top), empty / error state when the camera isn't running.
struct PreviewStage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isPreviewSuspended) private var previewSuspended

    var body: some View {
        let running = model.cameraState == .running
        let issue = running ? model.cameraSwitchError ?? model.status.cameraIssue : nil
        ZStack {
            if running {
                Color.black
            } else {
                StageBackdrop()
            }
            if !previewSuspended {
                PreviewLayerView(layer: model.preview.layer)
                    .opacity(running ? 1 : 0)
                    .accessibilityLabel("Live preview of the MemeCam output")
            }
            if !running {
                StateOverlay()
                    .transition(.opacity)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .overlay(alignment: .topLeading) {
            if running, issue == nil, model.status.guided == nil {
                ReactionChip(reaction: model.status.reaction, confidence: model.status.confidence,
                             paused: model.memesPaused, away: model.isAway)
                    .padding(14)
                    .transition(.opacity.combined(with: .scale(0.95, anchor: .topLeading)))
            }
        }
        .overlay(alignment: .top) {
            if let issue {
                CameraIssueBanner(message: issue)
                    .padding(14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .overlay { AccuracyTestOverlay() }
        .clipShape(.rect(cornerRadius: Design.stageRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Design.stageRadius)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 28, y: 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .smooth, value: running)
        .animation(reduceMotion ? nil : .smooth, value: issue)
    }
}

/// Calm gradient shown inside the stage while the camera is off.
private struct StageBackdrop: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            LinearGradient(colors: [Design.brandSecondary.opacity(0.22), Design.brand.opacity(0.14),
                                    Color.purple.opacity(0.14)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

extension EnvironmentValues {
    /// True while another view (the onboarding) shows the shared preview layer.
    // Manual key: the @Entry macro plugin isn't available with Command Line Tools builds.
    var isPreviewSuspended: Bool {
        get { self[PreviewSuspendedKey.self] }
        set { self[PreviewSuspendedKey.self] = newValue }
    }
}

private struct PreviewSuspendedKey: EnvironmentKey {
    static let defaultValue = false
}
