// Renders the promo cards in a light, playful bento-grid style.
// Usage: swiftc tools/make-card.swift -o build/make-card && build/make-card promo Sources/ShotIt/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png
import AppKit

// Edit the content here (the numbers come from /cost and the repo).
let duration = "1h 57m"
let durationNote = "≈ 57 min AI time + 1 h builds & tests"
let testsCount = "47 tests"
let linesNote = "5,300+ lines of Swift"
let tagline = "A native macOS screenshot & annotation tool, inspired by Shottr"
let stack = "Swift · AppKit · ScreenCaptureKit · Vision · built with Claude Code"

let keyBullets = [
    "A hotkey for every capture mode",
    "Space turns an area into a window pick",
    "Pin, preview and drag-out in one flow",
]
let hotkeys: [(String, String)] = [("Fullscreen", "⌘⇧1"), ("Area", "⌘⇧2"), ("Text recognition", "⌃⌥⌘O")]

let capture = ["Fullscreen, area & window", "Scrolling capture, 3 modes", "Text & QR recognition", "Preview popup at your cursor"]
let edit = ["12 annotation tools", "Smart Erase keeps the grain", "Colour picker, 6 formats", "Backdrop: wallpaper & shadow"]
let everywhere = ["Pin screenshots on screen", "Drag-out & reopen last", "Global hotkeys & URL scheme", "Menu-bar app with Settings"]

// MARK: - Palette (warm neutrals, tinted; no pure black or white)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
let paper = rgb(0xF4EEE3), ink = rgb(0x1F1C2B), cream = rgb(0xFBF6EA)
let sun = rgb(0xFFCE3A), tomato = rgb(0xFF6B4B), mint = rgb(0x5BD9A8), sky = rgb(0x6DB9FF), pink = rgb(0xFFA6C9), lilac = rgb(0xC9BBFF)

/// Secondary text on a coloured tile: a shade of that tile, never grey.
func muted(on tile: NSColor) -> NSColor { tile.blended(withFraction: 0.68, of: ink) ?? ink }

func font(_ name: String, _ size: CGFloat) -> NSFont { NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: .bold) }
func display(_ size: CGFloat) -> NSFont { font("Futura-Bold", size) }
func heavy(_ size: CGFloat) -> NSFont { font("AvenirNext-Heavy", size) }
func demi(_ size: CGFloat) -> NSFont { font("AvenirNext-DemiBold", size) }
func body(_ size: CGFloat) -> NSFont { font("AvenirNext-Medium", size) }

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "promo", isDirectory: true)
let icon = CommandLine.arguments.count > 2 ? NSImage(contentsOfFile: CommandLine.arguments[2]) : nil

// MARK: - Drawing helpers (flipped coordinates: origin top-left)

@discardableResult
func text(_ s: String, in rect: CGRect, font: NSFont, color: NSColor, kern: CGFloat = 0, lineSpacing: CGFloat = 2,
          align: NSTextAlignment = .left, draw: Bool = true) -> CGFloat {
    let p = NSMutableParagraphStyle(); p.alignment = align; p.lineSpacing = lineSpacing; p.lineBreakMode = .byWordWrapping
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: p, .kern: kern]
    let ns = s as NSString
    let h = ceil(ns.boundingRect(with: CGSize(width: rect.width, height: 4000), options: [.usesLineFragmentOrigin], attributes: attrs).height)
    if draw { ns.draw(in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h), withAttributes: attrs) }
    return h
}

func fillTile(_ r: CGRect, _ c: NSColor, radius: CGFloat) {
    c.setFill(); NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
}

func clipToTile(_ r: CGRect, radius: CGFloat, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).addClip()
    body()
    NSGraphicsContext.restoreGraphicsState()
}

func dot(_ c: CGPoint, _ r: CGFloat, _ color: NSColor) {
    color.setFill(); NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
}

