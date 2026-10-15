import XCTest
@testable import ShotIt

final class EditorTests: XCTestCase {
    /// 200×120 pt @2x image: white with a black 20 pt square at (20,20) (top-left origin).
    private func makeShot() -> Screenshot {
        let w = 400, h = 240
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(NSColor.black.cgColor)
        // CG is bottom-left: top-left (40,40) px → y = h - 40 - 40.
        ctx.fill(CGRect(x: 40, y: h - 80, width: 40, height: 40))
        return Screenshot(image: ctx.makeImage()!, scale: 2)
    }

    private func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> NSColor {
        PixelReader(image: img).color(x: x, y: y)!
    }

    func testPixelReaderUsesTopLeftOrigin() {
        let shot = makeShot()
        let r = PixelReader(image: shot.image)
        XCTAssertEqual(r.color(x: 50, y: 50)?.hexString, "#000000")
        XCTAssertEqual(r.color(x: 5, y: 5)?.hexString, "#FFFFFF")
        XCTAssertNil(r.color(x: 400, y: 0))
    }

    func testFlattenBurnsInFilledRectangle() {
        let doc = EditorDocument(screenshot: makeShot())
        var a = Annotation(kind: .rectangle, p1: CGPoint(x: 100, y: 60), p2: CGPoint(x: 160, y: 100),
                           color: NSColor(hex: "#FF0000")!, size: 4)
        a.style = 1
        doc.state.annotations = [a]
        let out = doc.flattened()
        XCTAssertEqual(out.width, 400)
        XCTAssertEqual(out.height, 240)
        // Centre of the rectangle (130,80 pt → 260,160 px) is red; outside stays white.
        XCTAssertEqual(pixel(out, 260, 160).hexString, "#FF0000")
        XCTAssertEqual(pixel(out, 10, 230).hexString, "#FFFFFF")
    }

