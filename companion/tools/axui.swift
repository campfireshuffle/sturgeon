// axui — drive Sturgeon's own controls through the Accessibility tree (no mouse events).
//
//   axui <pid> tree [filter]          print every element with an AXIdentifier
//   axui <pid> get <identifier>       print role/value/title/enabled
//   axui <pid> press <identifier>     AXPress
//   axui <pid> set <identifier> <v>   AXUIElementSetAttributeValue(kAXValueAttribute)
//   axui <pid> inc <identifier> [n]   AXIncrement
//   axui <pid> dec <identifier> [n]   AXDecrement
//   axui <pid> menuitem <title>       press the menu item with that title (anywhere in the app)
//
// Built by work/companion/tools/build-tools.sh.  AX only: this is the inspection path the task
// allows (no synthetic clicks or drags anywhere).
import Cocoa
import ApplicationServices

setvbuf(stdout, nil, _IONBF, 0)

func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil
}
func str(_ e: AXUIElement, _ n: String) -> String {
    if let s = attr(e, n) as? String { return s }
    if let v = attr(e, n) { return String(describing: v) }
    return ""
}
func kids(_ e: AXUIElement) -> [AXUIElement] {
    (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func walk(_ e: AXUIElement, _ depth: Int = 0, _ out: inout [(AXUIElement, Int)]) {
    out.append((e, depth))
    if depth > 14 { return }
    for c in kids(e) { walk(c, depth + 1, &out) }
}

func find(_ e: AXUIElement, _ id: String, _ depth: Int = 0) -> AXUIElement? {
    if str(e, "AXIdentifier") == id { return e }
    if depth > 14 { return nil }
    for c in kids(e) { if let r = find(c, id, depth + 1) { return r } }
    return nil
}

func findByTitle(_ e: AXUIElement, _ title: String, _ depth: Int = 0) -> AXUIElement? {
    let role = str(e, kAXRoleAttribute)
    if str(e, kAXTitleAttribute) == title && (role == "AXMenuItem" || role == "AXButton") {
        return e
    }
    if depth > 14 { return nil }
    for c in kids(e) { if let r = findByTitle(c, title, depth + 1) { return r } }
    return nil
}

guard CommandLine.arguments.count >= 3, let pid = Int32(CommandLine.arguments[1]) else {
    print("usage: axui <pid> tree|get|press|set|inc|dec|menuitem ...")
    exit(2)
}
let app = AXUIElementCreateApplication(pid)
let cmd = CommandLine.arguments[2]

switch cmd {
case "tree":
    let filter = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : ""
    var all: [(AXUIElement, Int)] = []
    walk(app, 0, &all)
    for (e, d) in all {
        let id = str(e, "AXIdentifier")
        let role = str(e, kAXRoleAttribute)
        let title = str(e, kAXTitleAttribute)
        let value = str(e, kAXValueAttribute)
        let line = "\(String(repeating: "  ", count: min(d, 8)))[\(role)] id=\(id) title=\(title) value=\(value)"
        if filter.isEmpty || line.contains(filter) { print(line) }
    }
case "get", "press":
    let id = CommandLine.arguments[3]
    guard let e = find(app, id) else { print("not found: \(id)"); exit(3) }
    if cmd == "get" {
        var actions: CFArray?
        AXUIElementCopyActionNames(e, &actions)
        print("id=\(id) role=\(str(e, kAXRoleAttribute)) title=\(str(e, kAXTitleAttribute)) " +
              "value=\(str(e, kAXValueAttribute)) enabled=\(str(e, kAXEnabledAttribute)) " +
              "actions=\(actions as? [String] ?? [])")
    } else {
        let r = AXUIElementPerformAction(e, kAXPressAction as CFString)
        print("press \(id) -> \(r.rawValue)")
    }
case "set":
    let id = CommandLine.arguments[3]
    let v = CommandLine.arguments[4]
    guard let e = find(app, id) else { print("not found: \(id)"); exit(3) }
    let err = AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, v as CFTypeRef)
    print("set \(id)=\(v) -> \(err.rawValue)")
case "inc", "dec":
    let id = CommandLine.arguments[3]
    let n = CommandLine.arguments.count > 4 ? (Int(CommandLine.arguments[4]) ?? 1) : 1
    guard let e = find(app, id) else { print("not found: \(id)"); exit(3) }
    for _ in 0..<n {
        let r = AXUIElementPerformAction(e, (cmd == "inc" ? "AXIncrement" : "AXDecrement") as CFString)
        if r != .success { print("action -> \(r.rawValue)"); break }
    }
    print("\(cmd) \(id) x\(n) -> value=\(str(e, kAXValueAttribute))")
case "popover":
    var all: [(AXUIElement, Int)] = []
    walk(app, 0, &all)
    guard let pop = all.first(where: { str($0.0, kAXRoleAttribute) == "AXPopover" })?.0 else {
        print("no popover"); exit(3)
    }
    var pos = CGPoint.zero, size = CGSize.zero
    if let v = attr(pop, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &pos) }
    if let v = attr(pop, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &size) }
    print("\(Int(pos.x)) \(Int(pos.y)) \(Int(size.width)) \(Int(size.height))")
case "menuitem":
    let title = CommandLine.arguments[3]
    // menus live in their own AXWindow; search from every window, not just the popover
    var found: AXUIElement?
    if let wins = attr(app, kAXWindowsAttribute) as? [AXUIElement] {
        for w in wins { if let f = findByTitle(w, title) { found = f; break } }
    }
    if found == nil { found = findByTitle(app, title) }
    guard let e = found else { print("menu item not found: \(title)"); exit(3) }
    print("press \(title) -> \(AXUIElementPerformAction(e, kAXPressAction as CFString).rawValue)")
default:
    print("unknown command \(cmd)")
    exit(2)
}
