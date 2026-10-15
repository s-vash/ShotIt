import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Clipboard / file output for screenshots.
enum Exporter {
    static func fileName(for date: Date, ext: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "ShotIt \(f.string(from: date)).\(ext)"
    }

    /// Applies the "downscale Retina screenshots" preference.
    static func outputImage(_ image: CGImage, scale: CGFloat) -> (CGImage, CGFloat) {
        guard AppSettings.shared.downscaleRetina, scale > 1 else { return (image, scale) }
        let w = Int(CGFloat(image.width) / scale), h = Int(CGFloat(image.height) / scale)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (image, scale) }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (ctx.makeImage() ?? image, 1)
    }

    static func encode(_ image: CGImage, scale: CGFloat, format: ImageFormat) -> Data? {
        let data = NSMutableData()
        let type = format == .png ? UTType.png : UTType.jpeg
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * scale
        var props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = AppSettings.shared.jpegQuality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func copy(_ image: CGImage, scale: CGFloat) {
        let (img, s) = outputImage(image, scale: scale)
        let pb = NSPasteboard.general
        pb.clearContents()
        let nsImage = NSImage(cgImage: img, size: CGSize(width: CGFloat(img.width) / s, height: CGFloat(img.height) / s))
        if let png = encode(img, scale: s, format: .png) {
            pb.declareTypes([.png, .tiff], owner: nil)
            pb.setData(png, forType: .png)
            if let tiff = nsImage.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        } else {
            pb.writeObjects([nsImage])
        }
    }

    /// Saves into the default folder and returns the file URL.
    @discardableResult
    static func save(_ image: CGImage, scale: CGFloat, date: Date = Date()) throws -> URL {
        let format = AppSettings.shared.imageFormat
        let folder = AppSettings.shared.saveFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent(fileName(for: date, ext: format.fileExtension))
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(fileName(for: date, ext: "\(n).\(format.fileExtension)"))
            n += 1
        }
        try write(image, scale: scale, to: url, format: format)
        return url
    }

    static func write(_ image: CGImage, scale: CGFloat, to url: URL, format: ImageFormat) throws {
        let (img, s) = outputImage(image, scale: scale)
        guard let data = encode(img, scale: s, format: format) else {
            throw NSError(domain: "ShotIt", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode image"])
        }
        try data.write(to: url, options: .atomic)
    }

    /// Shows a Save As panel. Calls back with the URL written, if any.
    static func saveAs(_ image: CGImage, scale: CGFloat, date: Date, window: NSWindow?, done: ((URL?) -> Void)? = nil) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.directoryURL = AppSettings.shared.saveFolder
        panel.nameFieldStringValue = fileName(for: date, ext: AppSettings.shared.imageFormat.fileExtension)
        panel.canCreateDirectories = true
        let handler: (NSApplication.ModalResponse) -> Void = { resp in
            guard resp == .OK, let url = panel.url else { done?(nil); return }
            let format: ImageFormat = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? .jpeg : .png
            do {
                try write(image, scale: scale, to: url, format: format)
                done?(url)
            } catch {
                Toast.show(error.localizedDescription, style: .error)
                done?(nil)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    static var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ShotIt", isDirectory: true)
    }

    /// Removes drag-out files older than `age` seconds. Screenshots themselves live in memory until saved.
    static func purgeTemporaryFiles(olderThan age: TimeInterval = 24 * 3600) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for f in files {
            let modified = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if Date().timeIntervalSince(modified) > age { try? fm.removeItem(at: f) }
        }
    }

    /// Writes a temporary file (used for drag-out). Lives in `temporaryDirectory`, purged at launch after a day.
    static func temporaryFile(_ image: CGImage, scale: CGFloat, date: Date) -> URL? {
        let dir = temporaryDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName(for: date, ext: AppSettings.shared.imageFormat.fileExtension))
        do {
            try write(image, scale: scale, to: url, format: AppSettings.shared.imageFormat)
            return url
        } catch {
            return nil
        }
    }

    static func loadImage(from url: URL) -> Screenshot? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? Double) ?? 72
        return Screenshot(image: img, scale: max(1, CGFloat(dpi / 72).rounded()), fileURL: url)
    }

    static func imageFromClipboard() -> Screenshot? {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL],
           let url = urls.first, let shot = loadImage(from: url) {
            return shot
        }
        guard let nsImage = NSImage(pasteboard: pb),
              let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = nsImage.size.width > 0 ? CGFloat(cg.width) / nsImage.size.width : 1
        return Screenshot(image: cg, scale: max(1, scale.rounded()))
    }
}
