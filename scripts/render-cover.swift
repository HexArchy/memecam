// Renders the README / GitHub social-preview cover: Resources/Branding/cover.png (1280×640).
// Usage: swift scripts/render-cover.swift
import AppKit
import ImageIO

let root = URL(filePath: FileManager.default.currentDirectoryPath)
let size = NSSize(width: 1280, height: 640)
let scale: CGFloat = 2

func load(_ path: String) -> NSImage {
    guard let img = NSImage(contentsOf: root.appending(path: path)) else { fatalError("missing \(path)") }
    return img
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
NSGraphicsContext.current?.imageInterpolation = .high

// Background: deep plum → warm coral, with a soft highlight.
NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.07, blue: 0.16, alpha: 1),
                    NSColor(srgbRed: 0.42, green: 0.12, blue: 0.24, alpha: 1),
                    NSColor(srgbRed: 0.93, green: 0.38, blue: 0.36, alpha: 1)])!
    .draw(in: NSRect(origin: .zero, size: size), angle: -25)
NSGradient(starting: NSColor.white.withAlphaComponent(0.18), ending: .clear)!
    .draw(fromCenter: NSPoint(x: 980, y: 520), radius: 0, toCenter: NSPoint(x: 980, y: 520), radius: 520, options: [])

// Icon.
load("Resources/Branding/icon-1024.png").draw(in: NSRect(x: 40, y: 300, width: 300, height: 300))

func text(_ s: String, _ font: NSFont, _ color: NSColor, at p: NSPoint, kern: CGFloat = 0) {
    NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: kern]).draw(at: p)
}
func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
}

text("MemeCam", rounded(104, .black), .white, at: NSPoint(x: 70, y: 168), kern: -2)
text("Your face  →  cat & hamster memes.", rounded(34, .semibold), NSColor.white.withAlphaComponent(0.92),
     at: NSPoint(x: 74, y: 120))
text("Live in Discord, Telegram & any video call.", rounded(26, .medium), NSColor.white.withAlphaComponent(0.7),
     at: NSPoint(x: 74, y: 82))

// Chips.
var x: CGFloat = 74
for chip in ["Apple Vision", "30 FPS", "Virtual Camera", "macOS 26"] {
    let font = rounded(17, .semibold)
    let w = (chip as NSString).size(withAttributes: [.font: font]).width + 28
    let r = NSRect(x: x, y: 30, width: w, height: 34)
    NSColor.white.withAlphaComponent(0.14).setFill()
    NSBezierPath(roundedRect: r, xRadius: 17, yRadius: 17).fill()
    text(chip, font, .white, at: NSPoint(x: x + 14, y: 37))
    x += w + 10
}

// Meme polaroids (first frame of bundled GIFs).
/// Middle frame of an animated GIF (first frames are often fades or black).
func middleFrame(_ path: String) -> NSImage {
    guard let src = CGImageSourceCreateWithURL(root.appending(path: path) as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, CGImageSourceGetCount(src) / 2, nil) else { return load(path) }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

func polaroid(_ path: String, caption: String, center: NSPoint, angle: CGFloat) {
    let img = middleFrame(path)
    let photo = NSSize(width: 300, height: 300)
    let card = NSRect(x: -photo.width / 2 - 16, y: -photo.height / 2 - 56, width: photo.width + 32, height: photo.height + 72)
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angle * .pi / 180)
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    NSColor(white: 0.98, alpha: 1).setFill()
    NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14).fill()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    // Aspect-fill crop into the square photo area.
    let src = img.size
    let s = max(photo.width / src.width, photo.height / src.height)
    let crop = NSRect(x: (src.width - photo.width / s) / 2, y: (src.height - photo.height / s) / 2,
                      width: photo.width / s, height: photo.height / s)
    let dst = NSRect(x: -photo.width / 2, y: -photo.height / 2, width: photo.width, height: photo.height)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: dst, xRadius: 6, yRadius: 6).addClip()
    img.draw(in: dst, from: crop, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let font = rounded(24, .bold)
    let w = (caption as NSString).size(withAttributes: [.font: font]).width
    text(caption, font, NSColor(white: 0.15, alpha: 1), at: NSPoint(x: -w / 2, y: card.minY + 16))
    ctx.restoreGState()
}

polaroid("Resources/Memes/surprised_cat_1.gif", caption: "😮  surprised", center: NSPoint(x: 790, y: 335), angle: 7)
polaroid("Resources/Memes/thumbsUp_cat_1.gif", caption: "👍  thumbs up", center: NSPoint(x: 1085, y: 300), angle: -6)

NSGraphicsContext.restoreGraphicsState()
let out = root.appending(path: "Resources/Branding/cover.png")
try rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
