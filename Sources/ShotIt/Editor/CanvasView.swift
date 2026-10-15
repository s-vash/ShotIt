import AppKit

/// Draws the screenshot and annotations; handles all drawing/editing mouse interaction.
/// Coordinates: flipped, one unit = one image point.
final class CanvasView: NSView {
    let doc: EditorDocument

    var tool: Tool = .arrow {
        didSet {
            if tool != .crop { cropRect = nil }
            commitTextEditing()
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    var color: NSColor = .systemRed
    var strokeSize: CGFloat = 4
    var style: Int = 0

    private(set) var selectedID: UUID? {
        didSet { if selectedID != oldValue { onSelectionChange?(doc.annotation(selectedID)); needsDisplay = true } }
    }
    private(set) var cropRect: CGRect? {
        didSet { onCropChange?(cropRect); needsDisplay = true }
    }

    var onHover: ((CGPoint?, NSColor?) -> Void)?
    var onSelectionChange: ((Annotation?) -> Void)?
    var onCropChange: ((CGRect?) -> Void)?

    private enum Drag {
        case none
        case creating(UUID)
        case moving(UUID, last: CGPoint)
        case handle(UUID, index: Int)
        case cropNew(start: CGPoint)
        case cropMove(origin: CGRect, start: CGPoint)
    }
    private var drag: Drag = .none
    private var dragCheckpointed = false
    private var textField: NSTextField?
    private var editingTextID: UUID?
    private var trackingArea: NSTrackingArea?

    init(doc: EditorDocument) {
        self.doc = doc
        super.init(frame: CGRect(origin: .zero, size: doc.pointSize))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func documentDidChange() {
        let size = doc.pointSize
        if frame.size != size { setFrameSize(size) }
        if let id = selectedID, doc.index(of: id) == nil { selectedID = nil }
        onSelectionChange?(doc.annotation(selectedID))
        needsDisplay = true
    }

    // MARK: - Drawing

    private var magnification: CGFloat { enclosingScrollView?.magnification ?? 1 }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = magnification >= 2 ? .none : .high
        let anns = doc.state.annotations.filter { $0.id != editingTextID }
        doc.renderer.render(anns, in: ctx)

        let px = 1 / magnification
        if let a = doc.annotation(selectedID), a.id != editingTextID {
            ctx.saveGState()
            let b = a.bounds.insetBy(dx: -3 * px, dy: -3 * px)
            ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(px)
            ctx.setLineDash(phase: 0, lengths: [4 * px, 3 * px])
            if a.kind != .arrow && a.kind != .line { ctx.stroke(b) }
            ctx.restoreGState()
            for h in handles(for: a) { drawKnob(at: h, ctx: ctx, px: px) }
        }

        if let c = cropRect {
            ctx.saveGState()
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addRect(c)
            ctx.addPath(path)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(px)
            ctx.stroke(c)
            // Rule-of-thirds guides.
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
            for i in 1...2 {
                let x = c.minX + c.width * CGFloat(i) / 3, y = c.minY + c.height * CGFloat(i) / 3
                ctx.move(to: CGPoint(x: x, y: c.minY)); ctx.addLine(to: CGPoint(x: x, y: c.maxY))
                ctx.move(to: CGPoint(x: c.minX, y: y)); ctx.addLine(to: CGPoint(x: c.maxX, y: y))
            }
            ctx.strokePath()
            ctx.restoreGState()
            for h in rectCorners(c) { drawKnob(at: h, ctx: ctx, px: px) }
        }
    }

    private func drawKnob(at p: CGPoint, ctx: CGContext, px: CGFloat) {
        let r = 4.5 * px
        let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 2 * px, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: rect)
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.5 * px)
        ctx.strokeEllipse(in: rect.insetBy(dx: 0.75 * px, dy: 0.75 * px))
    }

    private func rectCorners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    private func handles(for a: Annotation) -> [CGPoint] {
        switch a.kind {
        case .arrow, .line: return [a.p1, a.p2]
        case .text, .counter, .freehand: return []
        default: return rectCorners(a.rect)
        }
    }

