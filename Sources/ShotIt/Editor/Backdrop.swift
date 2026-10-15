import AppKit

/// How the screenshot is presented on a background ("Backdrop"). Persisted between sessions, except the image.
struct BackdropStyle: Equatable, Codable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case wallpaper, auto, gradient, solid, image
        var id: String { rawValue }
        var title: String {
            switch self {
            case .wallpaper: return "Wallpaper"
            case .auto: return "Auto"
            case .gradient: return "Gradient"
            case .solid: return "Solid"
            case .image: return "Image"
            }
        }
    }

    enum Aspect: String, Codable, CaseIterable, Identifiable {
        case free, square, r4x3, r3x2, r16x9, r2x1, r3x4, r9x16
        var id: String { rawValue }
        var title: String {
            switch self {
            case .free: return "Auto"
            case .square: return "1:1"
            case .r4x3: return "4:3"
            case .r3x2: return "3:2"
            case .r16x9: return "16:9"
            case .r2x1: return "2:1"
            case .r3x4: return "3:4"
            case .r9x16: return "9:16"
            }
        }
        /// width / height, or nil to size the canvas around the screenshot.
        var ratio: CGFloat? {
            switch self {
            case .free: return nil
            case .square: return 1
            case .r4x3: return 4.0 / 3
            case .r3x2: return 3.0 / 2
            case .r16x9: return 16.0 / 9
            case .r2x1: return 2
            case .r3x4: return 3.0 / 4
            case .r9x16: return 9.0 / 16
            }
        }
    }

    var enabled = false
    var kind: Kind = .wallpaper
    var fromHex = "#6A3DE8"
    var toHex = "#23D5C0"
    var solidHex = "#2B2F3A"
    /// Gradient direction in degrees (0 = left→right, 90 = top→bottom).
    var angle: Double = 45
    /// Minimum space around the screenshot, in points.
    var padding: Double = 56
    /// 0...1 shadow strength.
    var shadow: Double = 0.65
    /// Multiplier for how far and how softly the shadow spreads (0.5...2).
    var shadowDepth: Double = 1.0
    var aspect: Aspect = .free
    /// Fine grain over the background; hides gradient banding.
    var noise = true
    /// Background image for `.image`; not persisted.
    var image: CGImage?

    private enum CodingKeys: String, CodingKey {
        case enabled, kind, fromHex, toHex, solidHex, angle, padding, shadow, shadowDepth, aspect, noise
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? kind
        fromHex = try c.decodeIfPresent(String.self, forKey: .fromHex) ?? fromHex
        toHex = try c.decodeIfPresent(String.self, forKey: .toHex) ?? toHex
        solidHex = try c.decodeIfPresent(String.self, forKey: .solidHex) ?? solidHex
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? angle
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? padding
        shadow = try c.decodeIfPresent(Double.self, forKey: .shadow) ?? shadow
        shadowDepth = try c.decodeIfPresent(Double.self, forKey: .shadowDepth) ?? shadowDepth
        aspect = try c.decodeIfPresent(Aspect.self, forKey: .aspect) ?? aspect
        noise = try c.decodeIfPresent(Bool.self, forKey: .noise) ?? noise
    }

    static func == (a: BackdropStyle, b: BackdropStyle) -> Bool {
        a.enabled == b.enabled && a.kind == b.kind && a.fromHex == b.fromHex && a.toHex == b.toHex && a.solidHex == b.solidHex
            && a.angle == b.angle && a.padding == b.padding && a.shadow == b.shadow && a.shadowDepth == b.shadowDepth
            && a.aspect == b.aspect && a.noise == b.noise && a.image === b.image
    }

    static let defaultsKey = "backdropStyle"
    /// Tests turn this off so they neither read nor overwrite the user's remembered style.
    nonisolated(unsafe) static var persistenceEnabled = true

    static func loadSaved() -> BackdropStyle {
        guard persistenceEnabled, let data = UserDefaults.standard.data(forKey: defaultsKey),
              let style = try? JSONDecoder().decode(BackdropStyle.self, from: data) else { return BackdropStyle() }
        return style
    }

    func save() {
        guard Self.persistenceEnabled else { return }
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }

    /// A fresh pleasant gradient (the "Randomize" button).
    mutating func randomize() {
        let hue = CGFloat.random(in: 0..<1)
        let a = NSColor(hue: hue, saturation: .random(in: 0.55...0.85), brightness: .random(in: 0.85...1), alpha: 1)
        let b = NSColor(hue: (hue + .random(in: 0.08...0.22)).truncatingRemainder(dividingBy: 1),
                        saturation: .random(in: 0.65...0.95), brightness: .random(in: 0.5...0.85), alpha: 1)
        kind = .gradient
        fromHex = a.hexString
        toHex = b.hexString
        angle = Double([0, 30, 45, 60, 90, 120, 135].randomElement()!)
    }
}

