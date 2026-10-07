import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import MemeCamCore
import Metal

/// Animated test card for the virtual camera (colour bars, "MemeCam test", a running clock and a sweeping
/// marker), so the user can check that Discord / Telegram see the MemeCam camera without turning the
/// real camera on. Rendered with Core Image at 15 fps on its own queue; the extension repeats frames to
/// keep its 30 fps output steady.
///
/// `@unchecked Sendable` invariant: everything mutable is only touched on `queue` (serial).
final class TestPatternSource: @unchecked Sendable {
    static let fps = 15

    private let queue = DispatchQueue(label: "com.hexarch.memecam.test-pattern", qos: .userInitiated)
    private let output: @Sendable (CVPixelBuffer) -> Void
    private let title: String
    private var timer: DispatchSourceTimer?
    private var context: CIContext?
    private var pool: CVPixelBufferPool?
    private var background: CIImage?
    private var clock: (text: String, image: CIImage)?
    private let startDate = Date()
    /// 24-hour clock with seconds, the same in every locale (only used on `queue`).
    private let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    private var size = CGSize(width: OutputFormat.default.width, height: OutputFormat.default.height)
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    init(title: String, output: @escaping @Sendable (CVPixelBuffer) -> Void) {
        self.title = title
        self.output = output
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: 1 / Double(Self.fps), leeway: .milliseconds(5))
            t.setEventHandler { [weak self] in self?.renderFrame() }
            t.resume()
            timer = t
        }
    }

    /// Renders at the output format's size from the next frame on (the extension expects that size).
    func setFormat(_ format: OutputFormat) {
        queue.async { [self] in
            let new = CGSize(width: format.width, height: format.height)
            guard new != size else { return }
            size = new
            pool = nil
            context = nil // setUp() rebuilds the pool and background at the new size
            background = nil
            clock = nil
        }
    }

    /// Stops the timer and frees the GPU context and buffers (nothing is kept while off).
    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            context = nil
            pool = nil
            background = nil
            clock = nil
        }
    }

    // MARK: queue

    private func renderFrame() {
        if context == nil { setUp() }
        guard let context, let pool, let background else { return }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return }
        let canvas = CGRect(origin: .zero, size: size)
        let elapsed = Date().timeIntervalSince(startDate)

        // Marker sweeping left → right along the bottom strip once every 2 s: proves the video moves.
        let travel = (elapsed / 2).truncatingRemainder(dividingBy: 1)
        let marker = CIImage(color: CIColor(red: 1, green: 0.42, blue: 0.2))
            .cropped(to: CGRect(x: (size.width - 60) * travel, y: 0, width: 60, height: 10))
        var image = marker.composited(over: background)
        image = clockImage().composited(over: image)
        context.render(image.cropped(to: canvas), to: out, bounds: canvas, colorSpace: colorSpace)
        output(out)
    }

    private func setUp() {
        context = MTLCreateSystemDefaultDevice().map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false]) }
            ?? CIContext(options: [.cacheIntermediates: false])
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Int(size.width),
            kCVPixelBufferHeightKey: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        background = makeBackground()
    }

    /// Colour bars over the top two thirds, a dark strip with the title below. Rendered once to a bitmap.
    private func makeBackground() -> CIImage {
        let w = size.width, h = size.height
        let barsBottom = h * 0.36
        let colors: [CIColor] = [
            CIColor(red: 0.75, green: 0.75, blue: 0.75), CIColor(red: 0.75, green: 0.75, blue: 0),
            CIColor(red: 0, green: 0.75, blue: 0.75), CIColor(red: 0, green: 0.75, blue: 0),
            CIColor(red: 0.75, green: 0, blue: 0.75), CIColor(red: 0.75, green: 0, blue: 0),
            CIColor(red: 0, green: 0, blue: 0.75),
        ]
        var image = CIImage(color: CIColor(red: 0.07, green: 0.07, blue: 0.09))
            .cropped(to: CGRect(origin: .zero, size: size))
        let barW = (w / CGFloat(colors.count)).rounded(.up)
        for (i, c) in colors.enumerated() {
            image = CIImage(color: c)
                .cropped(to: CGRect(x: CGFloat(i) * barW, y: barsBottom, width: barW, height: h - barsBottom))
                .composited(over: image)
        }
        let label = text(title, size: 64, weight: .heavy)
        let e = label.extent
        image = label.transformed(by: CGAffineTransform(translationX: (w - e.width) / 2 - e.minX,
                                                        y: barsBottom - 100 - e.minY))
            .composited(over: image)
        let canvas = CGRect(origin: .zero, size: size)
        guard let context, let cg = context.createCGImage(image, from: canvas) else { return image }
        return CIImage(cgImage: cg)
    }

    private func clockImage() -> CIImage {
        let text = clockFormatter.string(from: Date())
        if let clock, clock.text == text { return clock.image }
        let label = self.text(text, size: 48, weight: .semibold, monospaced: true)
        let e = label.extent
        let placed = label.transformed(by: CGAffineTransform(translationX: (size.width - e.width) / 2 - e.minX,
                                                             y: 60 - e.minY))
        clock = (text, placed)
        return placed
    }

    private func text(_ string: String, size: CGFloat, weight: NSFont.Weight, monospaced: Bool = false) -> CIImage {
        let font = monospaced ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                              : NSFont.systemFont(ofSize: size, weight: weight)
        let gen = CIFilter.attributedTextImageGenerator()
        gen.text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor.white])
        gen.scaleFactor = 1
        return gen.outputImage ?? .empty()
    }
}
