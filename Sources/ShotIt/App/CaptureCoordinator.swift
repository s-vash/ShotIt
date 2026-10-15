import AppKit

/// Actions to run after a capture, overriding preferences (used by the `shotit://` URL scheme).
enum PostAction: String {
    case copy, save, edit, pin, preview
}

/// Runs capture flows and routes the result.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()
    private var busy = false
    /// Most recent capture, kept so the Reopen hotkey can bring it back.
    private var lastShot: Screenshot?
    private var scrollSession: ScrollCaptureSession?

    func perform(_ action: HotKeyAction, then: [PostAction]? = nil) {
        switch action {
        case .fullscreen: fullscreen(then: then)
        case .area: area(then: then)
        case .repeatArea: repeatArea(then: then)
        case .window: activeWindow(then: then)
        case .windowPick: pickWindow(then: then)
        case .scrolling: scrolling(then: then)
        case .scrollingUp: scrolling(direction: .up, then: then)
        case .scrollingManual: scrolling(manual: true, then: then)
        case .reopen: reopenLast()
        case .delayed: delayed(then: then)
        case .ocr: ocrArea()
        case .pinClipboard: pinFromClipboard()
        }
    }

    // MARK: - Flows

    func fullscreen(then: [PostAction]? = nil) {
        run {
            let shot = try await ScreenCapturer.captureScreenUnderMouse()
            self.deliver(shot, mode: AppSettings.shared.afterFullscreen, then: then)
        }
    }

    func area(then: [PostAction]? = nil) {
        select(mode: .area, hint: nil, allowWindowToggle: true) { result in
            if case .window(let w) = result {  // Space switched to window picking
                self.run {
                    let shot = try await ScreenCapturer.captureWindow(id: w.id)
                    self.deliver(shot, mode: AppSettings.shared.afterWindow, then: then)
                }
                return
            }
            guard case .area(let rect, let frame) = result else { return }
            AppSettings.shared.lastArea = rect
            guard let img = frame.crop(rect) else { Toast.show("Selected area seems to be empty", style: .error); return }
            self.deliver(Screenshot(image: img, scale: frame.scale), mode: AppSettings.shared.afterArea, then: then)
        }
    }

    func repeatArea(then: [PostAction]? = nil) {
        guard let rect = AppSettings.shared.lastArea else {
            Toast.show("No area to repeat — take an area capture first", style: .error)
            return
        }
        run {
            let frames = try await ScreenCapturer.captureAllScreens()
            let center = CGPoint(x: rect.midX, y: rect.midY)
            guard let frame = frames.first(where: { $0.frame.contains(center) }) ?? frames.first,
                  let img = frame.crop(rect) else {
                Toast.show("No area to repeat", style: .error)
                return
            }
            self.deliver(Screenshot(image: img, scale: frame.scale), mode: AppSettings.shared.afterArea, then: then)
        }
    }

    func activeWindow(then: [PostAction]? = nil) {
        run {
            guard let id = ScreenCapturer.activeWindowID() else { throw CaptureError.noWindow }
            let shot = try await ScreenCapturer.captureWindow(id: id)
            self.deliver(shot, mode: AppSettings.shared.afterWindow, then: then)
        }
    }

    func pickWindow(then: [PostAction]? = nil) {
        select(mode: .window, hint: "Click a window, or drag to select an area · Esc to cancel") { result in
            switch result {
            case .window(let w):
                self.run {
                    let shot = try await ScreenCapturer.captureWindow(id: w.id)
                    self.deliver(shot, mode: AppSettings.shared.afterWindow, then: then)
                }
            case .area(let rect, let frame):
                guard let img = frame.crop(rect) else { return }
                self.deliver(Screenshot(image: img, scale: frame.scale), mode: AppSettings.shared.afterArea, then: then)
            case .cancelled:
                break
            }
        }
    }

    func delayed(seconds: Int = 3, then: [PostAction]? = nil) {
        guard !busy else { return }
        busy = true
        func tick(_ n: Int) {
            if n == 0 {
                busy = false
                // Give the toast time to fade before grabbing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.fullscreen(then: then) }
                return
            }
            Toast.show("Screenshot in \(n)…", duration: 0.8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tick(n - 1) }
        }
        tick(seconds)
    }

    /// Scrolling capture. Pressing the hotkey again while a capture is running finishes it.
    func scrolling(direction: ScrollStitcher.Direction = .down, manual: Bool = false, then: [PostAction]? = nil) {
        if let running = scrollSession { running.stop(keep: true); return }
        if !manual && !AXIsProcessTrusted() {
            // Synthesizing scroll events needs Accessibility. One ShotIt alert explains it (and the manual alternative);
            // the system prompt only appears if the user chooses to grant access.
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Scrolling Capture needs Accessibility access"
            alert.informativeText = "ShotIt scrolls the window for you, which macOS only allows with Accessibility permission. Manual Scrolling Capture works without it."
            alert.addButton(withTitle: "Grant Access…")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
            return
        }
        let hint = manual ? "Select the area, then scroll it yourself · Esc to finish" : "Select the area to scroll · Esc to finish"
        select(mode: .area, hint: hint) { result in
            guard case .area(let rect, let frame) = result else { return }
            AppSettings.shared.lastArea = rect
            let session = ScrollCaptureSession(rect: rect, screen: frame.screen, scale: frame.scale,
                                               direction: direction, mode: manual ? .manual : .auto)
            session.onFinish = { [weak self] shot in
                self?.scrollSession = nil
                guard let shot else { return }
                self?.deliver(shot, mode: AppSettings.shared.afterArea, then: then)
            }
            self.scrollSession = session
            session.start()
        }
    }

    func reopenLast() {
        guard let shot = lastShot else {
            Toast.show("No capture to reopen yet", style: .error)
            return
        }
        EditorWindowController.open(shot)
    }

    func ocrArea() {
        select(mode: .area, hint: "Select the text or QR code to recognize") { result in
            guard case .area(let rect, let frame) = result, let img = frame.crop(rect) else { return }
            TextRecognizer.recognizeAndCopy(img)
        }
    }

    func pinFromClipboard() {
        guard let shot = Exporter.imageFromClipboard() else {
            Toast.show("Make sure your clipboard contains an image and try again", style: .error)
            return
        }
        PinWindowController.pin(shot)
    }

    func openFromClipboard() {
        guard let shot = Exporter.imageFromClipboard() else {
            Toast.show("Make sure your clipboard contains an image and try again", style: .error)
            return
        }
        EditorWindowController.open(shot)
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .heic, .bmp]
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url) }
    }

    func open(_ url: URL) {
        guard let shot = Exporter.loadImage(from: url) else {
            Toast.show("Failed to open image file", style: .error)
            return
        }
        EditorWindowController.open(shot)
    }

    // MARK: - Plumbing

    private func select(mode: SelectionMode, hint: String?, allowWindowToggle: Bool = false,
                        completion: @escaping (SelectionResult) -> Void) {
        run {
            let frames = try await ScreenCapturer.captureAllScreens()
            RegionSelector.begin(frames: frames, mode: mode, hint: hint, allowWindowToggle: allowWindowToggle) { result in
                completion(result)
            }
        }
    }

    private func run(_ body: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        PreviewPanel.dismissCurrent()
        Task { @MainActor in
            defer { self.busy = false }
            do {
                try await body()
            } catch let e as CaptureError {
                self.report(e)
            } catch {
                Toast.show("Capturing error: \(error.localizedDescription)", style: .error, duration: 4)
            }
        }
    }

    private func report(_ e: CaptureError) {
        if case .permissionDenied = e {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "ShotIt needs permission to record the screen"
            alert.informativeText = e.errorDescription ?? ""
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                // Registers ShotIt in the list (and shows the system prompt the first time), then opens the pane.
                ScreenCapturer.requestPermission()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
        } else {
            Toast.show(e.errorDescription ?? "Something went wrong", style: .error, duration: 3)
        }
    }

    /// Post-capture pipeline: sound → copy/save per preferences → preview or editor.
    func deliver(_ shot: Screenshot, mode: AfterCapture, then: [PostAction]? = nil) {
        lastShot = shot
        if AppSettings.shared.playSound { Self.shutterSound?.play() }

        if let then {
            for a in then {
                switch a {
                case .copy: Exporter.copy(shot.image, scale: shot.scale)
                case .save: saveQuietly(shot)
                case .edit: EditorWindowController.open(shot)
                case .pin: PinWindowController.pin(shot)
                case .preview: PreviewPanel.show(shot)
                }
            }
            return
        }

        if AppSettings.shared.copyAfterCapture { Exporter.copy(shot.image, scale: shot.scale) }
        if AppSettings.shared.saveAfterCapture { saveQuietly(shot) }
        switch mode {
        case .preview: PreviewPanel.show(shot)
        case .editor: EditorWindowController.open(shot)
        case .nothing:
            if AppSettings.shared.copyAfterCapture { Toast.show("Copied to the clipboard") }
        }
    }

    private func saveQuietly(_ shot: Screenshot) {
        do {
            shot.fileURL = try Exporter.save(shot.image, scale: shot.scale, date: shot.date)
        } catch {
            Toast.show("Failed to save file: \(error.localizedDescription)", style: .error)
        }
    }

    private static let shutterSound: NSSound? = {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif"
        return NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: "Tink")
    }()
}
