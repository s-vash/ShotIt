import XCTest
import SwiftUI
@testable import ShotIt

final class BackdropTests: XCTestCase {
    /// A flat-coloured "screenshot" (pixels) at scale 2.
    private func solidImage(_ c: NSColor, w: Int = 400, h: Int = 300) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(c.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// A window-like capture: opaque colour with transparent rounded corners, like ScreenCaptureKit delivers.
    private func roundedWindowImage(_ c: NSColor, w: Int = 400, h: Int = 300, radius: CGFloat = 40) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(c.cgColor); ctx.fillPath()
        return ctx.makeImage()!
    }

    func testCanvasGrowsByPaddingOnEachSide() {
        var s = BackdropStyle(); s.padding = 40
        let (canvas, origin) = BackdropRenderer.layout(content: CGSize(width: 200, height: 150), style: s)
        XCTAssertEqual(canvas, CGSize(width: 280, height: 230))
        XCTAssertEqual(origin, CGPoint(x: 40, y: 40))
    }

    func testAspectRatioExpandsShortSideAndCentres() {
        var s = BackdropStyle(); s.padding = 20; s.aspect = .square
        let (canvas, origin) = BackdropRenderer.layout(content: CGSize(width: 300, height: 100), style: s)
        XCTAssertEqual(canvas.width, canvas.height)
        XCTAssertEqual(canvas.width, 340)
        XCTAssertEqual(origin.x, 20)
        XCTAssertEqual(origin.y, 120, "screenshot is centred vertically")
        s.aspect = .r16x9
        let wide = BackdropRenderer.layout(content: CGSize(width: 100, height: 300), style: s).canvas
        XCTAssertEqual(wide.width / wide.height, 16.0 / 9, accuracy: 0.01)
    }

    func testComposeKeepsScaleAndAddsPadding() throws {
        var s = BackdropStyle(); s.enabled = true; s.padding = 30; s.kind = .solid; s.solidHex = "#00FF00"; s.noise = false
        let out = try XCTUnwrap(BackdropRenderer.compose(content: solidImage(.red), scale: 2, style: s))
        XCTAssertEqual(out.width, 400 + 120)   // 2 * 30pt * scale 2
        XCTAssertEqual(out.height, 300 + 120)
        let px = PixelReader(image: out)
        XCTAssertEqual(px.color(x: 260, y: 210)?.hexString, "#FF0000", "centre is the screenshot")
        XCTAssertEqual(px.color(x: 2, y: 2)?.hexString, "#00FF00", "corner is the backdrop")
    }

    func testRoundedCornersShowBackdropAndShadowFallsBelow() throws {
        var s = BackdropStyle(); s.padding = 60; s.kind = .solid; s.solidHex = "#FFFFFF"; s.noise = false; s.shadow = 1
        let out = try XCTUnwrap(BackdropRenderer.compose(content: roundedWindowImage(.red), scale: 2, style: s))
        let px = PixelReader(image: out)
        let originPx = 120  // 60pt * 2
        // The very corner pixel of the screenshot is transparent in the capture, so the backdrop shows through.
        XCTAssertNotEqual(px.color(x: originPx + 1, y: originPx + 1)?.hexString, "#FF0000")
        // Shadow is darker directly below the screenshot than directly above it.
        let below = px.rgb(x: 260, y: originPx + 300 + 14)!, above = px.rgb(x: 260, y: originPx - 14)!
        XCTAssertLessThan(below.x, above.x - 5, "shadow should fall below the window (below \(below.x), above \(above.x))")
    }

    func testAutoColorsFollowTheScreenshot() throws {
        let red = try XCTUnwrap(BackdropRenderer.dominantColors(solidImage(NSColor(hex: "#D32F2F")!)).first)
        XCTAssertGreaterThan(red.srgb.redComponent, 0.6)
        XCTAssertLessThan(red.srgb.blueComponent, 0.4)
        var s = BackdropStyle(); s.kind = .auto
        let (a, b) = BackdropRenderer.colors(for: s, content: solidImage(NSColor(hex: "#1E88E5")!))
        XCTAssertGreaterThan(a.srgb.blueComponent, a.srgb.redComponent)
        XCTAssertGreaterThan(b.srgb.blueComponent, b.srgb.redComponent)
    }

