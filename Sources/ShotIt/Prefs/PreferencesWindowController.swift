import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// Settings window: General / Shortcuts / Advanced.
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: PreferencesWindowController?

    static func show() {
        if shared == nil { shared = PreferencesWindowController() }
        NSApp.activate(ignoringOtherApps: true)
        shared?.window?.center()
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
    }

    init() {
        let host = NSHostingController(rootView: PreferencesView())
        let window = NSWindow(contentViewController: host)
        window.title = "ShotIt Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(CGSize(width: 560, height: 740))
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        HotKeyCenter.shared.registerAll()
        PreferencesWindowController.shared = nil
    }
}

struct PreferencesView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "General", shortcuts = "Shortcuts", advanced = "Advanced"
        var id: String { rawValue }
    }

    @State var tab: Tab = .general

    var body: some View {
        // A plain segmented picker instead of TabView: macOS 26 draws a stray accent-coloured sliver next to the
        // selected TabView tab, and TabView also needs a fixed height to avoid collapsing around a Form.
        VStack(spacing: 14) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Group {
                switch tab {
                case .general: GeneralPane()
                case .shortcuts: ShortcutsPane()
                case .advanced: AdvancedPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .frame(width: 560, height: 740)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @State private var afterFullscreen = AppSettings.shared.afterFullscreen
    @State private var afterArea = AppSettings.shared.afterArea
    @State private var afterWindow = AppSettings.shared.afterWindow
    @State private var copyAfter = AppSettings.shared.copyAfterCapture
    @State private var saveAfter = AppSettings.shared.saveAfterCapture
    @State private var folder = AppSettings.shared.saveFolder
    @State private var format = AppSettings.shared.imageFormat
    @State private var previewSeconds = AppSettings.shared.previewSeconds
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var playSound = AppSettings.shared.playSound

    var body: some View {
        Form {
            Section("After capture") {
                Picker("Fullscreen screenshot", selection: $afterFullscreen) {
                    ForEach(AfterCapture.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: afterFullscreen) { _, v in AppSettings.shared.afterFullscreen = v }
                Picker("Area capture", selection: $afterArea) {
                    ForEach(AfterCapture.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: afterArea) { _, v in AppSettings.shared.afterArea = v }
                Picker("Window capture", selection: $afterWindow) {
                    ForEach(AfterCapture.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: afterWindow) { _, v in AppSettings.shared.afterWindow = v }
                Toggle("Copy to clipboard", isOn: $copyAfter)
                    .onChange(of: copyAfter) { _, v in AppSettings.shared.copyAfterCapture = v }
                Toggle("Save to folder", isOn: $saveAfter)
                    .onChange(of: saveAfter) { _, v in AppSettings.shared.saveAfterCapture = v }
                Toggle("Play shutter sound", isOn: $playSound)
                    .onChange(of: playSound) { _, v in AppSettings.shared.playSound = v }
                HStack {
                    Text("Close thumbnail after")
                    Slider(value: $previewSeconds, in: 0...20, step: 1)
                        .onChange(of: previewSeconds) { _, v in AppSettings.shared.previewSeconds = v }
                    Text(previewSeconds == 0 ? "never" : "\(Int(previewSeconds))s")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
            Section("Saving") {
                HStack {
                    Text("Folder")
                    Spacer()
                    Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { chooseFolder() }
                }
                Picker("Format", selection: $format) {
                    Text("PNG").tag(ImageFormat.png)
                    Text("JPEG").tag(ImageFormat.jpeg)
                }
                .pickerStyle(.segmented)
                .onChange(of: format) { _, v in AppSettings.shared.imageFormat = v }
            }
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            Toast.show("Launch At Login failed: \(error.localizedDescription)", style: .error)
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Choose"
        panel.message = "Pick a folder for your screenshots."
        if panel.runModal() == .OK, let url = panel.url {
            AppSettings.shared.saveFolder = url
            folder = url
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    @State private var revision = 0

    var body: some View {
        Form {
            macOSShortcutsSection
            Section {
                ForEach(HotKeyAction.allCases) { action in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(action.title)
                            Spacer()
                            let current = HotKeyCenter.shared.shortcut(for: action)
                            if current != action.defaultShortcut {
                                Button { HotKeyCenter.shared.resetShortcut(for: action); revision += 1 } label: {
                                    Image(systemName: "arrow.counterclockwise")
                                }
                                .buttonStyle(.borderless)
                                .help(action.defaultShortcut.map { "Reset to default (\($0.displayString))" } ?? "Reset to default (none)")
                            }
                            if current != nil {
                                Button { HotKeyCenter.shared.setShortcut(nil, for: action); revision += 1 } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("Clear shortcut")
                            }
                            ShortcutRecorder(action: action)
                                .frame(width: 140, height: 24)
                                .id("\(action.rawValue)-\(revision)")
                        }
                        conflictNote(for: action)
                    }
                }
            } footer: {
                Text("Click a field and press the new shortcut. Press ⌫ to clear, Esc to cancel; ↺ resets a shortcut to its default, ✕ clears it. While selecting an area, press Space to pick a window instead. Editor tools: A R O L D T C B H S M X, K backdrop, [ ] size, I copies color.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Restore Defaults") {
                    HotKeyCenter.shared.resetToDefaults()
                    revision += 1
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: HotKeyCenter.didChange)) { _ in revision += 1 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            HotKeyCenter.shared.refreshSystemShortcuts()  // the user may have changed them in System Settings
        }
    }

    // MARK: Built-in macOS screenshot shortcuts

    /// Offers to swap macOS's ⌘⇧3 / ⌘⇧4 screenshot shortcuts for ShotIt's, or to give them back.
    @ViewBuilder private var macOSShortcutsSection: some View {
        let _ = revision
        let system = SystemShortcuts.load()
        let builtInOn = system.contains { SystemShortcuts.replacedIDs.contains($0.id) && $0.enabled }
        let mine = SystemShortcuts.disabledByShotIt().intersection(SystemShortcuts.replacedIDs)
        if builtInOn {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The built-in macOS screenshot shortcuts (⌘⇧3, ⌘⇧4) are on.")
                    Text("Replace them to use those keys for ShotIt: ⌘⇧3 takes a fullscreen screenshot and ⌘⇧4 captures an area. You can undo this at any time.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Replace with ShotIt") { takeOverBuiltInShortcuts() }
                }
            }
        } else if !mine.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ShotIt has turned off the built-in macOS screenshot shortcuts.")
                    Button("Give Them Back to macOS") { restoreBuiltInShortcuts() }
                }
            }
        }
    }

    private func takeOverBuiltInShortcuts() {
        guard SystemShortcuts.setEnabled(SystemShortcuts.replacedIDs, false) else {
            Toast.show("Couldn't change the macOS shortcuts. Turn them off in System Settings › Keyboard › Keyboard Shortcuts › Screenshots.", style: .error, duration: 5)
            return
        }
        let cmdShift = NSEvent.ModifierFlags([.command, .shift]).rawValue
        HotKeyCenter.shared.setShortcut(Shortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: cmdShift), for: .fullscreen)
        HotKeyCenter.shared.setShortcut(Shortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: cmdShift), for: .area)
        HotKeyCenter.shared.refreshSystemShortcuts()
        revision += 1
    }

    private func restoreBuiltInShortcuts() {
        SystemShortcuts.setEnabled(Array(SystemShortcuts.disabledByShotIt()), true)
        HotKeyCenter.shared.refreshSystemShortcuts()
        // Anything of ours that now collides with macOS goes back to its default.
        for action in HotKeyAction.allCases {
            if case .system = HotKeyCenter.shared.conflict(for: action) { HotKeyCenter.shared.resetShortcut(for: action) }
        }
        revision += 1
    }

    // MARK: Conflicts

    @ViewBuilder private func conflictNote(for action: HotKeyAction) -> some View {
        if let conflict = HotKeyCenter.shared.conflict(for: action) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                switch conflict {
                case .action(let other):
                    Text("Also used by “\(other.title)”, so only one of them will work.")
                case .system(let s):
                    Text("macOS already uses this for “\(s.name)”.")
                    Button("Turn Off in macOS") {
                        if SystemShortcuts.setEnabled([s.id], false) { HotKeyCenter.shared.refreshSystemShortcuts() }
                        else { Toast.show("Couldn't change the macOS shortcut. Change it in System Settings › Keyboard › Keyboard Shortcuts.", style: .error, duration: 5) }
                        revision += 1
                    }
                    .controlSize(.small)
                case .otherApp:
                    Text("Another app already uses this shortcut. Quit it or choose different keys.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let action: HotKeyAction

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let v = ShortcutRecorderView()
        v.hotKeyAction = action
        return v
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {}
}

final class ShortcutRecorderView: NSButton {
    var hotKeyAction: HotKeyAction? { didSet { refresh() } }
    private var recording = false { didSet { refresh() } }
    private var monitor: Any?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(clicked)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        guard let action = hotKeyAction else { return }
        if recording {
            title = "Type shortcut…"
        } else {
            title = HotKeyCenter.shared.shortcut(for: action)?.displayString ?? "Record Shortcut"
        }
    }

    @objc private func clicked() {
        recording ? stop() : start()
    }

    private func start() {
        recording = true
        HotKeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.recording else { return event }
            self.handle(event)
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        HotKeyCenter.shared.registerAll()
    }

    private func handle(_ event: NSEvent) {
        guard let action = hotKeyAction else { return }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53 { stop(); return }  // Esc cancels
        if (event.keyCode == 51 || event.keyCode == 117) && flags.isEmpty {  // ⌫ clears
            stop()
            HotKeyCenter.shared.setShortcut(nil, for: action)
            refresh()
            return
        }
        // Require at least one modifier (or a function key) so global hotkeys don't eat typing.
        let isFunctionKey = (96...122).contains(Int(event.keyCode))
        guard !flags.subtracting(.shift).isEmpty || isFunctionKey else { NSSound.beep(); return }
        let sc = Shortcut(keyCode: UInt32(event.keyCode), modifiers: flags.rawValue)
        stop()
        HotKeyCenter.shared.setShortcut(sc, for: action)
        refresh()
    }
}

// MARK: - Advanced

private struct AdvancedPane: View {
    @State private var escCopies = AppSettings.shared.escCopies
    @State private var escSaves = AppSettings.shared.escSaves
    @State private var downscale = AppSettings.shared.downscaleRetina
    @State private var colorFormat = AppSettings.shared.colorFormat
    @State private var ocrNoBreaks = AppSettings.shared.ocrRemoveLineBreaks
    @State private var windowShadow = AppSettings.shared.windowShadow
    @State private var jpegQuality = AppSettings.shared.jpegQuality
    @State private var scrollStep = AppSettings.shared.scrollingStep
    @State private var scrollReverse = AppSettings.shared.scrollingReverse
    @State private var scrollMax = Double(AppSettings.shared.scrollingMaxHeight)

    var body: some View {
        Form {
            Section("Editor") {
                Toggle("Esc copies the image before closing", isOn: $escCopies)
                    .onChange(of: escCopies) { _, v in AppSettings.shared.escCopies = v }
                Toggle("Esc saves the image before closing", isOn: $escSaves)
                    .onChange(of: escSaves) { _, v in AppSettings.shared.escSaves = v }
                Picker("Color format", selection: $colorFormat) {
                    ForEach(ColorFormat.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: colorFormat) { _, v in AppSettings.shared.colorFormat = v }
            }
            Section("Output") {
                Toggle("Downscale Retina screenshots to 1×", isOn: $downscale)
                    .onChange(of: downscale) { _, v in AppSettings.shared.downscaleRetina = v }
                Toggle("Include window shadow in window captures (can soften the image)", isOn: $windowShadow)
                    .onChange(of: windowShadow) { _, v in AppSettings.shared.windowShadow = v }
                HStack {
                    Text("JPEG quality")
                    Slider(value: $jpegQuality, in: 0.4...1, step: 0.05)
                        .onChange(of: jpegQuality) { _, v in AppSettings.shared.jpegQuality = v }
                    Text("\(Int(jpegQuality * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            Section("Scrolling capture") {
                HStack {
                    Text("Scroll step")
                    Slider(value: $scrollStep, in: 0.25...0.8, step: 0.05)
                        .onChange(of: scrollStep) { _, v in AppSettings.shared.scrollingStep = v }
                    Text("\(Int(scrollStep * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                HStack {
                    Text("Height limit")
                    Slider(value: $scrollMax, in: 3000...30000, step: 1000)
                        .onChange(of: scrollMax) { _, v in AppSettings.shared.scrollingMaxHeight = Int(v) }
                    Text("\(Int(scrollMax)) px").monospacedDigit().frame(width: 70, alignment: .trailing)
                }
                Toggle("Reverse auto-scroll direction", isOn: $scrollReverse)
                    .onChange(of: scrollReverse) { _, v in AppSettings.shared.scrollingReverse = v }
                Text("Auto-scroll needs Accessibility permission; Manual Scrolling Capture does not.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Text recognition") {
                Toggle("Join recognized lines (remove line breaks)", isOn: $ocrNoBreaks)
                    .onChange(of: ocrNoBreaks) { _, v in AppSettings.shared.ocrRemoveLineBreaks = v }
            }
            Section("Deep links") {
                Text("shotit://grab/fullscreen · area · repeat · window · window/any · delayed · ocr\nAppend ?then=copy,save,edit,pin,preview to override the after-capture behaviour.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Reset All Settings") {
                    AppSettings.shared.reset()
                    HotKeyCenter.shared.resetToDefaults()
                }
            }
        }
        .formStyle(.grouped)
    }
}
