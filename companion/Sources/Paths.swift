import Foundation

/// One resolver for the privileged tool tree.
///
/// Bundled (shipping) layout — the app is relocatable, no path to the developer's checkout:
///
///   Sturgeon.app/Contents/Resources/wmship/        <- `WMSHIP_WORK`
///     wmship.sh  asroot  wmlocate.py  sites.json
///     wmship/{install.py,ctl.py,wmshipd.py,payload.img,profile.json,wmhb,wmcls,...}
///     a/stagepilot  wm/...  re/round{8,19,20,21,24}/...
///
/// Development fallback: walk up from the executable until a directory that contains
/// `wmship/wmship.sh` is found (that directory is the repo's `work/`).  `STURGEON_WMSHIP_ROOT`
/// overrides both, which is what the test harness uses.  There is no hard-coded user path here.
enum Paths {
    static let bundleRoot: URL? = {
        guard let res = Bundle.main.resourceURL else { return nil }
        let dir = res.appendingPathComponent("wmship", isDirectory: true)
        guard FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent("wmship.sh").path)
        else { return nil }
        return dir
    }()

    static let devRoot: URL? = {
        var candidates: [URL] = []
        if let e = ProcessInfo.processInfo.environment["STURGEON_WMSHIP_ROOT"], !e.isEmpty {
            candidates.append(URL(fileURLWithPath: e, isDirectory: true))
        }
        var d = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        if !d.hasDirectoryPath { d.deleteLastPathComponent() }
        for _ in 0..<10 {
            candidates.append(d)
            let up = d.deletingLastPathComponent()
            if up.path == d.path { break }
            d = up
        }
        for c in candidates {
            let launcher = c.appendingPathComponent("wmship.sh")
            let installer = c.appendingPathComponent("wmship/install.py")
            if FileManager.default.isExecutableFile(atPath: launcher.path)
                || FileManager.default.fileExists(atPath: installer.path) {
                return c
            }
        }
        return nil
    }()

    static var root: URL? { bundleRoot ?? devRoot }
    static var isBundled: Bool { bundleRoot != nil }

    static var wmship: URL? { root?.appendingPathComponent("wmship.sh") }
    /// The NOPASSWD passthrough.  The checkout keeps it at the tool root; the app bundle keeps it
    /// in `bin/` (wmlayout.bin_path).  The sudoers rule names exactly one of these paths.
    static var asroot: URL? {
        guard let r = root else { return nil }
        for rel in ["asroot", "bin/asroot"] {
            let u = r.appendingPathComponent(rel)
            if FileManager.default.isExecutableFile(atPath: u.path) { return u }
        }
        return nil
    }
    static var installPy: URL? { root?.appendingPathComponent("wmship/install.py") }

    /// The stage lister.  The checkout keeps it at `a/stagepilot`; the bundle carries it in the
    /// same place (and, for tolerance, `bin/stagepilot`).
    static var stagepilot: URL? {
        guard let r = root else { return nil }
        for rel in ["a/stagepilot", "bin/stagepilot"] {
            let u = r.appendingPathComponent(rel)
            if FileManager.default.isExecutableFile(atPath: u.path) { return u }
        }
        return nil
    }
    static var plist: URL? { root?.appendingPathComponent("wmship/com.stagemgr.wmshipd.plist") }
    static var setupScript: URL? { root?.appendingPathComponent("setup.sh") }

    /// Shell single-quote, for the one string we must pass through `asroot -c`.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