func keycap(_ s: String, x: CGFloat, y: CGFloat, size: CGFloat) -> CGFloat {
    let f = body(size)
    let w = ceil((s as NSString).size(withAttributes: [.font: f, .kern: 1.5]).width) + size * 1.1
    let r = CGRect(x: x, y: y, width: w, height: size * 1.9)
    fillTile(r.offsetBy(dx: 0, dy: size * 0.12), rgb(0x8E887A), radius: size * 0.5)       // key edge
    fillTile(r, cream, radius: size * 0.5)
    text(s, in: CGRect(x: r.minX, y: r.minY + size * 0.34, width: w, height: size * 1.5), font: f, color: ink, kern: 1.5, align: .center)
    return w
}

// MARK: - Tiles

func heroTile(_ r: CGRect) {
    fillTile(r, sun, radius: 44)
    clipToTile(r, radius: 44) {  // big playful circle peeking from the corner
        dot(CGPoint(x: r.maxX - r.width * 0.05, y: r.minY + r.height * 0.06), r.width * 0.30, rgb(0xFFDB6A))
    }
    let pad = r.width * 0.06
    let iconSize = r.width * 0.17
    icon?.draw(in: CGRect(x: r.minX + pad, y: r.minY + pad, width: iconSize, height: iconSize), from: .zero, operation: .sourceOver,
               fraction: 1, respectFlipped: true, hints: nil)
    let titleSize = r.width * 0.18
    let titleY = r.minY + pad + iconSize + 6
    let hTitle = text("ShotIt", in: CGRect(x: r.minX + pad - 4, y: titleY, width: r.width - pad, height: 400), font: display(titleSize), color: ink, kern: -titleSize * 0.03)
    text(tagline, in: CGRect(x: r.minX + pad, y: titleY + hTitle + 2, width: r.width * 0.8, height: 200), font: demi(r.width * 0.037), color: muted(on: sun), lineSpacing: 3)
    text(stack, in: CGRect(x: r.minX + pad, y: r.maxY - pad - r.width * 0.026, width: r.width - 2 * pad, height: 60), font: body(r.width * 0.024), color: muted(on: sun))
}

func timeTile(_ r: CGRect) {
    fillTile(r, tomato, radius: 40)
    let pad = r.width * 0.08
    // Stopwatch.
    let sw = r.width * 0.17, c = CGPoint(x: r.maxX - pad - sw / 2, y: r.minY + pad + sw / 2 + 6)
    ink.setStroke()
    let ring = NSBezierPath(ovalIn: CGRect(x: c.x - sw / 2, y: c.y - sw / 2, width: sw, height: sw)); ring.lineWidth = sw * 0.09; ring.stroke()
    let hand = NSBezierPath(); hand.move(to: c); hand.line(to: CGPoint(x: c.x + sw * 0.18, y: c.y - sw * 0.24)); hand.lineWidth = sw * 0.08; hand.lineCapStyle = .round; hand.stroke()
    let knob = NSBezierPath(); knob.move(to: CGPoint(x: c.x, y: c.y - sw / 2)); knob.line(to: CGPoint(x: c.x, y: c.y - sw / 2 - sw * 0.14)); knob.lineWidth = sw * 0.1; knob.lineCapStyle = .round; knob.stroke()
    let bigSize = r.width * 0.155
    let h = text(duration, in: CGRect(x: r.minX + pad, y: r.minY + r.height * 0.30, width: r.width - 2 * pad, height: 200), font: display(bigSize), color: ink, kern: -bigSize * 0.02)
    let h2 = text("roughly, prompt to working app", in: CGRect(x: r.minX + pad, y: r.minY + r.height * 0.30 + h + 2, width: r.width - 2 * pad, height: 100), font: demi(r.width * 0.052), color: ink)
    text(durationNote, in: CGRect(x: r.minX + pad, y: r.minY + r.height * 0.30 + h + h2 + 8, width: r.width - 2 * pad, height: 100), font: body(r.width * 0.042), color: muted(on: tomato))
}