    func testAutoFallsBackToDefaultForGreyScreenshots() {
        var s = BackdropStyle(); s.kind = .auto
        let (a, b) = BackdropRenderer.colors(for: s, content: solidImage(NSColor(white: 0.93, alpha: 1)))
        XCTAssertEqual(a.hexString, "#6A3DE8"); XCTAssertEqual(b.hexString, "#23D5C0")
    }

    func testDeeperShadowReachesFurtherAndLayersFallOffSmoothly() throws {
        func shade(depth: Double, below: Int) throws -> Float {
            var s = BackdropStyle(); s.padding = 200; s.kind = .solid; s.solidHex = "#FFFFFF"
            s.noise = false; s.shadow = 1; s.shadowDepth = depth
            let out = try XCTUnwrap(BackdropRenderer.compose(content: solidImage(.white, w: 400, h: 300), scale: 2, style: s))
            // content bottom edge is at pixel 400 + 300 = 700; sample `below` pixels under it, centred.
            return PixelReader(image: out).rgb(x: 400, y: 700 + below)!.x
        }
        // Further below the window, a deeper shadow is still darker than a shallow one.
        XCTAssertLessThan(try shade(depth: 2.0, below: 90), try shade(depth: 0.5, below: 90) - 5)
        // Falloff is monotonic: darkest next to the window, lightening with distance.
        let near = try shade(depth: 1, below: 6), mid = try shade(depth: 1, below: 60), far = try shade(depth: 1, below: 140)
        XCTAssertLessThan(near, mid); XCTAssertLessThan(mid, far)
        XCTAssertLessThan(near, 255 * 0.75, "contact shadow should darken white by at least 25% (got \(near))")
    }

    func testWallpaperFillUsesTheDesktopPicture() throws {
        guard let wall = WallpaperProvider.current() else { throw XCTSkip("no readable wallpaper on this machine") }
        XCTAssertLessThanOrEqual(max(wall.width, wall.height), 2880)
        var s = BackdropStyle(); s.kind = .wallpaper; s.padding = 80; s.noise = false; s.shadow = 0
        let out = try XCTUnwrap(BackdropRenderer.compose(content: solidImage(.black, w: 300, h: 200), scale: 1, style: s))
        let px = PixelReader(image: out)
        // The corner pixel comes from the picture, and different corners differ unless the picture is flat.
        let a = px.rgb(x: 4, y: 4)!, b = px.rgb(x: out.width - 5, y: out.height - 5)!
        XCTAssertGreaterThan(abs(a.x - b.x) + abs(a.y - b.y) + abs(a.z - b.z), 3, "wallpaper should vary across the canvas")
    }

    func testOlderSavedStylesStillDecode() throws {
        let old = #"{"enabled":true,"kind":"gradient","padding":70}"#.data(using: .utf8)!   // written before depth / wallpaper existed
        let s = try JSONDecoder().decode(BackdropStyle.self, from: old)
        XCTAssertTrue(s.enabled); XCTAssertEqual(s.kind, .gradient); XCTAssertEqual(s.padding, 70)
        XCTAssertEqual(s.shadowDepth, 1.0)
    }

    func testStylePersistsExceptImage() throws {
        var s = BackdropStyle(); s.enabled = true; s.padding = 99; s.kind = .gradient; s.image = solidImage(.blue)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(BackdropStyle.self, from: data)
        XCTAssertEqual(back.padding, 99); XCTAssertTrue(back.enabled); XCTAssertNil(back.image)
    }

    func testRandomizeProducesGradient() {
        var s = BackdropStyle(); let before = s.fromHex
        s.randomize()
        XCTAssertEqual(s.kind, .gradient)
        XCTAssertNotNil(NSColor(hex: s.fromHex)); XCTAssertNotNil(NSColor(hex: s.toHex))
        _ = before
    }

