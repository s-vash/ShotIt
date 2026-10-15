import AppKit
import SwiftUI

/// Annotation editor window.
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private(set) static var open: [EditorWindowController] = []

    let doc: EditorDocument
    private let canvas: CanvasView
    private var container: BackdropContainerView!
    private var backdropPopover: NSPopover?
    private var backdropButton: NSButton!
    private let scrollView = NSScrollView()

    private var toolControl: NSSegmentedControl!
    private var styleControl: NSSegmentedControl!
    private let colorWell = NSColorWell(style: .minimal)
    private let sizeSlider = NSSlider(value: 4, minValue: 1, maxValue: 20, target: nil, action: nil)
    private var undoButton: NSButton!
    private var redoButton: NSButton!
    private let zoomLabel = NSButton(title: "100%", target: nil, action: nil)
    private let sizeLabel = NSTextField(labelWithString: "")
    private let colorSwatch = NSView()
    private let colorLabel = NSButton(title: "", target: nil, action: nil)
    private let hintLabel = NSTextField(labelWithString: "")
    private var hoverColor: NSColor?
    private var magnificationObserver: NSObjectProtocol?

    static let palette: [NSColor] = [
        NSColor(hex: "#E5383B")!, NSColor(hex: "#FFC200")!, NSColor(hex: "#2DBE60")!,
        NSColor(hex: "#1E88E5")!, NSColor(hex: "#9C27B0")!, NSColor(hex: "#111111")!, NSColor(hex: "#FFFFFF")!,
    ]

    // MARK: - Opening

    @discardableResult
    static func open(_ shot: Screenshot) -> EditorWindowController {
        let wc = EditorWindowController(screenshot: shot)
        open.append(wc)
        // Show a Dock icon and menu bar while an editor is open, like a regular app.
        NSApp.setActivationPolicy(.regular)
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        wc.window?.makeKeyAndOrderFront(nil)
        wc.window?.makeFirstResponder(wc.canvas)
        return wc
    }

    init(screenshot: Screenshot) {
        doc = EditorDocument(screenshot: screenshot)
        canvas = CanvasView(doc: doc)
        let window = EditorWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 820, height: 420)
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        buildUI()
        restoreToolDefaults()
        doc.onChange = { [weak self] in self?.documentChanged() }
        documentChanged()
        sizeWindowToFit()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI

    private func buildUI() {
        guard let window, let content = window.contentView else { return }

        // Tools
        toolControl = NSSegmentedControl(images: Tool.allCases.map {
            NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.title) ?? NSImage()
        }, trackingMode: .selectOne, target: self, action: #selector(toolChanged(_:)))
        for (i, t) in Tool.allCases.enumerated() {
            toolControl.setToolTip("\(t.title) (\(t.key.uppercased()))", forSegment: i)
            toolControl.setWidth(30, forSegment: i)
        }
        toolControl.segmentStyle = .texturedRounded

        styleControl = NSSegmentedControl(labels: ["Outline", "Filled"], trackingMode: .selectOne,
                                          target: self, action: #selector(styleChanged(_:)))
        styleControl.segmentStyle = .texturedRounded
        styleControl.controlSize = .small

        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        colorWell.toolTip = "Color"
        colorWell.widthAnchor.constraint(equalToConstant: 38).isActive = true

        let swatches = NSStackView(views: Self.palette.enumerated().map { i, c in
            let b = NSButton(title: "", target: self, action: #selector(swatchClicked(_:)))
            b.tag = i
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.backgroundColor = c.cgColor
            b.layer?.cornerRadius = 7
            b.layer?.borderWidth = 1
            b.layer?.borderColor = NSColor.separatorColor.cgColor
            b.toolTip = c.hexString
            b.widthAnchor.constraint(equalToConstant: 14).isActive = true
            b.heightAnchor.constraint(equalToConstant: 14).isActive = true
            return b
        })
        swatches.spacing = 4

        sizeSlider.target = self
        sizeSlider.action = #selector(sizeChanged(_:))
        sizeSlider.controlSize = .small
        sizeSlider.toolTip = "Size ([ and ])"
        sizeSlider.widthAnchor.constraint(equalToConstant: 90).isActive = true

        undoButton = symbolButton("arrow.uturn.backward", tooltip: "Undo (⌘Z)", target: self, action: #selector(undo(_:)))
        redoButton = symbolButton("arrow.uturn.forward", tooltip: "Redo (⇧⌘Z)", target: self, action: #selector(redo(_:)))
        let ocr = symbolButton("text.viewfinder", tooltip: "Recognize Text/QR — whole image or crop selection (⌘T)", target: self, action: #selector(recognizeText(_:)))
        let pin = symbolButton("pin", tooltip: "Pin to Screen (⌘P)", target: self, action: #selector(pin(_:)))
        let drag = DragOutButton(image: NSImage(systemSymbolName: "hand.draw", accessibilityDescription: "Drag out")!,
                                 target: nil, action: nil)
        drag.bezelStyle = .texturedRounded
        drag.toolTip = "Drag into another app"
        drag.fileProvider = { [weak self] in
            guard let self else { return nil }
            return Exporter.temporaryFile(self.doc.exported(), scale: self.doc.scale, date: self.doc.date)
        }
        drag.dragImage = { [weak self] in
            guard let self else { return nil }
            let img = self.doc.exported()
            return NSImage(cgImage: img, size: CGSize(width: CGFloat(img.width) / self.doc.scale, height: CGFloat(img.height) / self.doc.scale))
        }
        let copy = symbolButton("doc.on.doc", tooltip: "Copy (⌘C)", target: self, action: #selector(copy(_:)))
        let save = symbolButton("square.and.arrow.down", tooltip: "Save (⌘S) — ⇧⌘S Save As", target: self, action: #selector(save(_:)))

        backdropButton = symbolButton("photo.artframe", tooltip: "Backdrop — background, padding and shadow (K)", target: self, action: #selector(toggleBackdropPanel(_:)))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let toolbar = NSStackView(views: [toolControl, sep(), colorWell, swatches, sizeSlider, styleControl, spacer,
                                          undoButton, redoButton, sep(), backdropButton, ocr, pin, drag, copy, save])
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        toolbar.setHuggingPriority(.defaultHigh, for: .vertical)

        // Canvas
        let clip = CenteringClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        container = BackdropContainerView(canvas: canvas, doc: doc)
        scrollView.documentView = container
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 32
        scrollView.backgroundColor = NSColor(white: 0.16, alpha: 1)
        scrollView.drawsBackground = true

        // Info bar
        zoomLabel.bezelStyle = .inline
        zoomLabel.target = self
        zoomLabel.action = #selector(zoomMenu(_:))
        zoomLabel.toolTip = "Zoom: ⌘= ⌘- ⌘0 (fit) ⌘1 (100%)"
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        colorSwatch.wantsLayer = true
        colorSwatch.layer?.cornerRadius = 3
        colorSwatch.layer?.borderWidth = 1
        colorSwatch.layer?.borderColor = NSColor.separatorColor.cgColor
        colorSwatch.widthAnchor.constraint(equalToConstant: 14).isActive = true
        colorSwatch.heightAnchor.constraint(equalToConstant: 14).isActive = true
        colorLabel.bezelStyle = .inline
        colorLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        colorLabel.target = self
        colorLabel.action = #selector(copyHoverColor(_:))
        colorLabel.toolTip = "Color under cursor — click or press I to copy"
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let infoSpacer = NSView()
        infoSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let info = NSStackView(views: [zoomLabel, sizeLabel, colorSwatch, colorLabel, infoSpacer, hintLabel])
        info.orientation = .horizontal
        info.spacing = 10
        info.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)

        for v in [toolbar, scrollView, info] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        let line1 = NSBox(); line1.boxType = .separator
        let line2 = NSBox(); line2.boxType = .separator
        for v in [line1, line2] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            line1.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            line1.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            line1.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: line1.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            line2.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            line2.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            line2.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            info.topAnchor.constraint(equalTo: line2.bottomAnchor),
            info.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            info.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            info.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            info.heightAnchor.constraint(equalToConstant: 26),
        ])

        canvas.onHover = { [weak self] p, c in self?.hoverChanged(p, c) }
        canvas.onSelectionChange = { [weak self] a in self?.selectionChanged(a) }
        canvas.onCropChange = { [weak self] r in self?.updateHint(crop: r) }

        magnificationObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main
        ) { [weak self] _ in self?.updateZoomLabel() }
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    private func sep() -> NSView {
        let b = NSBox()
        b.boxType = .separator
        b.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return b
    }

    private func restoreToolDefaults() {
        let color = NSColor(hex: AppSettings.shared.editorColorHex) ?? .systemRed
        canvas.color = color
        colorWell.color = color
        canvas.strokeSize = CGFloat(AppSettings.shared.editorSize)
        sizeSlider.doubleValue = AppSettings.shared.editorSize
        setTool(.arrow)
    }

    private func sizeWindowToFit() {
        guard let window else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let chrome = CGSize(width: 2, height: 44 + 27 + 28)
        container.relayout()
        let img = container.frame.size
        let maxContent = CGSize(width: vf.width * 0.85 - chrome.width, height: vf.height * 0.85 - chrome.height)
        let zoom = min(1, maxContent.width / img.width, maxContent.height / img.height)
        let contentSize = CGSize(width: max(img.width * zoom + chrome.width + 30, window.minSize.width),
                                 height: max(img.height * zoom + chrome.height + 30, window.minSize.height))
        window.setContentSize(contentSize)
        var origin = CGPoint(x: vf.midX - window.frame.width / 2, y: vf.midY - window.frame.height / 2)
        // Cascade from the previously opened editor so a new window never hides exactly behind it.
        if let prev = Self.open.last(where: { $0 !== self })?.window {
            origin = CGPoint(x: prev.frame.minX + 32, y: prev.frame.minY - 32)
            if origin.x + window.frame.width > vf.maxX || origin.y < vf.minY {
                origin = CGPoint(x: vf.minX + 40, y: vf.maxY - window.frame.height - 40)
            }
        }
        window.setFrameOrigin(origin)
        window.layoutIfNeeded()
        scrollView.magnification = zoom
        updateZoomLabel()
    }

    // MARK: - State sync

    private func documentChanged() {
        canvas.documentDidChange()
        container.relayout()
        let px = doc.image
        sizeLabel.stringValue = "\(px.width) × \(px.height) px"
        window?.title = "ShotIt — \(px.width) × \(px.height)"
        undoButton.isEnabled = doc.canUndo
        redoButton.isEnabled = doc.canRedo
    }

    private func selectionChanged(_ a: Annotation?) {
        guard let a else { updateStyleControl(for: canvas.tool); return }
        colorWell.color = a.color
        sizeSlider.doubleValue = Double(a.size)
        if let t = a.kind.toolForStyle {
            updateStyleControl(for: t)
            styleControl.selectedSegment = a.style
        } else {
            styleControl.isHidden = true
        }
    }

    private func hoverChanged(_ p: CGPoint?, _ c: NSColor?) {
        hoverColor = c
        if let c {
            colorSwatch.layer?.backgroundColor = c.cgColor
            colorLabel.title = c.formatted(AppSettings.shared.colorFormat)
        }
        if let p, canvas.cropRect == nil {
            hintLabel.stringValue = "x \(Int(p.x * doc.scale))  y \(Int(p.y * doc.scale))"
        }
    }

    private func updateHint(crop: CGRect?) {
        if let c = crop {
            hintLabel.stringValue = "Crop \(Int((c.width * doc.scale).rounded())) × \(Int((c.height * doc.scale).rounded())) — Enter to apply, Esc to cancel"
        } else {
            hintLabel.stringValue = ""
        }
    }

    private func updateStyleControl(for tool: Tool) {
        let options = tool.styleOptions
        styleControl.isHidden = options.isEmpty
        guard !options.isEmpty else { return }
        styleControl.segmentCount = options.count
        for (i, o) in options.enumerated() {
            styleControl.setLabel(o, forSegment: i)
            styleControl.setWidth(0, forSegment: i)
        }
        let saved = UserDefaults.standard.integer(forKey: "style.\(tool.rawValue)")
        styleControl.selectedSegment = min(saved, options.count - 1)
        canvas.style = styleControl.selectedSegment
        if tool == .blur { doc.renderer.prefetchTextBoxes() }
    }

    private func updateZoomLabel() {
        zoomLabel.title = "\(Int((scrollView.magnification * 100).rounded()))%"
    }

    @objc private func boundsChanged(_ n: Notification) { updateZoomLabel() }

    func setTool(_ tool: Tool) {
        canvas.commitTextEditing()
        canvas.tool = tool
        if let i = Tool.allCases.firstIndex(of: tool) { toolControl.selectedSegment = i }
        updateStyleControl(for: tool)
        if tool == .crop { hintLabel.stringValue = "Drag to select the crop area, Enter to apply" }
        window?.makeFirstResponder(canvas)
    }

    // MARK: - Actions

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        setTool(Tool.allCases[sender.selectedSegment])
    }

    @objc private func styleChanged(_ sender: NSSegmentedControl) {
        canvas.style = sender.selectedSegment
        UserDefaults.standard.set(sender.selectedSegment, forKey: "style.\(canvas.tool.rawValue)")
        canvas.applyToSelection(style: sender.selectedSegment)
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        applyColor(sender.color)
    }

    @objc private func swatchClicked(_ sender: NSButton) {
        let c = Self.palette[sender.tag]
        colorWell.color = c
        applyColor(c)
    }

    private func applyColor(_ c: NSColor) {
        canvas.color = c
        AppSettings.shared.editorColorHex = c.hexString
        canvas.applyToSelection(color: c)
    }

    @objc private func sizeChanged(_ sender: NSSlider) {
        let v = CGFloat(sender.doubleValue.rounded())
        canvas.strokeSize = v
        AppSettings.shared.editorSize = Double(v)
        canvas.applyToSelection(size: v)
    }

    private func nudgeSize(_ delta: Double) {
        sizeSlider.doubleValue = min(sizeSlider.maxValue, max(sizeSlider.minValue, sizeSlider.doubleValue + delta))
        sizeChanged(sizeSlider)
    }

    @objc func undo(_ sender: Any?) { canvas.commitTextEditing(); doc.undo() }
    @objc func redo(_ sender: Any?) { canvas.commitTextEditing(); doc.redo() }

    @objc func copy(_ sender: Any?) {
        canvas.commitTextEditing()
        Exporter.copy(doc.exported(), scale: doc.scale)
        Toast.show("Copied to the clipboard")
    }

    @objc func save(_ sender: Any?) {
        canvas.commitTextEditing()
        do {
            let url = try Exporter.save(doc.exported(), scale: doc.scale, date: doc.date)
            doc.fileURL = url
            Toast.show("Saved \(url.lastPathComponent)")
        } catch {
            Toast.show(error.localizedDescription, style: .error)
        }
    }

    @objc func saveAs(_ sender: Any?) {
        canvas.commitTextEditing()
        Exporter.saveAs(doc.exported(), scale: doc.scale, date: doc.date, window: window) { [weak self] url in
            if let url { self?.doc.fileURL = url; Toast.show("Saved \(url.lastPathComponent)") }
        }
    }

    @objc func pin(_ sender: Any?) {
        canvas.commitTextEditing()
        PinWindowController.pin(Screenshot(image: doc.exported(), scale: doc.scale, date: doc.date))
    }

    @objc func recognizeText(_ sender: Any?) {
        var image = doc.image
        if let c = canvas.cropRect {
            let px = CGRect(x: c.minX * doc.scale, y: c.minY * doc.scale, width: c.width * doc.scale, height: c.height * doc.scale).integral
            image = doc.image.cropping(to: px) ?? image
        }
        TextRecognizer.recognizeAndCopy(image)
    }

    @objc func toggleBackdropPanel(_ sender: Any?) {
        if let p = backdropPopover, p.isShown { p.close(); return }
        canvas.commitTextEditing()
        let model = BackdropModel(style: doc.backdrop) { [weak self] style in self?.doc.backdrop = style }
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.contentViewController = NSHostingController(rootView: BackdropPanel(model: model))
        popover.show(relativeTo: backdropButton.bounds, of: backdropButton, preferredEdge: .maxY)
        backdropPopover = popover
        // Turning it on the first time should show something immediately.
        if !doc.backdrop.enabled { model.style.enabled = true }
    }

    @objc private func copyHoverColor(_ sender: Any?) {
        guard let c = hoverColor else { return }
        let s = c.formatted(AppSettings.shared.colorFormat)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        Toast.show("Color \(s) copied")
    }

    @objc private func zoomMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Zoom to Fit", action: #selector(zoomToFit(_:)), keyEquivalent: "0").target = self
        for z in [0.5, 1, 2, 4, 8] {
            let item = menu.addItem(withTitle: "\(Int(z * 100))%", action: #selector(zoomPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = z
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func zoomPreset(_ sender: NSMenuItem) {
        if let z = sender.representedObject as? Double { setZoom(CGFloat(z)) }
    }

    @objc func zoomToFit(_ sender: Any?) {
        let avail = scrollView.contentSize
        let img = container.frame.size
        setZoom(min(avail.width / img.width, avail.height / img.height) * 0.97)
    }

    private func setZoom(_ z: CGFloat, around p: CGPoint? = nil) {
        let clamped = min(max(z, scrollView.minMagnification), scrollView.maxMagnification)
        let center = p ?? CGPoint(x: container.visibleRect.midX, y: container.visibleRect.midY)
        scrollView.setMagnification(clamped, centeredAt: center)
        updateZoomLabel()
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags.isEmpty || flags == .shift {
            if let tool = Tool.allCases.first(where: { $0.key == chars }) { setTool(tool); return }
            switch chars {
            case "[": nudgeSize(-1); return
            case "]": nudgeSize(1); return
            case "i": copyHoverColor(nil); return
            case "k": toggleBackdropPanel(nil); return
            case "=", "+": setZoom(scrollView.magnification * 1.25); return
            case "-": setZoom(scrollView.magnification / 1.25); return
            default: break
            }
            if event.keyCode == 53 { escape(); return }  // Esc
        }
        super.keyDown(with: event)
    }

    /// Handle ⌘-shortcuts directly so they work without a visible menu bar.
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // Leave text editing shortcuts to the field editor.
        if window?.firstResponder is NSTextView { return false }
        switch (flags, chars) {
        case (.command, "z"): undo(nil)
        case ([.command, .shift], "z"): redo(nil)
        case (.command, "c"): copy(nil)
        case (.command, "s"): save(nil)
        case ([.command, .shift], "s"): saveAs(nil)
        case (.command, "p"): pin(nil)
        case (.command, "t"): recognizeText(nil)
        case (.command, "w"): window?.performClose(nil)
        case (.command, "0"): zoomToFit(nil)
        case (.command, "1"): setZoom(1)
        case (.command, "2"): setZoom(2)
        case (.command, "="), (.command, "+"): setZoom(scrollView.magnification * 1.25)
        case (.command, "-"): setZoom(scrollView.magnification / 1.25)
        default: return false
        }
        return true
    }

    private func escape() {
        if AppSettings.shared.escCopies { Exporter.copy(doc.exported(), scale: doc.scale) }
        if AppSettings.shared.escSaves { save(nil) }
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        canvas.commitTextEditing()
        if let o = magnificationObserver { NotificationCenter.default.removeObserver(o) }
        NotificationCenter.default.removeObserver(self)
        EditorWindowController.open.removeAll { $0 === self }
        if EditorWindowController.open.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}

/// Routes ⌘-shortcuts to the editor even though ShotIt runs without a visible menu bar.
final class EditorWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let wc = windowController as? EditorWindowController, wc.handleKeyEquivalent(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}
