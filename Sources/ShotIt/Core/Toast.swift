import AppKit

/// Small HUD notification near the top of the active screen.
final class Toast {
    enum Style { case info, error }

    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ message: String, style: Style = .info, duration: TimeInterval = 2.2) {
        hideWork?.cancel()
        panel?.orderOut(nil)

        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.maximumNumberOfLines = 4
        label.preferredMaxLayoutWidth = 360

        let icon = NSImageView(image: NSImage(systemSymbolName: style == .error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                                              accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = style == .error ? .systemYellow : .systemGreen
        icon.symbolConfiguration = .init(pointSize: 16, weight: .semibold)

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 16)

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        let size = stack.fittingSize

        let p = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.markTransient()
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = effect

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            p.setFrameOrigin(CGPoint(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 24))
        }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        panel = p

        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 },
                                                 completionHandler: { p.orderOut(nil); if panel === p { panel = nil } })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}
