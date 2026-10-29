import AppKit

/// The readout shown while a scale gesture is running.  The popover may be closed, so the number
/// has to appear next to the strip itself: a borderless, non-activating, click-through panel that
/// fades out when the gesture stops.
final class ScaleHUD {
    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideWork: DispatchWorkItem?

    func show(_ text: String) {
        let panel = ensurePanel()
        label?.stringValue = text
        position(panel)
        panel.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 132, height: 34),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 132, height: 34))
        container.wantsLayer = true
        container.layer?.cornerRadius = 9
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.86).cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor(calibratedWhite: 1.0, alpha: 0.12).cgColor

        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 8, y: 7, width: 116, height: 20)
        container.addSubview(label)
        panel.contentView = container

        self.panel = panel
        self.label = label
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame
        panel.setFrameOrigin(NSPoint(x: frame.minX + 336, y: frame.maxY - 96))
    }
}
