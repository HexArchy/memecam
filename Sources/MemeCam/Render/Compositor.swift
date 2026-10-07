import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Metal
import MemeCamCore

enum OutputLayout: String, CaseIterable, Identifiable, Sendable {
    case sideBySide, pictureInPicture, memeOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sideBySide: "Side by Side"
        case .pictureInPicture: "Picture in Picture"
        case .memeOnly: "Meme Only"
        }
    }
    var symbol: String {
        switch self {
        case .sideBySide: "rectangle.split.2x1"
        case .pictureInPicture: "pip"
        case .memeOnly: "photo"
        }
    }
}

struct CompositorInput {
    var camera: CIImage?
    var meme: CGImage?
    /// Previous meme frame + progress 0...1 for a short crossfade.
    var previousMeme: CGImage?
    var transition: Double = 1
    var caption: String?
    var layout: OutputLayout = .sideBySide
    var mirror = true
    /// 0 = camera only (full frame), 1 = the layout with the meme; in between = crossfade.
    var presence: Double = 1
}

/// Renders the final 1280×720 BGRA frame that the preview and the virtual camera share.
/// GPU-only path: CIContext on Metal, IOSurface-backed pool buffers, no CPU copies.
final class Compositor: @unchecked Sendable {
    static let size = CGSize(width: 1280, height: 720)

