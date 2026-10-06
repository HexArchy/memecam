import AVFoundation
import AppKit
import SwiftUI

/// Hosts the shared `AVSampleBufferDisplayLayer` that the pipeline renders into.
///
/// The layer can live in only one view at a time: whichever `PreviewLayerView` was created last
/// adopts it (e.g. the onboarding's camera viewport, then the stage again).
struct PreviewLayerView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    /// Visible part of the 16:9 output in unit coordinates, origin bottom-left (Core Image / CALayer).
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)

    func makeNSView(context: Context) -> HostView { HostView(content: layer, crop: crop) }

    func updateNSView(_ view: HostView, context: Context) {
        guard view.crop != crop else { return }
        view.crop = crop
        view.needsLayout = true
    }

    final class HostView: NSView {
        private let content: CALayer
        var crop: CGRect

        init(content: CALayer, crop: CGRect) {
            self.content = content
            self.crop = crop
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = true
            layer?.addSublayer(content)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            // Another host adopted the shared layer; don't fight over its frame.
            guard content.superlayer === layer, crop.width > 0, crop.height > 0 else { return }
            let full = CGSize(width: bounds.width / crop.width, height: bounds.height / crop.height)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            content.frame = CGRect(x: -crop.minX * full.width, y: -crop.minY * full.height,
                                   width: full.width, height: full.height)
            CATransaction.commit()
        }
    }
}
