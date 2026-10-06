import SwiftUI

/// 16:9 preview with overlays: reaction chip (top-left), state CTA (center), controls (bottom).
struct PreviewStage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let running = model.cameraState == .running
        ZStack {
            Rectangle().fill(.black.opacity(running ? 1 : 0.06))
            PreviewLayerView(layer: model.preview.layer)
                .opacity(running ? 1 : 0)
                .accessibilityLabel("Live preview of the MemeCam output")
            if !running { StateOverlay() }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .overlay(alignment: .topLeading) {
            if running {
                ReactionChip(reaction: model.status.reaction, confidence: model.status.confidence)
                    .padding(16)
                    .transition(.opacity.combined(with: .scale(0.95)))
            }
        }
        .overlay(alignment: .bottom) {
            ControlBar().padding(.bottom, 8)
        }
        .clipShape(.rect(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .animation(reduceMotion ? nil : .smooth, value: running)
    }
}
