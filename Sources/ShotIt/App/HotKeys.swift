import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut: virtual key code + Cocoa modifier flags.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt  // NSEvent.ModifierFlags raw value (device-independent subset)

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    var displayString: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + Shortcut.keyName(keyCode)
    }

    /// Key equivalent usable in NSMenuItem (lowercase character), if representable.
    var menuKeyEquivalent: String {
        let name = Shortcut.keyName(keyCode)
        return name.count == 1 ? name.lowercased() : ""
    }

    static func keyName(_ code: UInt32) -> String {
        let special: [Int: String] = [
            kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        ]
        if let s = special[Int(code)] { return s }
        // Translate through the current keyboard layout.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// Capture actions that can be bound to a global hotkey.
enum HotKeyAction: String, CaseIterable, Identifiable {
    case fullscreen, area, repeatArea, window, windowPick, scrolling, scrollingUp, scrollingManual, reopen, delayed, ocr, pinClipboard
    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullscreen: return "Fullscreen Screenshot"
        case .area: return "Area Capture"
        case .repeatArea: return "Repeat Area Capture"
        case .window: return "Capture Active Window"
        case .windowPick: return "Capture Any Window"
        case .scrolling: return "Scrolling Capture"
        case .scrollingUp: return "Scrolling Capture (Up)"
        case .scrollingManual: return "Manual Scrolling Capture"
        case .reopen: return "Reopen Last Capture"
        case .delayed: return "Delayed Screenshot (3s)"
        case .ocr: return "Recognize Text/QR"
        case .pinClipboard: return "Pin Image from Clipboard"
        }
    }

    /// Default shortcuts:
    /// fullscreen ⌘⇧1, area ⌘⇧2, ocr ⌃⌥⌘O; repeat/window/anyWindow/scrolling/reopen have none.
    var defaultShortcut: Shortcut? {
        let cmdShift = NSEvent.ModifierFlags([.command, .shift]).rawValue
        let ctrlOptCmd = NSEvent.ModifierFlags([.control, .option, .command]).rawValue
        switch self {
        case .fullscreen: return Shortcut(keyCode: UInt32(kVK_ANSI_1), modifiers: cmdShift)
        case .area: return Shortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: cmdShift)
        case .ocr: return Shortcut(keyCode: UInt32(kVK_ANSI_O), modifiers: ctrlOptCmd)
        default: return nil
        }
    }
}

/// Why a shortcut may not work as expected.
enum HotKeyConflict: Equatable {
    case action(HotKeyAction)        // another ShotIt action uses the same keys
    case system(SystemShortcut)      // macOS itself uses the same keys
    case otherApp                    // another app already registered the same keys
}

/// Registers system-wide hotkeys through Carbon's RegisterEventHotKey.
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    static let didChange = Notification.Name("ShotItHotKeysChanged")

    var handler: ((HotKeyAction) -> Void)?
    private var refs: [HotKeyAction: EventHotKeyRef] = [:]
    private var ids: [UInt32: HotKeyAction] = [:]
    private var eventHandler: EventHandlerRef?
    private var failed: Set<HotKeyAction> = []
    private var systemShortcuts: [SystemShortcut] = SystemShortcuts.load()
    private let signature: OSType = 0x53_48_4F_54  // 'SHOT'

    private init() {}

    func shortcut(for action: HotKeyAction) -> Shortcut? {
        let key = "hotkey.\(action.rawValue)"
        if let data = UserDefaults.standard.data(forKey: key) {
            // An empty payload means "explicitly cleared".
            if data.isEmpty { return nil }
            return try? JSONDecoder().decode(Shortcut.self, from: data)
        }
        return action.defaultShortcut
    }

    func setShortcut(_ shortcut: Shortcut?, for action: HotKeyAction) {
        let key = "hotkey.\(action.rawValue)"
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.set(Data(), forKey: key)
        }
        registerAll()
        NotificationCenter.default.post(name: HotKeyCenter.didChange, object: nil)
    }

    /// Drops any customisation (including "cleared") so the action falls back to its default shortcut.
    func resetShortcut(for action: HotKeyAction) {
        UserDefaults.standard.removeObject(forKey: "hotkey.\(action.rawValue)")
        registerAll()
        NotificationCenter.default.post(name: HotKeyCenter.didChange, object: nil)
    }

    func resetToDefaults() {
        for action in HotKeyAction.allCases { UserDefaults.standard.removeObject(forKey: "hotkey.\(action.rawValue)") }
        registerAll()
        NotificationCenter.default.post(name: HotKeyCenter.didChange, object: nil)
    }

    /// Whether `action`'s shortcut collides with another ShotIt action, a macOS shortcut or another app.
    func conflict(for action: HotKeyAction) -> HotKeyConflict? {
        guard let sc = shortcut(for: action) else { return nil }
        let mask = NSEvent.ModifierFlags([.command, .option, .control, .shift]).rawValue
        if let other = HotKeyAction.allCases.first(where: {
            $0 != action && shortcut(for: $0).map { $0.keyCode == sc.keyCode && $0.modifiers & mask == sc.modifiers & mask } == true
        }) { return .action(other) }
        if let system = SystemShortcuts.conflict(for: sc, in: systemShortcuts) { return .system(system) }
        return failed.contains(action) ? .otherApp : nil
    }

    /// Re-reads macOS's shortcuts (after the user or ShotIt changed them) and refreshes registrations and the UI.
    func refreshSystemShortcuts() {
        systemShortcuts = SystemShortcuts.load()
        registerAll()
        NotificationCenter.default.post(name: HotKeyCenter.didChange, object: nil)
    }

    /// Temporarily disable hotkeys (e.g. while recording a new shortcut).
    func suspend() { unregisterAll() }

    func registerAll() {
        installHandlerIfNeeded()
        unregisterAll()
        failed.removeAll()
        systemShortcuts = SystemShortcuts.load()
        var next: UInt32 = 1
        for action in HotKeyAction.allCases {
            guard let sc = shortcut(for: action) else { continue }
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: signature, id: next)
            let status = RegisterEventHotKey(sc.keyCode, sc.carbonModifiers, hkID, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[action] = ref
                ids[next] = action
            } else {
                failed.insert(action)
                NSLog("ShotIt: failed to register hotkey \(sc.displayString) for \(action.rawValue): \(status)")
            }
            next += 1
        }
    }

    private func unregisterAll() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        ids.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            if let action = center.ids[hkID.id] {
                DispatchQueue.main.async { center.handler?(action) }
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }
}
