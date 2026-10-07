import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// The "Be right back" sticker shown while the person is away: a white card with the MemeCam hamster
/// (from the app icon) and big friendly text. Drawn once with Core Graphics, with room around it for a
/// soft shadow; the compositor only transforms the cached image.
enum AwayCard {
    /// Transparent margin around the card for its shadow.
    static let shadowPad: CGFloat = 48

    static func render(title: String) -> CGImage? {
        let iconSide: CGFloat = 132
        let fontSize: CGFloat = 64
        let line = textLine(title, size: fontSize)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let cardW = max(440, (bounds.width + 112).rounded())
        let cardH: CGFloat = 300
        let pad = shadowPad
        let width = Int(cardW + pad * 2), height = Int(cardH + pad * 2)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let card = CGRect(x: pad, y: pad, width: cardW, height: cardH)
        let path = CGPath(roundedRect: card, cornerWidth: 40, cornerHeight: 40, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 32,
                      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        if let icon = appIcon(maxSide: Int(iconSide * 2)) {
            ctx.interpolationQuality = .high
            ctx.draw(icon, in: CGRect(x: card.midX - iconSide / 2, y: card.maxY - 36 - iconSide,
                                      width: iconSide, height: iconSide))
        }
        ctx.textPosition = CGPoint(x: card.midX - bounds.width / 2 - bounds.minX, y: card.minY + 56)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }

    private static func textLine(_ text: String, size: CGFloat) -> CTLine {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let traits = [kCTFontWeightTrait: 0.62] as CFDictionary // heavy
        let desc = CTFontDescriptorCreateWithAttributes([kCTFontTraitsAttribute: traits] as CFDictionary)
        let font = CTFontCreateCopyWithAttributes(base, size, nil, desc)
        let attrs = [kCTFontAttributeName: font,
                     kCTForegroundColorAttributeName: CGColor(srgbRed: 0.13, green: 0.12, blue: 0.16, alpha: 1)]
            as CFDictionary
        let string = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attrs)!
        return CTLineCreateWithAttributedString(string)
    }

    /// The app icon (bundled app: Contents/Resources/AppIcon.icns; `swift run`: ./Resources/AppIcon.icns),
    /// picking the representation closest to `maxSide`.
    private static func appIcon(maxSide: Int) -> CGImage? {
        let url = [Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                   URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "Resources/AppIcon.icns")]
            .compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
        guard let url, let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxSide]
        // The largest representation, downscaled: icns order isn't guaranteed.
        let count = CGImageSourceGetCount(src)
        let best = (0..<count).max { a, b in pixelWidth(src, a) < pixelWidth(src, b) } ?? 0
        return CGImageSourceCreateThumbnailAtIndex(src, best, opts as CFDictionary)
    }

    private static func pixelWidth(_ src: CGImageSource, _ i: Int) -> Int {
        let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
        return props?[kCGImagePropertyPixelWidth] as? Int ?? 0
    }
}
