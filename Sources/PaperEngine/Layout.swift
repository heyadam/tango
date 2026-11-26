import CoreText
import Foundation
import PaperModel

/// Layout. A stack places its children in a row or column along its axis; a grid places
/// them in equal columns. Each child's width and height sizing say whether it keeps its
/// size (Fixed), takes the space that is left (Grow), or fits its content (Auto).
extension ResolvedLayer {
    private enum Axis { case horizontal, vertical }

    private var arrangement: Axis? {
        switch value(.layout).textValue {
        case "Stack": value(.axis).textValue == "Horizontal" ? .horizontal : .vertical
        // What a cable may still bring from a document made before stacks had an axis.
        case "Horizontal": .horizontal
        case "Vertical": .vertical
        default: nil
        }
    }

    /// The container's padding along an axis: before its content, and after it.
    private func padding(_ axis: Axis) -> (start: Double, end: Double) {
        axis == .horizontal
            ? (value(.paddingLeft).numberValue, value(.paddingRight).numberValue)
            : (value(.paddingTop).numberValue, value(.paddingBottom).numberValue)
    }

    /// Whether this is a scroll view: a stack whose content moves by its content offset.
    public var scrolls: Bool { arrangement != nil && value(.scrolls).boolValue }

    private func mode(_ property: LayerProperty) -> String {
        kind == .screen || isPage ? "Fixed" : value(property).textValue
    }

    private var takesPartInLayout: Bool { !isPage && !value(.absolute).boolValue }

    /// A screen fills the device whatever the root does with its other children. Where it
    /// is told to be (by the runtime, while it moves in or out) counts from the corner.
    private mutating func placePages(in size: Size2) {
        guard kind == .screen else { return }
        for index in children.indices where children[index].isPage {
            let offset = children[index].overrides[.position]?.pointValue ?? .zero
            let anchor = children[index].anchor
            children[index].overrides[.size] = .size(size)
            children[index].overrides[.position] = .point(Point2(
                x: (offset.x + anchor.x * size.width).clampedFinite, y: (offset.y + anchor.y * size.height).clampedFinite
            ))
        }
    }

    /// The tree with layout applied: sizes and positions of arranged layers are final.
    public func laidOut() -> ResolvedLayer {
        var copy = self
        copy.layout(width: nil, height: nil)
        return copy
    }

    /// The size this layer wants before any space is handed out by its parent.
    private func preferredSize(width assigned: Double? = nil) -> Size2 {
        let stored = size
        var width = assigned ?? stored.width
        var height = stored.height
        let autoWidth = assigned == nil && mode(.widthMode) == "Auto"
        let autoHeight = mode(.heightMode) == "Auto"
        guard autoWidth || autoHeight else { return Size2(width: width, height: height) }

        if kind == .text {
            let measured = TextMeasurer.measure(
                value(.text).textValue,
                fontSize: value(.fontSize).numberValue,
                weight: value(.fontWeight).numberValue,
                family: value(.fontFamily).textValue,
                italic: value(.italic).boolValue,
                // A single-line label never wraps; it is cut short with an ellipsis instead.
                maxWidth: autoWidth || value(.singleLine).boolValue ? nil : width
            )
            if autoWidth { width = measured.width }
            if autoHeight { height = measured.height }
        } else if isGrid {
            if autoHeight {
                var copy = self
                height = copy.layoutGrid(width: width, place: false)
            }
        } else if let axis = arrangement {
            let cross: Axis = axis == .horizontal ? .vertical : .horizontal
            let (mainPadding, crossPadding) = (padding(axis), padding(cross))
            let spacing = value(.spacing).numberValue
            let flow = children.filter(\.takesPartInLayout)
            var main = 0.0
            var crossLength = 0.0
            for child in flow {
                let wanted = child.preferredSize()
                let growsOnMain = child.mode(axis == .horizontal ? .widthMode : .heightMode) == "Grow"
                main += growsOnMain ? 0 : (axis == .horizontal ? wanted.width : wanted.height)
                crossLength = max(crossLength, axis == .horizontal ? wanted.height : wanted.width)
            }
            main += spacing * Double(max(flow.count - 1, 0)) + mainPadding.start + mainPadding.end
            crossLength += crossPadding.start + crossPadding.end
            if autoWidth { width = axis == .horizontal ? main : crossLength }
            if autoHeight { height = axis == .horizontal ? crossLength : main }
        }
        return Size2(width: width, height: height)
    }

    private var isGrid: Bool { value(.layout).textValue == "Grid" }
    private var columnCount: Int { min(max(value(.columns).numberValue.whole, 1), 1000) }

