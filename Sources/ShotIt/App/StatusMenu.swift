import AppKit

/// Menu bar item.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    override init() {
        super.init()
        if let button = item.button {
            let img = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "ShotIt")
            img?.isTemplate = true
            button.image = img
            button.toolTip = "ShotIt"
        }
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for action in HotKeyAction.allCases {
            let mi = NSMenuItem(title: action.title, action: #selector(captureItem(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = action.rawValue
            if let sc = HotKeyCenter.shared.shortcut(for: action), !sc.menuKeyEquivalent.isEmpty {
                mi.keyEquivalent = sc.menuKeyEquivalent
                mi.keyEquivalentModifierMask = sc.flags
            }
            mi.image = NSImage(systemSymbolName: symbol(for: action), accessibilityDescription: nil)
            menu.addItem(mi)
            if action == .delayed { menu.addItem(.separator()) }
        }
        menu.addItem(.separator())
        add("Open File…", #selector(openFile), symbol: "folder")
        add("Open from Clipboard", #selector(openClipboard), symbol: "doc.on.clipboard")
        add("Show Screenshots Folder", #selector(openFolder), symbol: "photo.on.rectangle")
        add("Close All Pins", #selector(closePins), symbol: "pin.slash")
        menu.addItem(.separator())
        add("Settings…", #selector(openSettings), key: ",")
        if !ScreenCapturer.hasPermission {
            add("Grant Screen Recording Permission…", #selector(grantPermission), symbol: "exclamationmark.triangle")
        }
        add("About ShotIt", #selector(about))
        add("Quit ShotIt", #selector(quit), key: "q")
    }

    private func add(_ title: String, _ sel: Selector, key: String = "", symbol: String? = nil) {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        mi.target = self
        if let symbol { mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        menu.addItem(mi)
    }

    private func symbol(for action: HotKeyAction) -> String {
        switch action {
        case .fullscreen: return "macwindow.on.rectangle"
        case .area: return "rectangle.dashed"
        case .repeatArea: return "arrow.clockwise"
        case .window: return "macwindow"
        case .windowPick: return "cursorarrow.rays"
        case .scrolling: return "arrow.down.to.line"
        case .scrollingUp: return "arrow.up.to.line"
        case .scrollingManual: return "hand.draw"
        case .reopen: return "arrow.uturn.backward.circle"
        case .delayed: return "timer"
        case .ocr: return "text.viewfinder"
        case .pinClipboard: return "pin"
        }
    }

    @objc private func captureItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = HotKeyAction(rawValue: raw) else { return }
        // Let the menu close before freezing the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            CaptureCoordinator.shared.perform(action)
        }
    }

    @objc private func openFile() { CaptureCoordinator.shared.openFile() }
    @objc private func openClipboard() { CaptureCoordinator.shared.openFromClipboard() }
    @objc private func openFolder() { NSWorkspace.shared.open(AppSettings.shared.saveFolder) }
    @objc private func closePins() { PinWindowController.closeAll() }
    @objc private func openSettings() { PreferencesWindowController.show() }
    @objc private func grantPermission() {
        ScreenCapturer.requestPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationIcon: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage as Any,
            .credits: NSAttributedString(string: "A screenshot & annotation tool inspired by Shottr.",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11)]),
        ])
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
