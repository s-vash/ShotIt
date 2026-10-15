import AppKit
import ScreenCaptureKit

/// A captured bitmap plus the point→pixel scale it was taken at.
final class Screenshot {
    var image: CGImage
    let scale: CGFloat
    let date: Date
    /// File the screenshot was last saved to or opened from.
    var fileURL: URL?

    init(image: CGImage, scale: CGFloat, date: Date = Date(), fileURL: URL? = nil) {
        self.image = image
        self.scale = max(scale, 1)
        self.date = date
        self.fileURL = fileURL
    }

    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }
    var pointSize: CGSize { CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }
    var nsImage: NSImage { NSImage(cgImage: image, size: pointSize) }
}

/// A frozen frame of one display, used as the backdrop for area/window selection.
struct ScreenFrame {
    let screen: NSScreen
    let image: CGImage
    let scale: CGFloat
    /// Screen frame in global AppKit coordinates (bottom-left origin).
    var frame: CGRect { screen.frame }

    /// Crops `rect` (global AppKit coordinates) out of this frame.
    func crop(_ rect: CGRect) -> CGImage? {
        let r = rect.intersection(frame)
        guard !r.isEmpty else { return nil }
        let px = CGRect(x: (r.minX - frame.minX) * scale,
                        y: (frame.maxY - r.maxY) * scale,
                        width: r.width * scale,
                        height: r.height * scale).integral
        return image.cropping(to: px)
    }
}

/// On-screen window description (global AppKit coordinates).
struct WindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let frame: CGRect
    let title: String
    let owner: String
}

enum CaptureError: LocalizedError {
    case permissionDenied
    case noDisplay
    case noWindow
    case emptySelection

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "ShotIt needs the Screen Recording permission. Enable it in System Settings › Privacy & Security › Screen & System Audio Recording, then relaunch ShotIt."
        case .noDisplay: return "No matching display found"
        case .noWindow: return "No windows are present, try taking a fullscreen screenshot instead"
        case .emptySelection: return "Selected area seems to be empty"
        }
    }
}

extension NSWindow {
    static let transientIdentifier = NSUserInterfaceItemIdentifier("shotit.transient")

    /// Marks a short-lived ShotIt window (selection overlay, toast, preview, scroll HUD) so captures leave it out.
    /// Other ShotIt windows (Settings, editor, pins) are captured like any other app's.
    func markTransient() { identifier = NSWindow.transientIdentifier }
}

@MainActor
enum ScreenCapturer {
    /// Window numbers of ShotIt's transient windows that are currently on screen.
    static var transientWindowIDs: Set<CGWindowID> {
        Set(NSApp.windows.filter { $0.identifier == NSWindow.transientIdentifier }.map { CGWindowID($0.windowNumber) })
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Captures every connected display, leaving out ShotIt's transient windows.
    static func captureAllScreens() async throws -> [ScreenFrame] {
        let content = try await shareableContent()
        let screens = NSScreen.screens
        var frames: [ScreenFrame] = []
        for screen in screens {
            guard let id = displayID(of: screen),
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let scale = screen.backingScaleFactor
            let image = try await captureDisplay(display, scale: scale, content: content)
            frames.append(ScreenFrame(screen: screen, image: image, scale: scale))
        }
        if frames.isEmpty { throw CaptureError.noDisplay }
        return frames
    }

    /// Captures one display (leaving out ShotIt's transient windows) as a frozen frame.
    static func captureFrame(of screen: NSScreen) async throws -> ScreenFrame {
        let content = try await shareableContent()
        guard let id = displayID(of: screen), let display = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.noDisplay }
        let scale = screen.backingScaleFactor
        return ScreenFrame(screen: screen, image: try await captureDisplay(display, scale: scale, content: content), scale: scale)
    }

    /// Captures the display that currently contains the mouse pointer.
    static func captureScreenUnderMouse() async throws -> Screenshot {
        let content = try await shareableContent()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        guard let screen, let id = displayID(of: screen),
              let display = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.noDisplay }
        let image = try await captureDisplay(display, scale: scale, content: content)
        return Screenshot(image: image, scale: scale)
    }

    static func captureWindow(id: CGWindowID) async throws -> Screenshot {
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.noWindow }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let points = filter.contentRect.size
        // Use the backing scale of the display the window is on; pointPixelScale alone can under-report.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let appKitFrame = CGRect(x: window.frame.minX, y: primaryHeight - window.frame.maxY,
                                 width: window.frame.width, height: window.frame.height)
        let screenScale = NSScreen.screens.max { a, b in
            a.frame.intersection(appKitFrame).area < b.frame.intersection(appKitFrame).area
        }?.backingScaleFactor ?? 1
        let scale = max(CGFloat(filter.pointPixelScale), screenScale)

        let config = SCStreamConfiguration()
        config.width = max(1, Int((points.width * scale).rounded()))
        config.height = max(1, Int((points.height * scale).rounded()))
        config.showsCursor = false
        config.captureResolution = .best
        config.scalesToFit = false
        // With a shadow, SCK squeezes window + shadow into the window-sized canvas and the result looks soft,
        // so shadows are opt-in (Settings › Advanced).
        config.ignoreShadowsSingleWindow = !AppSettings.shared.windowShadow
        config.shouldBeOpaque = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        // Report the scale actually delivered so the editor shows the right point size.
        let delivered = points.width > 0 ? CGFloat(image.width) / points.width : scale
        return Screenshot(image: image, scale: max(1, delivered))
    }

    // MARK: - Window discovery

    /// All normal (layer 0) on-screen windows, front to back, excluding ShotIt's transient windows.
    static func onScreenWindows() -> [WindowInfo] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let transient = transientWindowIDs
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  !transient.contains(id),
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let cg = CGRect(dictionaryRepresentation: boundsDict),
                  cg.width > 40, cg.height > 40 else { return nil }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { return nil }
            // CG window bounds are top-left based on the primary display.
            let frame = CGRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height)
            return WindowInfo(id: id, pid: pid, frame: frame,
                              title: info[kCGWindowName as String] as? String ?? "",
                              owner: info[kCGWindowOwnerName as String] as? String ?? "")
        }
    }

    /// Front-most window of the active application (falls back to the top-most window).
    static func activeWindowID() -> CGWindowID? {
        let windows = onScreenWindows()
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let w = windows.first(where: { $0.pid == pid }) {
            return w.id
        }
        return windows.first?.id
    }

    // MARK: - Private

    private static func shareableContent() async throws -> SCShareableContent {
        // No system prompt here: CaptureCoordinator.report shows a single ShotIt alert, whose button requests access.
        guard hasPermission else { throw CaptureError.permissionDenied }
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.permissionDenied
        }
    }

    private static func captureDisplay(_ display: SCDisplay, scale: CGFloat, content: SCShareableContent) async throws -> CGImage {
        let transient = transientWindowIDs
        let hidden = content.windows.filter { transient.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: hidden)
        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = false
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