    func testAllAnnotationKindsRender() throws {
        let doc = EditorDocument(screenshot: makeShot())
        let red = NSColor(hex: "#E5383B")!
        var anns: [Annotation] = [
            Annotation(kind: .arrow, p1: CGPoint(x: 10, y: 110), p2: CGPoint(x: 90, y: 60), color: red, size: 4),
            Annotation(kind: .rectangle, p1: CGPoint(x: 100, y: 10), p2: CGPoint(x: 140, y: 40), color: red, size: 3),
            Annotation(kind: .oval, p1: CGPoint(x: 150, y: 10), p2: CGPoint(x: 190, y: 40), color: red, size: 3),
            Annotation(kind: .line, p1: CGPoint(x: 100, y: 110), p2: CGPoint(x: 190, y: 110), color: red, size: 2),
            Annotation(kind: .blur, p1: CGPoint(x: 15, y: 15), p2: CGPoint(x: 45, y: 45), color: red, size: 3),
            Annotation(kind: .highlighter, p1: CGPoint(x: 100, y: 50), p2: CGPoint(x: 190, y: 60), color: .yellow, size: 3),
            Annotation(kind: .spotlight, p1: CGPoint(x: 100, y: 65), p2: CGPoint(x: 140, y: 100), color: red, size: 3),
            Annotation(kind: .magnifier, p1: CGPoint(x: 150, y: 65), p2: CGPoint(x: 190, y: 100), color: red, size: 3),
        ]
        var text = Annotation(kind: .text, p1: CGPoint(x: 50, y: 5), p2: .zero, color: red, size: 2)
        text.text = "Hi"
        var counter = Annotation(kind: .counter, p1: CGPoint(x: 60, y: 90), p2: .zero, color: red, size: 2)
        counter.number = 1
        var free = Annotation(kind: .freehand, p1: .zero, p2: .zero, color: red, size: 2)
        free.points = [CGPoint(x: 5, y: 60), CGPoint(x: 20, y: 70), CGPoint(x: 35, y: 60)]
        anns += [text, counter, free]
        doc.state.annotations = anns
        let out = doc.flattened()

        // Spotlight dims outside its rect: a white corner pixel becomes darker.
        let corner = pixel(out, 396, 236).srgb
        XCTAssertLessThan(corner.redComponent, 0.6)
        // Pixelated blur over the black square edge mixes colours: no longer exactly black/white at the boundary.
        XCTAssertEqual(out.width, 400)

        // Write for visual inspection.
        let dir = ProcessInfo.processInfo.environment["SHOTIT_TEST_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        try Exporter.encode(out, scale: 2, format: .png)!.write(to: dir.appendingPathComponent("shotit-render-test.png"))
    }

    func testBlurVariantsChangePixels() {
        for style in 0...2 {
            let doc = EditorDocument(screenshot: makeShot())
            var a = Annotation(kind: .blur, p1: CGPoint(x: 10, y: 10), p2: CGPoint(x: 50, y: 50), color: .red, size: 3)
            a.style = style
            doc.state.annotations = [a]
            let out = doc.flattened()
            // Inside the blur rect, pixels near the square's edge must differ from the original
            // (pixelate samples block centres, so check a band of pixels rather than one).
            let before = PixelReader(image: doc.image), after = PixelReader(image: out)
            let changed = (24..<96).contains { x in before.color(x: x, y: 50)?.hexString != after.color(x: x, y: 50)?.hexString }
            XCTAssertTrue(changed, "style \(style) left the region untouched")
            // Pixels outside the blur rect are untouched.
            XCTAssertEqual(pixel(out, 300, 200).hexString, "#FFFFFF")
        }
    }

    func testCropShiftsAnnotationsAndUndoRestores() {
        let doc = EditorDocument(screenshot: makeShot())
        doc.checkpoint()
        doc.state.annotations = [Annotation(kind: .line, p1: CGPoint(x: 50, y: 50), p2: CGPoint(x: 80, y: 60),
                                            color: .red, size: 2)]
        doc.crop(to: CGRect(x: 20, y: 20, width: 100, height: 50))
        XCTAssertEqual(doc.image.width, 200)
        XCTAssertEqual(doc.image.height, 100)
        XCTAssertEqual(doc.state.annotations[0].p1, CGPoint(x: 30, y: 30))
        // The cropped image starts with the black square at its top-left.
        XCTAssertEqual(doc.pixels.color(x: 5, y: 5)?.hexString, "#000000")

        doc.undo()
        XCTAssertEqual(doc.image.width, 400)
        XCTAssertEqual(doc.state.annotations[0].p1, CGPoint(x: 50, y: 50))
        doc.redo()
        XCTAssertEqual(doc.image.width, 200)
    }

    func testHitTesting() {
        let line = Annotation(kind: .line, p1: CGPoint(x: 0, y: 0), p2: CGPoint(x: 100, y: 0), color: .red, size: 2)
        XCTAssertTrue(line.hitTest(CGPoint(x: 50, y: 3), tolerance: 3))
        XCTAssertFalse(line.hitTest(CGPoint(x: 50, y: 20), tolerance: 3))

        let outline = Annotation(kind: .rectangle, p1: CGPoint(x: 0, y: 0), p2: CGPoint(x: 100, y: 100), color: .red, size: 2)
        XCTAssertTrue(outline.hitTest(CGPoint(x: 1, y: 50), tolerance: 3))
        XCTAssertFalse(outline.hitTest(CGPoint(x: 50, y: 50), tolerance: 3), "outline rect is hollow")

        var filled = outline
        filled.style = 1
        XCTAssertTrue(filled.hitTest(CGPoint(x: 50, y: 50), tolerance: 3))
    }

    func testColorFormats() {
        let c = NSColor(hex: "#FFC200")!
        XCTAssertEqual(c.formatted(.hex), "#FFC200")
        XCTAssertEqual(c.formatted(.rgb), "255, 194, 0")
        XCTAssertEqual(c.formatted(.cssRGB), "rgb(255 194 0)")
        XCTAssertEqual(c.formatted(.hsl), "hsl(46, 100%, 50%)")
    }

    func testExporterWritesRetinaDPI() throws {
        let shot = makeShot()
        let data = try XCTUnwrap(Exporter.encode(shot.image, scale: 2, format: .png))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyDPIWidth] as? Double, 144)
    }

    func testCounterNumbersIncrement() {
        let doc = EditorDocument(screenshot: makeShot())
        XCTAssertEqual(doc.nextCounterNumber, 1)
        var c = Annotation(kind: .counter, p1: .zero, p2: .zero, color: .red, size: 2)
        c.number = 1
        doc.state.annotations = [c]
        XCTAssertEqual(doc.nextCounterNumber, 2)
    }

    func testScreenFrameCropConvertsCoordinates() throws {
        // Cropping uses AppKit global coords (bottom-left) → pixel coords (top-left).
        let shot = makeShot()
        guard let screen = NSScreen.screens.first else { throw XCTSkip("no screen") }
        let frame = ScreenFrame(screen: screen, image: shot.image, scale: 2)
        let sf = screen.frame
        // Select the top-left 40×40 pt region of the screen (contains the black square at 20..40 pt).
        let rect = CGRect(x: sf.minX, y: sf.maxY - 40, width: 40, height: 40)
        let img = try XCTUnwrap(frame.crop(rect))
        XCTAssertEqual(img.width, 80)
        XCTAssertEqual(PixelReader(image: img).color(x: 60, y: 60)?.hexString, "#000000")
        XCTAssertEqual(PixelReader(image: img).color(x: 10, y: 10)?.hexString, "#FFFFFF")
    }
}

