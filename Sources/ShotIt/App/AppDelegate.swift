import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenu?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // When hosting unit tests, skip global side effects (menu bar item, hotkeys, onboarding).
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        // Set the icon explicitly so the Dock and About panel never depend on Launch Services' icon cache,
        // which can hold on to a stale "no icon" entry for a path that was built before the icon existed.
        if let icon = NSImage(named: "AppIcon") { NSApp.applicationIconImage = icon }
        buildMainMenu()
        Exporter.purgeTemporaryFiles()
        statusMenu = StatusMenu()
        HotKeyCenter.shared.handler = { action in
            CaptureCoordinator.shared.perform(action)
        }
        HotKeyCenter.shared.registerAll()

        if !UserDefaults.standard.bool(forKey: "didOnboard") {
            UserDefaults.standard.set(true, forKey: "didOnboard")
            if !ScreenCapturer.hasPermission { ScreenCapturer.requestPermission() }
            Toast.show("ShotIt is running in the menu bar.\n⌘⇧1 fullscreen · ⌘⇧2 area", duration: 5)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { PreferencesWindowController.show() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL {
                CaptureCoordinator.shared.open(url)
            } else if url.scheme?.lowercased() == "shotit" {
                URLCommand.handle(url)
            }
        }
    }

    /// Minimal main menu so standard editing shortcuts work in text fields and dialogs.
    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About ShotIt", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit ShotIt", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    @objc private func showSettings() { PreferencesWindowController.show() }
}

/// `shotit://` deep links:
///   shotit://grab/fullscreen | area | repeat | window | window/any | scrolling | scrolling/reverse | scrolling/manual | delayed | ocr
///   shotit://grab/area?then=copy,save,edit,pin,preview
///   shotit://open?path=/path/to/image.png
///   shotit://pin/clipboard
enum URLCommand {
    @MainActor
    static func handle(_ url: URL) {
        let parts = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" }).map { $0.lowercased() }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let then = query.first { $0.name == "then" }?.value.map {
            $0.split(separator: ",").compactMap { PostAction(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) }
        }
        let c = CaptureCoordinator.shared
        switch parts.first {
        case "grab":
            switch parts.dropFirst().joined(separator: "/") {
            case "fullscreen": c.fullscreen(then: then)
            case "area": c.area(then: then)
            case "repeat": c.repeatArea(then: then)
            case "window", "window/active": c.activeWindow(then: then)
            case "window/any": c.pickWindow(then: then)
            case "delayed": c.delayed(then: then)
            case "ocr": c.ocrArea()
            case "scrolling": c.scrolling(then: then)
            case "scrolling/reverse": c.scrolling(direction: .up, then: then)
            case "scrolling/manual": c.scrolling(manual: true, then: then)
            default: Toast.show("ShotIt: command is not recognized", style: .error)
            }
        case "open":
            if let path = query.first(where: { $0.name == "path" })?.value {
                c.open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            } else {
                c.openFile()
            }
        case "pin":
            c.pinFromClipboard()
        case "settings":
            PreferencesWindowController.show()
        default:
            Toast.show("ShotIt: command is not recognized", style: .error)
        }
    }
}
