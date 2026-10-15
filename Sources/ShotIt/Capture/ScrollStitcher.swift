import CoreGraphics
import Foundation

/// Stitches successive frames of a scrolling region into one tall image.
///
/// Each new frame is aligned to the previous one by finding the vertical shift `d` for which the
/// frames overlap. Only rows with real detail ("informative" rows) vote, so blank areas can't
/// cause false matches, and rows that don't move (sticky headers/footers) simply don't vote for the true
/// shift. A sticky footer (header when scrolling up) is detected on the first pair, cut out of every
/// strip, and re-attached once at the end so it appears exactly once.
final class ScrollStitcher {
    enum Direction { case down, up }

    enum Outcome: Equatable {
        /// New rows were appended (0 when the new content is hidden behind a sticky edge).
        case added(Int)
        /// Frame is the same as the previous one: scrolling has stopped or reached the end.
        case identical
        /// Frames don't overlap enough to align (scrolled too far, or content changed).
        case noMatch
    }

    let direction: Direction
    /// Expected scroll step in pixels; used to disambiguate repeating content.
    var hint: Int?

    private(set) var totalHeight = 0
    private(set) var frameCount = 0

    private var strips: [CGImage] = []
    private var prev: Features?
    private var prevImage: CGImage?
    private var sticky = 0
    private var stickyKnown = false
    private var width = 0

    init(direction: Direction, hint: Int? = nil) {
        self.direction = direction
        self.hint = hint
    }

    // MARK: - Features

    struct Features {
        static let columns = 64
        let height: Int
        let rows: [[UInt8]]
        let informative: [Bool]

