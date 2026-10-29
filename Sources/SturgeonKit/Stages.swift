import CoreGraphics
import Foundation

/// One Stage Manager stage, as `a/stagepilot stages` prints it:
///
///   [0] 'Granola' frame=(0, 0, 286, 118) windows=[59, 57, 434]
///
/// `title` is what the CLI addresses a stage by; an untitled stage cannot be moved to.
/// `frame` is the tile in the strip (the WindowManager's own accessibility frame), which is what
/// a drop hit-test needs.  A collapsed strip reports a zero-size frame, so callers must check the
/// size as well as the point.
public struct StageItem: Identifiable, Equatable {
    public let id: Int
    public let title: String
    public let windows: [Int]
    public let frame: CGRect?

    public init(id: Int, title: String, windows: [Int] = [], frame: CGRect? = nil) {
        self.id = id
        self.title = title
        self.windows = windows
        self.frame = frame
    }

    public var label: String { title.isEmpty ? "Untitled stage \(id + 1)" : title }
    public var addressable: Bool { !title.isEmpty }

    public static func parse(_ text: String) -> [StageItem] {
        StageSnapshot.parse(text).stages
    }

    /// One line of `stagepilot stages`.
    static func parse(line: Substring) -> StageItem? {
        let s = String(line)
        guard s.hasPrefix("["), let close = s.firstIndex(of: "]") else { return nil }
        let idx = Int(s[s.index(after: s.startIndex)..<close]) ?? 0
        var title = ""
        if let a = s.range(of: "'"), let b = s.range(of: "'", options: .backwards),
           a.upperBound <= b.lowerBound {
            title = String(s[a.upperBound..<b.lowerBound])
        }
        var ids: [Int] = []
        if let a = s.range(of: "windows=["),
           let b = s.range(of: "]", range: a.upperBound..<s.endIndex) {
            ids = s[a.upperBound..<b.lowerBound].split(separator: ",").compactMap {
                Int($0.trimmingCharacters(in: .whitespaces))
            }
        }
        return StageItem(id: idx, title: title, windows: ids, frame: rect(after: "frame=", in: s))
    }

    /// `frame=(0.0, 0.0, 286.92, 945.0)` or `frame=(0, 0, 1512, 945)`, and the optional-wrapped
    /// `strip=Optional((0.0, 0.0, 286.92, 945.0))` that `String(describing:)` produces.
    static func rect(after label: String, in text: String) -> CGRect? {
        guard let range = text.range(of: label) else { return nil }
        let tail = text[range.upperBound...]
        var numbers: [Double] = []
        var token = ""
        for character in tail {
            if character.isNumber || character == "." || character == "-" || character == "+" {
                token.append(character)
            } else {
                if let value = Double(token) { numbers.append(value) }
                token = ""
                if numbers.count == 4 { break }
            }
        }
        if numbers.count < 4, let value = Double(token) { numbers.append(value) }
        guard numbers.count >= 4 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }
}

/// Everything `stagepilot stages` publishes: the stages (each with its tile frame) and the strip
/// rect.  The strip rect is read at call time because it moves while the strip reveals.
public struct StageSnapshot: Equatable {
    public var stages: [StageItem]
    public var strip: CGRect?

    public init(stages: [StageItem] = [], strip: CGRect? = nil) {
        self.stages = stages
        self.strip = strip
    }

    public static func parse(_ text: String) -> StageSnapshot {
        var stages: [StageItem] = []
        var strip: CGRect?
        for line in text.split(separator: "\n") {
            let s = String(line)
            if s.hasPrefix("strip=") {
                strip = StageItem.rect(after: "strip=", in: s)
                continue
            }
            if let stage = StageItem.parse(line: line) { stages.append(stage) }
        }
        return StageSnapshot(stages: stages.sorted { $0.id < $1.id }, strip: strip)
    }
}
