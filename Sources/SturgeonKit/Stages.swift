import Foundation

/// One Stage Manager stage, as `a/stagepilot stages` prints it:
///
///   [0] 'Granola' frame=(0, 0, 1512, 945) windows=[59, 57, 434]
///
/// `title` is what the CLI addresses a stage by; an untitled stage cannot be moved to.
public struct StageItem: Identifiable, Equatable {
    public let id: Int
    public let title: String
    public let windows: [Int]

    public init(id: Int, title: String, windows: [Int] = []) {
        self.id = id
        self.title = title
        self.windows = windows
    }

    public var label: String { title.isEmpty ? "Untitled stage \(id + 1)" : title }
    public var addressable: Bool { !title.isEmpty }

    public static func parse(_ text: String) -> [StageItem] {
        var out: [StageItem] = []
        for line in text.split(separator: "\n") {
            let s = String(line)
            guard s.hasPrefix("["), let close = s.firstIndex(of: "]") else { continue }
            let idx = Int(s[s.index(after: s.startIndex)..<close]) ?? out.count
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
            out.append(StageItem(id: idx, title: title, windows: ids))
        }
        return out.sorted { $0.id < $1.id }
    }
}
