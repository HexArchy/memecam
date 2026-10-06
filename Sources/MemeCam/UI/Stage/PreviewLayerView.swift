import AVFoundation
import AppKit
import SwiftUI

/// Hosts the shared `AVSampleBufferDisplayLayer` that the pipeline renders into.
struct PreviewLayerView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> HostView { HostView(content: layer) }

    func updateNSView(_ view: HostView, context: Context) {}

    final class HostView: NSView {
        private let content: CALayer

        init(content: CALayer) {
            self.content = content
            super.init(frame: .zero)
            wantsLayer = true
            layer?.addSublayer(content)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            content.frame = bounds
            CATransaction.commit()
        }
    }
}