    private let context: CIContext
    private var pool: CVPixelBufferPool?
    private var captionCache: (String, CIImage)?
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .name: "MemeCam"])
        } else {
            context = CIContext(options: [.cacheIntermediates: false])
        }
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Int(Self.size.width),
            kCVPixelBufferHeightKey: Int(Self.size.height),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary,
                                attrs as CFDictionary, &pool)
    }

    func render(_ input: CompositorInput) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return nil }

        let canvas = CGRect(origin: .zero, size: Self.size)
        let background = CIImage(color: CIColor(red: 0.08, green: 0.08, blue: 0.1)).cropped(to: canvas)
        var cam = input.camera
        if input.mirror, let c = cam {
            // fill() re-normalises the extent origin, so a bare flip is enough.
            cam = c.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
        }
        let cameraOnly = cam.map { fill($0, in: canvas).composited(over: background) } ?? background

        let image: CIImage
        if input.presence <= 0 || input.meme == nil {
            image = cameraOnly
        } else {
            let withMeme = composeLayout(input, camera: cam, canvas: canvas, background: background)
            if input.presence >= 1 {
                image = withMeme
            } else {
                let f = CIFilter.dissolveTransition()
                f.inputImage = cameraOnly
                f.targetImage = withMeme
                f.time = Float(input.presence)
                image = f.outputImage?.cropped(to: canvas) ?? withMeme
            }
        }

        context.render(image, to: out, bounds: canvas, colorSpace: colorSpace)
        return out
    }

    private func composeLayout(_ input: CompositorInput, camera cam: CIImage?, canvas: CGRect,
                               background: CIImage) -> CIImage {
        var image = background
        let meme = memeImage(input)

        switch input.layout {
        case .sideBySide:
            let left = CGRect(x: 0, y: 0, width: canvas.width / 2, height: canvas.height)
            let right = CGRect(x: canvas.width / 2, y: 0, width: canvas.width / 2, height: canvas.height)
            if let cam { image = fill(cam, in: left).composited(over: image) }
            if let meme { image = fitWithBackdrop(meme, in: right).composited(over: image) }
        case .pictureInPicture:
            if let cam { image = fill(cam, in: canvas).composited(over: image) }
            if let meme {
                let w = canvas.width * 0.36, h = w * 0.75, m: CGFloat = 24
                let card = CGRect(x: canvas.maxX - w - m, y: m, width: w, height: h)
                image = rounded(fitWithBackdrop(meme, in: card), rect: card, radius: 22).composited(over: image)
            }
        case .memeOnly:
            if let meme { image = fitWithBackdrop(meme, in: canvas).composited(over: image) }
            if let cam {
                let d: CGFloat = 200, m: CGFloat = 24
                let bubble = CGRect(x: m, y: m, width: d, height: d)
                image = rounded(fill(cam, in: bubble), rect: bubble, radius: d / 2).composited(over: image)
            }
        }

        if let caption = input.caption, !caption.isEmpty {
            image = captionImage(caption, canvas: canvas, layout: input.layout).composited(over: image)
        }
        return image
    }

    /// Mean brightness 0...1 of an image (GPU reduction to 1 px). Used to detect black cameras.
    func averageBrightness(_ image: CIImage) -> Double {
        let f = CIFilter.areaAverage()
        f.inputImage = image
        f.extent = image.extent
        guard let out = f.outputImage else { return 1 }
        var px = [UInt8](repeating: 0, count: 4)
        context.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)
        return (Double(px[0]) * 0.3 + Double(px[1]) * 0.59 + Double(px[2]) * 0.11) / 255
    }

    // MARK: - Pieces

    private func memeImage(_ input: CompositorInput) -> CIImage? {
        guard let cg = input.meme else { return nil }
        let current = CIImage(cgImage: cg)
        guard let prev = input.previousMeme, input.transition < 1 else { return current }
        // Crossfade at a common extent: normalise both to the current meme's size.
        let p = CIImage(cgImage: prev)
        let scaled = p.transformed(by: CGAffineTransform(scaleX: current.extent.width / p.extent.width,
                                                         y: current.extent.height / p.extent.height))
        let f = CIFilter.dissolveTransition()
        f.inputImage = scaled
        f.targetImage = current
        f.time = Float(input.transition)
        return f.outputImage?.cropped(to: current.extent)
    }

    /// Aspect-fill `img` into `rect`.
    private func fill(_ img: CIImage, in rect: CGRect) -> CIImage {
        let e = img.extent
        let s = max(rect.width / e.width, rect.height / e.height)
        let t = CGAffineTransform(translationX: -e.minX, y: -e.minY)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: rect.midX - e.width * s / 2,
                                             y: rect.midY - e.height * s / 2))
        return img.transformed(by: t).cropped(to: rect)
    }

    /// Aspect-fit `img` into `rect` over a blurred, darkened fill of itself.
    private func fitWithBackdrop(_ img: CIImage, in rect: CGRect) -> CIImage {
        let e = img.extent
        // Cheap blur: shrink 8x, blur, scale back up.
        let small = img.transformed(by: CGAffineTransform(scaleX: 0.125, y: 0.125))
        let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 6)
            .cropped(to: small.extent)
            .transformed(by: CGAffineTransform(scaleX: 8, y: 8))
            .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.15,
                                                            kCIInputSaturationKey: 1.2])
        let backdrop = fill(blurred, in: rect)
        let s = min(rect.width / e.width, rect.height / e.height)
        let t = CGAffineTransform(translationX: -e.minX, y: -e.minY)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: rect.midX - e.width * s / 2,
                                             y: rect.midY - e.height * s / 2))
        return img.transformed(by: t).composited(over: backdrop).cropped(to: rect)
    }

    private func rounded(_ img: CIImage, rect: CGRect, radius: CGFloat) -> CIImage {
        let g = CIFilter.roundedRectangleGenerator()
        g.extent = rect
        g.radius = Float(radius)
        g.color = .white
        guard let mask = g.outputImage else { return img }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = img
        blend.backgroundImage = CIImage.empty()
        blend.maskImage = mask
        return blend.outputImage ?? img
    }

    private func captionImage(_ text: String, canvas: CGRect, layout: OutputLayout) -> CIImage {
        let label: CIImage
        if let (t, img) = captionCache, t == text {
            label = img
        } else {
            let attr = NSAttributedString(string: text.uppercased(), attributes: [
                .font: NSFont.systemFont(ofSize: 44, weight: .black),
                .foregroundColor: NSColor.white,
                .strokeColor: NSColor.black,
                .strokeWidth: -4.0,
            ])
            let gen = CIFilter.attributedTextImageGenerator()
            gen.text = attr
            gen.scaleFactor = 1
            label = gen.outputImage ?? .empty()
            captionCache = (text, label)
        }
        let area: CGRect = switch layout {
        case .sideBySide: CGRect(x: canvas.midX, y: 0, width: canvas.width / 2, height: canvas.height)
        case .pictureInPicture: CGRect(x: canvas.maxX - canvas.width * 0.36 - 24, y: 24,
                                       width: canvas.width * 0.36, height: canvas.width * 0.27)
        case .memeOnly: canvas
        }
        let e = label.extent
        let s = min(1, (area.width - 32) / max(e.width, 1))
        return label.transformed(by: CGAffineTransform(scaleX: s, y: s)
            .concatenating(CGAffineTransform(translationX: area.midX - e.width * s / 2, y: area.minY + 20)))
    }
}
