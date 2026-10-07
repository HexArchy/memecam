import AVFoundation
import SwiftUI

/// What the face guide over the live camera should show.
enum FaceGuideState: Equatable {
    case hidden
    /// Looking for a face (dashed, slowly marching ring).
    case searching
    /// Face found (solid green ring).
    case locked
    /// Calibration measuring, 0...1 traced around the oval.
    case measuring(Double)
    case done
}

extension OutputLayout {
    /// Where the camera image sits inside the 1280×720 output (unit coordinates, origin bottom-left).
    var cameraCrop: CGRect {
        switch self {
        case .sideBySide: CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .pictureInPicture: CGRect(x: 0, y: 0, width: 1, height: 1)
        case .memeOnly: CGRect(x: 24 / 1280, y: 24 / 720, width: 200 / 1280, height: 200 / 720)
        }
    }

    /// Width / height of `cameraCrop` in points.
    var cameraAspect: CGFloat {
        let crop = cameraCrop
        return (crop.width * 16) / (crop.height * 9)
    }
}

/// The live camera part of the shared preview, cropped out of the composed output, with a face guide.
struct CameraViewport: View {
    let layer: AVSampleBufferDisplayLayer
    let layout: OutputLayout
    let guide: FaceGuideState

    var body: some View {
        let radius: CGFloat = 24
        ZStack {
            Color.black
            PreviewLayerView(layer: layer, crop: layout.cameraCrop)
                .accessibilityHidden(true)
            FaceGuide(state: guide)
        }
        .aspectRatio(layout.cameraAspect, contentMode: .fit)
        .clipShape(.rect(cornerRadius: radius))
        .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(.white.opacity(0.14)) }
        .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Camera preview")
        .accessibilityValue(guide.accessibilityValue)
    }
}

private extension FaceGuideState {
    var accessibilityValue: String {
        switch self {
        case .hidden: ""
        case .searching: String(localized: "Looking for your face")
        case .locked: String(localized: "Face found")
        case .measuring(let p): String(localized: "Calibrating, \(Int(p * 100)) percent")
        case .done: String(localized: "Calibrated")
        }
    }
}

/// Oval ring + vignette. Dashed while searching, green when a face is found, a gradient trace while measuring.
private struct FaceGuide: View {
    let state: FaceGuideState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var march = false

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height * 0.74
            let w = min(geo.size.width * 0.7, h * 0.76)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.48)
            ZStack {
                vignette(oval: CGSize(width: w, height: h), center: center)
                ring(width: w, height: h)
                    .position(center)
                if case .done = state {
                    SuccessCheckmark()
                        .position(center)
                        .transition(.scale(0.4).combined(with: .opacity))
                }
            }
        }
        .opacity(state == .hidden ? 0 : 1)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .bouncy(duration: 0.5), value: state)
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { march = true }
        }
    }

    private var locked: Bool {
        switch state {
        case .locked, .measuring, .done: true
        default: false
        }
    }

    private func vignette(oval: CGSize, center: CGPoint) -> some View {
        Rectangle()
            .fill(.black.opacity(locked ? 0.28 : 0.4))
            .mask {
                ZStack {
                    Rectangle()
                    Ellipse()
                        .frame(width: oval.width, height: oval.height)
                        .position(center)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            }
    }

    @ViewBuilder
    private func ring(width w: CGFloat, height h: CGFloat) -> some View {
        ZStack {
            Ellipse()
                .stroke(locked ? AnyShapeStyle(OnboardingStyle.success) : AnyShapeStyle(.white.opacity(0.85)),
                        style: StrokeStyle(lineWidth: locked ? 3 : 2.5, lineCap: .round,
                                           dash: locked ? [] : [7, 9], dashPhase: march ? -16 : 0))
                .frame(width: w, height: h)
                .scaleEffect(locked ? 1 : 0.97)
            // Progress trace starting at 12 o'clock: draw a sideways oval and rotate it upright.
            Ellipse()
                .trim(from: 0, to: progress)
                .stroke(OnboardingStyle.accentGradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .frame(width: h, height: w)
                .rotationEffect(.degrees(-90))
                .shadow(color: Design.brand.opacity(0.6), radius: 6)
                .animation(.smooth(duration: 0.35), value: progress)
        }
    }

    private var progress: Double {
        switch state {
        case .measuring(let p): max(0.02, min(p, 1))
        case .done: 1
        default: 0
        }
    }
}

/// Big green checkmark that bounces once when it appears.
struct SuccessCheckmark: View {
    var size: CGFloat = 56
    @State private var bounce = false

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: size, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, OnboardingStyle.success)
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            .symbolEffect(.bounce, options: .nonRepeating, value: bounce)
            .task {
                try? await Task.sleep(for: .milliseconds(120))
                bounce = true
            }
            .accessibilityHidden(true)
    }
}