    /// Grid: children fill rows of equal-width cells, left to right, top to bottom. A row
    /// is as tall as its tallest child. Returns the height the rows need.
    @discardableResult
    private mutating func layoutGrid(width: Double, place: Bool) -> Double {
        let verticalPadding = self.padding(.vertical)
        let padding = self.padding(.horizontal)
        let spacing = value(.spacing).numberValue
        let alignment = value(.alignment).textValue
        let columns = columnCount
        let cell = max((width - padding.start - padding.end - spacing * Double(columns - 1)) / Double(columns), 0)
        let flow = children.indices.filter { children[$0].takesPartInLayout }
        var y = verticalPadding.start
        var row = 0
        while row * columns < flow.count {
            let members = flow[(row * columns)..<min((row + 1) * columns, flow.count)]
            var rowHeight = 0.0
            for index in members {
                let grows = children[index].mode(.widthMode) == "Grow"
                if place {
                    children[index].layout(width: grows ? cell : nil, height: nil)
                    rowHeight = max(rowHeight, children[index].size.height)
                } else {
                    rowHeight = max(rowHeight, children[index].preferredSize(width: grows ? cell : nil).height)
                }
            }
            if place {
                for (column, index) in members.enumerated() {
                    let placed = children[index].size
                    if children[index].mode(.heightMode) == "Grow", placed.height != rowHeight {
                        children[index].layout(width: placed.width, height: rowHeight)
                    }
                    let size = children[index].size
                    let free = cell - size.width
                    let inset = alignment == "Center" ? free / 2 : alignment == "End" ? free : 0
                    let origin = Point2(x: padding.start + Double(column) * (cell + spacing) + inset, y: y)
                    let anchor = children[index].anchor
                    children[index].overrides[.position] = .point(Point2(
                        x: (origin.x + anchor.x * size.width).clampedFinite, y: (origin.y + anchor.y * size.height).clampedFinite
                    ))
                }
            }
            y += rowHeight + spacing
            row += 1
        }
        if place {
            for index in children.indices where !flow.contains(index) { children[index].layout(width: nil, height: nil) }
        }
        return (row > 0 ? y - spacing : y) + verticalPadding.end
    }

    private mutating func layout(width: Double?, height: Double?) {
        var size = preferredSize(width: width)
        if let height { size.height = height }
        if size != self.size { overrides[.size] = .size(size) }
        placePages(in: size)

        if isGrid {
            layoutGrid(width: size.width, place: true)
            return
        }

        guard let axis = arrangement else {
            for index in children.indices { children[index].layout(width: nil, height: nil) }
            return
        }

        let mainPadding = padding(axis)
        let crossPadding = padding(axis == .horizontal ? .vertical : .horizontal)
        var spacing = value(.spacing).numberValue
        let alignment = value(.alignment).textValue
        let mainMode: LayerProperty = axis == .horizontal ? .widthMode : .heightMode
        let crossMode: LayerProperty = axis == .horizontal ? .heightMode : .widthMode
        let mainLength = axis == .horizontal ? size.width : size.height
        let crossLength = (axis == .horizontal ? size.height : size.width) - crossPadding.start - crossPadding.end

        let flow = children.indices.filter { children[$0].takesPartInLayout }
        var fixedTotal = 0.0
        var growCount = 0
        for index in flow {
            if children[index].mode(mainMode) == "Grow" {
                growCount += 1
            } else {
                let wanted = children[index].preferredSize()
                fixedTotal += axis == .horizontal ? wanted.width : wanted.height
            }
        }
        let free = mainLength - mainPadding.start - mainPadding.end - spacing * Double(max(flow.count - 1, 0)) - fixedTotal
        let growLength = growCount > 0 ? max(free / Double(growCount), 0) : 0
        // How long the content is, for a scroll view to know how far it can move.
        contentLength = growCount > 0 ? max(mainLength, mainLength - free) : mainLength - free

        // Space the children leave is handed out by the distribution. A child that grows
        // takes it all, and content longer than the stack leaves none.
        var cursor = mainPadding.start
        if growCount == 0, free > 0 {
            switch value(.distribution).textValue {
            case "Center": cursor += free / 2
            case "End": cursor += free
            case "Space Between" where flow.count > 1: spacing += free / Double(flow.count - 1)
            default: break
            }
        }
        if value(.scrolls).boolValue { cursor += value(.contentOffset).numberValue }
        for index in children.indices {
            guard flow.contains(index) else {
                children[index].layout(width: nil, height: nil)
                continue
            }
            let growsMain = children[index].mode(mainMode) == "Grow"
            let growsCross = children[index].mode(crossMode) == "Grow"
            let main: Double? = growsMain ? growLength : nil
            let cross: Double? = growsCross ? max(crossLength, 0) : nil
            if axis == .horizontal {
                children[index].layout(width: main, height: cross)
            } else {
                children[index].layout(width: cross, height: main)
            }

            let placed = children[index].size
            let childMain = axis == .horizontal ? placed.width : placed.height
            let childCross = axis == .horizontal ? placed.height : placed.width
            let crossOffset: Double
            switch alignment {
            case "Center": crossOffset = crossPadding.start + (crossLength - childCross) / 2
            case "End": crossOffset = crossPadding.start + crossLength - childCross
            default: crossOffset = crossPadding.start
            }
            let origin = axis == .horizontal
                ? Point2(x: cursor, y: crossOffset)
                : Point2(x: crossOffset, y: cursor)
            let anchor = children[index].anchor
            children[index].overrides[.position] = .point(Point2(
                x: (origin.x + anchor.x * placed.width).clampedFinite, y: (origin.y + anchor.y * placed.height).clampedFinite
            ))
            cursor += childMain + spacing
        }
    }
}

