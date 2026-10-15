// Renders the icon macOS (Launch Services) shows for a path: swiftc tools/icon-probe.swift -o build/icon-probe && build/icon-probe App.app out.png
import AppKit
let args = CommandLine.arguments
let img = NSWorkspace.shared.icon(forFile: args[1])
let size = 256
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(white: 0.18, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: size, height: size).fill()
img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("reps:", img.representations.count, "size:", img.size)
