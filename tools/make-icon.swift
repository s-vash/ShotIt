// Generates Sources/ShotIt/Assets.xcassets/AppIcon.appiconset from scratch.
// Usage: swiftc tools/make-icon.swift -o /tmp/make-icon && /tmp/make-icon Sources/ShotIt/Assets.xcassets/AppIcon.appiconset
import AppKit

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)
    let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
    func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: rgb, components: [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, a])!
    }

    // macOS icon grid: 824pt tile centred in a 1024 canvas, soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: c(0x000000, 0.35))
    ctx.addPath(path); ctx.setFillColor(c(0x1B1F3B)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let grad = CGGradient(colorsSpace: rgb, colors: [c(0x23D5C0), c(0x3A7BD5), c(0x6A3DE8)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
    // soft top sheen
    let sheen = CGGradient(colorsSpace: rgb, colors: [c(0xFFFFFF, 0.28), c(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 520), options: [])
    ctx.restoreGState()

    // Viewfinder corner brackets.
    let inset: CGFloat = 250, arm: CGFloat = 150, lw: CGFloat = 54
    let lo = inset + 24, hi = 1024 - inset - 24
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: c(0x000000, 0.25))
    ctx.setStrokeColor(c(0xFFFFFF)); ctx.setLineWidth(lw); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    for (cx, cy, dx, dy) in [(lo, hi, 1.0, -1.0), (hi, hi, -1.0, -1.0), (lo, lo, 1.0, 1.0), (hi, lo, -1.0, 1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
        ctx.move(to: CGPoint(x: cx + dx * arm, y: cy))
        ctx.addLine(to: CGPoint(x: cx, y: cy))
        ctx.addLine(to: CGPoint(x: cx, y: cy + dy * arm))
        ctx.strokePath()
    }
    // Centre "shot" dot.
    ctx.setFillColor(c(0xFFFFFF))
    ctx.fillEllipse(in: CGRect(x: 512 - 74, y: 512 - 74, width: 148, height: 148))
    ctx.restoreGState()
    ctx.setFillColor(c(0xFF4D5E))
    ctx.fillEllipse(in: CGRect(x: 512 - 40, y: 512 - 40, width: 80, height: 80))

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try render(size: px).write(to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let json = try JSONSerialization.data(withJSONObject: ["images": images, "info": ["version": 1, "author": "xcode"]],
                                      options: [.prettyPrinted, .sortedKeys])
try json.write(to: out.appendingPathComponent("Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": ["version": 1, "author": "xcode"]])
    .write(to: out.deletingLastPathComponent().appendingPathComponent("Contents.json"))
print("wrote \(images.count) icons to \(out.path)")
