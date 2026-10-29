import Foundation
import CoreGraphics
// wmkey <keycode> [ctrl-opt] — post a keyDown/keyUp pair with modifiers, for the
// Ctrl+Option+Up / Ctrl+Option+Down resize hotkey.  keycode 126 = Up, 125 = Down.
let a = CommandLine.arguments
let kc = CGKeyCode(Int(a[1])!)
let mods: CGEventFlags = a.count > 2 && a[2] == "ctrl-opt"
    ? [.maskControl, .maskAlternate] : []
let src = CGEventSource(stateID: .hidSystemState)!
for down in [true, false] {
    let e = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: down)
    e?.flags = mods
    e?.post(tap: .cghidEventTap)
    usleep(40_000)
}
print("key \(kc) mods=\(mods.isEmpty ? "-" : "ctrl+opt")")
