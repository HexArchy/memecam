#if DEBUG
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import MemeCamCore

/// Dev tool: renders still frames of every pop-up style so the animation can be reviewed without a camera.
/// `MEMECAM_RENDER_POP=<dir> swift run MemeCam` writes the PNGs and exits (debug builds only).
enum PopPreviewRenderer {
    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["MEMECAM_RENDER_POP"] else { return }
        render(to: URL(filePath: dir, directoryHint: .isDirectory))
        exit(0)
    }

    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let memeFile = ProcessInfo.processInfo.environment["MEMECAM_RENDER_MEME"] ?? "Resources/Memes/laugh_cat_1.gif"
        guard let meme = AnimatedImage(url: URL(filePath: memeFile))?.frames.first else {
            print("cannot load \(memeFile)")
            return
        }
        let compositor = Compositor()
        let context = CIContext()
        let camera = syntheticCamera()
        let times = [0.1, 0.3, 0.6, 1.0]
        for layout in OutputLayout.allCases {
            for style in PopStyle.allCases {
                var frames: [CIImage] = []
                for t in times {
                    let input = CompositorInput(camera: camera, meme: meme, caption: "Laughing Cat", layout: layout,
                                                mirror: false, presence: t, appearing: true, popStyle: style,
                                                quietMode: true)
                    guard let px = compositor.render(input) else { continue }
                    let img = CIImage(cvPixelBuffer: px)
                    frames.append(img)
                    write(img, to: dir.appending(path: "\(layout.rawValue)-\(style.rawValue)-t\(Int(t * 100)).png"), context)
                }
                // Mid-disappear frame.
                let out = CompositorInput(camera: camera, meme: meme, caption: "Laughing Cat", layout: layout, mirror: false,
                                          presence: 0.5, appearing: false, popStyle: style, quietMode: true)
                if let px = compositor.render(out) {
                    write(CIImage(cvPixelBuffer: px), to: dir.appending(path: "\(layout.rawValue)-\(style.rawValue)-out50.png"), context)
                }
                // 2×2 contact sheet at half size: t = 0.1, 0.3 / 0.6, 1.0.
                var sheet = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: Compositor.size))
                for (i, f) in frames.enumerated() {
                    let x = CGFloat(i % 2) * 640, y = CGFloat(1 - i / 2) * 360
                    sheet = f.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5)
                        .concatenating(CGAffineTransform(translationX: x, y: y))).composited(over: sheet)
                }
                write(sheet, to: dir.appending(path: "sheet-\(layout.rawValue)-\(style.rawValue).png"), context)
            }
        }
        // "Be right back" card over a side-by-side meme: appearing at 0.15 / 0.4 / 1.0, half-way out.
        for (presence, appearing) in [(0.15, true), (0.4, true), (1.0, true), (0.5, false)] {
            let input = CompositorInput(camera: camera, meme: meme, layout: .sideBySide, mirror: false,
                                        presence: 1, popStyle: .pop, quietMode: true,
                                        awayPresence: presence, awayAppearing: appearing, awayStyle: .pop)
            if let px = compositor.render(input) {
                let name = "away-\(appearing ? "in" : "out")\(Int(presence * 100)).png"
                write(CIImage(cvPixelBuffer: px), to: dir.appending(path: name), context)
            }
        }
        print("wrote frames to \(dir.path)")
    }

    private static func write(_ img: CIImage, to url: URL, _ context: CIContext) {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        try? context.writePNGRepresentation(of: img.cropped(to: CGRect(origin: .zero, size: Compositor.size)),
                                            to: url, format: .RGBA8, colorSpace: srgb)
    }

    /// A webcam-ish scene: warm room gradient, a head-and-shoulders silhouette left of centre.
    private static func syntheticCamera() -> CIImage {
        let size = Compositor.size
        let bounds = CGRect(origin: .zero, size: size)
        let room = CIFilter.linearGradient()
        room.point0 = CGPoint(x: 0, y: 0)
        room.point1 = CGPoint(x: size.width * 0.3, y: size.height)
        room.color0 = CIColor(red: 0.20, green: 0.22, blue: 0.27)
        room.color1 = CIColor(red: 0.62, green: 0.55, blue: 0.47)
        var img = room.outputImage!.cropped(to: bounds)
        // Window light on the right.
        let light = CIFilter.radialGradient()
        light.center = CGPoint(x: size.width * 0.85, y: size.height * 0.8)
        light.radius0 = 40
        light.radius1 = 520
        light.color0 = CIColor(red: 1, green: 0.95, blue: 0.85, alpha: 0.55)
        light.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
        img = light.outputImage!.cropped(to: bounds).composited(over: img)
        // Shoulders and head.
        let body = CIFilter.roundedRectangleGenerator()
        body.extent = CGRect(x: size.width * 0.22, y: -120, width: 520, height: 330)
        body.radius = 150
        body.color = CIColor(red: 0.16, green: 0.30, blue: 0.48)
        img = body.outputImage!.composited(over: img)
        let head = CIFilter.radialGradient()
        head.center = CGPoint(x: size.width * 0.22 + 260, y: 380)
        head.radius0 = 120
        head.radius1 = 132
        head.color0 = CIColor(red: 0.93, green: 0.76, blue: 0.63)
        head.color1 = CIColor(red: 0.93, green: 0.76, blue: 0.63, alpha: 0)
        img = head.outputImage!.cropped(to: bounds).composited(over: img)
        return img.cropped(to: bounds)
    }
}
#endif