    func testWriteWallpaperAndShadowSamples() throws {
        // A light "window" with a title bar, so the shadow is easy to judge.
        let w = 520, h = 340
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor(white: 0.97, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(NSColor(white: 0.88, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: h - 36, width: w, height: 36))
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            ctx.setFillColor(c.cgColor); ctx.fillEllipse(in: CGRect(x: 14 + i * 22, y: h - 26, width: 14, height: 14))
        }
        let window = ctx.makeImage()!
        var wall = BackdropStyle(); wall.enabled = true; wall.kind = .wallpaper; wall.padding = 70
        var dark = BackdropStyle(); dark.enabled = true; dark.kind = .solid; dark.solidHex = "#14161F"; dark.padding = 70; dark.shadowDepth = 1.6
        for (name, style) in [("wallpaper", wall), ("dark", dark)] {
            let out = try XCTUnwrap(BackdropRenderer.compose(content: window, scale: 1, style: style))
            try Exporter.encode(out, scale: 1, format: .png)!.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("shotit-backdrop-\(name).png"))
        }
    }

    func testWriteBackdropSample() throws {
        let shot = ScrollStitcherTests.image(rows: ScrollStitcherTests.makeDocument(rows: 260))
        var s = BackdropStyle(); s.enabled = true; s.kind = .gradient; s.fromHex = "#6A3DE8"; s.toHex = "#23D5C0"; s.angle = 45
        let out = try XCTUnwrap(BackdropRenderer.compose(content: shot, scale: 1, style: s))
        try Exporter.encode(out, scale: 1, format: .png)!.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("shotit-backdrop.png"))
    }
}

@MainActor
final class BackdropEditorTests: XCTestCase {
    override func setUp() { BackdropStyle.persistenceEnabled = false }
    override func tearDown() { BackdropStyle.persistenceEnabled = true }

    private func shot() -> Screenshot {
        Screenshot(image: ScrollStitcherTests.image(rows: ScrollStitcherTests.makeDocument(rows: 200)), scale: 2)
    }

    func testExportIncludesBackdropOnlyWhenEnabled() {
        let doc = EditorDocument(screenshot: shot())
        let plain = doc.exported()
        XCTAssertEqual(plain.width, 160); XCTAssertEqual(plain.height, 200)
        doc.backdrop.enabled = true
        doc.backdrop.padding = 25
        let framed = doc.exported()
        XCTAssertEqual(framed.width, 160 + 100)   // 2 * 25pt * scale 2
        XCTAssertEqual(framed.height, 200 + 100)
    }

    func testEditorContainerPositionsCanvasInsideBackdrop() throws {
        let wc = EditorWindowController(screenshot: shot())
        defer { wc.close() }
        wc.doc.backdrop.enabled = true
        wc.doc.backdrop.padding = 30
        wc.doc.backdrop.aspect = .square
        let container = try XCTUnwrap(wc.window?.contentView?.firstSubview(ofType: BackdropContainerView.self))
        let expected = BackdropRenderer.layout(content: wc.doc.pointSize, style: wc.doc.backdrop)
        XCTAssertEqual(container.frame.size, expected.canvas)
        let canvas = try XCTUnwrap(container.subviews.first as? CanvasView)
        XCTAssertEqual(canvas.frame.origin, expected.origin)
        XCTAssertEqual(canvas.frame.size, wc.doc.pointSize, "annotation coordinates stay in image space")
        wc.doc.backdrop.enabled = false
        XCTAssertEqual(container.frame.size, wc.doc.pointSize)
        XCTAssertEqual(canvas.frame.origin, .zero)
    }

    func testWriteEditorAndPanelSnapshots() throws {
        let wc = EditorWindowController(screenshot: shot())
        defer { wc.close() }
        wc.doc.backdrop = { var s = BackdropStyle(); s.enabled = true; s.kind = .auto; s.padding = 40; return s }()
        wc.doc.state.annotations = [Annotation(kind: .rectangle, p1: CGPoint(x: 10, y: 10), p2: CGPoint(x: 60, y: 50), color: .systemRed, size: 3)]
        let window = try XCTUnwrap(wc.window); window.layoutIfNeeded()
        let view = try XCTUnwrap(window.contentView); view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: FileManager.default.temporaryDirectory.appendingPathComponent("shotit-editor-backdrop.png"))

        let model = BackdropModel(style: wc.doc.backdrop) { _ in }
        let host = NSHostingView(rootView: BackdropPanel(model: model))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let prep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: prep)
        try XCTUnwrap(prep.representation(using: .png, properties: [:])).write(to: FileManager.default.temporaryDirectory.appendingPathComponent("shotit-backdrop-panel.png"))
    }
}

private extension NSView {
    func firstSubview<T: NSView>(ofType: T.Type) -> T? {
        if let me = self as? T { return me }
        for v in subviews { if let f = v.firstSubview(ofType: T.self) { return f } }
        return nil
    }
}
