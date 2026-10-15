import XCTest
@testable import ShotIt

@MainActor
final class RegressionTests: XCTestCase {
    private func gradientShot(width: Int = 600, height: Int = 400, scale: CGFloat = 2) -> Screenshot {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [NSColor(srgbRed: 0.1, green: 0.2, blue: 0.9, alpha: 1).cgColor,
                                    NSColor(srgbRed: 0.9, green: 0.8, blue: 0.1, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: width, y: 0), options: [])
        return Screenshot(image: ctx.makeImage()!, scale: scale)
    }

    func testPreviewPanelEndsUpOnScreen() throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("no screen") }
        PreviewPanel.show(gradientShot())
        let panel = try XCTUnwrap(PreviewPanel.current)
        // Wait for the slide-in to finish rather than assuming a fixed delay.
        // Count iterations, not wall time: a slow first launch of a fresh build can stall the run loop for minutes.
        var ticks = 0
        while !screen.visibleFrame.insetBy(dx: -1, dy: -1).contains(panel.frame), ticks < 200 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            ticks += 1
        }
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.frame.insetBy(dx: -60, dy: -60).contains(NSEvent.mouseLocation),
                      "panel \(panel.frame) is not next to the pointer \(NSEvent.mouseLocation)")
        XCTAssertTrue(screen.visibleFrame.insetBy(dx: -1, dy: -1).contains(panel.frame),
                      "panel \(panel.frame) not inside visible frame \(screen.visibleFrame)")
        PreviewPanel.dismissCurrent()
    }

    func testSecondEditorOpensWhileFirstIsOpen() throws {
        let first = EditorWindowController.open(gradientShot())
        defer { first.close() }
        XCTAssertTrue(first.window?.isVisible ?? false)
        CaptureCoordinator.shared.deliver(gradientShot(), mode: .editor)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(EditorWindowController.open.count, 2)
        let second = try XCTUnwrap(EditorWindowController.open.last)
        defer { second.close() }
        XCTAssertTrue(second.window?.isVisible ?? false, "second editor not visible")
        XCTAssertNotEqual(second.window?.frame, first.window?.frame, "second editor sits exactly on top of the first")
    }

    func testEraseReproducesGradientBehindObject() throws {
        let shot = gradientShot()
        let doc = EditorDocument(screenshot: shot)
        // Pretend there is text: scribble a black block into the pixels, then erase over it.
        let ctx = CGContext(data: nil, width: shot.image.width, height: shot.image.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(shot.image, in: CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height))
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 320, y: 150, width: 240, height: 60))
        let dirty = Screenshot(image: ctx.makeImage()!, scale: 2)
        let dirtyDoc = EditorDocument(screenshot: dirty)
        var a = Annotation(kind: .blur, p1: CGPoint(x: 140, y: 80), p2: CGPoint(x: 290, y: 130), color: .red, size: 3)
        a.style = 2
        dirtyDoc.state.annotations = [a]
        let out = PixelReader(image: dirtyDoc.flattened())
        let clean = PixelReader(image: doc.image)
        // Compare several points inside the erased rect (pixels = points * 2) to the clean gradient.
        var worst: CGFloat = 0
        for (x, y) in [(330, 200), (400, 200), (500, 200), (550, 220), (450, 240)] {
            let o = out.color(x: x, y: y)!.srgb, c = clean.color(x: x, y: y)!.srgb
            worst = max(worst, abs(o.redComponent - c.redComponent), abs(o.blueComponent - c.blueComponent))
        }
        XCTAssertLessThan(worst, 0.08, "erase should continue the gradient, worst channel error \(worst)")
    }
}

