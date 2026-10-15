import AppKit

/// A keyboard shortcut that macOS itself owns (System Settings › Keyboard › Keyboard Shortcuts).
struct SystemShortcut: Equatable {
    let id: Int
    let name: String
    let shortcut: Shortcut
    let enabled: Bool
}

/// Reads and changes the system's symbolic hotkeys (`com.apple.symbolichotkeys`), used to detect shortcuts that collide
/// with ShotIt's and to switch off the built-in screenshot shortcuts so ShotIt can take them over.
enum SystemShortcuts {
    /// Save/copy screen (⌘⇧3, ⌃⌘⇧3), save/copy selected area (⌘⇧4, ⌃⌘⇧4) and the screenshot toolbar (⌘⇧5).
    static let screenshotIDs = [28, 29, 30, 31, 184]
    /// The ⌘⇧3 / ⌘⇧4 families that ShotIt's fullscreen and area captures replace.
    static let replacedIDs = [28, 29, 30, 31]

    private static let domain = "com.apple.symbolichotkeys" as CFString
    private static let key = "AppleSymbolicHotKeys" as CFString
    private static let disabledKey = "systemShortcutsDisabledByShotIt"

    /// Name and factory-default parameters (ASCII, key code, modifier flags) of the shortcuts we know about.
    private static let known: [Int: (name: String, parameters: [Int]?)] = [
        28: ("Save picture of screen as a file", [51, 20, 1_179_648]),
        29: ("Copy picture of screen to the clipboard", [51, 20, 1_441_792]),
        30: ("Save picture of selected area as a file", [52, 21, 1_179_648]),
        31: ("Copy picture of selected area to the clipboard", [52, 21, 1_441_792]),
        184: ("Screenshot and recording options", [53, 23, 1_179_648]),
        32: ("Mission Control", nil), 33: ("Application windows", nil), 36: ("Show Desktop", nil),
        52: ("Turn Dock hiding on/off", nil), 60: ("Select the previous input source", nil),
        61: ("Select next source in Input menu", nil), 64: ("Show Spotlight search", nil),
        65: ("Show Finder search window", nil), 79: ("Move left a space", nil), 81: ("Move right a space", nil),
    ]

    private static let modifierMask: UInt = NSEvent.ModifierFlags([.command, .option, .control, .shift]).rawValue

    // MARK: Reading

    static func load() -> [SystemShortcut] {
        parse(CFPreferencesCopyAppValue(key, domain) as? [String: Any] ?? [:])
    }

    /// Turns the raw preference dictionary into shortcuts. Built-in screenshot shortcuts missing from the dictionary
    /// are still on at their factory defaults, so they are reported as enabled.
    static func parse(_ root: [String: Any]) -> [SystemShortcut] {
        var result: [SystemShortcut] = []
        for (id, info) in known.sorted(by: { $0.key < $1.key }) {
            let entry = root[String(id)] as? [String: Any]
            let value = entry?["value"] as? [String: Any]
            let parameters = (value?["parameters"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? info.parameters
            guard let p = parameters, p.count >= 3, p[1] != 65535 else { continue }
            let enabled = (entry?["enabled"] as? NSNumber)?.boolValue ?? (entry == nil)
            let shortcut = Shortcut(keyCode: UInt32(p[1]), modifiers: UInt(p[2]) & modifierMask)
            result.append(SystemShortcut(id: id, name: info.name, shortcut: shortcut, enabled: enabled))
        }
        return result
    }

    /// The enabled system shortcut that uses the same keys, if any.
    static func conflict(for shortcut: Shortcut, in all: [SystemShortcut]) -> SystemShortcut? {
        let mods = shortcut.modifiers & modifierMask
        return all.first { s in
            guard s.enabled else { return false }
            return s.shortcut.keyCode == shortcut.keyCode && s.shortcut.modifiers == mods
        }
    }

    /// True when ShotIt itself switched this system shortcut off (so it can offer to restore it).
    static func disabledByShotIt() -> Set<Int> {
        Set(UserDefaults.standard.array(forKey: disabledKey) as? [Int] ?? [])
    }

    // MARK: Writing

    /// Returns `root` with the given shortcuts switched on or off, keeping everything else untouched.
    static func setting(ids: [Int], enabled: Bool, in root: [String: Any]) -> [String: Any] {
        var root = root
        for id in ids {
            var entry = root[String(id)] as? [String: Any] ?? [:]
            if entry["value"] == nil, let p = known[id]?.parameters {
                entry["value"] = ["parameters": p, "type": "standard"] as [String: Any]
            }
            entry["enabled"] = enabled
            root[String(id)] = entry
        }
        return root
    }

    /// Switches system shortcuts on or off for the current user and tells the system to reload them.
    @discardableResult
    static func setEnabled(_ ids: [Int], _ enabled: Bool) -> Bool {
        let current = CFPreferencesCopyAppValue(key, domain) as? [String: Any] ?? [:]
        CFPreferencesSetValue(key, setting(ids: ids, enabled: enabled, in: current) as CFDictionary, domain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { return false }
        var mine = disabledByShotIt()
        if enabled { mine.subtract(ids) } else { mine.formUnion(ids) }
        UserDefaults.standard.set(Array(mine).sorted(), forKey: disabledKey)
        applyChanges()
        return true
    }

    /// Asks the system to re-read the symbolic hotkeys so a change takes effect without logging out.
    private static func applyChanges() {
        let tool = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["-u"]
        try? p.run()
        p.waitUntilExit()
    }
}