        init?(_ image: CGImage) {
            let h = image.height
            guard h > 0, image.width > 0 else { return nil }
            let cols = Features.columns
            var buffer = [UInt8](repeating: 0, count: cols * h)
            let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(data: raw.baseAddress, width: cols, height: h, bitsPerComponent: 8,
                                          bytesPerRow: cols, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                ctx.interpolationQuality = .medium
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: cols, height: h))
                return true
            }
            guard ok else { return nil }
            height = h
            // The bitmap is stored top row first, matching the image's own top-down order.
            rows = (0..<h).map { Array(buffer[$0 * cols..<($0 + 1) * cols]) }
            informative = rows.map { r in (r.max() ?? 0) &- (r.min() ?? 0) >= 12 }
        }

        /// Features with rows in reverse order (used to treat "scroll up" as "scroll down").
        var flipped: Features { Features(height: height, rows: rows.reversed(), informative: informative.reversed()) }
        private init(height: Int, rows: [[UInt8]], informative: [Bool]) {
            self.height = height; self.rows = rows; self.informative = informative
        }
    }

    @inline(__always)
    private static func rowsEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        let limit = a.count * 3  // mean absolute difference <= 3
        var sum = 0
        for i in 0..<a.count {
            sum += abs(Int(a[i]) - Int(b[i]))
            if sum > limit { return false }
        }
        return true
    }

    static func looksIdentical(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height, let fa = Features(a), let fb = Features(b) else { return false }
        return identical(fa, fb)
    }

    private static func identical(_ a: Features, _ b: Features) -> Bool {
        guard a.height == b.height else { return false }
        var same = 0
        for y in 0..<a.height where rowsEqual(a.rows[y], b.rows[y]) { same += 1 }
        return Double(same) >= 0.985 * Double(a.height)
    }

    // MARK: - Alignment

    /// Finds `d` such that `next[y] ≈ prev[y + d]` (content moved up by `d` rows), for scrolling down.
    static func bestShift(prev: Features, next: Features, hint: Int?) -> Int? {
        let h = prev.height
        guard next.height == h else { return nil }
        let minOverlap = max(16, h / 6)
        guard h > minOverlap + 1 else { return nil }

        var results: [(d: Int, matched: Int, perfect: Bool)] = []
        var best = 0
        for d in 1...(h - minOverlap) {
            var informative = 0, matched = 0
            for y in 0..<(h - d) where next.informative[y] {
                informative += 1
                if rowsEqual(next.rows[y], prev.rows[y + d]) { matched += 1 }
            }
            guard informative >= 8, matched >= 8, Double(matched) >= 0.3 * Double(informative) else { continue }
            results.append((d, matched, Double(matched) >= 0.97 * Double(informative)))
            best = max(best, matched)
        }
        guard best > 0 else { return nil }
        // Several shifts that match perfectly means the content repeats; only the expected step can tell them apart.
        if let hint {
            let perfect = results.filter(\.perfect)
            if perfect.count > 1 { return perfect.min { abs($0.d - hint) < abs($1.d - hint) }?.d }
        }
        let near = results.filter { Double($0.matched) >= 0.9 * Double(best) }
        if let hint, near.count > 1 { return near.min { abs($0.d - hint) < abs($1.d - hint) }?.d }
        return near.max { $0.matched < $1.matched }?.d
    }

    /// Number of rows at the bottom that are identical in both frames and contain detail (sticky footer).
    private static func stickyRows(prev: Features, next: Features) -> Int {
        let h = prev.height
        var n = 0, informative = 0
        while n < h / 3, rowsEqual(prev.rows[h - 1 - n], next.rows[h - 1 - n]) {
            if next.informative[h - 1 - n] { informative += 1 }
            n += 1
        }
        // Only trailing rows up to the last informative one count as UI; blank padding belongs to the page.
        guard informative >= 2 else { return 0 }
        while n > 0, !next.informative[h - n] { n -= 1 }
        return n
    }

    // MARK: - Adding frames

    @discardableResult
    func add(_ image: CGImage) -> Outcome {
        guard var feat = Features(image) else { return .noMatch }
        guard let prevFeat = prev, let prevImage else {
            width = image.width
            strips = [image]
            totalHeight = image.height
            prev = feat
            self.prevImage = image
            frameCount = 1
            return .added(image.height)
        }
        guard image.width == width, image.height == prevFeat.height else { return .noMatch }

        if ScrollStitcher.identical(prevFeat, feat) { return .identical }

        let h = image.height
        var a = prevFeat
        if direction == .up { a = a.flipped; feat = feat.flipped }
        guard let d = ScrollStitcher.bestShift(prev: a, next: feat, hint: hint) else { return .noMatch }

        if !stickyKnown {
            stickyKnown = true
            sticky = ScrollStitcher.stickyRows(prev: a, next: feat)
            if sticky > 0 { trimFirstStrip(prevImage, edge: sticky) }
        }

        // New rows (real orientation) are the `d` rows at the leading edge of the content area, i.e. the area
        // between the sticky edges: just above a sticky footer when scrolling down, just below a sticky header when up.
        let range: Range<Int>
        switch direction {
        case .down: range = max(0, h - sticky - d)..<(h - sticky)
        case .up: range = sticky..<min(h, sticky + d)
        }
        hint = d
        prev = direction == .up ? feat.flipped : feat
        self.prevImage = image
        frameCount += 1
        guard !range.isEmpty, let strip = image.cropping(to: CGRect(x: 0, y: range.lowerBound, width: width, height: range.count)) else {
            return .added(0)
        }
        strips.append(strip)
        totalHeight += range.count
        return .added(range.count)
    }

    private func trimFirstStrip(_ first: CGImage, edge: Int) {
        let h = first.height
        let rect: CGRect
        switch direction {
        case .down: rect = CGRect(x: 0, y: 0, width: first.width, height: h - edge)
        case .up: rect = CGRect(x: 0, y: edge, width: first.width, height: h - edge)
        }
        if let trimmed = first.cropping(to: rect), !strips.isEmpty {
            totalHeight -= edge
            strips[0] = trimmed
        }
    }

    // MARK: - Result

    func finish() -> CGImage? {
        guard !strips.isEmpty, let last = prevImage else { return nil }
        var parts: [CGImage]
        switch direction {
        case .down:
            parts = strips
            if sticky > 0, let footer = last.cropping(to: CGRect(x: 0, y: last.height - sticky, width: width, height: sticky)) { parts.append(footer) }
        case .up:
            parts = strips.reversed()  // newest (top-most) content first
            if sticky > 0, let header = last.cropping(to: CGRect(x: 0, y: 0, width: width, height: sticky)) { parts.insert(header, at: 0) }
        }
        let total = parts.reduce(0) { $0 + $1.height }
        guard let ctx = CGContext(data: nil, width: width, height: total, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var y = total
        for p in parts {
            y -= p.height
            ctx.draw(p, in: CGRect(x: 0, y: y, width: width, height: p.height))
        }
        return ctx.makeImage()
    }
}
