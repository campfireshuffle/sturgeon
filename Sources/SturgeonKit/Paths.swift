import Foundation

/// One resolver for the privileged tool tree.
///
/// Bundled (shipping) layout — the app is relocatable, no path to the developer's checkout:
///
///   Sturgeon.app/Contents/Resources/wmship/        <- root
///     wmship.sh  wmlayout.py  setup.sh  teardown.sh  wmlocate.py
///     wmship/{install.py,ctl.py,wmshipd.py,payload.img,profile.json,wmhb,wmcls,...}
///     bin/asroot  bin/wmx  bin/r19ax …
///     a/stagepilot  wm/{wmobs,wmkey,wmctl.py,wm.py}
///
/// Development fallback: walk up from the executable until a directory that contains
/// `wmship.sh` or `wmship/install.py` is found (that directory is the repository root).
/// `STURGEON_WMSHIP_ROOT` overrides both, which is what a proof harness uses. There is no
/// hard-coded user path here.
public struct Paths: Equatable {
    public enum Layout: String, Equatable {
        /// Inside `Sturgeon.app/Contents/Resources/wmship`.
        case bundle
        /// A checkout (or any directory that carries the tool tree).
        case checkout
    }

    public let root: URL
    public let layout: Layout
    /// The executable that resolved this tree, kept for diagnostics.
    public let executable: URL

    public init(root: URL, layout: Layout, executable: URL) {
        self.root = root
        self.layout = layout
        self.executable = executable
    }

    // MARK: - entries

    public var wmshipScript: URL { root.appendingPathComponent("wmship.sh") }
    public var installPy: URL { root.appendingPathComponent("wmship/install.py") }
    public var plist: URL { root.appendingPathComponent("wmship/com.stagemgr.wmshipd.plist") }
    public var setupScript: URL { root.appendingPathComponent("setup.sh") }

    /// The NOPASSWD passthrough. The checkout keeps it in `bin/` (installed by
    /// scripts/build-helpers.sh); the shipped bundle keeps it there too. The top-level spelling is
    /// tolerated for an older tree. The sudoers rule names exactly one of these paths.
    public var asroot: URL? {
        firstExecutable(["asroot", "bin/asroot"])
    }

    /// The stage lister. The checkout keeps it at `a/stagepilot`; the bundle carries it in the
    /// same place (and, for tolerance, `bin/stagepilot`).
    public var stagepilot: URL? {
        firstExecutable(["a/stagepilot", "bin/stagepilot"])
    }

    private func firstExecutable(_ relatives: [String]) -> URL? {
        for rel in relatives {
            let url = root.appendingPathComponent(rel)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    // MARK: - resolution

    /// Resolve a tool tree from injected observations, so the two layouts are testable without a
    /// real bundle. `bundleResourceURL` is `Bundle.main.resourceURL` in the app.
    public static func resolve(bundleResourceURL: URL?,
                               executableURL: URL,
                               override: String? = nil,
                               fileManager: FileManager = .default) -> Paths? {
        if let resources = bundleResourceURL {
            let dir = resources.appendingPathComponent("wmship", isDirectory: true)
            if fileManager.isExecutableFile(atPath: dir.appendingPathComponent("wmship.sh").path) {
                return Paths(root: dir, layout: .bundle, executable: executableURL)
            }
        }

        var candidates: [URL] = []
        if let override, !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        var dir = executableURL.resolvingSymlinksInPath()
        if !dir.hasDirectoryPath { dir.deleteLastPathComponent() }
        for _ in 0..<10 {
            candidates.append(dir)
            let up = dir.deletingLastPathComponent()
            if up.path == dir.path { break }
            dir = up
        }

        for candidate in candidates {
            let launcher = candidate.appendingPathComponent("wmship.sh")
            let installer = candidate.appendingPathComponent("wmship/install.py")
            if fileManager.isExecutableFile(atPath: launcher.path)
                || fileManager.fileExists(atPath: installer.path) {
                return Paths(root: candidate, layout: .checkout, executable: executableURL)
            }
        }
        return nil
    }

    /// This process's own tree: the app bundle first, then a checkout.
    public static let current: Paths? = resolve(
        bundleResourceURL: Bundle.main.resourceURL,
        executableURL: URL(fileURLWithPath: CommandLine.arguments[0]),
        override: ProcessInfo.processInfo.environment["STURGEON_WMSHIP_ROOT"]
    )

    // Conveniences the view model reads. `root` and friends are nil only when no tree was found.
    public static var root: URL? { current?.root }
    public static var isBundled: Bool { current?.layout == .bundle }
    public static var wmship: URL? { current?.wmshipScript }
    public static var asroot: URL? { current?.asroot }
    public static var installPy: URL? { current?.installPy }
    public static var stagepilot: URL? { current?.stagepilot }
    public static var setupScript: URL? { current?.setupScript }

    /// Shell single-quote, for the one string we must pass through `asroot -c`.
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
