import Cocoa
import Foundation
import ApplicationServices

// wmsize <cgid> <w> <h> — resize an AX window by CGWindowID, keeping its position.
// Used by `wmctl pulse`: a 1 px resize makes the WM re-lay the stage out, which is what
// re-emits every strip window's 4x4 (the keeper then applies the current scale/level).
@_silgen_name("_AXUIElementGetWindow") func _AXUIElementGetWindow(_ e: AXUIElement, _ w: UnsafeMutablePointer<UInt32>) -> AXError

setvbuf(stdout, nil, _IONBF, 0)

func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil
}

let a = CommandLine.arguments
guard a.count == 4, let want = UInt32(a[1]), let nw = Double(a[2]), let nh = Double(a[3]) else {
    print("usage: wmsize <cgid> <w> <h>"); exit(2)
}

for app in NSWorkspace.shared.runningApplications {
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    guard let wins = attr(ax, kAXWindowsAttribute) as? [AXUIElement] else { continue }
    for w in wins {
        var cg: UInt32 = 0
        _ = _AXUIElementGetWindow(w, &cg)
        if cg != want { continue }
        var sz = CGSize(width: nw, height: nh)
        let sv = AXValueCreate(.cgSize, &sz)!
        let e = AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv)
        var got = CGSize.zero
        if let v = attr(w, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &got) }
        print("resize cgid=\(cg) err=\(e.rawValue) now=\(Int(got.width))x\(Int(got.height))")
        exit(0)
    }
}
print("no ax window cgid=\(want)")
exit(3)
