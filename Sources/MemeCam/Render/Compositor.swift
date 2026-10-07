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
    /// 0 = camera only (full frame), 1 = the layout with the meme; in between = the appear (or, with
    /// `appearing == false`, disappear) animation. Linear in time; the compositor applies the easing.
    var presence: Double = 1
    var appearing = true
    var popStyle: PopStyle = .fade
    /// Quiet mode with `.pop` / `.slide`: the camera stays full-frame and the meme floats over it as a card.
    var quietMode = false
}

extension PopStyle {
    var title: String {
        switch self {
        case .pop: "Pop"
        case .slide: "Slide"
        case .fade: "Fade"
        }
    }
}

/// Renders the final 1280×720 BGRA frame that the preview and the virtual camera share.
/// GPU-only path: CIContext on Metal, IOSurface-backed pool buffers, no CPU copies.
final class Compositor: @unchecked Sendable {
    static let size = CGSize(width: 1280, height: 720)

    private let context: CIContext
    private var pool: CVPixelBufferPool?
    private var captionCache: (String, CIImage)?
    /// Sticker frames (outline + shadow) and corner masks per card size; rendered once, reused every frame.
    private var cardCache: [CardKey: CardDecoration] = [:]
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
        } else if input.quietMode, input.popStyle != .fade {
            image = composeFloatingCard(input, camera: cam, cameraOnly: cameraOnly, canvas: canvas)
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
        let backdrop = blurredFill(img, in: rect)
        let s = min(rect.width / e.width, rect.height / e.height)
        let t = CGAffineTransform(translationX: -e.minX, y: -e.minY)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: rect.midX - e.width * s / 2,
                                             y: rect.midY - e.height * s / 2))
        return img.transformed(by: t).composited(over: backdrop).cropped(to: rect)
    }

    /// Blurred, darkened aspect-fill of `img` (meme backdrop).
    private func blurredFill(_ img: CIImage, in rect: CGRect) -> CIImage {
        // Cheap blur: shrink 8x, blur, scale back up.
        let small = img.transformed(by: CGAffineTransform(scaleX: 0.125, y: 0.125))
        let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 6)
            .cropped(to: small.extent)
            .transformed(by: CGAffineTransform(scaleX: 8, y: 8))
            .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.15,
                                                            kCIInputSaturationKey: 1.2])
        return fill(blurred, in: rect)
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
        let area: CGRect = switch layout {
        case .sideBySide: CGRect(x: canvas.midX, y: 0, width: canvas.width / 2, height: canvas.height)
        case .pictureInPicture: CGRect(x: canvas.maxX - canvas.width * 0.36 - 24, y: 24,
                                       width: canvas.width * 0.36, height: canvas.width * 0.27)
        case .memeOnly: canvas
        }
        return captionImage(text, in: area)
    }

    private func captionImage(_ text: String, in area: CGRect) -> CIImage {
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
        let e = label.extent
        let s = min(1, (area.width - 32) / max(e.width, 1))
        return label.transformed(by: CGAffineTransform(scaleX: s, y: s)
            .concatenating(CGAffineTransform(translationX: area.midX - e.width * s / 2, y: area.minY + 20)))
    }
}

// MARK: - Floating meme card (quiet mode, .pop / .slide)

/// Quiet mode with an animated style keeps the camera full-frame the whole time: the person never jumps
/// to half the frame and back. The meme floats over the camera as a card in the layout's meme area
/// (right half / PiP corner / centre over a blurred backdrop) and only the card animates.
extension Compositor {
    struct CardKey: Hashable {
        var width: Int
        var height: Int
        var outlined: Bool
    }

    struct CardDecoration {
        /// White sticker outline (if any) over a soft drop shadow, in card-local coordinates.
        var frame: CIImage
        /// Rounded-corner mask for the meme itself, card-local.
        var mask: CIImage
    }

