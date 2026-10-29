import Foundation

/// One control the popover can change in the payload config. `values` is exactly what is merged
/// into the config document; `label` is exactly what the footer reports.
public enum ConfigChange: Equatable {
    case births(Bool)
    /// One toggle, two keys: the keeper replays the pose set and the tiles are raised.
    case onTop(Bool)
    case level(Bool)
    /// The keeper's per-pose trace, published in its log ring.  Advanced and loud on purpose.
    case trace(Bool)

    public var values: [String: Any] {
        switch self {
        case .births(let on): return ["births": on]
        case .onTop(let on): return ["replay": on, "levels": on]
        case .level(let on): return ["level_manual": on ? 3 : 0]
        case .trace(let on): return ["trace": on]
        }
    }

    public var label: String {
        switch self {
        case .births(let on): return "births=\(on)"
        case .onTop(let on): return "replay=\(on) levels=\(on)"
        case .level(let on): return "level_manual=\(on ? 3 : 0)"
        case .trace(let on): return "trace=\(on)"
        }
    }
}

/// The payload's config document (`wmship.sh cfg`, written with `install.py cfg '<json>'`).
///
/// The document carries keys this app does not interpret (`qx`, `qy`, `gen`, `dilate`, …). A write
/// is a read, a merge of the changed keys, and a sorted-key encode — so unknown keys survive
/// verbatim and a write is byte-for-byte what the CLI's own `cfg_set` would produce.
public struct PayloadConfig {
    public var values: [String: Any]

    public init(values: [String: Any] = [:]) {
        self.values = values
    }

    public init?(json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        values = object
    }

    /// `nil` when the document cannot be encoded (it must be a JSON object of JSON values).
    public func encoded() -> String? {
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public mutating func apply(_ change: ConfigChange) {
        for (key, value) in change.values { values[key] = value }
    }

    public func applying(_ change: ConfigChange) -> PayloadConfig {
        var copy = self
        copy.apply(change)
        return copy
    }

    // MARK: - typed reads

    public var births: Bool { values["births"] as? Bool ?? false }
    public var replay: Bool { values["replay"] as? Bool ?? false }
    public var levels: Bool { values["levels"] as? Bool ?? false }
    public var levelManual: Int { values["level_manual"] as? Int ?? 0 }
    public var scale: Double { values["s"] as? Double ?? 1.0 }
    public var trace: Bool { values["trace"] as? Bool ?? false }
    public var onTop: Bool { replay && levels }
    public var level3: Bool { levelManual == 3 }

    /// The footer's read-back: the five keys the popover shows, in a stable order. Numbers are
    /// rendered as numbers (NSNumber would otherwise bridge 0/1 to false/true).
    public var brief: String {
        func flag(_ key: String) -> String {
            guard let value = values[key] else { return "?" }
            if let number = value as? NSNumber { return number.boolValue ? "true" : "false" }
            return String(describing: value)
        }
        func number(_ key: String, _ formatted: String) -> String {
            values[key] == nil ? "?" : formatted
        }
        return [
            "births=\(flag("births"))",
            "replay=\(flag("replay"))",
            "levels=\(flag("levels"))",
            "level_manual=\(number("level_manual", String(levelManual)))",
            "s=\(number("s", String(format: "%.2f", scale)))",
        ].joined(separator: " ")
    }
}
