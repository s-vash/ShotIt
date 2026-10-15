import AppKit

/// Keeps a smaller document view centred inside a scroll view.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return r }
        let f = doc.frame
        if r.width > f.width { r.origin.x = f.midX - r.width / 2 }
        if r.height > f.height { r.origin.y = f.midY - r.height / 2 }
        return r
    }
}

/// Button that, when dragged, drags the screenshot as a file into other apps.
final class DragOutButton: NSButton, NSDraggingSource {
    /// Produces the file to drag (written lazily at drag start).
    var fileProvider: (() -> URL?)?
    var dragImage: (() -> NSImage?)?
    private var mouseDownEvent: NSEvent?

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        // Track ourselves so a plain click still fires the action.
        guard let window else { return }
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp {
                sendAction(action, to: target)
                break
            }
            let a = event.locationInWindow, b = next.locationInWindow
            if hypot(a.x - b.x, a.y - b.y) > 3 {
                startDrag(with: next)
                break
            }
        }
    }

    private func startDrag(with event: NSEvent) {
        guard let url = fileProvider?() else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let img = dragImage?() ?? NSWorkspace.shared.icon(forFile: url.path)
        let size = img.size.fitting(in: CGSize(width: 160, height: 160))
        let p = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height),
                              contents: img)
        beginDraggingSession(with: [item], event: mouseDownEvent ?? event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
}

extension CGSize {
    func fitting(in box: CGSize) -> CGSize {
        guard width > 0, height > 0 else { return box }
        let s = min(box.width / width, box.height / height, 1)
        return CGSize(width: width * s, height: height * s)
    }
}

func symbolButton(_ symbol: String, tooltip: String, target: AnyObject?, action: Selector?) -> NSButton {
    let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage(),
                     target: target, action: action)
    b.bezelStyle = .texturedRounded
    b.isBordered = true
    b.toolTip = tooltip
    b.setButtonType(.momentaryPushIn)
    return b
}