    fileprivate func composeFloatingCard(_ input: CompositorInput, camera cam: CIImage?, cameraOnly: CIImage,
                                         canvas: CGRect) -> CIImage {
        guard let meme = memeImage(input) else { return cameraOnly }
        let phase = input.appearing ? input.presence : 1 - input.presence
        let pose = PopAnimation.pose(input.popStyle, progress: phase, appearing: input.appearing)
        // Secondary layers (memeOnly backdrop and camera bubble) just fade with the eased presence.
        let support = PopAnimation.smoothstep(input.presence)
        var image = cameraOnly

        let region: CGRect
        var corner = false
        switch input.layout {
        case .sideBySide:
            region = CGRect(x: canvas.midX, y: 0, width: canvas.width / 2, height: canvas.height).insetBy(dx: 56, dy: 76)
        case .pictureInPicture:
            let w = canvas.width * 0.36, m: CGFloat = 28
            region = CGRect(x: canvas.maxX - w - m, y: m, width: w, height: w * 0.75)
            corner = true
        case .memeOnly:
            region = canvas.insetBy(dx: 72, dy: 56)
            image = withOpacity(blurredFill(meme, in: canvas), support).composited(over: image)
        }

        // Aspect-fit the meme; in the PiP corner hug the bottom-right edge instead of centring.
        let e = meme.extent
        let s = min(region.width / e.width, region.height / e.height)
        let size = CGSize(width: (e.width * s).rounded(), height: (e.height * s).rounded())
        let card = CGRect(x: corner ? region.maxX - size.width : (region.midX - size.width / 2).rounded(),
                          y: corner ? region.minY : (region.midY - size.height / 2).rounded(),
                          width: size.width, height: size.height)

        let deco = decoration(for: size, outlined: input.popStyle == .pop)
        let local = CGRect(origin: .zero, size: size)
        let fitted = meme.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)
            .concatenating(CGAffineTransform(scaleX: size.width / e.width, y: size.height / e.height)))
        var face = fitted.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: deco.mask,
        ]).cropped(to: local)
        if let caption = input.caption, !caption.isEmpty {
            face = captionImage(caption, in: local).composited(over: face).cropped(to: local)
        }
        var sticker = face.composited(over: deco.frame)

        // Pose: scale + rotate about the card centre, slide towards the nearest canvas edge.
        let travel = slideVector(for: card, canvas: canvas, margin: Self.decorationPad)
        let t = CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2)
            .concatenating(CGAffineTransform(scaleX: pose.scale, y: pose.scale))
            .concatenating(CGAffineTransform(rotationAngle: pose.rotation * .pi / 180))
            .concatenating(CGAffineTransform(translationX: card.midX + travel.dx * pose.travel,
                                             y: card.midY + travel.dy * pose.travel))
        sticker = withOpacity(sticker.transformed(by: t), pose.opacity)
        image = sticker.composited(over: image)

        if input.layout == .memeOnly, let cam {
            let d: CGFloat = 200, m: CGFloat = 24
            let bubble = CGRect(x: m, y: m, width: d, height: d)
            image = withOpacity(rounded(fill(cam, in: bubble), rect: bubble, radius: d / 2), support)
                .composited(over: image)
        }
        return image
    }

    /// Room around the card for the outline and shadow in the cached decoration.
    fileprivate static let decorationPad: CGFloat = 64

    /// Offset that moves `card` (plus its shadow) fully off the nearest canvas edge.
    private func slideVector(for card: CGRect, canvas: CGRect, margin: CGFloat) -> CGVector {
        let options: [(gap: CGFloat, v: CGVector)] = [
            (canvas.maxX - card.maxX, CGVector(dx: canvas.maxX - card.minX + margin, dy: 0)),
            (card.minX - canvas.minX, CGVector(dx: -(card.maxX - canvas.minX + margin), dy: 0)),
            (card.minY - canvas.minY, CGVector(dx: 0, dy: -(card.maxY - canvas.minY + margin))),
            (canvas.maxY - card.maxY, CGVector(dx: 0, dy: canvas.maxY - card.minY + margin)),
        ]
        return options.min { $0.gap < $1.gap }!.v
    }

    /// Outline + shadow for a card size: built with Core Image once, rendered to a bitmap and cached, so a
    /// frame only samples one texture instead of re-running a blur.
    private func decoration(for size: CGSize, outlined: Bool) -> CardDecoration {
        let key = CardKey(width: Int(size.width), height: Int(size.height), outlined: outlined)
        if let hit = cardCache[key] { return hit }

        let local = CGRect(origin: .zero, size: size)
        let short = min(size.width, size.height)
        let radius = min(26, max(10, short * 0.05))
        let border: CGFloat = outlined ? min(12, max(5, short * 0.022)) : 0
        let outer = local.insetBy(dx: -border, dy: -border)
        let pad = Self.decorationPad
        let canvas = local.insetBy(dx: -pad, dy: -pad)

        let shadow = roundedRect(outer.offsetBy(dx: 0, dy: -12), radius: radius + border,
                                 color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.7))
            .applyingGaussianBlur(sigma: 16)
        var frame = shadow
        if outlined {
            frame = roundedRect(outer, radius: radius + border, color: .white).composited(over: frame)
        }
        frame = frame.cropped(to: canvas)
        let baked = context.createCGImage(frame, from: canvas, format: .RGBA8, colorSpace: colorSpace)
            .map { CIImage(cgImage: $0).transformed(by: CGAffineTransform(translationX: -pad, y: -pad)) }
            ?? frame
        let deco = CardDecoration(frame: baked, mask: roundedRect(local, radius: radius, color: .white))
        if cardCache.count > 16 { cardCache.removeAll() }
        cardCache[key] = deco
        return deco
    }

    private func roundedRect(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        let g = CIFilter.roundedRectangleGenerator()
        g.extent = rect
        g.radius = Float(radius)
        g.color = color
        return g.outputImage ?? .empty()
    }

    private func withOpacity(_ img: CIImage, _ alpha: Double) -> CIImage {
        guard alpha < 1 else { return img }
        return img.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, alpha))),
        ])
    }
}
