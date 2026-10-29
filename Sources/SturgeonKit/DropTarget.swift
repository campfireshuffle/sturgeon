import CoreGraphics
import Foundation

/// What a mouse release over the strip means.  Hit-testing is deliberately strict: a point that
/// is not inside the strip's own rect belongs to the native drag gesture, and two tile frames
/// under the same point are ambiguous — doing nothing is the only safe answer.
public enum DropDecision: Equatable {
    /// Exactly one tile under the point: move the dragged window into its stage.
    case move(StageItem)
    /// The point is outside the strip: native behaviour, untouched.
    case ignore
    /// Inside the strip but not on a tile (the empty gutter): native behaviour, untouched.
    case emptyGutter
    /// Two or more tile frames contain the point: do nothing and count it.
    case ambiguous([StageItem])

    public var shouldMove: Bool {
        if case .move = self { return true }
        return false
    }

    public var isAmbiguous: Bool {
        if case .ambiguous = self { return true }
        return false
    }

    public var tile: StageItem? {
        if case .move(let tile) = self { return tile }
        return nil
    }
}

public enum DropHitTest {
    /// `strip` and `tiles` must be read at release time: the strip animates during the drag, so
    /// frames cached at mouse-down describe a different layout.
    public static func resolve(point: CGPoint, strip: CGRect?, tiles: [StageItem]) -> DropDecision {
        guard let strip, strip.width > 0, strip.height > 0, strip.contains(point) else {
            return .ignore
        }
        let hits = tiles.filter { tile in
            guard let frame = tile.frame, frame.width > 0, frame.height > 0 else { return false }
            return frame.contains(point)
        }
        switch hits.count {
        case 0: return .emptyGutter
        case 1: return .move(hits[0])
        default: return .ambiguous(hits)
        }
    }
}