/// Measures text the way the renderer draws it, in the font `FontBook` gives both.
public enum TextMeasurer {
    /// The font at a size and a weight from 100 to 900, in the same nine steps the
    /// renderer draws with, so text takes the room it is drawn in.
    public static func font(size: Double, weight: Double, family: String = "", italic: Bool = false) -> CTFont {
        FontBook.font(family: family, size: size, weight: weight, italic: italic)
    }

    /// Core Text's weight for a font weight, the values AppKit and UIKit name ultraLight to black.
    public static func weightTrait(_ weight: Double) -> Double {
        switch weight {
        case ..<150: -0.8
        case ..<250: -0.6
        case ..<350: -0.4
        case ..<450: 0
        case ..<550: 0.23
        case ..<650: 0.3
        case ..<750: 0.4
        case ..<850: 0.56
        default: 0.62
        }
    }

    /// What was asked for, and so what the answer depends on. The fonts known to Core Text
    /// are part of it: a family whose file has arrived measures differently from then on.
    private struct Asked: Hashable {
        var text: String
        var fontSize: Double
        var weight: Double
        var family: String
        var italic: Bool
        var maxWidth: Double?
        var fonts: Int
    }

    private static let lock = NSLock()
    /// Sizes already measured. Layout asks for every text's size every frame, and setting
    /// type is by far the dearest thing it does, so a text is set once and remembered.
    nonisolated(unsafe) private static var measured: [Asked: Size2] = [:]
    /// The most sizes kept; past it they are all let go, since text that changes every
    /// frame (a counter, an answer being written) would otherwise fill it for ever.
    static let mostKept = 4096
    /// How many sizes are kept now.
    static var kept: Int {
        lock.lock()
        defer { lock.unlock() }
        return measured.count
    }

    public static func measure(
        _ text: String, fontSize: Double, weight: Double, family: String = "", italic: Bool = false, maxWidth: Double?
    ) -> Size2 {
        let asked = Asked(
            text: text, fontSize: fontSize, weight: weight, family: family, italic: italic, maxWidth: maxWidth,
            fonts: FontBook.generation
        )
        lock.lock()
        let known = measured[asked]
        lock.unlock()
        if let known { return known }
        let size = set(text, fontSize: fontSize, weight: weight, family: family, italic: italic, maxWidth: maxWidth)
        lock.lock()
        if measured.count >= mostKept { measured.removeAll(keepingCapacity: true) }
        measured[asked] = size
        lock.unlock()
        return size
    }

    /// Sets the text with Core Text and reads its size: what `measure` remembers.
    private static func set(
        _ text: String, fontSize: Double, weight: Double, family: String, italic: Bool, maxWidth: Double?
    ) -> Size2 {
        let font = font(size: fontSize, weight: weight, family: family, italic: italic)
        let attributed = NSAttributedString(
            string: text.isEmpty ? " " : text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let limit = CGSize(width: maxWidth.map { max($0, 1) } ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil, limit, nil)
        // Text of several lines is as tall as every line with its leading, the last one
        // included: the size Core Text suggests leaves that leading off, and a text layer
        // given only that drops its last line and runs its words off the edge of the one
        // before (`TextMeasurerTests`).
        // One line already fits the size suggested, and stays as it was measured; only
        // taller text is broken into lines to count them, which costs a second layout.
        let lineHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        guard fitted.height > lineHeight * 1.5 else { return Size2(width: ceil(fitted.width), height: ceil(fitted.height)) }
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: 0),
            CGPath(rect: CGRect(x: 0, y: 0, width: min(limit.width, 1_000_000), height: 1_000_000), transform: nil), nil
        )
        let lines = max((CTFrameGetLines(frame) as? [CTLine])?.count ?? 1, 1)
        return Size2(width: ceil(fitted.width), height: max(ceil(fitted.height), ceil(Double(lines) * lineHeight)))
    }
}
