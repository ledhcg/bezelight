// Generates AppIcon.icns from the brand mark: the blue "b" on a white macOS-style tile.
// usage: swift scripts/make-icon.swift <mark.png> <output.icns>
import AppKit

/// Renders the tile at an exact pixel size (no screen-scale surprises, unlike `NSImage.lockFocus`).
func render(mark: CGImage, size: Int) -> Data {
    let s = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high

    // Apple's template: an 824 pt tile centred in a 1024 pt canvas, leaving room for the shadow.
    let tile = CGRect(x: s * 0.0977, y: s * 0.0977, width: s * 0.8047, height: s * 0.8047)
    let path = CGPath(roundedRect: tile, cornerWidth: s * 0.18, cornerHeight: s * 0.18, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.025, color: CGColor(gray: 0, alpha: 0.28))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.addPath(path); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [CGColor(gray: 1.0, alpha: 1), CGColor(gray: 0.93, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    // The artwork has an off-white background: multiply makes it vanish into the tile.
    let side = tile.width * 0.86
    let rect = CGRect(x: tile.midX - side / 2, y: tile.midY - side / 2, width: side, height: side)
    ctx.setBlendMode(.multiply)
    ctx.draw(mark, in: rect)
    ctx.setBlendMode(.normal)
    ctx.restoreGState()

    ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.10)); ctx.setLineWidth(max(1, s * 0.002))
    ctx.addPath(path); ctx.strokePath()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count == 3,
      let src = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let mark = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <mark.png> <output.icns>\n".utf8)); exit(2)
}
let out = CommandLine.arguments[2]
let dir = NSTemporaryDirectory() + "bezelight.iconset"
try? FileManager.default.removeItem(atPath: dir)
try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(mark: mark, size: px).write(to: URL(fileURLWithPath: "\(dir)/icon_\(name).png"))
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", dir, "-o", out]; try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote \(out)" : "iconutil failed")
exit(p.terminationStatus)
