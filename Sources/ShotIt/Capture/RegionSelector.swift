import AppKit
import QuartzCore

enum SelectionMode {
    /// Drag a rectangle.
    case area
    /// Hover highlights windows; click picks one, drag still selects an area.
    case window
}

enum SelectionResult {
    case area(CGRect, ScreenFrame)
    case window(WindowInfo)
    case cancelled
}

/// Full-screen overlay shown on top of a frozen capture of every display.
/// Crosshair guides, dimmed surroundings and a live pixel-size readout.
@MainActor
final class RegionSelector {
    private var windows: [OverlayWindow] = []
    private var completion: ((SelectionResult) -> Void)?
    private var finished = false
    private static var current: RegionSelector?

    /// `allowWindowToggle`: Space switches between dragging an area and picking a window (like ⌘⇧4 + Space).
    static func begin(frames: [ScreenFrame], mode: SelectionMode, hint: String? = nil, allowWindowToggle: Bool = false,
                      completion: @escaping (SelectionResult) -> Void) {
        current?.finish(.cancelled)
        let selector = RegionSelector()
        current = selector
        selector.completion = completion
        selector.currentMode = mode
        let windowList = (mode == .window || allowWindowToggle) ? ScreenCapturer.onScreenWindows() : []
        for frame in frames {
            let win = OverlayWindow(frame: frame, mode: mode, windows: windowList, hint: hint, allowWindowToggle: allowWindowToggle)
            win.onFinish = { [weak selector] result in selector?.finish(result) }
            win.onToggleMode = { [weak selector] in selector?.toggleMode() }
            selector.windows.append(win)
        }
        NSApp.activate(ignoringOtherApps: true)
        for win in selector.windows { win.orderFrontRegardless() }
        // Key window = the screen under the mouse so Esc works immediately.
        let mouse = NSEvent.mouseLocation
        (selector.windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? selector.windows.first)?.makeKey()
        NSCursor.crosshair.push()
    }

    private var currentMode: SelectionMode = .area

    /// Space: flip every display's overlay between area selection and window picking.
    private func toggleMode() {
        currentMode = currentMode == .area ? .window : .area
        for w in windows { w.setMode(currentMode) }
    }

    private func finish(_ result: SelectionResult) {
        guard !finished else { return }
        finished = true
        NSCursor.pop()
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        RegionSelector.current = nil
        // Let the overlay disappear from screen before anything re-captures.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [completion] in completion?(result) }
    }
}

private final class OverlayWindow: NSWindow {
    var onFinish: ((SelectionResult) -> Void)?
    var onToggleMode: (() -> Void)? { didSet { (contentView as? OverlayView)?.onToggleMode = onToggleMode } }
    private let view: OverlayView

    func setMode(_ mode: SelectionMode) { view.setMode(mode) }

