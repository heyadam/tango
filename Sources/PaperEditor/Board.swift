import CoreGraphics
import Foundation
import PaperModel

/// Where each screen sits on the Canvas: side by side in a row, in the order they have in
/// the document, the first (where the prototype starts) on the left. Nothing of it is
/// stored. A document without screens has one frame, the root.
public struct Board: Equatable, Sendable {
    public struct Frame: Equatable, Sendable, Identifiable {
        /// The screen, or the root when it is the only one.
        public var id: LayerID
        public var name: String
        /// Whether this is one of the root's screens (false for the root itself).
        public var isPage: Bool
        /// In board coordinates: points, y down, the first frame's corner at the origin.
        public var rect: CGRect
    }

    /// The room between two frames, in the document's points: enough for an arrow and its
    /// label when the board is zoomed out to show several screens.
    public static let gap: CGFloat = 200

    public var frames: [Frame]

    public init(_ document: Document) {
        let root = document.screen
        let size = root.value(.size).sizeValue
        let pages = root.pages
        guard !pages.isEmpty else {
            frames = [Frame(id: root.id, name: root.name, isPage: false, rect: CGRect(x: 0, y: 0, width: size.width, height: size.height))]
            return
        }
        frames = pages.enumerated().map { index, page in
            Frame(
                id: page.id, name: page.name, isPage: true,
                rect: CGRect(x: CGFloat(index) * (size.width + Board.gap), y: 0, width: size.width, height: size.height)
            )
        }
    }

    /// Everything, for fitting it in view.
    public var bounds: CGRect { frames.reduce(CGRect.null) { $0.union($1.rect) } }

    /// The frame a board point is in.
    public func index(at point: CGPoint) -> Int? { frames.firstIndex { $0.rect.contains(point) } }

    /// The frame nearest a board point: the one it is in, or else the closest along the row.
    public func nearestIndex(to point: CGPoint) -> Int {
        if let inside = index(at: point) { return inside }
        return frames.indices.min { abs(frames[$0].rect.midX - point.x) < abs(frames[$1].rect.midX - point.x) } ?? 0
    }

    /// The frame a view is shown in: its screen's. What is in the root beside the screens
    /// floats over every one of them, and is edited in the first.
    public func index(holding layer: LayerID, in document: Document) -> Int {
        let chain = document.screen.path(to: layer)
        guard chain.count > 1 else { return frames.firstIndex { $0.id == layer } ?? 0 }
        return frames.firstIndex { $0.id == chain[1].id } ?? 0
    }

    /// A point of a screen, on the board.
    public func boardPoint(_ point: CGPoint, inFrame index: Int) -> CGPoint {
        CGPoint(x: point.x + frames[index].rect.minX, y: point.y + frames[index].rect.minY)
    }

    /// A point of the board, in a screen's own coordinates.
    public func screenPoint(_ point: CGPoint, inFrame index: Int) -> CGPoint {
        CGPoint(x: point.x - frames[index].rect.minX, y: point.y - frames[index].rect.minY)
    }
}

/// Lining a dragged view up with what is around it.
public enum Snapping {
    public struct Result: Equatable, Sendable {
        /// How far to move the view so that it lines up.
        public var dx: CGFloat = 0
        public var dy: CGFloat = 0
        /// The vertical lines (x) and horizontal lines (y) it lines up with, for drawing.
        public var linesX: [CGFloat] = []
        public var linesY: [CGFloat] = []
    }

    /// Lines `moving` up with the edges and middles of `others` and of a container of a
    /// `size`, all in the container's coordinates, when one is within `threshold`.
    public static func snap(_ moving: CGRect, to others: [CGRect], in size: CGSize, threshold: CGFloat) -> Result {
        let all = others + [CGRect(origin: .zero, size: size)]
        var result = Result()
        if let (delta, line) = nearest([moving.minX, moving.midX, moving.maxX], all.flatMap { [$0.minX, $0.midX, $0.maxX] }, threshold) {
            result.dx = delta
            result.linesX = [line]
        }
        if let (delta, line) = nearest([moving.minY, moving.midY, moving.maxY], all.flatMap { [$0.minY, $0.midY, $0.maxY] }, threshold) {
            result.dy = delta
            result.linesY = [line]
        }
        return result
    }

    private static func nearest(_ own: [CGFloat], _ targets: [CGFloat], _ threshold: CGFloat) -> (CGFloat, CGFloat)? {
        var best: (CGFloat, CGFloat)?
        for value in own {
            for target in targets where abs(target - value) <= threshold {
                if best == nil || abs(target - value) < abs(best!.0) { best = (target - value, target) }
            }
        }
        return best
    }

    /// How a container lays its children out, for telling where a dragged one belongs.
    public enum Flow: Sendable {
        case vertical, horizontal
        /// Rows read left to right, top to bottom.
        case grid
    }

    /// Where a view dragged inside a stack or grid goes among its siblings: after every
    /// sibling whose middle the pointer has passed. Going by the middles keeps it still
    /// once it has moved, whatever the sizes, where "the sibling under the pointer" would
    /// swap a small view and a large one back and forth. `frames` are the siblings' frames
    /// in order, the dragged one (at `dragged`) included.
    public static func place(of point: CGPoint, among frames: [CGRect], dragged: Int, flow: Flow) -> Int? {
        guard frames.indices.contains(dragged) else { return nil }
        var passed = 0
        for (index, frame) in frames.enumerated() where index != dragged {
            switch flow {
            case .vertical: if point.y > frame.midY { passed += 1 }
            case .horizontal: if point.x > frame.midX { passed += 1 }
            case .grid: if point.y > frame.maxY || (point.y >= frame.minY && point.x > frame.midX) { passed += 1 }
            }
        }
        return passed
    }
}
