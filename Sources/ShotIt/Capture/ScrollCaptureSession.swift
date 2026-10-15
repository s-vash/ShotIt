import AppKit
import ApplicationServices

/// Drives one scrolling capture: grabs the selected region repeatedly, optionally scrolling it by
/// synthesizing wheel events (needs Accessibility permission), and feeds each frame to `ScrollStitcher`.
@MainActor
final class ScrollCaptureSession {
    enum Mode { case auto, manual }

    /// Called once with the stitched screenshot, or nil if cancelled / nothing was captured.
    var onFinish: ((Screenshot?) -> Void)?

    private let rect: CGRect  // selected region, global AppKit coordinates
    private let screen: NSScreen
    private let scale: CGFloat
    private let direction: ScrollStitcher.Direction
    private let mode: Mode
    private let stitcher: ScrollStitcher
    private let hud: ScrollHUD
    private let startMouse = NSEvent.mouseLocation

    private var task: Task<Void, Never>?
    private var monitors: [Any] = []
    private var finished = false
    private var keepResult = true

    init(rect: CGRect, screen: NSScreen, scale: CGFloat, direction: ScrollStitcher.Direction, mode: Mode) {
        self.rect = rect
        self.screen = screen
        self.scale = scale
        self.direction = direction
        self.mode = mode
        let stepPx = Int((rect.height * CGFloat(AppSettings.shared.scrollingStep) * scale).rounded())
        stitcher = ScrollStitcher(direction: direction, hint: mode == .auto ? stepPx : nil)
        hud = ScrollHUD(region: rect, auto: mode == .auto)
    }

    func start() {
        hud.onDone = { [weak self] in self?.stop(keep: true) }
        hud.onCancel = { [weak self] in self?.stop(keep: false) }
        hud.show()
        // Esc / Return finish; the global monitor only fires with the right permissions, the HUD buttons always work.
        let handler: (NSEvent) -> Void = { [weak self] e in
            if e.keyCode == 53 || e.keyCode == 36 { Task { @MainActor in self?.stop(keep: true) } }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in handler(e); return e }) { monitors.append(m) }
        task = Task { await run() }
    }

    /// Ends the capture early (used when the hotkey is pressed again).
    func stop(keep: Bool) {
        keepResult = keep
        task?.cancel()
        finish()
    }

    // MARK: - Loop

    private func run() async {
        do {
            var step = max(40, Int(rect.height * CGFloat(AppSettings.shared.scrollingStep)))
            stitcher.add(try await grab())
            var idle = 0, misses = 0
            while !Task.isCancelled {
                if mode == .auto {
                    postScroll(points: step)
                    try await Task.sleep(nanoseconds: 300_000_000)
                } else {
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
                let frame = mode == .auto ? try await grabSettled() : try await grab()
                switch stitcher.add(frame) {
                case .added:
                    idle = 0; misses = 0
                    hud.update(pixels: stitcher.totalHeight)
                    if stitcher.totalHeight >= AppSettings.shared.scrollingMaxHeight {
                        Toast.show("Max height reached — you can change the limit in Settings › Advanced", style: .error, duration: 4)
                        finish()
                        return
                    }
                case .identical:
                    idle += 1
                    if mode == .auto && idle >= 2 {
                        if stitcher.frameCount <= 1 { Toast.show("ShotIt wasn't able to scroll. Try Manual Scrolling Capture, or Settings › Advanced › reverse direction.", style: .error, duration: 5) }
                        finish()  // reached the end
                        return
                    }
                case .noMatch:
                    misses += 1
                    if mode == .auto {
                        step = max(40, step / 2)  // overshot: scroll less next time
                        if misses >= 3 { Toast.show("The frames stopped overlapping, so capturing ended here", style: .error, duration: 4); finish(); return }
                    } else if misses % 4 == 1 {
                        hud.warn("You're going too fast — scroll slower")
                    }
                }
            }
        } catch is CancellationError {
            // stopped by the user
        } catch {
            Toast.show("Capturing error: \(error.localizedDescription)", style: .error, duration: 4)
        }
        finish()
    }

    private func grab() async throws -> CGImage {
        let frame = try await ScreenCapturer.captureFrame(of: screen)
        guard let image = frame.crop(rect) else { throw CaptureError.emptySelection }
        return image
    }

    /// Waits for scroll momentum to stop: returns the first frame equal to its predecessor.
    private func grabSettled() async throws -> CGImage {
        var previous = try await grab()
        for _ in 0..<8 {
            try await Task.sleep(nanoseconds: 120_000_000)
            let current = try await grab()
            if ScrollStitcher.looksIdentical(previous, current) { return current }
            previous = current
        }
        return previous
    }

    // MARK: - Scrolling

    /// Scrolls the content under the region's centre. Wheel events are posted at the HID level,
    /// which requires Accessibility permission.
    private func postScroll(points: Int) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let center = CGPoint(x: rect.midX, y: primaryHeight - rect.midY)  // global CG coordinates (top-left origin)
        CGWarpMouseCursorPosition(center)
        // Positive wheel values scroll the content down (towards the top of the document).
        var sign: Int32 = direction == .down ? -1 : 1
        if AppSettings.shared.scrollingReverse { sign = -sign }
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: sign * Int32(points), wheel2: 0, wheel3: 0) else { return }
        event.location = center
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Finish

    private func finish() {
        guard !finished else { return }
        finished = true
        task?.cancel()
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        hud.hide()
        if mode == .auto {  // put the pointer back where the user left it
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            CGWarpMouseCursorPosition(CGPoint(x: startMouse.x, y: primaryHeight - startMouse.y))
        }
        var result: Screenshot?
        if keepResult, stitcher.frameCount >= 1, let image = stitcher.finish() {
            result = Screenshot(image: image, scale: scale)
        }
        onFinish?(result)
    }
}

