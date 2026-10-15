import AppKit

enum AfterCapture: String, CaseIterable, Identifiable {
    case preview, editor, nothing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .preview: return "Show thumbnail preview"
        case .editor: return "Open in editor"
        case .nothing: return "Do nothing"
        }
    }
}

enum ImageFormat: String, CaseIterable, Identifiable {
    case png, jpeg
    var id: String { rawValue }
    var fileExtension: String { self == .png ? "png" : "jpg" }
}

enum ColorFormat: String, CaseIterable, Identifiable {
    case hex, rgb, rgba, hsl, swiftUI, cssRGB
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hex: return "HEX  #FFC200"
        case .rgb: return "RGB  255, 194, 0"
        case .rgba: return "RGBA 1.00, 0.76, 0.00, 1.00"
        case .hsl: return "HSL  hsl(46, 100%, 50%)"
        case .swiftUI: return "SwiftUI  Color(red:…)"
        case .cssRGB: return "CSS  rgb(255 194 0)"
        }
    }
}

/// UserDefaults-backed settings. Keys are namespaced to avoid collisions.
final class AppSettings {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "afterFullscreen": AfterCapture.preview.rawValue,
            "afterArea": AfterCapture.editor.rawValue,
            "afterWindow": AfterCapture.preview.rawValue,
            "copyAfterCapture": true,
            "saveAfterCapture": false,
            "imageFormat": ImageFormat.png.rawValue,
            "jpegQuality": 0.9,
            "downscaleRetina": false,
            "previewSeconds": 6.0,
            "escCopies": true,
            "escSaves": false,
            "colorFormat": ColorFormat.hex.rawValue,
            "ocrRemoveLineBreaks": false,
            "playSound": true,
            "windowShadow": false,
            "scrollingStep": 0.55,
            "scrollingReverse": false,
            "scrollingMaxHeight": 15000,
            "editorColor": "#E5383B",
            "editorSize": 4.0,
        ])
    }

    var afterFullscreen: AfterCapture {
        get { AfterCapture(rawValue: d.string(forKey: "afterFullscreen") ?? "") ?? .preview }
        set { d.set(newValue.rawValue, forKey: "afterFullscreen") }
    }
    var afterArea: AfterCapture {
        get { AfterCapture(rawValue: d.string(forKey: "afterArea") ?? "") ?? .editor }
        set { d.set(newValue.rawValue, forKey: "afterArea") }
    }
    var afterWindow: AfterCapture {
        get { AfterCapture(rawValue: d.string(forKey: "afterWindow") ?? "") ?? .preview }
        set { d.set(newValue.rawValue, forKey: "afterWindow") }
    }
    var copyAfterCapture: Bool {
        get { d.bool(forKey: "copyAfterCapture") }
        set { d.set(newValue, forKey: "copyAfterCapture") }
    }
    var saveAfterCapture: Bool {
        get { d.bool(forKey: "saveAfterCapture") }
        set { d.set(newValue, forKey: "saveAfterCapture") }
    }
    var imageFormat: ImageFormat {
        get { ImageFormat(rawValue: d.string(forKey: "imageFormat") ?? "") ?? .png }
        set { d.set(newValue.rawValue, forKey: "imageFormat") }
    }
    var jpegQuality: Double {
        get { d.double(forKey: "jpegQuality") }
        set { d.set(newValue, forKey: "jpegQuality") }
    }
    var downscaleRetina: Bool {
        get { d.bool(forKey: "downscaleRetina") }
        set { d.set(newValue, forKey: "downscaleRetina") }
    }
    var previewSeconds: Double {
        get { d.double(forKey: "previewSeconds") }
        set { d.set(newValue, forKey: "previewSeconds") }
    }
    var escCopies: Bool {
        get { d.bool(forKey: "escCopies") }
        set { d.set(newValue, forKey: "escCopies") }
    }
    var escSaves: Bool {
        get { d.bool(forKey: "escSaves") }
        set { d.set(newValue, forKey: "escSaves") }
    }
    var colorFormat: ColorFormat {
        get { ColorFormat(rawValue: d.string(forKey: "colorFormat") ?? "") ?? .hex }
        set { d.set(newValue.rawValue, forKey: "colorFormat") }
    }
    var ocrRemoveLineBreaks: Bool {
        get { d.bool(forKey: "ocrRemoveLineBreaks") }
        set { d.set(newValue, forKey: "ocrRemoveLineBreaks") }
    }
    var playSound: Bool {
        get { d.bool(forKey: "playSound") }
        set { d.set(newValue, forKey: "playSound") }
    }
    var windowShadow: Bool {
        get { d.bool(forKey: "windowShadow") }
        set { d.set(newValue, forKey: "windowShadow") }
    }
    /// Fraction of the selected height scrolled per step in auto mode.
    var scrollingStep: Double {
        get { d.double(forKey: "scrollingStep") }
        set { d.set(newValue, forKey: "scrollingStep") }
    }
    /// Flip the direction of synthesized scroll events (some setups invert them).
    var scrollingReverse: Bool {
        get { d.bool(forKey: "scrollingReverse") }
        set { d.set(newValue, forKey: "scrollingReverse") }
    }
    /// Stop a scrolling capture when the stitched image reaches this many pixels.
    var scrollingMaxHeight: Int {
        get { max(1000, d.integer(forKey: "scrollingMaxHeight")) }
        set { d.set(newValue, forKey: "scrollingMaxHeight") }
    }
    var editorColorHex: String {
        get { d.string(forKey: "editorColor") ?? "#E5383B" }
        set { d.set(newValue, forKey: "editorColor") }
    }
    var editorSize: Double {
        get { d.double(forKey: "editorSize") }
        set { d.set(newValue, forKey: "editorSize") }
    }

    /// Folder for saved screenshots. Defaults to the Desktop.
    var saveFolder: URL {
        get {
            if let path = d.string(forKey: "saveFolder") { return URL(fileURLWithPath: path, isDirectory: true) }
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
        }
        set { d.set(newValue.path, forKey: "saveFolder") }
    }

    /// Last area capture, in global AppKit screen coordinates (bottom-left origin).
    var lastArea: CGRect? {
        get {
            guard let s = d.string(forKey: "lastArea") else { return nil }
            let r = NSRectFromString(s)
            return r.isEmpty ? nil : r
        }
        set { d.set(newValue.map { NSStringFromRect($0) }, forKey: "lastArea") }
    }

    func reset() {
        if let id = Bundle.main.bundleIdentifier { d.removePersistentDomain(forName: id) }
    }
}
