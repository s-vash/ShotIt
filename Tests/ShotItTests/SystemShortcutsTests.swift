import AppKit
import Carbon.HIToolbox
import XCTest
@testable import ShotIt

final class SystemShortcutsTests: XCTestCase {
    private let cmdShift = NSEvent.ModifierFlags([.command, .shift]).rawValue

    private func entry(_ params: [Int], enabled: Bool) -> [String: Any] {
        ["enabled": enabled, "value": ["parameters": params, "type": "standard"] as [String: Any]]
    }

    func testMissingScreenshotShortcutsCountAsEnabledDefaults() {
        let all = SystemShortcuts.parse([:])
        let ids = Set(all.filter(\.enabled).map(\.id))
        XCTAssertEqual(ids, Set(SystemShortcuts.screenshotIDs))
        let area = all.first { $0.id == 30 }
        XCTAssertEqual(area?.shortcut, Shortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: cmdShift))
    }

    func testDisabledEntryIsReportedDisabledAndIgnoredForConflicts() {
        let root: [String: Any] = ["28": entry([51, 20, 1_179_648], enabled: false)]
        let all = SystemShortcuts.parse(root)
        XCTAssertEqual(all.first { $0.id == 28 }?.enabled, false)
        let cmdShift3 = Shortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: cmdShift)
        XCTAssertNil(SystemShortcuts.conflict(for: cmdShift3, in: all))
    }

    func testConflictFindsEnabledShortcutWithSameKeys() {
        let all = SystemShortcuts.parse([:])
        let cmdShift4 = Shortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: cmdShift)
        XCTAssertEqual(SystemShortcuts.conflict(for: cmdShift4, in: all)?.id, 30)
        // ShotIt's defaults (⌘⇧1, ⌘⇧2) are free.
        for action in [HotKeyAction.fullscreen, .area, .ocr] {
            XCTAssertNil(SystemShortcuts.conflict(for: action.defaultShortcut!, in: all), "\(action)")
        }
    }

    func testCustomParametersAreRead() {
        // ⌃⌥⌘O on key code 31 as a hypothetical user-assigned Spotlight shortcut.
        let mods = Int(NSEvent.ModifierFlags([.control, .option, .command]).rawValue)
        let all = SystemShortcuts.parse(["64": entry([111, 31, mods], enabled: true)])
        XCTAssertEqual(SystemShortcuts.conflict(for: HotKeyAction.ocr.defaultShortcut!, in: all)?.id, 64)
    }

    func testSettingOnlyTouchesRequestedEntries() {
        let other = entry([1, 2, 3], enabled: true)
        let root: [String: Any] = ["64": other]
        let changed = SystemShortcuts.setting(ids: [28, 30], enabled: false, in: root)
        XCTAssertEqual((changed["28"] as? [String: Any])?["enabled"] as? Bool, false)
        XCTAssertEqual((changed["30"] as? [String: Any])?["enabled"] as? Bool, false)
        XCTAssertEqual((changed["64"] as? [String: Any])?["enabled"] as? Bool, true)
        // A missing entry gets its factory parameters so macOS can still show it.
        let params = ((changed["30"] as? [String: Any])?["value"] as? [String: Any])?["parameters"] as? [Int]
        XCTAssertEqual(params, [52, 21, 1_179_648])
        // The change survives a parse round trip.
        XCTAssertEqual(SystemShortcuts.parse(changed).first { $0.id == 30 }?.enabled, false)
    }

    func testHotKeyCenterFlagsDuplicateActions() {
        let center = HotKeyCenter.shared
        let saved = HotKeyAction.allCases.map { ($0, center.shortcut(for: $0)) }
        defer { for (a, s) in saved { center.setShortcut(s, for: a) } }
        let dup = Shortcut(keyCode: UInt32(kVK_ANSI_8), modifiers: cmdShift)
        center.setShortcut(dup, for: .window)
        center.setShortcut(dup, for: .windowPick)
        XCTAssertEqual(center.conflict(for: .window), .action(.windowPick))
        center.setShortcut(nil, for: .windowPick)
        XCTAssertNil(center.conflict(for: .window))
    }
}
