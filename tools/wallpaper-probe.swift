// swiftc tools/wallpaper-probe.swift -o build/wallpaper-probe && build/wallpaper-probe
import AppKit
import ImageIO
for (i, s) in NSScreen.screens.enumerated() {
    let url = NSWorkspace.shared.desktopImageURL(for: s)
    var isDir: ObjCBool = false
    let exists = url.map { FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) } ?? false
    print("screen \(i): \(url?.path ?? "nil") exists=\(exists) dir=\(isDir.boolValue)")
    if let url, exists, !isDir.boolValue, let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        print("  type=\(CGImageSourceGetType(src) as String? ?? "?") frames=\(CGImageSourceGetCount(src)) first=\(img.map { "\($0.width)x\($0.height)" } ?? "failed")")
    }
    print("  options: \(NSWorkspace.shared.desktopImageOptions(for: s) ?? [:])")
}
