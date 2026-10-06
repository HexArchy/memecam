// Renders Resources/Branding/icon.svg into Resources/AppIcon.icns (plus a 1024 PNG).
// Usage: swift scripts/render-icon.swift
import AppKit

let root = URL(filePath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let svg = root.appending(path: "Resources/Branding/icon.svg")
guard let image = NSImage(contentsOf: svg) else { fatalError("cannot load \(svg.path)") }

func png(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(base).write(to: iconset.appending(path: "icon_\(base)x\(base).png"))
    try png(base * 2).write(to: iconset.appending(path: "icon_\(base)x\(base)@2x.png"))
}
try png(1024).write(to: root.appending(path: "Resources/Branding/icon-1024.png"))

let task = Process()
task.executableURL = URL(filePath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appending(path: "Resources/AppIcon.icns").path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