    init(frame: ScreenFrame, mode: SelectionMode, windows: [WindowInfo], hint: String?, allowWindowToggle: Bool) {
        view = OverlayView(frame: CGRect(origin: .zero, size: frame.frame.size),
                           screenFrame: frame, mode: mode, windows: windows, hint: hint, allowWindowToggle: allowWindowToggle)
        super.init(contentRect: frame.frame, styleMask: .borderless, backing: .buffered, defer: false)
        markTransient()
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        view.onFinish = { [weak self] r in self?.onFinish?(r) }
        contentView = view
        setFrame(frame.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class OverlayView: NSView {
    var onFinish: ((SelectionResult) -> Void)?
    var onToggleMode: (() -> Void)?

    private let screenFrame: ScreenFrame
    private var mode: SelectionMode
    private let windows: [WindowInfo]
    private let baseHint: String?
    private let allowWindowToggle: Bool

    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let guideLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let labelLayer = CATextLayer()
    private let hintLayer = CATextLayer()

    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var hovered: WindowInfo?
    private var trackingArea: NSTrackingArea?

    init(frame: CGRect, screenFrame: ScreenFrame, mode: SelectionMode, windows: [WindowInfo], hint: String?, allowWindowToggle: Bool) {
        self.screenFrame = screenFrame
        self.mode = mode
        self.windows = windows
        self.baseHint = hint
        self.allowWindowToggle = allowWindowToggle
        super.init(frame: frame)
        wantsLayer = true
        let scale = screenFrame.scale

        imageLayer.frame = bounds
        imageLayer.contents = screenFrame.image
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .nearest

        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.35).cgColor

        guideLayer.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        guideLayer.lineWidth = 1
        guideLayer.lineDashPattern = [4, 4]
        guideLayer.shadowColor = NSColor.black.cgColor
        guideLayer.shadowOpacity = 0.6
        guideLayer.shadowRadius = 0.5
        guideLayer.shadowOffset = .zero

        borderLayer.strokeColor = NSColor.white.cgColor
        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.lineWidth = 1

        for l in [labelLayer, hintLayer] {
            l.contentsScale = scale
            l.fontSize = 12
            l.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            l.foregroundColor = NSColor.white.cgColor
            l.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
            l.cornerRadius = 5
            l.alignmentMode = .center
            l.isHidden = true
        }

        for l in [imageLayer, dimLayer, guideLayer, borderLayer, labelLayer, hintLayer] { layer?.addSublayer(l) }

        showHint(hint)
        updateLayers(mouse: nil)
    }

    private func showHint(_ hint: String?) {
        guard let hint else { hintLayer.isHidden = true; return }
        hintLayer.string = hint
        let w = (hint as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width + 24
        hintLayer.frame = CGRect(x: (bounds.width - w) / 2, y: bounds.height - 80, width: w, height: 22)
        hintLayer.isHidden = false
    }

    /// Switches between area selection and window picking (Space).
    func setMode(_ newMode: SelectionMode) {
        mode = newMode
        dragStart = nil
        selection = nil
        let mouse = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
        hovered = (newMode == .window) ? mouse.flatMap { windowAt($0) } : nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        showHint(newMode == .window && baseHint == nil ? "Click a window · Space for area · Esc to cancel" : baseHint)
        CATransaction.commit()
        updateLayers(mouse: mouse)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if mode == .window { hovered = windowAt(p) }
        updateLayers(mouse: p)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        dragStart = clamp(convert(event.locationInWindow, from: nil))
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let p = clamp(convert(event.locationInWindow, from: nil))
        var r = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        if event.modifierFlags.contains(.shift) {
            let side = max(r.width, r.height)
            r.size = CGSize(width: side, height: side)
            if p.x < start.x { r.origin.x = start.x - side }
            if p.y < start.y { r.origin.y = start.y - side }
        }
        selection = pixelAligned(r)
        hovered = nil
        updateLayers(mouse: p)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        if let sel = selection, sel.width >= 2, sel.height >= 2 {
            let global = sel.offsetBy(dx: screenFrame.frame.minX, dy: screenFrame.frame.minY)
            onFinish?(.area(global, screenFrame))
            return
        }
        if mode == .window {
            let p = convert(event.locationInWindow, from: nil)
            if let w = windowAt(p) { onFinish?(.window(w)) ; return }
        }
        selection = nil
        updateLayers(mouse: convert(event.locationInWindow, from: nil))
    }

    override func rightMouseDown(with event: NSEvent) { onFinish?(.cancelled) }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onFinish?(.cancelled)  // Esc
        case 49 where allowWindowToggle && dragStart == nil:  // Space: area ⇄ window
            onToggleMode?()
        case 36, 76:  // Return: capture the full screen
            onFinish?(.area(screenFrame.frame, screenFrame))
        default: super.keyDown(with: event)
        }
    }

    // MARK: - Helpers

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    /// Snap a rect to whole device pixels.
    private func pixelAligned(_ r: CGRect) -> CGRect {
        let s = screenFrame.scale
        let x0 = (r.minX * s).rounded() / s, y0 = (r.minY * s).rounded() / s
        let x1 = (r.maxX * s).rounded() / s, y1 = (r.maxY * s).rounded() / s
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    private func windowAt(_ local: CGPoint) -> WindowInfo? {
        let g = CGPoint(x: local.x + screenFrame.frame.minX, y: local.y + screenFrame.frame.minY)
        return windows.first { $0.frame.contains(g) }
    }

    private func localRect(_ global: CGRect) -> CGRect {
        global.offsetBy(dx: -screenFrame.frame.minX, dy: -screenFrame.frame.minY)
    }

    private func updateLayers(mouse: CGPoint?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let full = CGPath(rect: bounds, transform: nil)
        let hole: CGRect? = selection ?? hovered.map { localRect($0.frame).intersection(bounds) }
        let dim = CGMutablePath()
        dim.addPath(full)
        if let hole { dim.addRect(hole) }
        dimLayer.path = dim
        dimLayer.fillColor = (hole == nil && mode == .area)
            ? NSColor.black.withAlphaComponent(0.12).cgColor
            : NSColor.black.withAlphaComponent(0.35).cgColor

        if let hole {
            borderLayer.path = CGPath(rect: hole.insetBy(dx: -0.5, dy: -0.5), transform: nil)
            borderLayer.strokeColor = (selection == nil ? NSColor.controlAccentColor : NSColor.white).cgColor
            borderLayer.lineWidth = selection == nil ? 3 : 1
        } else {
            borderLayer.path = nil
        }

        // Crosshair guides across the whole screen.
        if let m = mouse, dragStart == nil || selection == nil {
            let g = CGMutablePath()
            let x = floor(m.x) + 0.5, y = floor(m.y) + 0.5
            g.move(to: CGPoint(x: x, y: 0)); g.addLine(to: CGPoint(x: x, y: bounds.height))
            g.move(to: CGPoint(x: 0, y: y)); g.addLine(to: CGPoint(x: bounds.width, y: y))
            guideLayer.path = g
        } else {
            guideLayer.path = nil
        }

        // Size readout in pixels next to the cursor / selection.
        let s = screenFrame.scale
        var text: String?
        if let sel = selection {
            text = "\(Int((sel.width * s).rounded())) × \(Int((sel.height * s).rounded()))"
        } else if let w = hovered {
            text = w.owner.isEmpty ? "Window" : w.owner
        } else if let m = mouse {
            text = "\(Int((m.x * s).rounded())), \(Int(((bounds.height - m.y) * s).rounded()))"
        }
        if let text, let anchor = selection.map({ CGPoint(x: $0.maxX, y: $0.minY) }) ?? mouse {
            labelLayer.string = text
            let w = (text as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)]).width + 16
            var origin = CGPoint(x: anchor.x + 10, y: anchor.y - 30)
            if origin.x + w > bounds.width { origin.x = anchor.x - w - 10 }
            if origin.y < 4 { origin.y = anchor.y + 12 }
            labelLayer.frame = CGRect(x: origin.x, y: origin.y, width: w, height: 20)
            labelLayer.isHidden = false
        } else {
            labelLayer.isHidden = true
        }
    }
}