/// Small floating control shown next to the region while a scrolling capture runs.
@MainActor
final class ScrollHUD {
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?

    private let panel: NSPanel
    private let outline: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let region: CGRect
    private let auto: Bool

    init(region: CGRect, auto: Bool) {
        self.region = region
        self.auto = auto
        let size = CGSize(width: 330, height: 40)
        panel = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        outline = NSPanel(contentRect: region.insetBy(dx: -4, dy: -4), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        build(size: size)
    }

    private func build(size: CGSize) {
        for p in [panel, outline] {
            p.markTransient()
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false
        }
        outline.ignoresMouseEvents = true
        let box = OutlineView(frame: CGRect(origin: .zero, size: outline.frame.size))
        outline.contentView = box

        let effect = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.stringValue = auto ? "Scrolling… Esc to finish" : "Scroll the content yourself · Esc to finish"
        let done = NSButton(title: "Done", target: self, action: #selector(doneTapped))
        done.bezelStyle = .rounded; done.controlSize = .small; done.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded; cancel.controlSize = .small
        let stack = NSStackView(views: [label, cancel, done])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 8)
        stack.frame = effect.bounds
        stack.autoresizingMask = [.width, .height]
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        effect.addSubview(stack)
        panel.contentView = effect

        // Below the region if there is room, otherwise above, otherwise inside at the bottom.
        let vf = (NSScreen.screens.first { $0.frame.intersects(region) } ?? NSScreen.main)?.visibleFrame ?? region
        var origin = CGPoint(x: region.midX - size.width / 2, y: region.minY - size.height - 10)
        if origin.y < vf.minY + 4 { origin.y = region.maxY + 10 }
        if origin.y + size.height > vf.maxY - 4 { origin.y = region.minY + 10 }
        origin.x = min(max(origin.x, vf.minX + 4), vf.maxX - size.width - 4)
        panel.setFrameOrigin(origin)
    }

    func show() {
        outline.orderFrontRegardless()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        outline.orderOut(nil)
    }

    func update(pixels: Int) {
        label.stringValue = "\(pixels) px captured · Esc to finish"
    }

    func warn(_ message: String) { label.stringValue = message }

    @objc private func doneTapped() { onDone?() }
    @objc private func cancelTapped() { onCancel?() }

    private final class OutlineView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.controlAccentColor.setStroke()
            let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 3, yRadius: 3)
            p.lineWidth = 2
            p.setLineDash([6, 4], count: 2, phase: 0)
            p.stroke()
        }
    }
}
