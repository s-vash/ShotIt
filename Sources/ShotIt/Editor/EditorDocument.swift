import AppKit

/// Editor model: base image + annotations, with snapshot-based undo/redo.
final class EditorDocument {
    struct State {
        var image: CGImage
        var annotations: [Annotation]
    }

    let scale: CGFloat
    let date: Date
    var fileURL: URL?
    private(set) var renderer: AnnotationRenderer
    private(set) var pixels: PixelReader

    var state: State {
        didSet {
            if state.image !== oldValue.image { rebuildImageCaches() }
            onChange?()
        }
    }

    var onChange: (() -> Void)?

    /// Background/shadow/padding applied around the screenshot at export time. Remembered between sessions.
    var backdrop = BackdropStyle.loadSaved() {
        didSet {
            guard backdrop != oldValue else { return }
            backdrop.save()
            onChange?()
        }
    }
    private var undoStack: [State] = []
    private var redoStack: [State] = []

    init(screenshot: Screenshot) {
        scale = screenshot.scale
        date = screenshot.date
        fileURL = screenshot.fileURL
        state = State(image: screenshot.image, annotations: [])
        let size = screenshot.pointSize
        renderer = AnnotationRenderer(base: screenshot.image, pointSize: size)
        pixels = PixelReader(image: screenshot.image)
    }

    var image: CGImage { state.image }
    var pointSize: CGSize { CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private func rebuildImageCaches() {
        renderer = AnnotationRenderer(base: state.image, pointSize: pointSize)
        pixels = PixelReader(image: state.image)
    }

    /// Records the current state so the next mutation can be undone.
    func checkpoint() {
        undoStack.append(state)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// Drops the last checkpoint (used when a gesture produced nothing).
    func discardCheckpoint() {
        if let s = undoStack.popLast() { state = s }
    }

    func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(state)
        state = s
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(state)
        state = s
    }

    func index(of id: UUID?) -> Int? {
        guard let id else { return nil }
        return state.annotations.firstIndex { $0.id == id }
    }

    func annotation(_ id: UUID?) -> Annotation? {
        index(of: id).map { state.annotations[$0] }
    }

    func update(_ id: UUID, _ body: (inout Annotation) -> Void) {
        guard let i = index(of: id) else { return }
        body(&state.annotations[i])
    }

    func remove(_ id: UUID) {
        state.annotations.removeAll { $0.id == id }
    }

    var nextCounterNumber: Int {
        (state.annotations.filter { $0.kind == .counter }.map(\.number).max() ?? 0) + 1
    }

    /// Crops the image to `rect` (points, top-left origin). Annotations are shifted to match.
    func crop(to rect: CGRect) {
        let bounds = CGRect(origin: .zero, size: pointSize)
        let r = rect.intersection(bounds)
        guard r.width >= 1, r.height >= 1 else { return }
        let px = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale).integral
        guard let cropped = image.cropping(to: px) else { return }
        checkpoint()
        let origin = CGPoint(x: px.minX / scale, y: px.minY / scale)
        var anns = state.annotations
        for i in anns.indices { anns[i].offset(by: CGVector(dx: -origin.x, dy: -origin.y)) }
        state = State(image: cropped, annotations: anns)
    }

    func flattened() -> CGImage {
        renderer.flatten(state.annotations) ?? image
    }

    /// What gets copied, saved, pinned and dragged: annotations burned in, plus the backdrop when enabled.
    func exported() -> CGImage {
        let flat = flattened()
        guard backdrop.enabled, let composed = BackdropRenderer.compose(content: flat, scale: scale, style: backdrop) else { return flat }
        return composed
    }
}

/// Reads sRGB pixel colours from an image (cached RGBA8 buffer).
final class PixelReader {
    private let width: Int
    private let height: Int
    private var buffer: [UInt8]

    init(image: CGImage) {
        width = image.width
        height = image.height
        buffer = [UInt8](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Raw 0...255 RGB (assumes opaque pixels, as screenshots are). `x`,`y` in pixels, top-left origin.
    func rgb(x: Int, y: Int) -> SIMD3<Float>? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let i = (y * width + x) * 4
        let a = Float(buffer[i + 3])
        guard a > 0 else { return SIMD3(0, 0, 0) }
        let k = 255 / a
        return SIMD3(Float(buffer[i]) * k, Float(buffer[i + 1]) * k, Float(buffer[i + 2]) * k)
    }

    /// `x`,`y` in pixels with top-left origin.
    func color(x: Int, y: Int) -> NSColor? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let i = (y * width + x) * 4
        let a = CGFloat(buffer[i + 3]) / 255
        guard a > 0 else { return NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0) }
        return NSColor(srgbRed: CGFloat(buffer[i]) / 255 / a, green: CGFloat(buffer[i + 1]) / 255 / a,
                       blue: CGFloat(buffer[i + 2]) / 255 / a, alpha: a)
    }
}

extension NSColor {
    /// Formats the colour per the user's chosen color format.
    func formatted(_ format: ColorFormat) -> String {
        let c = srgb
        let r = Int((c.redComponent * 255).rounded()), g = Int((c.greenComponent * 255).rounded()),
            b = Int((c.blueComponent * 255).rounded())
        switch format {
        case .hex: return hexString
        case .rgb: return "\(r), \(g), \(b)"
        case .rgba: return String(format: "%.2f, %.2f, %.2f, %.2f", c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
        case .cssRGB: return "rgb(\(r) \(g) \(b))"
        case .swiftUI: return String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", c.redComponent, c.greenComponent, c.blueComponent)
        case .hsl:
            let rf = c.redComponent, gf = c.greenComponent, bf = c.blueComponent
            let mx = max(rf, gf, bf), mn = min(rf, gf, bf)
            let l = (mx + mn) / 2
            var h: CGFloat = 0, s: CGFloat = 0
            if mx != mn {
                let d = mx - mn
                s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
                switch mx {
                case rf: h = (gf - bf) / d + (gf < bf ? 6 : 0)
                case gf: h = (bf - rf) / d + 2
                default: h = (rf - gf) / d + 4
                }
                h /= 6
            }
            return "hsl(\(Int((h * 360).rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)"
        }
    }
}