func testsTile(_ r: CGRect) {
    fillTile(r, mint, radius: 40)
    let pad = r.width * 0.08
    let bigSize = r.width * 0.17
    let h = text(testsCount, in: CGRect(x: r.minX + pad, y: r.minY + pad - 2, width: r.width - 2 * pad, height: 200), font: display(bigSize), color: ink, kern: -bigSize * 0.02)
    text(linesNote, in: CGRect(x: r.minX + pad, y: r.minY + pad + h, width: r.width - 2 * pad, height: 100), font: demi(r.width * 0.058), color: ink)
    // One dot per test, all passing.
    let cols = 16, rows = 3
    let gap = (r.width - 2 * pad) / CGFloat(cols)
    let rad = gap * 0.34
    let top = r.maxY - pad - CGFloat(rows) * gap + gap / 2
    for i in 0..<47 {
        dot(CGPoint(x: r.minX + pad + gap * (CGFloat(i % cols) + 0.5), y: top + gap * CGFloat(i / cols)), rad, ink)
    }
}

func hotkeyTile(_ r: CGRect, wide: Bool) {
    fillTile(r, ink, radius: 44)
    let pad = r.width * (wide ? 0.032 : 0.085)
    let leftW = wide ? r.width * 0.56 : r.width - 2 * pad
    // Pill.
    let pillH: CGFloat = wide ? 32 : r.width * 0.1
    let pillText = "Hotkeys"
    let pf = heavy(pillH * 0.5)
    let pw = ceil((pillText as NSString).size(withAttributes: [.font: pf, .kern: 1]).width) + pillH * 0.9
    fillTile(CGRect(x: r.minX + pad, y: r.minY + pad, width: pw, height: pillH), sun, radius: pillH / 2)
    text(pillText, in: CGRect(x: r.minX + pad, y: r.minY + pad + pillH * 0.22, width: pw, height: pillH), font: pf, color: ink, kern: 1, align: .center)

    let titleSize = wide ? r.height * 0.125 : r.width * 0.088
    var y = r.minY + pad + pillH + (wide ? 12 : 18)
    y += text("Keyboard friendly", in: CGRect(x: r.minX + pad, y: y, width: leftW, height: 300), font: display(titleSize), color: cream, kern: -0.3) + (wide ? 8 : 14)
    let bs = wide ? r.height * 0.076 : r.width * 0.05
    for b in keyBullets {
        dot(CGPoint(x: r.minX + pad + 5, y: y + bs * 0.62), 4.5, sky)
        y += text(b, in: CGRect(x: r.minX + pad + 22, y: y, width: leftW - 22, height: 300), font: body(bs), color: cream.withAlphaComponent(0.9)) + (wide ? 5 : 10)
    }
    // Recovered hotkeys as keycaps.
    let ks = wide ? r.height * 0.09 : r.width * 0.052
    if wide {
        var ky = r.minY + pad + 4
        let kx = r.minX + r.width * 0.62
        text("Default hotkeys", in: CGRect(x: kx, y: ky, width: r.width * 0.34, height: 40), font: demi(ks * 0.95), color: sun)
        ky += ks * 2.1
        for (label, keys) in hotkeys {
            text(label, in: CGRect(x: kx, y: ky + ks * 0.3, width: r.width * 0.17, height: 40), font: body(ks), color: cream.withAlphaComponent(0.85))
            _ = keycap(keys, x: kx + r.width * 0.18, y: ky, size: ks)
            ky += ks * 2.45
        }
    } else {
        var ky = r.maxY - pad * 0.7 - CGFloat(hotkeys.count) * ks * 2.4
        for (label, keys) in hotkeys {
            text(label, in: CGRect(x: r.minX + pad, y: ky + ks * 0.3, width: r.width * 0.4, height: 40), font: body(ks), color: cream.withAlphaComponent(0.85))
            _ = keycap(keys, x: r.minX + pad + r.width * 0.42, y: ky, size: ks)
            ky += ks * 2.4
        }
    }
}

