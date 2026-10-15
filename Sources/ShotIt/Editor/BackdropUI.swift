import AppKit
import SwiftUI

/// Hosts the canvas and, when a backdrop is enabled, draws the background and shadow around it.
/// Mouse events still go straight to the canvas, so editing coordinates are unaffected.
final class BackdropContainerView: NSView {
    private let canvas: CanvasView
    private let doc: EditorDocument

    init(canvas: CanvasView, doc: EditorDocument) {
        self.canvas = canvas
        self.doc = doc
        super.init(frame: .zero)
        addSubview(canvas)
        canvas.wantsLayer = true
        relayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Resizes to the padded canvas (or the bare image) and positions the screenshot inside it.
    func relayout() {
        let style = doc.backdrop
        let size = doc.pointSize
        if style.enabled {
            let (canvasSize, origin) = BackdropRenderer.layout(content: size, style: style)
            setFrameSize(canvasSize)
            canvas.setFrameOrigin(origin)
        } else {
            setFrameSize(size)
            canvas.setFrameOrigin(.zero)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard doc.backdrop.enabled, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        BackdropRenderer.drawBackground(in: ctx, rect: bounds, style: doc.backdrop, content: doc.image, pixelScale: scale)
        BackdropRenderer.drawShadow(in: ctx, contentRect: canvas.frame, image: doc.image, style: doc.backdrop,
                                    tint: BackdropRenderer.shadowTint(style: doc.backdrop, content: doc.image))
    }
}

/// Backing model for the popover; every change is pushed straight to the document.
final class BackdropModel: ObservableObject {
    @Published var style: BackdropStyle { didSet { if style != oldValue { onChange(style) } } }
    let onChange: (BackdropStyle) -> Void

    init(style: BackdropStyle, onChange: @escaping (BackdropStyle) -> Void) {
        self.style = style
        self.onChange = onChange
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a background image"
        guard panel.runModal() == .OK, let url = panel.url, let shot = Exporter.loadImage(from: url) else { return }
        style.image = shot.image
        style.kind = .image
        style.enabled = true
    }

    func imageFromClipboard() {
        guard let shot = Exporter.imageFromClipboard() else {
            Toast.show("Make sure your clipboard contains an image and try again", style: .error)
            return
        }
        style.image = shot.image
        style.kind = .image
        style.enabled = true
    }
}

struct BackdropPanel: View {
    @ObservedObject var model: BackdropModel

    private func binding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(get: { Color(nsColor: NSColor(hex: hex.wrappedValue) ?? .gray) },
                set: { hex.wrappedValue = NSColor($0).hexString })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Backdrop", isOn: $model.style.enabled)
                .toggleStyle(.switch)
                .font(.headline)

            Group {
                Picker("Fill", selection: $model.style.kind) {
                    ForEach(BackdropStyle.Kind.allCases) { Text($0.title).tag($0) }
                }

                switch model.style.kind {
                case .wallpaper:
                    Text("Uses your current desktop picture automatically.").font(.caption).foregroundStyle(.secondary)
                case .auto:
                    Text("Colours are picked from your screenshot.").font(.caption).foregroundStyle(.secondary)
                case .gradient:
                    HStack {
                        ColorPicker("From", selection: binding($model.style.fromHex))
                        ColorPicker("To", selection: binding($model.style.toHex))
                        Button("Randomize") { model.style.randomize(); model.style.enabled = true }
                    }
                    slider("Angle", value: $model.style.angle, range: 0...360, unit: "°")
                case .solid:
                    ColorPicker("Colour", selection: binding($model.style.solidHex))
                case .image:
                    HStack {
                        Button("Choose Image…") { model.chooseImage() }
                        Button("From Clipboard") { model.imageFromClipboard() }
                    }
                    if model.style.image == nil {
                        Text("Pick an image to use as the background.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!model.style.enabled)

            Divider()

            Group {
                slider("Padding", value: $model.style.padding, range: 0...240, unit: " pt")
                slider("Shadow", value: Binding(get: { model.style.shadow * 100 }, set: { model.style.shadow = $0 / 100 }), range: 0...100, unit: "%")
                slider("Depth", value: Binding(get: { model.style.shadowDepth * 100 }, set: { model.style.shadowDepth = $0 / 100 }), range: 40...250, unit: "%")
                Picker("Aspect", selection: $model.style.aspect) {
                    ForEach(BackdropStyle.Aspect.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Grain", isOn: $model.style.noise)
            }
            .disabled(!model.style.enabled)
        }
        .padding(16)
        .frame(width: 300)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        HStack {
            Text(title).frame(width: 62, alignment: .leading)
            Slider(value: value, in: range)
            Text("\(Int(value.wrappedValue.rounded()))\(unit)").monospacedDigit().frame(width: 52, alignment: .trailing)
        }
    }
}
