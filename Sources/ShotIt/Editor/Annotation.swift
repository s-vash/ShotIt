import AppKit
import Vision
import CoreImage

/// Editor tools. Single-key shortcuts (A, R, O, L, D, T, C, B, H, S, M).
enum Tool: String, CaseIterable {
    case select, arrow, rectangle, oval, line, freehand, text, counter, blur, highlighter, spotlight, magnifier, crop

    var key: String {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .rectangle: return "r"
        case .oval: return "o"
        case .line: return "l"
        case .freehand: return "d"
        case .text: return "t"
        case .counter: return "c"
        case .blur: return "b"
        case .highlighter: return "h"
        case .spotlight: return "s"
        case .magnifier: return "m"
        case .crop: return "x"
        }
    }

    var title: String {
        switch self {
        case .select: return "Select / Move"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .oval: return "Oval"
        case .line: return "Line"
        case .freehand: return "Freehand Drawing"
        case .text: return "Text"
        case .counter: return "Counter"
        case .blur: return "Blur / Erase"
        case .highlighter: return "Highlighter"
        case .spotlight: return "Spotlight"
        case .magnifier: return "Magnifier"
        case .crop: return "Crop"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .oval: return "circle"
        case .line: return "line.diagonal"
        case .freehand: return "scribble"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .blur: return "drop.halffull"
        case .highlighter: return "highlighter"
        case .spotlight: return "flashlight.on.fill"
        case .magnifier: return "plus.magnifyingglass"
        case .crop: return "crop"
        }
    }

    var annotationKind: Annotation.Kind? {
        switch self {
        case .arrow: return .arrow
        case .rectangle: return .rectangle
        case .oval: return .oval
        case .line: return .line
        case .freehand: return .freehand
        case .text: return .text
        case .counter: return .counter
        case .blur: return .blur
        case .highlighter: return .highlighter
        case .spotlight: return .spotlight
        case .magnifier: return .magnifier
        case .select, .crop: return nil
        }
    }

    /// Whether the style control ("Fill" / blur type) applies.
    var styleOptions: [String] {
        switch self {
        case .rectangle, .oval: return ["Outline", "Filled"]
        case .text: return ["Plain", "Boxed"]
        case .blur: return ["Pixelate", "Blur", "Erase", "Blur Text", "Erase Text"]
        default: return []
        }
    }
}

/// One annotation object. Coordinates are in image points with a top-left origin.
struct Annotation {
    enum Kind { case arrow, rectangle, oval, line, freehand, text, counter, blur, highlighter, spotlight, magnifier }

    var id = UUID()
    var kind: Kind
    var p1: CGPoint
    var p2: CGPoint
    var points: [CGPoint] = []
    var text: String = ""
    var number: Int = 0
    var color: NSColor
    var size: CGFloat
    /// Tool-specific variant: fill (rect/oval/text) or blur type (0 pixelate, 1 blur, 2 erase, 3 blur text only, 4 erase text only).
    var style: Int = 0

    var rect: CGRect {
        CGRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
    }

    var isRectLike: Bool {
        switch kind {
        case .rectangle, .oval, .blur, .highlighter, .spotlight, .magnifier: return true
        default: return false
        }
    }

    var fontSize: CGFloat { max(12, size * 4 + 8) }
    var counterDiameter: CGFloat { max(18, size * 4 + 14) }