@MainActor
final class EraseVisualTests: XCTestCase {
    func testWriteEraseComparison() throws {
        let w = 900, h = 300
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [NSColor(srgbRed: 0.1, green: 0.4, blue: 0.8, alpha: 1).cgColor,
                                    NSColor(srgbRed: 0.9, green: 0.5, blue: 0.2, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
        // Fine noise so we can see whether the erased area keeps the background's texture.
        var seed: UInt64 = 5
        if let data = ctx.data?.assumingMemoryBound(to: UInt8.self) {
            let bpr = ctx.bytesPerRow
            for y in 0..<h { for x in 0..<w {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let toward: Float = (seed >> 33) % 2 == 0 ? 255 : 0  // blend 6% towards white or black
                let o = y * bpr + x * 4
                for c in 0..<3 { data[o + c] = UInt8(Float(data[o + c]) * 0.94 + toward * 0.06) }
            } }
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ("Secret: 4111 1111 1111 1111" as NSString).draw(at: CGPoint(x: 40, y: 180),
            withAttributes: [.font: NSFont.systemFont(ofSize: 44, weight: .bold), .foregroundColor: NSColor.white])
        ("Keep this line untouched" as NSString).draw(at: CGPoint(x: 40, y: 60),
            withAttributes: [.font: NSFont.systemFont(ofSize: 36), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let shot = Screenshot(image: ctx.makeImage()!, scale: 1)
        let doc = EditorDocument(screenshot: shot)
        // top-left coords: first text row is near y=70..120
        var a = Annotation(kind: .blur, p1: CGPoint(x: 20, y: 60), p2: CGPoint(x: 880, y: 130), color: .red, size: 3)
        a.style = 2
        doc.state.annotations = [a]
        // Separate document: the renderer caches erase results, so reusing `doc` would return the mask-less result.
        let rawDoc = EditorDocument(screenshot: shot)
        rawDoc.state.annotations = doc.state.annotations
        AnnotationRenderer.disableObjectMask = true
        let raw = PixelReader(image: rawDoc.flattened())
        AnnotationRenderer.disableObjectMask = false
        let out = doc.flattened()
        let pr = PixelReader(image: shot.image), po = PixelReader(image: out)
        var probe = ""
        for (x, y) in [(48, 100), (60, 98), (100, 95), (300, 100), (700, 100), (50, 70), (50, 125)] {
            let a = pr.rgb(x: x, y: y)!, b = po.rgb(x: x, y: y)!
            let r = raw.rgb(x: x, y: y)!
            probe += "(\(x),\(y)) orig=\(Int(a.x)),\(Int(a.y)),\(Int(a.z)) out=\(Int(b.x)),\(Int(b.y)),\(Int(b.z)) tfi=\(Int(r.x)),\(Int(r.y)),\(Int(r.z)); "
        }
        NSLog("SHOTIT-PROBE %@", probe)
        var col = ""
        for y in [56, 57, 58, 59, 60, 61, 70, 100, 129, 130, 131, 132, 133] {
            col += "y\(y): o=\(Int(pr.rgb(x: 50, y: y)!.x)) t=\(Int(raw.rgb(x: 50, y: y)!.x)); "
        }
        NSLog("SHOTIT-COL %@", col)
        // Away from the text (x 600..850), the erased band must be pixel-identical to the original: only objects change.
        var same = 0, total = 0
        for y in 65..<125 { for x in 600..<850 {
            total += 1
            let a = pr.rgb(x: x, y: y)!, b = po.rgb(x: x, y: y)!
            if abs(a.x - b.x) < 1.5, abs(a.y - b.y) < 1.5, abs(a.z - b.z) < 1.5 { same += 1 }
        } }
        NSLog("SHOTIT-SAME %d of %d unchanged", same, total)
        XCTAssertGreaterThan(Double(same) / Double(total), 0.97, "background away from the text should be untouched")
        // Inside the text (x 40..570) the white glyph pixels must be gone.
        var white = 0
        for y in 65..<125 { for x in 40..<570 { let b = po.rgb(x: x, y: y)!; if b.x > 200, b.y > 200, b.z > 200 { white += 1 } } }
        XCTAssertLessThan(white, 20, "text pixels left behind: \(white)")
        // side by side: before | after
        let both = CGContext(data: nil, width: w, height: h * 2 + 10, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        both.draw(shot.image, in: CGRect(x: 0, y: h + 10, width: w, height: h))
        both.draw(out, in: CGRect(x: 0, y: 0, width: w, height: h))
        let data = try XCTUnwrap(Exporter.encode(both.makeImage()!, scale: 1, format: .png))
        try data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("shotit-erase-compare.png"))
    }
}

@MainActor
final class PreferencesSnapshotTests: XCTestCase {
    func testPreferencesRenderNonEmpty() throws {
        let wc = PreferencesWindowController()
        let window = try XCTUnwrap(wc.window)
        window.layoutIfNeeded()
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        NSLog("SHOTIT prefs content size: %@", NSStringFromSize(view.frame.size))
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: FileManager.default.temporaryDirectory.appendingPathComponent("shotit-prefs.png"))
        XCTAssertGreaterThan(view.frame.height, 250, "settings window collapsed to \(view.frame.size)")
        window.close()
    }
}


final class PreviewPlacementTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 0, width: 1920, height: 1050)
    private let size = CGSize(width: 296, height: 203)

    func testPlacedBelowRightOfPointer() {
        let f = PreviewPanel.frame(near: CGPoint(x: 600, y: 700), size: size, in: visible)
        XCTAssertEqual(f.minX, 620); XCTAssertEqual(f.maxY, 680)
    }
    func testFlipsLeftNearRightEdge() {
        let f = PreviewPanel.frame(near: CGPoint(x: 1850, y: 700), size: size, in: visible)
        XCTAssertLessThan(f.maxX, 1850)
        XCTAssertTrue(visible.contains(f))
    }
    func testFlipsAboveNearBottomEdge() {
        let f = PreviewPanel.frame(near: CGPoint(x: 600, y: 60), size: size, in: visible)
        XCTAssertGreaterThan(f.minY, 60)
        XCTAssertTrue(visible.contains(f))
    }
    func testCornerStaysOnScreen() {
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 1919, y: 0), CGPoint(x: 0, y: 1049), CGPoint(x: 1919, y: 1049)] {
            XCTAssertTrue(visible.contains(PreviewPanel.frame(near: p, size: size, in: visible)), "\(p)")
        }
    }
}

