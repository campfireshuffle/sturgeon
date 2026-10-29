// makeicon — draw the Sturgeon app icon (1024²), then build.sh downsamples it into an .icns.
// Simple, deterministic, no assets: a dark rounded tile field with the Stage Manager rail.
import AppKit

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()

let bgRect = NSRect(x: 42, y: 42, width: S - 84, height: S - 84)
let bg = NSBezierPath(roundedRect: bgRect, xRadius: 230, yRadius: 230)
NSGradient(colors: [
    NSColor(srgbRed: 0.16, green: 0.24, blue: 0.40, alpha: 1),
    NSColor(srgbRed: 0.05, green: 0.08, blue: 0.15, alpha: 1),
])!.draw(in: bg, angle: -90)

// the rail
NSColor.white.withAlphaComponent(0.10).setFill()
NSBezierPath(roundedRect: NSRect(x: 206, y: 236, width: 14, height: 552),
             xRadius: 7, yRadius: 7).fill()

// three stage tiles, warm against the blue
let tiles: [(CGFloat, CGFloat, CGFloat)] = [(648, 168, 412), (438, 158, 344), (240, 148, 286)]
for (i, t) in tiles.enumerated() {
    let (y, h, w) = t
    let r = NSRect(x: 262, y: y, width: w, height: h)
    let p = NSBezierPath(roundedRect: r, xRadius: 34, yRadius: 34)
    let a = 1.0 - Double(i) * 0.18
    NSColor(srgbRed: 0.98, green: 0.82, blue: 0.52, alpha: a).setFill()
    p.fill()
    if i == 0 {
        NSColor(srgbRed: 0.99, green: 0.90, blue: 0.70, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: NSRect(x: r.minX + 34, y: r.maxY - 58, width: 120, height: 18),
                     xRadius: 9, yRadius: 9).fill()
    }
}
img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("makeicon: cannot encode PNG\n".data(using: .utf8)!)
    exit(1)
}
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print(out)