final class EditorSnapshotTests: XCTestCase {
    /// Renders the editor and preview UI offscreen and writes PNGs for visual review (no screen capture needed).
    func testEditorWindowSnapshot() throws {
        let w = 1200, h = 700
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [NSColor.systemTeal.cgColor, NSColor.systemIndigo.cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: w, y: h), options: [])
        let shot = Screenshot(image: ctx.makeImage()!, scale: 2)

        let wc = EditorWindowController(screenshot: shot)
        let red = NSColor(hex: "#E5383B")!
        var text = Annotation(kind: .text, p1: CGPoint(x: 330, y: 40), p2: .zero, color: red, size: 4)
        text.text = "ShotIt"
        text.style = 1
        var counter = Annotation(kind: .counter, p1: CGPoint(x: 80, y: 260), p2: .zero, color: red, size: 4)
        counter.number = 1
        wc.doc.state.annotations = [
            Annotation(kind: .arrow, p1: CGPoint(x: 80, y: 300), p2: CGPoint(x: 260, y: 160), color: red, size: 5),
            Annotation(kind: .rectangle, p1: CGPoint(x: 280, y: 120), p2: CGPoint(x: 520, y: 220), color: .systemYellow, size: 4),
            text, counter,
        ]
        let window = try XCTUnwrap(wc.window)
        window.layoutIfNeeded()
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("shotit-editor-snapshot.png"))
        XCTAssertGreaterThan(rep.pixelsWide, 800)
        window.close()
    }
}

final class HotKeyDefaultsTests: XCTestCase {
    func testDefaultHotkeys() {
        XCTAssertEqual(HotKeyAction.fullscreen.defaultShortcut?.displayString, "⇧⌘1")
        XCTAssertEqual(HotKeyAction.area.defaultShortcut?.displayString, "⇧⌘2")
        XCTAssertEqual(HotKeyAction.ocr.defaultShortcut?.displayString, "⌃⌥⌘O")
        for a in [HotKeyAction.repeatArea, .window, .windowPick, .scrolling, .scrollingUp, .scrollingManual, .reopen, .delayed, .pinClipboard] {
            XCTAssertNil(a.defaultShortcut, "\(a) should have no default")
        }
    }
}