func listTile(_ r: CGRect, title: String, items: [String], color: NSColor, columns: Int = 1) {
    fillTile(r, color, radius: 40)
    let pad = r.height * 0.1
    let ts = min(r.height * 0.15, r.width * 0.09)
    let h = text(title, in: CGRect(x: r.minX + pad, y: r.minY + pad - 2, width: r.width - 2 * pad, height: 100), font: display(ts), color: ink, kern: -0.2)
    let colW = (r.width - 2 * pad) / CGFloat(columns)
    let isz = min(r.height * (columns > 1 ? 0.09 : 0.08), colW * (columns > 1 ? 0.063 : 0.06))
    let perCol = (items.count + columns - 1) / columns
    let startY = r.minY + pad + h + r.height * 0.05
    let rowH = (r.maxY - pad - startY) / CGFloat(perCol)
    for (i, item) in items.enumerated() {
        let col = i / perCol, row = i % perCol
        let x = r.minX + pad + CGFloat(col) * colW, y = startY + CGFloat(row) * rowH
        dot(CGPoint(x: x + isz * 0.3, y: y + isz * 0.66), isz * 0.2, ink)
        text(item, in: CGRect(x: x + isz * 0.9, y: y, width: colW - isz * 1.0, height: rowH), font: demi(isz), color: ink)
    }
}

// MARK: - Rendering

func render(name: String, w: Int, h: Int, draw: (CGFloat, CGFloat) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let base = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    let cg = base.cgContext
    cg.translateBy(x: 0, y: CGFloat(h)); cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    paper.setFill(); CGRect(x: 0, y: 0, width: w, height: h).fill()
    draw(CGFloat(w), CGFloat(h))
    NSGraphicsContext.restoreGraphicsState()
    try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    try! rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent(name))
    print("wrote \(name) \(w)x\(h)")
}

/// Rect covering `cs`×`rs` cells of a grid.
func cell(_ c: Int, _ r: Int, _ cs: Int, _ rs: Int, margin m: CGFloat, gap g: CGFloat, cols: Int, rows: Int, w: CGFloat, h: CGFloat) -> CGRect {
    let cw = (w - 2 * m - CGFloat(cols - 1) * g) / CGFloat(cols), rh = (h - 2 * m - CGFloat(rows - 1) * g) / CGFloat(rows)
    return CGRect(x: m + CGFloat(c) * (cw + g), y: m + CGFloat(r) * (rh + g), width: CGFloat(cs) * cw + CGFloat(cs - 1) * g, height: CGFloat(rs) * rh + CGFloat(rs - 1) * g)
}

// 16:9 (X, LinkedIn, Facebook)
render(name: "shotit-card-landscape.png", w: 1600, h: 900) { w, h in
    func c(_ a: Int, _ b: Int, _ cs: Int = 1, _ rs: Int = 1) -> CGRect { cell(a, b, cs, rs, margin: 44, gap: 18, cols: 4, rows: 3, w: w, h: h) }
    heroTile(c(0, 0, 2, 2))
    timeTile(c(2, 0))
    hotkeyTile(c(3, 0, 1, 2), wide: false)
    testsTile(c(2, 1))
    listTile(c(0, 2), title: "Capture", items: capture, color: sky)
    listTile(c(1, 2), title: "Edit", items: edit, color: pink)
    listTile(c(2, 2, 2, 1), title: "Everywhere", items: everywhere, color: lilac, columns: 2)
}

// 1:1 (Instagram, feeds)
render(name: "shotit-card-square.png", w: 1080, h: 1080) { w, h in
    func c(_ a: Int, _ b: Int, _ cs: Int = 1, _ rs: Int = 1) -> CGRect { cell(a, b, cs, rs, margin: 40, gap: 16, cols: 3, rows: 4, w: w, h: h) }
    heroTile(c(0, 0, 2, 2))
    timeTile(c(2, 0))
    testsTile(c(2, 1))
    hotkeyTile(c(0, 2, 3, 1), wide: true)
    listTile(c(0, 3), title: "Capture", items: capture, color: sky)
    listTile(c(1, 3), title: "Edit", items: edit, color: pink)
    listTile(c(2, 3), title: "Everywhere", items: everywhere, color: lilac)
}
