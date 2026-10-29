import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var popover: NSPopover!
    private var timer: Timer?
    private let model = PilotModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = item.button {
            let img = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Sturgeon")
            img?.isTemplate = true
            b.image = img
            b.toolTip = "Sturgeon"
            b.target = self
            b.action = #selector(togglePopover)
        }

        popover = NSPopover()
        // .transient is the shipping behaviour (outside click dismisses).  `--pin` keeps it open
        // for the automated proof, where the terminal that drives AX would otherwise take focus.
        popover.behavior = CommandLine.arguments.contains("--pin") ? .applicationDefined : .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 392, height: 520)
        popover.contentViewController = NSHostingController(rootView: ContentView(model: model))

        model.refresh(doctor: true, stages: true)

        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.show() }
        }
    }

    @objc private func togglePopover() {
        popover.isShown ? close() : show()
    }

    private func show() {
        guard let b = item.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        model.refresh(doctor: false, stages: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.model.refresh()
        }
        if let t = timer { RunLoop.main.add(t, forMode: .common) }
    }

    private func close() {
        popover.performClose(nil)
        timer?.invalidate()
        timer = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

if CommandLine.arguments.contains("--print-paths") {
    let d: [String: Any] = [
        "root": Paths.root?.path ?? "",
        "bundled": Paths.isBundled,
        "bundle_resources": Bundle.main.resourceURL?.path ?? "",
        "wmship": Paths.wmship?.path ?? "",
        "install_py": Paths.installPy?.path ?? "",
        "stagepilot": Paths.stagepilot?.path ?? "",
        "setup_sh": Paths.setupScript?.path ?? "",
    ]
    let data = try! JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