    mutating func offset(by d: CGVector) {
        p1.x += d.dx; p1.y += d.dy
        p2.x += d.dx; p2.y += d.dy
        points = points.map { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
    }

    func textAttributes() -> [NSAttributedString.Key: Any] {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        if style == 1 {
            return [.font: font, .foregroundColor: color.contrastingTextColor]
        }
        let shadow = NSShadow()
        shadow.shadowColor = (color.isLight ? NSColor.black : NSColor.white).withAlphaComponent(0.85)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = .zero
        return [.font: font, .foregroundColor: color, .shadow: shadow]
    }

    /// Bounding rect used for hit testing and selection.
    var bounds: CGRect {
        switch kind {
        case .text:
            let s = ((text.isEmpty ? " " : text) as NSString).size(withAttributes: textAttributes())
            let pad: CGFloat = style == 1 ? fontSize * 0.35 : 0
            return CGRect(x: p1.x - pad, y: p1.y - pad, width: s.width + pad * 2, height: s.height + pad * 2)
        case .counter:
            let d = counterDiameter
            return CGRect(x: p1.x - d / 2, y: p1.y - d / 2, width: d, height: d)
        case .freehand:
            guard let f = points.first else { return .zero }
            var r = CGRect(origin: f, size: .zero)
            for p in points { r = r.union(CGRect(origin: p, size: .zero)) }
            return r.insetBy(dx: -size, dy: -size)
        case .arrow, .line:
            return rect.insetBy(dx: -size * 2, dy: -size * 2)
        default:
            return rect
        }
    }

    func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        let tol = tolerance + size / 2
        switch kind {
        case .arrow, .line:
            return distance(p, segment: (p1, p2)) <= tol + (kind == .arrow ? size : 0)
        case .freehand:
            guard points.count > 1 else { return points.first.map { hypot($0.x - p.x, $0.y - p.y) <= tol } ?? false }
            for i in 1..<points.count where distance(p, segment: (points[i - 1], points[i])) <= tol { return true }
            return false
        case .rectangle where style == 0:
            let r = rect
            return r.insetBy(dx: -tol, dy: -tol).contains(p) && !r.insetBy(dx: tol, dy: tol).contains(p)
        case .oval where style == 0:
            let r = rect
            guard r.width > 1, r.height > 1 else { return false }
            let nx = (p.x - r.midX) / (r.width / 2), ny = (p.y - r.midY) / (r.height / 2)
            let d = sqrt(nx * nx + ny * ny)
            let tolN = tol / max(1, min(r.width, r.height) / 2)
            return abs(d - 1) <= tolN
        default:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    private func distance(_ p: CGPoint, segment: (CGPoint, CGPoint)) -> CGFloat {
        let (a, b) = segment
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

extension NSColor {
    var srgb: NSColor { usingColorSpace(.sRGB) ?? self }
    var luminance: CGFloat {
        let c = srgb
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }
    var isLight: Bool { luminance > 0.6 }
    var contrastingTextColor: NSColor { isLight ? .black : .white }

    var hexString: String {
        let c = srgb
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

/// Draws a base image and its annotations into a top-left-origin context whose units are image points.
final class AnnotationRenderer {
    /// Test hook: skip the object-mask step to inspect the raw background estimate.
    nonisolated(unsafe) static var disableObjectMask = false
    let base: CGImage
    let pointSize: CGSize
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var pixelatedCache: CGImage?
    private var blurredCache: CGImage?

    init(base: CGImage, pointSize: CGSize) {
        self.base = base
        self.pointSize = pointSize
    }

    private var pixelScale: CGFloat { CGFloat(base.width) / max(pointSize.width, 1) }

    private var pixelated: CGImage? {
        if pixelatedCache == nil {
            let ci = CIImage(cgImage: base)
            let f = CIFilter(name: "CIPixellate")!
            f.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
            f.setValue(max(8, 9 * pixelScale), forKey: kCIInputScaleKey)
            f.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
            if let out = f.outputImage?.cropped(to: ci.extent) {
                pixelatedCache = AnnotationRenderer.ciContext.createCGImage(out, from: ci.extent)
            }
        }
        return pixelatedCache
    }

    private var blurred: CGImage? {
        if blurredCache == nil {
            let ci = CIImage(cgImage: base)
            let out = ci.clampedToExtent().applyingGaussianBlur(sigma: Double(10 * pixelScale)).cropped(to: ci.extent)
            blurredCache = AnnotationRenderer.ciContext.createCGImage(out, from: ci.extent)
        }
        return blurredCache
    }

    private lazy var pixels = PixelReader(image: base)

    // MARK: - Text detection (Blur Text / Erase Text)

    private let textLock = NSLock()
    private var textBoxesPx: [CGRect]?

    /// Starts text detection in the background so the first Blur Text / Erase Text drag doesn't stall.
    func prefetchTextBoxes() {
        DispatchQueue.global(qos: .userInitiated).async { _ = self.textBoxes }
    }

    /// Text line boxes in image pixels (top-left origin), detected once per base image.
    private var textBoxes: [CGRect] {
        textLock.lock(); defer { textLock.unlock() }
        if let t = textBoxesPx { return t }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: base, options: [:]).perform([request])
        let w = CGFloat(base.width), h = CGFloat(base.height)
        let boxes = (request.results ?? []).map { o -> CGRect in
            let b = o.boundingBox  // normalised, bottom-left origin
            return CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h)
        }
        textBoxesPx = boxes
        return boxes
    }

    /// Detected text lines in points, padded so anti-aliased glyph edges and descenders are covered.
    private func textRects() -> [CGRect] {
        let s = pixelScale
        return textBoxes.map { b in
            let pad = max(2 * s, b.height * 0.2)
            return b.insetBy(dx: -pad, dy: -pad).applying(CGAffineTransform(scaleX: 1 / s, y: 1 / s))
        }
    }
    private var eraseCache: [UUID: (CGRect, CGImage)] = [:]

    /// Content-aware fill for the Erase tool. Estimates the background under the selection from the
    /// pixels just outside it (robust per-position median, so text/objects touching the edge don't
    /// leak in), then blends the four edges with transfinite interpolation. Gradients and uneven
    /// backgrounds continue smoothly instead of becoming one flat colour.
    private func eraseImage(for a: Annotation) -> (CGImage, CGRect)? {
        let s = pixelScale
        let full = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let px = CGRect(x: floor(a.rect.minX * s), y: floor(a.rect.minY * s),
                        width: ceil(a.rect.width * s), height: ceil(a.rect.height * s)).intersection(full).integral
        guard px.width >= 1, px.height >= 1 else { return nil }
        if let c = eraseCache[a.id], c.0 == px {
            return (c.1, CGRect(x: px.minX / s, y: px.minY / s, width: px.width / s, height: px.height / s))
        }
        let x0 = Int(px.minX), y0 = Int(px.minY), w = Int(px.width), h = Int(px.height)
        let ring = 3, win = 7
        let hasT = y0 >= 1, hasB = y0 + h < base.height, hasL = x0 >= 1, hasR = x0 + w < base.width

        // Interquartile mean: average of the middle half of the samples. Ignores text/objects touching the edge
        // (outliers) but, unlike a median, stays smooth on noisy or dithered backgrounds.
        func median(_ pts: [(Int, Int)]) -> SIMD3<Float>? {
            var r = [Float](), g = [Float](), b = [Float]()
            for (x, y) in pts { if let c = pixels.rgb(x: x, y: y) { r.append(c.x); g.append(c.y); b.append(c.z) } }
            guard !r.isEmpty else { return nil }
            func iqm(_ v: inout [Float]) -> Float {
                v.sort()
                let lo = v.count / 4, hi = max(lo + 1, v.count - v.count / 4)
                return v[lo..<hi].reduce(0, +) / Float(hi - lo)
            }
            return SIMD3(iqm(&r), iqm(&g), iqm(&b))
        }
        func edge(count: Int, point: (Int, Int, Int) -> (Int, Int)) -> [SIMD3<Float>] {
            (0..<count).map { i in
                var pts = [(Int, Int)]()
                for d in 0..<ring { for k in -win...win { pts.append(point(i + k, d, i)) } }
                return median(pts) ?? SIMD3(255, 255, 255)
            }
        }
        // Outward samples: `i` is the position along the edge (already offset by k), `d` the distance outwards.
        let T = hasT ? edge(count: w) { i, d, _ in (x0 + i, y0 - 1 - d) } : []
        let B = hasB ? edge(count: w) { i, d, _ in (x0 + i, y0 + h + d) } : []
        let L = hasL ? edge(count: h) { j, d, _ in (x0 - 1 - d, y0 + j) } : []
        let R = hasR ? edge(count: h) { j, d, _ in (x0 + w + d, y0 + j) } : []

        var fallback = SIMD3<Float>(255, 255, 255)
        if !(hasT || hasB || hasL || hasR) { fallback = pixels.rgb(x: x0 + w / 2, y: y0 + h / 2) ?? fallback }

        var out = [UInt8](repeating: 255, count: w * h * 4)
        let all4 = hasT && hasB && hasL && hasR
        let tl = all4 ? (T[0] + L[0]) / 2 : .zero, tr = all4 ? (T[w - 1] + R[0]) / 2 : .zero
        let bl = all4 ? (B[0] + L[h - 1]) / 2 : .zero, br = all4 ? (B[w - 1] + R[h - 1]) / 2 : .zero
        for j in 0..<h {
            let v = (Float(j) + 0.5) / Float(h)
            for i in 0..<w {
                let u = (Float(i) + 0.5) / Float(w)
                var horiz: SIMD3<Float>?, vert: SIMD3<Float>?
                if hasL && hasR { horiz = L[j] * (1 - u) + R[j] * u } else if hasL { horiz = L[j] } else if hasR { horiz = R[j] }
                if hasT && hasB { vert = T[i] * (1 - v) + B[i] * v } else if hasT { vert = T[i] } else if hasB { vert = B[i] }
                var c: SIMD3<Float>
                if all4, let hz = horiz, let vt = vert {
                    let bil = tl * ((1 - u) * (1 - v)) + tr * (u * (1 - v)) + bl * ((1 - u) * v) + br * (u * v)
                    c = hz + vt - bil
                } else if let hz = horiz, let vt = vert {
                    c = (hz + vt) / 2
                } else {
                    c = horiz ?? vert ?? fallback
                }
                let o = (j * w + i) * 4
                out[o] = UInt8(max(0, min(255, c.x.rounded())))
                out[o + 1] = UInt8(max(0, min(255, c.y.rounded())))
                out[o + 2] = UInt8(max(0, min(255, c.z.rounded())))
            }
        }
        if !AnnotationRenderer.disableObjectMask { applyObjectMask(&out, width: w, height: h, x0: x0, y0: y0) }
        guard let provider = CGDataProvider(data: Data(out) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        eraseCache[a.id] = (px, img)
        return (img, CGRect(x: px.minX / s, y: px.minY / s, width: px.width / s, height: px.height / s))
    }


    /// Keeps the original pixels wherever they already match the estimated background and only repaints
    /// what differs from it (text, icons, other objects) plus a small halo for anti-aliasing. Background noise
    /// and texture therefore survive, and the repaired area has no visible flat patch.
    private func applyObjectMask(_ out: inout [UInt8], width w: Int, height h: Int, x0: Int, y0: Int) {
        let threshold: Float = 22
        var mask = [UInt8](repeating: 0, count: w * h)
        var covered = 0
        for j in 0..<h {
            for i in 0..<w {
                guard let o = pixels.rgb(x: x0 + i, y: y0 + j) else { continue }
                let k = (j * w + i) * 4
                let d = max(abs(o.x - Float(out[k])), abs(o.y - Float(out[k + 1])), abs(o.z - Float(out[k + 2])))
                if d > threshold { mask[j * w + i] = 255; covered += 1 }
            }
        }
        // Mostly-different region (a photo, a busy area): the synthesized fill is the best we have.
        if Double(covered) > 0.85 * Double(w * h) { return }
        let radius = max(1, Int((1.5 * pixelScale).rounded()))
        dilate(&mask, width: w, height: h, radius: radius)
        // Soften the mask edge so repainted pixels blend into untouched ones.
        var soft = [Float](repeating: 0, count: w * h)
        for j in 0..<h {
            for i in 0..<w {
                var sum: Float = 0, n: Float = 0
                for dj in -1...1 { for di in -1...1 {
                    let x = i + di, y = j + dj
                    if x >= 0, y >= 0, x < w, y < h { sum += Float(mask[y * w + x]); n += 1 }
                } }
                soft[j * w + i] = sum / (n * 255)
            }
        }
        // Grain: borrow the background's own noise (original minus estimate) from untouched pixels so the
        // repainted area doesn't look smoother than its surroundings.
        var grain = [SIMD3<Float>]()
        for j in 0..<h {
            for i in 0..<w where mask[j * w + i] == 0 {
                guard let o = pixels.rgb(x: x0 + i, y: y0 + j) else { continue }
                let k = (j * w + i) * 4
                grain.append(SIMD3(o.x - Float(out[k]), o.y - Float(out[k + 1]), o.z - Float(out[k + 2])))
            }
        }
        for j in 0..<h {
            for i in 0..<w {
                let a = soft[j * w + i]
                guard let o = pixels.rgb(x: x0 + i, y: y0 + j) else { continue }
                if a <= 0 {  // untouched: keep the original pixel
                    let k = (j * w + i) * 4
                    out[k] = UInt8(max(0, min(255, o.x.rounded()))); out[k + 1] = UInt8(max(0, min(255, o.y.rounded()))); out[k + 2] = UInt8(max(0, min(255, o.z.rounded())))
                    continue
                }
                let k = (j * w + i) * 4
                var bg = SIMD3(Float(out[k]), Float(out[k + 1]), Float(out[k + 2]))
                if grain.count >= 32 {
                    let idx = Int(UInt32(truncatingIfNeeded: i &* 73856093) ^ UInt32(truncatingIfNeeded: j &* 19349663)) % grain.count
                    bg += grain[idx]
                }
                let c = o * (1 - a) + bg * a
                out[k] = UInt8(max(0, min(255, c.x.rounded())))
                out[k + 1] = UInt8(max(0, min(255, c.y.rounded())))
                out[k + 2] = UInt8(max(0, min(255, c.z.rounded())))
            }
        }
    }

    /// Separable square max-filter (dilation) of a 0/255 mask.
    private func dilate(_ mask: inout [UInt8], width w: Int, height h: Int, radius r: Int) {
        var tmp = mask
        for j in 0..<h {
            for i in 0..<w {
                var m: UInt8 = 0
                for x in max(0, i - r)...min(w - 1, i + r) { m = max(m, mask[j * w + x]) }
                tmp[j * w + i] = m
            }
        }
        for j in 0..<h {
            for i in 0..<w {
                var m: UInt8 = 0
                for y in max(0, j - r)...min(h - 1, j + r) { m = max(m, tmp[y * w + i]) }
                mask[j * w + i] = m
            }
        }
    }

    static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// Renders everything. `ctx` must be top-left origin with point units; an NSGraphicsContext
    /// wrapping it (flipped) must be current for text drawing.
    func render(_ annotations: [Annotation], in ctx: CGContext, drawBase: Bool = true) {
        let full = CGRect(origin: .zero, size: pointSize)
        if drawBase { AnnotationRenderer.drawImage(base, in: full, ctx: ctx) }

        for a in annotations where a.kind == .blur { drawBlur(a, ctx: ctx, full: full) }
        for a in annotations where a.kind == .highlighter { drawHighlighter(a, ctx: ctx) }

        let spots = annotations.filter { $0.kind == .spotlight && $0.rect.width > 1 && $0.rect.height > 1 }
        if !spots.isEmpty {
            ctx.saveGState()
            let path = CGMutablePath()
            path.addRect(full)
            for s in spots {
                let r = s.rect
                let radius = min(8, min(r.width, r.height) / 4)
                path.addRoundedRect(in: r, cornerWidth: radius, cornerHeight: radius)
            }
            ctx.addPath(path)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
        }

        for a in annotations where a.kind == .magnifier { drawMagnifier(a, ctx: ctx, full: full) }

        for a in annotations {
            switch a.kind {
            case .arrow: drawArrow(a, ctx: ctx)
            case .rectangle: drawRect(a, ctx: ctx, oval: false)
            case .oval: drawRect(a, ctx: ctx, oval: true)
            case .line: drawLine(a, ctx: ctx)
            case .freehand: drawFreehand(a, ctx: ctx)
            case .text: drawText(a, ctx: ctx)
            case .counter: drawCounter(a, ctx: ctx)
            default: break
            }
        }
    }

    // MARK: - Shapes

    private func drawBlur(_ a: Annotation, ctx: CGContext, full: CGRect) {
        let r = a.rect.intersection(full)
        guard !r.isEmpty else { return }
        ctx.saveGState()
        ctx.clip(to: r)
        let textOnly = a.style >= 3
        if textOnly {
            let rects = textRects().filter { $0.intersects(r) }
            guard !rects.isEmpty else { ctx.restoreGState(); return }
            ctx.clip(to: rects)
        }
        switch a.style {
        case 1, 3: if let img = blurred { AnnotationRenderer.drawImage(img, in: full, ctx: ctx) }
        case 2, 4:
            if let (img, rect) = eraseImage(for: a) { AnnotationRenderer.drawImage(img, in: rect, ctx: ctx) }
        default:
            ctx.interpolationQuality = .none
            if let img = pixelated { AnnotationRenderer.drawImage(img, in: full, ctx: ctx) }
        }
        ctx.restoreGState()
    }

    private func drawHighlighter(_ a: Annotation, ctx: CGContext) {
        ctx.saveGState()
        ctx.setBlendMode(.multiply)
        ctx.setFillColor(a.color.withAlphaComponent(0.45).cgColor)
        ctx.fill(a.rect)
        ctx.restoreGState()
    }

    private func drawMagnifier(_ a: Annotation, ctx: CGContext, full: CGRect) {
        let r = a.rect
        guard r.width > 4, r.height > 4 else { return }
        let zoom: CGFloat = 2
        let circle = CGRect(x: r.midX - min(r.width, r.height) / 2, y: r.midY - min(r.width, r.height) / 2,
                            width: min(r.width, r.height), height: min(r.width, r.height))
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 10, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: circle.insetBy(dx: -3, dy: -3))
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addEllipse(in: circle)
        ctx.clip()
        ctx.interpolationQuality = .none
        let scaled = CGRect(x: circle.midX - circle.midX * zoom, y: circle.midY - circle.midY * zoom,
                            width: full.width * zoom, height: full.height * zoom)
        AnnotationRenderer.drawImage(base, in: scaled, ctx: ctx)
        ctx.restoreGState()
    }

    private func drawArrow(_ a: Annotation, ctx: CGContext) {
        let dx = a.p2.x - a.p1.x, dy = a.p2.y - a.p1.y
        let len = hypot(dx, dy)
        guard len > 1 else { return }
        let ux = dx / len, uy = dy / len
        let px = -uy, py = ux
        let w = a.size
        var headLen = max(10, w * 4.5)
        if headLen > len * 0.7 { headLen = len * 0.7 }
        let headHalf = max(6, w * 2.6) * (headLen / max(10, w * 4.5)).squareRoot()
        let tailHalf = max(0.75, w * 0.25)
        let shaftHalf = max(1.5, w * 0.6)
        let wingBase = CGPoint(x: a.p2.x - ux * headLen, y: a.p2.y - uy * headLen)
        let notch = CGPoint(x: a.p2.x - ux * headLen * 0.82, y: a.p2.y - uy * headLen * 0.82)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: a.p1.x + px * tailHalf, y: a.p1.y + py * tailHalf))
        path.addLine(to: CGPoint(x: notch.x + px * shaftHalf, y: notch.y + py * shaftHalf))
        path.addLine(to: CGPoint(x: wingBase.x + px * headHalf, y: wingBase.y + py * headHalf))
        path.addLine(to: a.p2)
        path.addLine(to: CGPoint(x: wingBase.x - px * headHalf, y: wingBase.y - py * headHalf))
        path.addLine(to: CGPoint(x: notch.x - px * shaftHalf, y: notch.y - py * shaftHalf))
        path.addLine(to: CGPoint(x: a.p1.x - px * tailHalf, y: a.p1.y - py * tailHalf))
        path.closeSubpath()

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.addPath(path)
        ctx.setFillColor(a.color.cgColor)
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(1)
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()
    }

    private func drawRect(_ a: Annotation, ctx: CGContext, oval: Bool) {
        let r = a.rect
        guard r.width > 0.5 || r.height > 0.5 else { return }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        let path: CGPath
        if oval {
            path = CGPath(ellipseIn: a.style == 1 ? r : r.insetBy(dx: a.size / 2, dy: a.size / 2), transform: nil)
        } else {
            let inset = a.style == 1 ? r : r.insetBy(dx: a.size / 2, dy: a.size / 2)
            let radius = min(a.size * 1.2, min(inset.width, inset.height) / 2)
            path = CGPath(roundedRect: inset, cornerWidth: max(0, radius), cornerHeight: max(0, radius), transform: nil)
        }
        ctx.addPath(path)
        if a.style == 1 {
            ctx.setFillColor(a.color.cgColor)
            ctx.fillPath()
        } else {
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(a.size)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private func drawLine(_ a: Annotation, ctx: CGContext) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setLineWidth(a.size)
        ctx.setLineCap(.round)
        ctx.move(to: a.p1)
        ctx.addLine(to: a.p2)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawFreehand(_ a: Annotation, ctx: CGContext) {
        guard let first = a.points.first else { return }
        ctx.saveGState()
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setLineWidth(a.size)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: first)
        if a.points.count == 1 {
            ctx.addLine(to: first)
        } else {
            // Quadratic smoothing through segment midpoints.
            for i in 1..<a.points.count {
                let prev = a.points[i - 1], cur = a.points[i]
                let mid = CGPoint(x: (prev.x + cur.x) / 2, y: (prev.y + cur.y) / 2)
                ctx.addQuadCurve(to: mid, control: prev)
            }
            ctx.addLine(to: a.points[a.points.count - 1])
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawText(_ a: Annotation, ctx: CGContext) {
        guard !a.text.isEmpty else { return }
        let attrs = a.textAttributes()
        if a.style == 1 {
            let b = a.bounds
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: NSColor.black.withAlphaComponent(0.3).cgColor)
            ctx.addPath(CGPath(roundedRect: b, cornerWidth: a.fontSize * 0.3, cornerHeight: a.fontSize * 0.3, transform: nil))
            ctx.setFillColor(a.color.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
        (a.text as NSString).draw(at: a.p1, withAttributes: attrs)
    }

    private func drawCounter(_ a: Annotation, ctx: CGContext) {
        let r = a.bounds
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.fillEllipse(in: r)
        ctx.restoreGState()
        let s = "\(a.number)" as NSString
        let font = NSFont.systemFont(ofSize: r.height * 0.55, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: a.color.contrastingTextColor]
        let size = s.size(withAttributes: attrs)
        s.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
    }

    // MARK: - Flatten

    /// Produces the final pixel image with annotations burned in.
    func flatten(_ annotations: [Annotation]) -> CGImage? {
        let w = base.width, h = base.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let s = pixelScale
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: s, y: -s)
        ctx.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        render(annotations, in: ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
