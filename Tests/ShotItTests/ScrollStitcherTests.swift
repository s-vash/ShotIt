import XCTest
@testable import ShotIt

final class ScrollStitcherTests: XCTestCase {
    static let width = 160

    /// Deterministic "document": blocks of detailed rows separated by blank gaps, so there are both
    /// informative and blank rows. Each row is `width` gray values.
    static func makeDocument(rows: Int, seed: UInt64 = 7) -> [[UInt8]] {
        var state = seed
        func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 33 }
        var doc = [[UInt8]]()
        while doc.count < rows {
            let detailed = 10 + Int(next() % 12), blank = 6 + Int(next() % 10)
            for _ in 0..<detailed {
                var row = [UInt8](repeating: 235, count: width)
                var x = 0
                while x < width { let run = 2 + Int(next() % 6); let v: UInt8 = next() % 2 == 0 ? 20 : 235
                    for k in x..<min(width, x + run) { row[k] = v }; x += run }
                doc.append(row)
            }
            for _ in 0..<blank { doc.append([UInt8](repeating: 235, count: width)) }
        }
        return Array(doc.prefix(rows))
    }

    static func image(rows: [[UInt8]]) -> CGImage {
        let h = rows.count
        var bytes = [UInt8](repeating: 255, count: width * h * 4)
        for (y, row) in rows.enumerated() { for x in 0..<width { let o = (y * width + x) * 4
            bytes[o] = row[x]; bytes[o + 1] = row[x]; bytes[o + 2] = row[x] } }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func pattern(rows: Int, mulX: Int, mulY: Int, base: Int, mod: Int) -> [[UInt8]] {
        var out = [[UInt8]]()
        for y in 0..<rows {
            var row = [UInt8]()
            for x in 0..<width { row.append(UInt8((x * mulX + y * mulY) % mod + base)) }
            out.append(row)
        }
        return out
    }
    static let header: [[UInt8]] = pattern(rows: 40, mulX: 3, mulY: 5, base: 20, mod: 200)
    static let footer: [[UInt8]] = pattern(rows: 30, mulX: 7, mulY: 2, base: 40, mod: 180)

    /// A frame shows `viewport` document rows starting at `offset`, between an optional sticky header/footer.
    static func frame(doc: [[UInt8]], offset: Int, viewport: Int, sticky: Bool) -> CGImage {
        let body = Array(doc[offset..<offset + viewport])
        return image(rows: sticky ? header + body + footer : body)
    }

    private func gray(_ img: CGImage, _ x: Int, _ y: Int) -> Int { Int(PixelReader(image: img).rgb(x: x, y: y)!.x.rounded()) }

    private func assertImage(_ result: CGImage, equals expected: [[UInt8]], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.height, expected.count, "height", file: file, line: line)
        guard result.height == expected.count else { return }
        let reader = PixelReader(image: result)
        var bad = 0
        for y in 0..<expected.count { for x in stride(from: 3, to: Self.width, by: 37) {
            if abs(Int(reader.rgb(x: x, y: y)!.x.rounded()) - Int(expected[y][x])) > 3 { bad += 1 } } }
        XCTAssertEqual(bad, 0, "\(bad) mismatching samples", file: file, line: line)
    }

    func testScrollDownWithStickyHeaderAndFooter() throws {
        let doc = Self.makeDocument(rows: 2400)
        let viewport = 370
        let s = ScrollStitcher(direction: .down)
        var offsets = [Int](), off = 0
        while off + viewport <= doc.count { offsets.append(off); off += 160 }
        for o in offsets {
            let r = s.add(Self.frame(doc: doc, offset: o, viewport: viewport, sticky: true))
            if o == 0 { XCTAssertEqual(r, .added(viewport + 70)) } else { if case .added = r {} else { XCTFail("offset \(o): \(r)") } }
        }
        let last = offsets.last!
        let expected = Self.header + Array(doc[0..<last + viewport]) + Self.footer
        assertImage(try XCTUnwrap(s.finish()), equals: expected)
    }

    func testScrollUpWithStickyHeaderAndFooter() throws {
        let doc = Self.makeDocument(rows: 2400)
        let viewport = 370
        let s = ScrollStitcher(direction: .up)
        var off = 2400 - viewport
        var offsets = [Int]()
        while off >= 0 { offsets.append(off); off -= 140 }
        for o in offsets {
            let r = s.add(Self.frame(doc: doc, offset: o, viewport: viewport, sticky: true))
            if case .noMatch = r { XCTFail("offset \(o) no match") }
        }
        let first = offsets.last!
        let expected = Self.header + Array(doc[first..<2400]) + Self.footer
        assertImage(try XCTUnwrap(s.finish()), equals: expected)
    }

    func testScrollDownWithoutStickyEdges() throws {
        let doc = Self.makeDocument(rows: 1800)
        let s = ScrollStitcher(direction: .down)
        for o in stride(from: 0, through: 1400, by: 200) { s.add(Self.frame(doc: doc, offset: o, viewport: 400, sticky: false)) }
        assertImage(try XCTUnwrap(s.finish()), equals: Array(doc[0..<1800]))
    }

    func testIdenticalFrameReported() {
        let doc = Self.makeDocument(rows: 900)
        let s = ScrollStitcher(direction: .down)
        s.add(Self.frame(doc: doc, offset: 100, viewport: 400, sticky: false))
        XCTAssertEqual(s.add(Self.frame(doc: doc, offset: 100, viewport: 400, sticky: false)), .identical)
    }

    func testTooFarIsNoMatchAndStitchedStateSurvives() throws {
        let doc = Self.makeDocument(rows: 2000)
        let s = ScrollStitcher(direction: .down)
        s.add(Self.frame(doc: doc, offset: 0, viewport: 400, sticky: false))
        XCTAssertEqual(s.add(Self.frame(doc: doc, offset: 900, viewport: 400, sticky: false)), .noMatch)
        // Recovering with a frame that does overlap the last accepted one still works.
        if case .added(let n) = s.add(Self.frame(doc: doc, offset: 250, viewport: 400, sticky: false)) { XCTAssertEqual(n, 250) } else { XCTFail("expected added") }
        assertImage(try XCTUnwrap(s.finish()), equals: Array(doc[0..<650]))
    }

    func testBlankFrameDoesNotInventAShift() {
        let blank = Self.image(rows: [[UInt8]](repeating: [UInt8](repeating: 235, count: Self.width), count: 400))
        let s = ScrollStitcher(direction: .down)
        s.add(blank)
        XCTAssertEqual(s.add(blank), .identical)
    }

    func testRepeatingContentUsesHint() throws {
        // A perfectly periodic list: only the hint can tell the real shift (70) from 10/30/50.
        var seed: UInt64 = 99
        func rnd() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed >> 33 }
        var period = [[UInt8]]()
        for _ in 0..<20 {
            var row = [UInt8]()
            for _ in 0..<(Self.width / 4) { let v: UInt8 = rnd() % 2 == 0 ? 30 : 220; row += [v, v, v, v] }
            period.append(row)
        }
        var doc = [[UInt8]]()
        for i in 0..<1200 { doc.append(period[i % 20]) }
        let s = ScrollStitcher(direction: .down, hint: 70)
        s.add(Self.frame(doc: doc, offset: 0, viewport: 300, sticky: false))
        let r = s.add(Self.frame(doc: doc, offset: 70, viewport: 300, sticky: false))
        XCTAssertEqual(r, .added(70))
    }
}