final class AppIconTests: XCTestCase {
    func testAppIconLoadsFromAssetCatalog() {
        let icon = NSImage(named: "AppIcon")
        XCTAssertNotNil(icon, "AppIcon missing from the asset catalog")
        XCTAssertGreaterThanOrEqual(icon?.representations.map(\.pixelsWide).max() ?? 0, 512)
    }
}

final class TextOnlyBlurTests: XCTestCase {
    /// White image with a line of black text ("Hello world") in the top half and a black block in the bottom half.
    private func textShot() -> Screenshot {
        let w = 600, h = 300
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ("Hello world, this is some text" as NSString).draw(at: CGPoint(x: 20, y: 200),
            withAttributes: [.font: NSFont.systemFont(ofSize: 36), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        ctx.setFillColor(NSColor.black.cgColor); ctx.fill(CGRect(x: 20, y: 20, width: 200, height: 80))
        return Screenshot(image: ctx.makeImage()!, scale: 1)
    }

    private func flattened(style: Int) -> PixelReader {
        let doc = EditorDocument(screenshot: textShot())
        var a = Annotation(kind: .blur, p1: .zero, p2: CGPoint(x: 600, y: 300), color: .red, size: 3)
        a.style = style
        doc.state.annotations = [a]
        return PixelReader(image: doc.flattened())
    }

    func testBlurTextLeavesNonTextAreasUntouched() {
        let original = PixelReader(image: textShot().image)
        let out = flattened(style: 3)
        // The black block (not text) keeps its exact pixels; the text line changed.
        XCTAssertEqual(out.color(x: 100, y: 240)?.hexString, original.color(x: 100, y: 240)?.hexString)
        var changed = 0
        for x in stride(from: 20, to: 400, by: 2) {
            for y in 40...110 where out.color(x: x, y: y)?.hexString != original.color(x: x, y: y)?.hexString { changed += 1 }
        }
        XCTAssertGreaterThan(changed, 50, "text should have been blurred")
    }

    func testEraseTextRemovesGlyphsButKeepsBlock() {
        let out = flattened(style: 4)
        XCTAssertEqual(out.color(x: 100, y: 240)?.hexString, "#000000", "non-text block must stay")
        var dark = 0
        for x in 20..<400 { for y in 40...110 { if let c = out.rgb(x: x, y: y), c.x < 100 { dark += 1 } } }
        XCTAssertLessThan(dark, 20, "glyphs should be erased (\(dark) dark pixels left)")
    }
}