enum BackdropRenderer {
    /// Size of the full canvas and the screenshot's origin inside it, in points.
    static func layout(content: CGSize, style: BackdropStyle) -> (canvas: CGSize, origin: CGPoint) {
        let pad = CGFloat(max(0, style.padding))
        var w = content.width + 2 * pad, h = content.height + 2 * pad
        if let r = style.aspect.ratio {
            if w / h > r { h = w / r } else { w = h * r }
        }
        return (CGSize(width: w.rounded(), height: h.rounded()),
                CGPoint(x: ((w - content.width) / 2).rounded(), y: ((h - content.height) / 2).rounded()))
    }

    // MARK: - Colours

    /// Most prominent distinct colours of an image, favouring colourful ones over flat white/grey UI.
    static func dominantColors(_ image: CGImage, count: Int = 3) -> [NSColor] {
        let maxSide = 48
        let scale = CGFloat(maxSide) / CGFloat(max(image.width, image.height))
        let w = max(1, Int(CGFloat(image.width) * min(1, scale))), h = max(1, Int(CGFloat(image.height) * min(1, scale)))
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return [] }
        var buckets: [Int: (n: Int, r: Int, g: Int, b: Int)] = [:]
        for i in 0..<(w * h) {
            let r = Int(buf[i * 4]), g = Int(buf[i * 4 + 1]), b = Int(buf[i * 4 + 2])
            let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)  // 12-bit colour
            let cur = buckets[key] ?? (0, 0, 0, 0)
            buckets[key] = (cur.n + 1, cur.r + r, cur.g + g, cur.b + b)
        }
        let scored: [(NSColor, Double)] = buckets.values.map { v in
            let c = NSColor(srgbRed: CGFloat(v.r) / CGFloat(v.n) / 255, green: CGFloat(v.g) / CGFloat(v.n) / 255,
                            blue: CGFloat(v.b) / CGFloat(v.n) / 255, alpha: 1)
            var s: CGFloat = 0, br: CGFloat = 0
            c.getHue(nil, saturation: &s, brightness: &br, alpha: nil)
            let weight = 0.25 + Double(s) * 1.5          // colourful beats grey
            let usable = br > 0.12 && br < 0.97 ? 1.0 : 0.4  // near-black / near-white are poor backgrounds
            return (c, Double(v.n) * weight * usable)
        }.sorted { $0.1 > $1.1 }
        var picked: [NSColor] = []
        for (c, _) in scored where picked.count < count {
            if picked.allSatisfy({ distance($0, c) > 0.22 }) { picked.append(c) }
        }
        return picked
    }

    private static func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let x = a.srgb, y = b.srgb
        return sqrt(pow(x.redComponent - y.redComponent, 2) + pow(x.greenComponent - y.greenComponent, 2) + pow(x.blueComponent - y.blueComponent, 2))
    }

    /// Gradient end colours for the current style. `.auto` derives them from the screenshot.
    static func colors(for style: BackdropStyle, content: CGImage?) -> (from: NSColor, to: NSColor) {
        switch style.kind {
        case .gradient:
            return (NSColor(hex: style.fromHex) ?? .systemPurple, NSColor(hex: style.toHex) ?? .systemTeal)
        case .solid:
            let c = NSColor(hex: style.solidHex) ?? .darkGray
            return (c, c)
        case .image:
            return (.darkGray, .black)
        case .wallpaper, .auto:
            // Only genuinely colourful colours make a good backdrop; for grey/white UI use the default gradient.
            // For `.wallpaper` the colours come from the wallpaper (shadow tint, and the fill if no wallpaper can be read).
            let source = style.kind == .wallpaper ? (WallpaperProvider.current() ?? content) : content
            let dominant = (source.map { dominantColors($0, count: 4) } ?? []).filter { c in
                var sat: CGFloat = 0
                c.srgb.getHue(nil, saturation: &sat, brightness: nil, alpha: nil)
                return sat >= 0.2
            }
            guard let first = dominant.first else { return (NSColor(hex: "#6A3DE8")!, NSColor(hex: "#23D5C0")!) }
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
            first.srgb.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
            let light = NSColor(hue: h, saturation: min(1, s * 0.85 + 0.1), brightness: min(1, b * 0.55 + 0.5), alpha: 1)
            if dominant.count > 1 { return (light, dominant[1]) }
            let dark = NSColor(hue: (h + 0.07).truncatingRemainder(dividingBy: 1), saturation: min(1, s + 0.15), brightness: max(0.25, b * 0.6), alpha: 1)
            return (light, dark)
        }
    }

    // MARK: - Drawing

    /// Fine monochrome grain tile (deterministic).
    private static let noiseTile: CGImage? = {
        let n = 128
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        var seed: UInt64 = 0x5EED
        for i in 0..<(n * n) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let white = (seed >> 33) % 2 == 0
            let v: UInt8 = white ? 255 : 0
            bytes[i * 4] = v; bytes[i * 4 + 1] = v; bytes[i * 4 + 2] = v; bytes[i * 4 + 3] = 9  // ≈3.5 % opacity
        }
        // Premultiplied: scale colour by alpha (v * a / 255).
        for i in 0..<(n * n) { let a = Int(bytes[i * 4 + 3]); for c in 0..<3 { bytes[i * 4 + c] = UInt8(Int(bytes[i * 4 + c]) * a / 255) } }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }()

    /// Draws the background into `rect` of a *top-left-origin* context (units = points).
    static func drawBackground(in ctx: CGContext, rect: CGRect, style: BackdropStyle, content: CGImage?, pixelScale: CGFloat) {
        ctx.saveGState()
        ctx.clip(to: rect)
        let (from, to) = colors(for: style, content: content)
        func fillImage(_ img: CGImage) {
            let k = max(rect.width / CGFloat(img.width), rect.height / CGFloat(img.height))
            let w = CGFloat(img.width) * k, h = CGFloat(img.height) * k
            AnnotationRenderer.drawImage(img, in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h), ctx: ctx)
        }
        func fillGradient() {
            let rad = CGFloat(style.angle) * .pi / 180
            let dir = CGPoint(x: cos(rad), y: sin(rad))
            let len = abs(rect.width * dir.x) + abs(rect.height * dir.y)
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      colors: [from.cgColor, to.cgColor] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(gradient, start: CGPoint(x: c.x - dir.x * len / 2, y: c.y - dir.y * len / 2),
                                   end: CGPoint(x: c.x + dir.x * len / 2, y: c.y + dir.y * len / 2),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        switch style.kind {
        case .solid:
            ctx.setFillColor(from.cgColor); ctx.fill(rect)
        case .image:
            if let img = style.image { fillImage(img) } else { ctx.setFillColor(NSColor.darkGray.cgColor); ctx.fill(rect) }
        case .wallpaper:
            // The desktop picture currently in use; if it can't be read (video wallpapers, missing file), use its colours.
            if let img = WallpaperProvider.current() { fillImage(img) } else { fillGradient() }
        case .auto, .gradient:
            fillGradient()
        }
        if style.noise, let tile = noiseTile {
            let side = 128 / max(1, pixelScale)
            ctx.draw(tile, in: CGRect(x: rect.minX, y: rect.minY, width: side, height: side), byTiling: true)
        }
        ctx.restoreGState()
    }

    /// Shadow colour: black pulled slightly towards a dark version of the backdrop, so shadows look natural on colour.
    static func shadowTint(style: BackdropStyle, content: CGImage?) -> NSColor {
        let base = colors(for: style, content: content).from.srgb
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        let dark = NSColor(hue: h, saturation: min(1, s * 1.1), brightness: 0.12, alpha: 1)
        return NSColor.black.blended(withFraction: 0.35, of: dark) ?? .black
    }

    /// Layered shadow under the screenshot: a wide ambient layer, two mid layers and a tight contact layer, the way
    /// real window shadows build up depth. `shadowDepth` stretches distance and softness. The visible shadow falls *below*.
    /// The shadow is cast by the screenshot's own alpha, so a window capture's native rounded corners are followed exactly.
    static func drawShadow(in ctx: CGContext, contentRect: CGRect, image: CGImage, style: BackdropStyle, tint: NSColor = .black) {
        guard style.shadow > 0.01 else { return }
        let k = CGFloat(style.shadow)
        let d = CGFloat(min(2.5, max(0.3, style.shadowDepth)))
        // (blur, y offset, opacity): ambient → contact.
        let layers: [(CGFloat, CGFloat, CGFloat)] = [
            (110 * d, 64 * d, 0.34 * k),
            (56 * d, 30 * d, 0.40 * k),
            (22 * d, 11 * d, 0.44 * k),
            (6 * d, 2 * d, 0.50 * k),
        ]
        for (blur, dy, alpha) in layers {
            ctx.saveGState()
            // Context is flipped (top-left origin): a negative CG offset height moves the shadow *down* on screen.
            ctx.setShadow(offset: CGSize(width: 0, height: -dy), blur: blur, color: tint.withAlphaComponent(min(1, alpha)).cgColor)
            AnnotationRenderer.drawImage(image, in: contentRect, ctx: ctx)
            ctx.restoreGState()
        }
    }

    /// Composites `content` (pixels) onto the backdrop. Returns pixels at the same scale.
    static func compose(content: CGImage, scale: CGFloat, style: BackdropStyle) -> CGImage? {
        let contentPts = CGSize(width: CGFloat(content.width) / scale, height: CGFloat(content.height) / scale)
        let (canvas, origin) = layout(content: contentPts, style: style)
        let w = Int((canvas.width * scale).rounded()), h = Int((canvas.height * scale).rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.interpolationQuality = .high
        drawBackground(in: ctx, rect: CGRect(origin: .zero, size: canvas), style: style, content: content, pixelScale: scale)
        let rect = CGRect(origin: origin, size: contentPts)
        drawShadow(in: ctx, contentRect: rect, image: content, style: style, tint: shadowTint(style: style, content: content))
        // No clip: window captures already carry their native rounded corners in the alpha channel.
        AnnotationRenderer.drawImage(content, in: rect, ctx: ctx)
        return ctx.makeImage()
    }
}


/// The desktop picture currently in use, downscaled and cached.
enum WallpaperProvider {
    private nonisolated(unsafe) static var cache: (key: String, image: CGImage)?

    /// `screen` defaults to the one under the front window (or the main screen).
    static func current(for screen: NSScreen? = nil) -> CGImage? {
        let target = screen ?? NSApp?.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let target, var url = NSWorkspace.shared.desktopImageURL(for: target) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue {  // a rotating folder: use its first picture
            let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            guard let first = files.filter({ ["jpg", "jpeg", "png", "heic", "tiff"].contains($0.pathExtension.lowercased()) })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first else { return nil }
            url = first
        }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)#\(modified)"
        if let cache, cache.key == key { return cache.image }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 2880]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        cache = (key, image)
        return image
    }
}
