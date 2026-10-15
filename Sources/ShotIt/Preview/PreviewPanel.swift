import AppKit

/// Floating thumbnail shown after a capture.
/// Hover reveals Copy / Save / Edit / Pin / OCR; click opens the editor; drag drops the file elsewhere.
final class PreviewPanel: NSPanel {
    private(set) static var current: PreviewPanel?

    private let shot: Screenshot
    private var hideTimer: Timer?
    private var hovering = false
    private let buttons = NSStackView()
    private let closeButton: NSButton
    private var trackingView: HoverView!

    static func show(_ shot: Screenshot) {
        current?.dismiss(animated: false)
        let p = PreviewPanel(shot: shot)
        current = p
        p.present()
    }

    static func dismissCurrent() { current?.dismiss(animated: true) }

    private init(shot: Screenshot) {
        self.shot = shot
        let thumb = shot.pointSize.fitting(in: CGSize(width: 280, height: 200))
        let size = CGSize(width: max(thumb.width, 200) + 16, height: max(thumb.height, 110) + 16)
        closeButton = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")!,
                               target: nil, action: nil)
        super.init(contentRect: CGRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        markTransient()
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false

        let root = HoverView(frame: CGRect(origin: .zero, size: size))
        root.onHover = { [weak self] inside in self?.setHover(inside) }
        trackingView = root

        let effect = NSVisualEffectView(frame: root.bounds)
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        root.addSubview(effect)

        // Thumbnail: click = edit, drag = drop file into other apps.
        let image = DragOutButton(image: shot.nsImage, target: nil, action: nil)
        image.isBordered = false
        image.imageScaling = .scaleProportionallyDown
        image.frame = CGRect(x: 8, y: 8, width: size.width - 16, height: size.height - 16)
        image.autoresizingMask = [.width, .height]
        image.toolTip = "Click to edit, drag to drop into another app"
        image.fileProvider = { [shot] in
            shot.fileURL ?? Exporter.temporaryFile(shot.image, scale: shot.scale, date: shot.date)
        }
        image.dragImage = { [shot] in shot.nsImage }
        root.addSubview(image)

        buttons.orientation = .horizontal
        buttons.spacing = 4
        buttons.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        buttons.wantsLayer = true
        buttons.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        buttons.layer?.cornerRadius = 8
        buttons.alphaValue = 0
        root.addSubview(buttons)

        super.contentView = root
        image.target = self
        image.action = #selector(edit)

        for (symbol, tip, sel) in [("doc.on.doc", "Copy", #selector(copyImage)),
                                   ("square.and.arrow.down", "Save", #selector(save)),
                                   ("pencil.tip.crop.circle", "Edit", #selector(edit)),
                                   ("pin", "Pin", #selector(pin)),
                                   ("text.viewfinder", "Recognize Text/QR", #selector(ocr))] {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: sel)
            b.isBordered = false
            b.contentTintColor = .white
            b.toolTip = tip
            b.symbolConfiguration = .init(pointSize: 14, weight: .medium)
            b.widthAnchor.constraint(equalToConstant: 26).isActive = true
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
            buttons.addArrangedSubview(b)
        }
        buttons.layoutSubtreeIfNeeded()
        let bs = buttons.fittingSize
        buttons.frame = CGRect(x: (size.width - bs.width) / 2, y: 12, width: bs.width, height: bs.height)
        buttons.autoresizingMask = [.minXMargin, .maxXMargin]

        closeButton.isBordered = false
        closeButton.contentTintColor = .white
        closeButton.symbolConfiguration = .init(pointSize: 16, weight: .semibold)
        closeButton.frame = CGRect(x: 6, y: size.height - 28, width: 22, height: 22)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.alphaValue = 0
        root.addSubview(closeButton)
    }

    override var canBecomeKey: Bool { false }

    /// Frame for a panel of `size` placed beside the pointer (below-right by default), kept inside `visible`.
    static func frame(near mouse: CGPoint, size: CGSize, in visible: CGRect, gap: CGFloat = 20) -> CGRect {
        var x = mouse.x + gap
        var y = mouse.y - size.height - gap
        if x + size.width > visible.maxX - 8 { x = mouse.x - size.width - gap }   // no room on the right: flip left
        if y < visible.minY + 8 { y = mouse.y + gap }                              // no room below: flip above
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private func present() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        // Appear right next to the pointer, where the user is already looking.
        let target = PreviewPanel.frame(near: mouse, size: frame.size, in: vf)
        let start = target.offsetBy(dx: 0, dy: -14)
        setFrame(start, display: false)
        alphaValue = 0
        orderFrontRegardless()
        // Rise and fade in. Driven by our own timer so it always lands exactly on the target.
        animate(duration: 0.18, update: { [weak self] t in
            let e = 1 - pow(1 - t, 3)
            self?.setFrame(CGRect(x: target.minX, y: start.minY + (target.minY - start.minY) * e,
                                  width: target.width, height: target.height), display: true)
            self?.alphaValue = e
        })
        scheduleHide()
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        let seconds = AppSettings.shared.previewSeconds
        guard seconds > 0 else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self, !self.hovering else { return }
            self.dismiss(animated: true)
        }
    }

    private func setHover(_ inside: Bool) {
        hovering = inside
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            buttons.animator().alphaValue = inside ? 1 : 0
            closeButton.animator().alphaValue = inside ? 1 : 0
        }
        if !inside { scheduleHide() }
    }

    func dismiss(animated: Bool) {
        hideTimer?.invalidate()
        if PreviewPanel.current === self { PreviewPanel.current = nil }
        guard animated else { orderOut(nil); return }
        animate(duration: 0.2, update: { [weak self] t in self?.alphaValue = 1 - t },
                completion: { [weak self] in self?.orderOut(nil) })
    }

    /// Runs `update` with progress 0→1 over `duration` seconds and always finishes with exactly 1.
    private func animate(duration: TimeInterval, update: @escaping (CGFloat) -> Void, completion: (() -> Void)? = nil) {
        let began = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
            let t = min(1, CGFloat(Date().timeIntervalSince(began) / duration))
            update(t)
            if t >= 1 { timer.invalidate(); completion?() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func closeClicked() { dismiss(animated: true) }

    @objc private func copyImage() {
        Exporter.copy(shot.image, scale: shot.scale)
        Toast.show("Copied to the clipboard")
        dismiss(animated: true)
    }

    @objc private func save() {
        do {
            let url = try Exporter.save(shot.image, scale: shot.scale, date: shot.date)
            shot.fileURL = url
            Toast.show("Saved \(url.lastPathComponent)")
        } catch {
            Toast.show(error.localizedDescription, style: .error)
        }
        dismiss(animated: true)
    }

    @objc private func edit() {
        dismiss(animated: false)
        EditorWindowController.open(shot)
    }

    @objc private func pin() {
        dismiss(animated: false)
        PinWindowController.pin(shot)
    }

    @objc private func ocr() {
        TextRecognizer.recognizeAndCopy(shot.image)
    }
}

/// Reports mouse enter/exit for its whole bounds.
final class HoverView: NSView {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