    // MARK: - Cursor & hover

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: tool == .select ? .arrow : (tool == .text ? .iBeam : .crosshair))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let ta = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        onHover?(p, colorAt(p))
    }

    override func mouseExited(with event: NSEvent) { onHover?(nil, nil) }

    func colorAt(_ p: CGPoint) -> NSColor? {
        doc.pixels.color(x: Int(floor(p.x * doc.scale)), y: Int(floor(p.y * doc.scale)))
    }

    // MARK: - Mouse

    private var hitTolerance: CGFloat { 5 / magnification }

    private func topAnnotation(at p: CGPoint) -> Annotation? {
        let candidates = doc.state.annotations.reversed()
        return candidates.first { a in
            let eligible = tool == .select || a.id == selectedID || a.kind == tool.annotationKind
            return eligible && a.hitTest(p, tolerance: hitTolerance)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        dragCheckpointed = false

        if textField != nil {
            commitTextEditing()
            return
        }

        if tool == .crop {
            if let c = cropRect {
                if let i = rectCorners(c).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) <= 8 / magnification }) {
                    let opposite = rectCorners(c)[(i + 2) % 4]
                    drag = .cropNew(start: opposite)
                    return
                }
                if c.contains(p) { drag = .cropMove(origin: c, start: p); return }
            }
            drag = .cropNew(start: clamp(p))
            cropRect = nil
            return
        }

        // Handles of the selected annotation.
        if let a = doc.annotation(selectedID),
           let i = handles(for: a).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) <= 8 / magnification }) {
            drag = .handle(a.id, index: i)
            return
        }

        if let hit = topAnnotation(at: p) {
            selectedID = hit.id
            if event.clickCount == 2, hit.kind == .text {
                beginTextEditing(hit.id)
                return
            }
            drag = .moving(hit.id, last: p)
            return
        }

        guard let kind = tool.annotationKind else {
            selectedID = nil
            drag = .none
            return
        }

        doc.checkpoint()
        var a = Annotation(kind: kind, p1: p, p2: p, color: color, size: strokeSize)
        a.style = style
        switch kind {
        case .counter:
            a.number = doc.nextCounterNumber
            doc.state.annotations.append(a)
            selectedID = a.id
            drag = .moving(a.id, last: p)
            dragCheckpointed = true
            return
        case .text:
            a.p1 = CGPoint(x: p.x, y: p.y - a.fontSize * 0.6)
            doc.state.annotations.append(a)
            selectedID = a.id
            beginTextEditing(a.id)
            drag = .none
            return
        case .freehand:
            a.points = [p]
        default: break
        }
        doc.state.annotations.append(a)
        selectedID = a.id
        drag = .creating(a.id)
    }

    override func mouseDragged(with event: NSEvent) {
        let raw = convert(event.locationInWindow, from: nil)
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case .none:
            return
        case .creating(let id):
            doc.update(id) { a in
                if a.kind == .freehand {
                    if let last = a.points.last, hypot(last.x - raw.x, last.y - raw.y) < 0.75 / magnification { return }
                    a.points.append(raw)
                    a.p2 = raw
                } else {
                    a.p2 = shift ? constrained(from: a.p1, to: raw, kind: a.kind) : raw
                }
            }
        case .moving(let id, let last):
            if !dragCheckpointed { doc.checkpoint(); dragCheckpointed = true }
            doc.update(id) { $0.offset(by: CGVector(dx: raw.x - last.x, dy: raw.y - last.y)) }
            drag = .moving(id, last: raw)
        case .handle(let id, let index):
            if !dragCheckpointed { doc.checkpoint(); dragCheckpointed = true }
            doc.update(id) { a in
                switch a.kind {
                case .arrow, .line:
                    if index == 0 { a.p1 = shift ? constrained(from: a.p2, to: raw, kind: a.kind) : raw }
                    else { a.p2 = shift ? constrained(from: a.p1, to: raw, kind: a.kind) : raw }
                default:
                    let corners = rectCorners(a.rect)
                    a.p1 = corners[(index + 2) % 4]
                    a.p2 = shift ? constrained(from: a.p1, to: raw, kind: a.kind) : raw
                }
            }
            if let a = doc.annotation(id), a.isRectLike {
                // Re-map handle index after the rect may have flipped.
                let corners = rectCorners(a.rect)
                if let ni = corners.firstIndex(where: { hypot($0.x - a.p2.x, $0.y - a.p2.y) < 0.01 }) {
                    drag = .handle(id, index: ni)
                }
            }
        case .cropNew(let start):
            let p = clamp(raw)
            var r = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            if shift { let s = max(r.width, r.height); r.size = CGSize(width: s, height: s) }
            cropRect = snapToPixels(r.intersection(bounds))
        case .cropMove(let origin, let start):
            var r = origin.offsetBy(dx: raw.x - start.x, dy: raw.y - start.y)
            r.origin.x = min(max(0, r.origin.x), bounds.width - r.width)
            r.origin.y = min(max(0, r.origin.y), bounds.height - r.height)
            cropRect = snapToPixels(r)
        }
        onHover?(raw, colorAt(raw))
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = .none }
        if case .creating(let id) = drag, let a = doc.annotation(id) {
            let tiny: Bool
            switch a.kind {
            case .freehand: tiny = a.points.count < 2
            case .arrow, .line: tiny = hypot(a.p2.x - a.p1.x, a.p2.y - a.p1.y) < 3
            default: tiny = a.rect.width < 3 || a.rect.height < 3
            }
            if tiny {
                selectedID = nil
                doc.discardCheckpoint()
            }
        }
        if case .cropNew = drag, let c = cropRect, c.width < 2 || c.height < 2 { cropRect = nil }
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    private func snapToPixels(_ r: CGRect) -> CGRect {
        let s = doc.scale
        let x0 = (r.minX * s).rounded() / s, y0 = (r.minY * s).rounded() / s
        let x1 = (r.maxX * s).rounded() / s, y1 = (r.maxY * s).rounded() / s
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Shift-constraint: 45° steps for lines/arrows, squares for rect-like shapes.
    private func constrained(from a: CGPoint, to b: CGPoint, kind: Annotation.Kind) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        switch kind {
        case .arrow, .line:
            let angle = atan2(dy, dx)
            let step = CGFloat.pi / 4
            let snapped = (angle / step).rounded() * step
            let len = hypot(dx, dy)
            return CGPoint(x: a.x + cos(snapped) * len, y: a.y + sin(snapped) * len)
        default:
            let s = max(abs(dx), abs(dy))
            return CGPoint(x: a.x + (dx < 0 ? -s : s), y: a.y + (dy < 0 ? -s : s))
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 51, 117:  // delete / forward delete
            if let id = selectedID {
                doc.checkpoint()
                doc.remove(id)
                selectedID = nil
                return
            }
        case 123, 124, 125, 126:  // arrows: nudge selection by one pixel (10 with shift)
            if let id = selectedID {
                let step = (flags.contains(.shift) ? 10 : 1) / doc.scale
                let d: CGVector
                switch event.keyCode {
                case 123: d = CGVector(dx: -step, dy: 0)
                case 124: d = CGVector(dx: step, dy: 0)
                case 125: d = CGVector(dx: 0, dy: step)
                default: d = CGVector(dx: 0, dy: -step)
                }
                doc.checkpoint()
                doc.update(id) { $0.offset(by: d) }
                return
            }
        case 36, 76:  // return
            if let c = cropRect {
                applyCrop(c)
                return
            }
            if let a = doc.annotation(selectedID), a.kind == .text {
                beginTextEditing(a.id)
                return
            }
        case 53:  // esc
            if cropRect != nil { cropRect = nil; return }
            if selectedID != nil { selectedID = nil; return }
        default: break
        }
        super.keyDown(with: event)
    }

    func applyCrop(_ rect: CGRect? = nil) {
        guard let c = rect ?? cropRect else { return }
        cropRect = nil
        doc.crop(to: c)
        tool = .arrow
    }

    func deselect() { selectedID = nil }

    /// Applies style changes from the toolbar to the selected annotation.
    func applyToSelection(color: NSColor? = nil, size: CGFloat? = nil, style: Int? = nil) {
        guard let id = selectedID, doc.annotation(id) != nil else { return }
        doc.checkpoint()
        doc.update(id) { a in
            if let color { a.color = color }
            if let size { a.size = size }
            if let style, !(a.kind.toolForStyle?.styleOptions.isEmpty ?? true) { a.style = style }
        }
    }

    // MARK: - Text editing

    private func beginTextEditing(_ id: UUID) {
        guard let a = doc.annotation(id) else { return }
        commitTextEditing()
        editingTextID = id
        let tf = NSTextField(string: a.text)
        tf.isBordered = false
        tf.drawsBackground = a.style == 1
        tf.backgroundColor = a.color
        tf.focusRingType = .none
        tf.font = NSFont.systemFont(ofSize: a.fontSize, weight: .semibold)
        tf.textColor = a.style == 1 ? a.color.contrastingTextColor : a.color
        tf.cell?.isScrollable = false
        tf.cell?.wraps = false
        tf.target = self
        tf.action = #selector(textFieldAction(_:))
        tf.delegate = self
        textField = tf
        layoutTextField()
        addSubview(tf)
        window?.makeFirstResponder(tf)
        needsDisplay = true
    }

    private func layoutTextField() {
        guard let tf = textField, let a = doc.annotation(editingTextID) else { return }
        tf.font = NSFont.systemFont(ofSize: a.fontSize, weight: .semibold)
        let size = ((tf.stringValue.isEmpty ? "Text" : tf.stringValue) as NSString).size(withAttributes: [.font: tf.font!])
        tf.frame = CGRect(x: a.p1.x - 2, y: a.p1.y, width: size.width + a.fontSize, height: size.height + 2)
    }

    @objc private func textFieldAction(_ sender: NSTextField) { commitTextEditing() }

    func commitTextEditing() {
        guard let tf = textField, let id = editingTextID else { return }
        let text = tf.stringValue
        textField = nil
        editingTextID = nil
        tf.removeFromSuperview()
        if let a = doc.annotation(id), a.text != text {
            if text.isEmpty {
                // Clearing an existing label deletes it (undoable).
                doc.checkpoint()
                doc.remove(id)
                selectedID = nil
            } else {
                if !a.text.isEmpty { doc.checkpoint() }
                doc.update(id) { $0.text = text }
            }
        } else if let a = doc.annotation(id), a.text.isEmpty {
            doc.remove(id)
            doc.discardCheckpoint()
            selectedID = nil
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
}

extension CanvasView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { layoutTextField() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            commitTextEditing()
            return true
        }
        return false
    }
}

extension Annotation.Kind {
    var toolForStyle: Tool? {
        switch self {
        case .rectangle: return .rectangle
        case .oval: return .oval
        case .text: return .text
        case .blur: return .blur
        default: return nil
        }
    }
}
