import CoreGraphics
import CoreText
import CoreVideo
import Foundation

/// Draws the "MemeCam is paused" frame once into an IOSurface-backed BGRA buffer from a pool.
enum PlaceholderRenderer {
    static func render(width: Int, height: Int) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess,
              let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        let w = CGFloat(width), h = CGFloat(height)
        // Dark vertical gradient background.
        let colors = [CGColor(srgbRed: 0.10, green: 0.10, blue: 0.13, alpha: 1),
                      CGColor(srgbRed: 0.04, green: 0.04, blue: 0.06, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
        }

        // Pause glyph.
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18))
        let barW = h * 0.035, barH = h * 0.14, gap = barW * 0.9, top = h * 0.60
        ctx.addPath(CGPath(roundedRect: CGRect(x: w / 2 - gap / 2 - barW, y: top, width: barW, height: barH),
                           cornerWidth: barW / 3, cornerHeight: barW / 3, transform: nil))
        ctx.addPath(CGPath(roundedRect: CGRect(x: w / 2 + gap / 2, y: top, width: barW, height: barH),
                           cornerWidth: barW / 3, cornerHeight: barW / 3, transform: nil))
        ctx.fillPath()

        let text = Text.current
        drawCentered(text.title, in: ctx, centerX: w / 2, baselineY: h * 0.46,
                     size: h * 0.075, weight: .semibold, alpha: 0.92)
        drawCentered(text.subtitle, in: ctx, centerX: w / 2, baselineY: h * 0.38,
                     size: h * 0.035, weight: .regular, alpha: 0.55)
        return buffer
    }

    /// The extension can't read the app's string tables, so its two lines carry their own translations.
    struct Text {
        let title: String
        let subtitle: String

        static let english = Text(title: "MemeCam is paused", subtitle: "Start the camera in MemeCam to go live")
        static let russian = Text(title: "MemeCam на паузе", subtitle: "Включи камеру в MemeCam, чтобы выйти в эфир")

        /// Russian when the system's preferred language is Russian, English otherwise.
        static var current: Text {
            Locale.preferredLanguages.first?.hasPrefix("ru") == true ? russian : english
        }
    }

    private static func drawCentered(_ text: String, in ctx: CGContext, centerX: CGFloat, baselineY: CGFloat,
                                     size: CGFloat, weight: CGFloat, alpha: CGFloat) {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let traits = [kCTFontWeightTrait: weight] as CFDictionary
        let desc = CTFontDescriptorCreateWithAttributes([kCTFontTraitsAttribute: traits] as CFDictionary)
        let font = CTFontCreateCopyWithAttributes(base, size, nil, desc)
        let attrs = [kCTFontAttributeName: font,
                     kCTForegroundColorAttributeName: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha)] as CFDictionary
        guard let string = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attrs) else { return }
        let line = CTLineCreateWithAttributedString(string)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.textPosition = CGPoint(x: centerX - CGFloat(width) / 2, y: baselineY)
        CTLineDraw(line, ctx)
    }
}

private extension CGFloat {
    static let semibold: CGFloat = 0.3
    static let regular: CGFloat = 0
}
