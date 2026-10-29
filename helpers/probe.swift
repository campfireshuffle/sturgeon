import CoreGraphics
import Foundation

// r21probe — dump every window the window server knows about, in front-to-back order, as JSON.
// Fields are deliberately the same names and types the tooling has always used:
//   id (CGWindowID), owner, x, y, w, h, layer, i (index in the list).
// On-screen only, unfiltered by owner: the strip code needs the WindowManager's own overlays
// (including the ones it parks just off the left edge) and negative-layer windows as well.

setvbuf(stdout, nil, _IONBF, 0)

let opts: CGWindowListOption = [.optionOnScreenOnly]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    print("[]")
    exit(0)
}

var out: [[String: Any]] = []
out.reserveCapacity(list.count)
var i = 0
for w in list {
    guard let id = w[kCGWindowNumber as String] as? Int,
          let boundsDict = w[kCGWindowBounds as String] as? [String: Any],
          let b = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
    let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
    let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
    out.append([
        "i": i,
        "id": id,
        "owner": owner,
        "layer": layer,
        "x": Int(b.origin.x.rounded()),
        "y": Int(b.origin.y.rounded()),
        "w": Int(b.size.width.rounded()),
        "h": Int(b.size.height.rounded()),
    ])
    i += 1
}

let data = try! JSONSerialization.data(withJSONObject: out, options: [])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write("\n".data(using: .utf8)!)
