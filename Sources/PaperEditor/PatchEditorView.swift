import AppKit
import PaperEngine
import PaperModel
import SwiftUI

/// Where the graph is built: patches, cables, and the values flowing through them.
public final class PatchEditorView: NSView, NSTextFieldDelegate {
    private let store: DocumentStore
    private var graph: Graph
    private var selection: Set<NodeID> = []
    private var layouts: [NodeID: PatchLayout] = [:]
    /// Everything upstream of the single selected patch, emphasized so its causes are visible.
    private var trace: (nodes: Set<NodeID>, connections: Set<Connection>)?

    private var pan = CGPoint(x: 24, y: 24)
    private var zoom: CGFloat = 1
    private var hasFramedContent = false

    private enum Drag {
        case none
        case moveNodes(start: CGPoint, originals: [NodeID: Point2])
        case marquee(start: CGPoint, current: CGPoint, base: Set<NodeID>)
        /// Dragging a cable out of an output. `rerouting` is the input it was pulled off.
        case cable(source: PortRef, point: CGPoint, rerouting: PortRef?)
        /// Dragging backwards from an empty input toward an output.
        case cableFromInput(input: PortRef, point: CGPoint)
        case scrub(node: NodeID, port: PaperEngine.Port, start: Double, startX: CGFloat, step: Double, moved: Bool)
        case pendingEdit(node: NodeID, port: PaperEngine.Port)
        /// Dragging a comment by its title carries the patches inside it along.
        case moveComment(id: UUID, start: CGPoint, origin: Point2, originals: [NodeID: Point2])
        case resizeComment(id: UUID, start: CGPoint, size: Size2)
    }

    static let commentTitleHeight: CGFloat = 28

    private enum Hit {
        case output(PortRef)
        case input(PortRef)
        case value(NodeID, PaperEngine.Port)
        case header(NodeID)
        case body(NodeID)
        case commentTitle(UUID)
        case commentCorner(UUID)
        case empty
    }

    private func frame(of comment: GraphComment) -> CGRect {
        CGRect(x: comment.origin.x, y: comment.origin.y, width: comment.size.width, height: comment.size.height)
    }

    private var drag: Drag = .none
    private var lastMouseUp: TimeInterval = 0
    private var pulseTimes: [PortRef: CFTimeInterval] = [:]
    private var fadeScheduled = false
    /// What each connected output last carried and when that last changed, so a cable can
    /// show its value moving while it is.
    private var lastValues: [PortRef: [Value]] = [:]
    private var changeTimes: [PortRef: CFTimeInterval] = [:]
    /// How long a cable keeps moving after its value settles, and how long its label stays.
    private static let flowTime: CFTimeInterval = 0.7
    private static let labelTime: CFTimeInterval = 2.4

    private var fieldEditor: NSTextField?
    private var commitEdit: ((String) -> Void)?
    private var colorTarget: (node: NodeID, port: String)?
    private var popover: NSPopover?
    private var lastMouseGraphPoint = CGPoint(x: 60, y: 60)

    public init(store: DocumentStore) {
        self.store = store
        graph = store.levelGraph
        super.init(frame: .zero)
        rebuildLayouts()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            store.removeFrameObserver(self)
        } else {
            store.addFrameObserver(self) { [weak self] in self?.frameDidTick() }
        }
    }

    // MARK: Updates

    func update(graph: Graph, selection: Set<NodeID>, reveal: NodeID?) {
        self.graph = graph
        self.selection = selection
        rebuildLayouts()
        trace = selection.count == 1 ? store.upstream(of: selection.first!) : nil
        if let reveal, let layout = layouts[reveal] {
            scrollToShow(layout.frame)
            DispatchQueue.main.async { [store] in
                if store.revealNode == reveal { store.revealNode = nil }
            }
        }
        needsDisplay = true
    }

    private func rebuildLayouts() {
        layouts = [:]
        for node in graph.nodes {
            layouts[node.id] = PatchLayout(node: node, ports: store.visiblePorts(for: node))
        }
    }

    public override func layout() {
        super.layout()
        // Keep the graph framed while panes settle and resize, until the person pans,
        // zooms, or starts editing.
        if !hasFramedContent, bounds.width > 40, bounds.height > 40 {
            frameContent(readable: true)
        }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !hasFramedContent, newSize.width > 40, newSize.height > 40 {
            frameContent(readable: true)
        }
    }

    /// Positions the view so the whole graph is visible, zooming out if it has to.
    ///
    /// `readable` is for framing nobody asked for, such as when a document opens: it never
    /// shrinks patches until their labels are too small to read. A graph too big for that
    /// starts at its top-left corner instead.
    public func frameContent(readable: Bool = false) {
        let frames = layouts.values.map(\.frame) + graph.comments.map { frame(of: $0) }
        guard let first = frames.first else { return }
        var content = frames.dropFirst().reduce(first) { $0.union($1) }
        // Room for the tails that name what is outside this level: they hang off the
        // left of inputs and the right of outputs.
        let full = store.document.graph
        var tails = (left: false, right: false)
        for holder in full.nodes {
            for port in holder.published ?? [] where layouts[port.inner.node] != nil {
                if port.isOutput { tails.right = true } else { tails.left = true }
            }
        }
        for cable in full.connections {
            let from = layouts[cable.from.node] != nil, to = layouts[cable.to.node] != nil
            if from, !to { tails.right = true }
            if to, !from { tails.left = true }
        }
        let room: CGFloat = 180
        if tails.left { content.origin.x -= room; content.size.width += room }
        if tails.right { content.size.width += room }
        let available = bounds.insetBy(dx: 28, dy: 28)
        guard available.width > 0, available.height > 0 else { return }
        zoom = min(1, max(readable ? 0.8 : 0.25, min(available.width / content.width, available.height / content.height)))
        pan = CGPoint(x: 28 - content.minX * zoom, y: 28 - content.minY * zoom)
        needsDisplay = true
    }

    private func scrollToShow(_ frame: CGRect) {
        let visible = CGRect(
            x: -pan.x / zoom, y: -pan.y / zoom, width: bounds.width / zoom, height: bounds.height / zoom
        ).insetBy(dx: 20, dy: 20)
        guard !visible.contains(frame) else { return }
        hasFramedContent = true
        pan = CGPoint(
            x: bounds.width / 2 - frame.midX * zoom,
            y: bounds.height / 2 - frame.midY * zoom
        )
    }

    private func frameDidTick() {
        // Remember when each pulse output last fired, so its cables can flash.
        if let runtime = store.runtime {
            let now = CACurrentMediaTime()
            for source in Set(graph.connections.map(\.from)) {
                let values = runtime.outputValues(source)
                if values.contains(.pulse(true)) { pulseTimes[source] = now }
                if let previous = lastValues[source], previous != values { changeTimes[source] = now }
                lastValues[source] = values
            }
        }
        needsDisplay = true
    }

    // MARK: Coordinates

    private func graphPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: (point.x - pan.x) / zoom, y: (point.y - pan.y) / zoom)
    }

    private func viewRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * zoom + pan.x, y: rect.minY * zoom + pan.y, width: rect.width * zoom, height: rect.height * zoom)
    }

    // MARK: Graph queries

    private func port(_ ref: PortRef, output: Bool) -> PaperEngine.Port? {
        guard let layout = layouts[ref.node] else { return nil }
        return output ? layout.ports.output(ref.port) : layout.ports.input(ref.port)
    }

    private func isConnected(input ref: PortRef) -> Bool {
        graph.connection(into: ref) != nil
    }

    /// Whether a literal on this input can be edited in the Patch Editor.
    private func isEditable(_ node: PatchNode, _ port: PaperEngine.Port) -> Bool {
        guard port.type != .pulse else { return false }
        // A view in a stack or grid is placed by it: its x and y show, but are not to edit.
        if node.kind == PatchKind.view, port.id == "x" || port.id == "y", let layer = node.layerID {
            return !store.isPlacedByParent(layer)
        }
        return true
    }

    private func hit(at point: CGPoint) -> Hit {
        for node in graph.nodes.reversed() {
            guard let layout = layouts[node.id] else { continue }
            let reach = PatchLayout.portRadius + 6
            guard layout.frame.insetBy(dx: -reach, dy: 0).contains(point) else { continue }

            for (index, port) in layout.ports.outputs.enumerated() {
                let center = layout.outputPort(index)
                if abs(center.x - point.x) <= reach, abs(center.y - point.y) <= PatchLayout.rowHeight / 2 {
                    return .output(PortRef(node: node.id, port: port.id))
                }
            }
            for (index, port) in layout.ports.inputs.enumerated() {
                let center = layout.inputPort(index)
                if abs(center.x - point.x) <= reach, abs(center.y - point.y) <= PatchLayout.rowHeight / 2 {
                    return .input(PortRef(node: node.id, port: port.id))
                }
            }
            guard layout.frame.contains(point) else { continue }
            for (index, port) in layout.ports.inputs.enumerated()
            where isEditable(node, port) && !isConnected(input: PortRef(node: node.id, port: port.id)) {
                if layout.inputValueRect(index).contains(point) { return .value(node.id, port) }
            }
            return layout.headerRect.contains(point) ? .header(node.id) : .body(node.id)
        }
        for comment in graph.comments.reversed() {
            let frame = frame(of: comment)
            if CGRect(x: frame.maxX - 16, y: frame.maxY - 16, width: 16, height: 16).contains(point) {
                return .commentCorner(comment.id)
            }
            if CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: Self.commentTitleHeight).contains(point) {
                return .commentTitle(comment.id)
            }
        }
        return .empty
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        drawGrid()

        context.saveGState()
        context.translateBy(x: pan.x, y: pan.y)
        context.scaleBy(x: zoom, y: zoom)

        for comment in graph.comments { drawComment(comment) }

        let now = CACurrentMediaTime()
        var hidden: PortRef?
        if case let .cable(_, _, rerouting) = drag { hidden = rerouting }
        var stillFading = false
        var labels: [(point: CGPoint, values: [Value], color: NSColor, alpha: CGFloat)] = []

        // Cables that leave this level: the end that is here, and what is at the other end.
        var leaving: [PortRef: (point: CGPoint, others: [NodeID], isInput: Bool)] = [:]

        for connection in graph.connections where connection.to != hidden {
            let fromPoint = layouts[connection.from.node]?.outputPortCenter(id: connection.from.port)
            let toPoint = layouts[connection.to.node]?.inputPortCenter(id: connection.to.port)
            if let toPoint, fromPoint == nil {
                leaving[connection.to] = (toPoint, [connection.from.node], true)
            } else if let fromPoint, toPoint == nil {
                leaving[connection.from, default: (fromPoint, [], false)].others.append(connection.to.node)
            }
            guard let from = fromPoint, let to = toPoint,
                  let type = port(connection.from, output: true)?.type
            else { continue }
            let dimmed = trace.map { !$0.connections.contains(connection) } ?? false
            var flash: CGFloat = 0
            if let fired = pulseTimes[connection.from] {
                flash = max(0, 1 - CGFloat(now - fired) / 0.35)
                if flash > 0 { stillFading = true }
            }
            // Live values: the cable moves while its value changes, and names the value
            // for a moment afterwards. A traced cable keeps its label.
            let values = store.runtime?.outputValues(connection.from) ?? []
            let sinceChange = changeTimes[connection.from].map { now - $0 } ?? .infinity
            let flow = CGFloat(max(0, 1 - sinceChange / Self.flowTime))
            let traced = trace != nil && !dimmed
            var label = traced ? 1 : CGFloat(min(1, max(0, (Self.labelTime - sinceChange) / 0.5)))
            // A pulse says all it has to with its flash, and a short cable has no room: the
            // ports at either end already show the value.
            if type == .pulse || values.isEmpty || hypot(to.x - from.x, to.y - from.y) < 84 { label = 0 }
            if flow > 0 || (label > 0 && label < 1) { stillFading = true }
            let cable = Cable(from: from, to: to)
            let resting = values.count == 1 && (values[0] == .bool(false) || values[0] == .pulse(false))
            drawCable(
                cable, color: PatchStyle.color(for: type), dimmed: dimmed, emphasized: traced,
                flash: flash, flow: flow, resting: resting, time: now
            )
            if label > 0 { labels.append((cable.point(at: 0.5), values, PatchStyle.color(for: type), label)) }
        }
        for label in labels { drawFlowLabel(label.values, at: label.point, color: label.color, alpha: label.alpha) }

        for node in graph.nodes {
            if let layout = layouts[node.id] { drawNode(node, layout) }
        }
        for (ref, end) in leaving { drawLeavingCable(from: ref, end.point, to: end.others, isInput: end.isInput) }

        // A port published on the view this level is inside: a tail naming it there.
        for holder in store.document.graph.nodes {
            for published in holder.published ?? [] where leaving[published.inner] == nil {
                guard let layout = layouts[published.inner.node] else { continue }
                let point = published.isOutput
                    ? layout.outputPortCenter(id: published.inner.port) : layout.inputPortCenter(id: published.inner.port)
                guard let point else { continue }
                drawTail(published.name, at: point, color: PatchStyle.color(for: published.type), isInput: !published.isOutput)
            }
        }

        switch drag {
        case let .cable(source, point, _):
            if let from = layouts[source.node]?.outputPortCenter(id: source.port),
               let type = port(source, output: true)?.type {
                drawCable(Cable(from: from, to: point), color: PatchStyle.color(for: type), dimmed: false, emphasized: true)
            }
        case let .cableFromInput(input, point):
            if let to = layouts[input.node]?.inputPortCenter(id: input.port),
               let type = port(input, output: false)?.type {
                drawCable(Cable(from: point, to: to), color: PatchStyle.color(for: type), dimmed: false, emphasized: true)
            }
        case let .marquee(start, current, _):
            let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(start.x - current.x), height: abs(start.y - current.y))
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(rect: rect).fill()
            NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
            let outline = NSBezierPath(rect: rect)
            outline.lineWidth = 1 / zoom
            outline.stroke()
        default:
            break
        }

        context.restoreGState()

        if graph.nodes.isEmpty {
            PatchStyle.draw(
                "Double-click to add a patch, or click a property in the Inspector.",
                in: bounds.insetBy(dx: 20, dy: 0), font: .systemFont(ofSize: 12), color: .tertiaryLabelColor, alignment: .center
            )
        }

        if stillFading, !fadeScheduled {
            fadeScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
                self?.fadeScheduled = false
                self?.needsDisplay = true
            }
        }
    }

    private func drawComment(_ comment: GraphComment) {
        let frame = frame(of: comment)
        let tint = NSColor.systemYellow
        let body = NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12)
        tint.withAlphaComponent(0.07).setFill()
        body.fill()
        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        tint.withAlphaComponent(0.3).setFill()
        CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: Self.commentTitleHeight).fill()
        NSGraphicsContext.restoreGraphicsState()
        tint.withAlphaComponent(0.45).setStroke()
        body.lineWidth = 1
        body.stroke()
        PatchStyle.draw(
            comment.text,
            in: CGRect(x: frame.minX + 10, y: frame.minY + 6, width: frame.width - 20, height: Self.commentTitleHeight - 8),
            font: PatchStyle.titleFont, color: .labelColor
        )
        // Resize grip.
        let grip = NSBezierPath()
        for inset in [5.0, 9.0] {
            grip.move(to: CGPoint(x: frame.maxX - inset, y: frame.maxY - 3))
            grip.line(to: CGPoint(x: frame.maxX - 3, y: frame.maxY - inset))
        }
        tint.withAlphaComponent(0.6).setStroke()
        grip.stroke()
    }

    /// The dot grid, drawn in view space so dots stay crisp at any zoom. Dots sit every two
    /// grid units; zoomed far out, only every fourth dot is kept so the field never gets busy.
    private func drawGrid() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        var spacing = CGFloat(PatchGrid.unit) * 2 * zoom
        while spacing < 14 { spacing *= 4 }
        let minorColor = NSColor.labelColor.withAlphaComponent(0.13).cgColor
        let majorColor = NSColor.labelColor.withAlphaComponent(0.26).cgColor
        let firstColumn = ((bounds.minX - pan.x) / spacing).rounded(.down)
        let firstRow = ((bounds.minY - pan.y) / spacing).rounded(.down)
        var row = firstRow
        while pan.y + row * spacing < bounds.maxY {
            var column = firstColumn
            while pan.x + column * spacing < bounds.maxX {
                let isMajor = Int(column) % 4 == 0 && Int(row) % 4 == 0
                let radius: CGFloat = isMajor ? 1.25 : 1
                context.setFillColor(isMajor ? majorColor : minorColor)
                context.fillEllipse(in: CGRect(
                    x: pan.x + column * spacing - radius, y: pan.y + row * spacing - radius,
                    width: radius * 2, height: radius * 2
                ))
                column += 1
            }
            row += 1
        }
    }

    /// The curve of one cable, with the means to place things along it.
    struct Cable {
        let from: CGPoint
        let to: CGPoint
        let control1: CGPoint
        let control2: CGPoint

        init(from: CGPoint, to: CGPoint) {
            self.from = from
            self.to = to
            let reach = max(36, abs(to.x - from.x) / 2)
            control1 = CGPoint(x: from.x + reach, y: from.y)
            control2 = CGPoint(x: to.x - reach, y: to.y)
        }

        var path: NSBezierPath {
            let path = NSBezierPath()
            path.move(to: from)
            path.curve(to: to, controlPoint1: control1, controlPoint2: control2)
            path.lineCapStyle = .round
            return path
        }

        func point(at t: CGFloat) -> CGPoint {
            let u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            return CGPoint(
                x: a * from.x + b * control1.x + c * control2.x + d * to.x,
                y: a * from.y + b * control1.y + c * control2.y + d * to.y
            )
        }

        /// Points spaced evenly along the curve, starting `offset` from its beginning.
        func points(every spacing: CGFloat, offset: CGFloat) -> [CGPoint] {
            let steps = 32
            var samples = [from]
            var lengths: [CGFloat] = [0]
            for step in 1...steps {
                let next = point(at: CGFloat(step) / CGFloat(steps))
                lengths.append(lengths[step - 1] + hypot(next.x - samples[step - 1].x, next.y - samples[step - 1].y))
                samples.append(next)
            }
            var result: [CGPoint] = []
            var distance = offset
            var segment = 1
            while distance < lengths[steps] {
                while segment < steps, lengths[segment] < distance { segment += 1 }
                let span = max(lengths[segment] - lengths[segment - 1], 0.0001)
                let part = (distance - lengths[segment - 1]) / span
                let a = samples[segment - 1], b = samples[segment]
                result.append(CGPoint(x: a.x + (b.x - a.x) * part, y: a.y + (b.y - a.y) * part))
                distance += spacing
            }
            return result
        }
    }

    /// `flow` is how recently the value changed (1 just now, 0 settled): beads then travel
    /// along the cable toward the input. `resting` is an Off or idle cable, drawn quieter.
    private func drawCable(
        _ cable: Cable, color: NSColor, dimmed: Bool, emphasized: Bool,
        flash: CGFloat = 0, flow: CGFloat = 0, resting: Bool = false, time: CFTimeInterval = 0
    ) {
        let path = cable.path
        // A casing in the background color keeps crossing cables apart.
        NSColor.underPageBackgroundColor.withAlphaComponent(dimmed ? 0.3 : 0.9).setStroke()
        path.lineWidth = 5
        path.stroke()
        if flash > 0 {
            color.withAlphaComponent(0.35 * flash).setStroke()
            path.lineWidth = 2 + 7 * flash
            path.stroke()
        }
        let strength: CGFloat = dimmed ? 0.22 : (resting && flow == 0 && flash == 0 ? 0.5 : 0.95)
        color.withAlphaComponent(strength).setStroke()
        path.lineWidth = (emphasized ? 2.5 : 2) + flow * 0.75
        path.stroke()

        guard flow > 0, !dimmed, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let spacing: CGFloat = 30
        let travelled = CGFloat((time * 110).truncatingRemainder(dividingBy: Double(spacing)))
        for point in cable.points(every: spacing, offset: travelled) {
            color.withAlphaComponent(flow).setFill()
            NSBezierPath(ovalIn: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)).fill()
            NSColor.white.withAlphaComponent(0.9 * flow).setFill()
            NSBezierPath(ovalIn: CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3)).fill()
        }
    }

    /// A cable whose other end is in another view's level: a short tail and the name of
    /// what is there, so nothing looks unconnected and the way to it is known.
    private func drawLeavingCable(from ref: PortRef, _ point: CGPoint, to others: [NodeID], isInput: Bool) {
        let full = store.document.graph
        guard let first = others.first.flatMap({ full.node($0) }) else { return }
        var text = store.title(for: first)
        if text.count > 16 { text = String(text.prefix(15)) + "…" }
        if others.count > 1 { text += " +\(others.count - 1)" }
        let color = port(ref, output: !isInput).map { PatchStyle.color(for: $0.type) } ?? .secondaryLabelColor
        drawTail(text, at: point, color: color, isInput: isInput)
    }

    /// A short dashed line out of a port, ending in a capsule that names what is at the
    /// other end, somewhere outside this level.
    private func drawTail(_ name: String, at point: CGPoint, color: NSColor, isInput: Bool) {
        var text = name
        if text.count > 20 { text = String(text.prefix(19)) + "…" }
        let direction: CGFloat = isInput ? -1 : 1
        let tail = CGPoint(x: point.x + direction * 30, y: point.y)
        let line = NSBezierPath()
        line.move(to: point)
        line.line(to: tail)
        line.lineWidth = 2
        line.setLineDash([4, 3], count: 2, phase: 0)
        color.withAlphaComponent(0.8).setStroke()
        line.stroke()

        let attributes: [NSAttributedString.Key: Any] = [.font: PatchStyle.valueFont]
        let width = ceil((text as NSString).size(withAttributes: attributes).width) + 14
        let rect = CGRect(x: isInput ? tail.x - width : tail.x, y: point.y - 9, width: width, height: 18)
        let capsule = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        NSColor.controlBackgroundColor.setFill()
        capsule.fill()
        color.withAlphaComponent(0.7).setStroke()
        capsule.lineWidth = 1
        capsule.stroke()
        PatchStyle.draw(text, in: rect.insetBy(dx: 7, dy: 2), font: PatchStyle.valueFont, color: .secondaryLabelColor, alignment: .center)
    }

    /// A small capsule on a cable naming what it carries right now.
    private func drawFlowLabel(_ values: [Value], at point: CGPoint, color: NSColor, alpha: CGFloat) {
        guard let first = values.first else { return }
        var text = values.count == 1 ? first.summary : "×\(values.count)"
        if text.count > 18 { text = String(text.prefix(17)) + "…" }
        var swatch: ColorValue?
        if values.count == 1, case let .color(value) = first { swatch = value }
        let attributes: [NSAttributedString.Key: Any] = [.font: PatchStyle.valueFont]
        let textWidth = swatch == nil ? ceil((text as NSString).size(withAttributes: attributes).width) : 18
        let rect = CGRect(x: point.x - textWidth / 2 - 7, y: point.y - 9, width: textWidth + 14, height: 18)
        let capsule = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        NSGraphicsContext.current?.cgContext.setAlpha(alpha)
        NSColor.controlBackgroundColor.setFill()
        capsule.fill()
        color.withAlphaComponent(0.7).setStroke()
        capsule.lineWidth = 1
        capsule.stroke()
        if let swatch {
            drawSwatch(swatch, in: rect.insetBy(dx: 5, dy: 4))
        } else {
            PatchStyle.draw(text, in: rect.insetBy(dx: 7, dy: 0), font: PatchStyle.valueFont, color: .labelColor, alignment: .center)
        }
        NSGraphicsContext.current?.cgContext.setAlpha(1)
    }

    private func drawNode(_ node: PatchNode, _ layout: PatchLayout) {
        let frame = layout.frame
        let isSelected = selection.contains(node.id)
        let inTrace = trace?.nodes.contains(node.id) ?? false
        let category = PatchStyle.category(of: node, in: store.registry)
        let radius = PatchLayout.cornerRadius
        let body = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
        // A patch whose extension is missing or off keeps its place, ports and cables,
        // and is drawn as the placeholder it is.
        let missing = store.missingExtension(for: node)

        // Shadow and body. A selected patch lifts a little.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(isSelected ? 0.3 : 0.16)
        shadow.shadowBlurRadius = isSelected ? 14 : 8
        shadow.shadowOffset = NSSize(width: 0, height: isSelected ? -5 : -2)
        shadow.set()
        NSColor.controlBackgroundColor.setFill()
        body.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Header tint, clipped to the rounded body.
        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        (missing == nil ? PatchStyle.color(for: category) : NSColor.secondaryLabelColor).withAlphaComponent(0.22).setFill()
        layout.headerRect.fill()
        NSColor.separatorColor.setFill()
        CGRect(x: frame.minX, y: layout.headerRect.maxY - 0.5, width: frame.width, height: 0.5).fill()
        NSGraphicsContext.restoreGraphicsState()

        if isSelected {
            NSColor.controlAccentColor.setStroke()
            body.lineWidth = 2
        } else if inTrace {
            NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
            body.lineWidth = 1.5
        } else {
            NSColor.separatorColor.setStroke()
            body.lineWidth = 1
        }
        if missing != nil, !isSelected {
            NSColor.secondaryLabelColor.setStroke()
            body.setLineDash([4, 3], count: 2, phase: 0)
        }
        body.stroke()

        // Title and what the patch is attached to.
        let titleRect = CGRect(x: frame.minX + 10, y: frame.minY, width: frame.width - 20, height: PatchLayout.titleHeight)
        if let subtitle = store.subtitle(for: node) {
            PatchStyle.draw(store.title(for: node), in: titleRect.offsetBy(dx: 0, dy: 1), font: PatchStyle.titleFont, color: .labelColor)
            PatchStyle.draw(
                subtitle,
                in: CGRect(x: titleRect.minX, y: titleRect.maxY - 4, width: titleRect.width, height: PatchLayout.subtitleHeight),
                font: PatchStyle.subtitleFont, color: .secondaryLabelColor
            )
        } else if let missing {
            // The name on the left, what it needs on the right.
            let need = "Needs \(missing)"
            let needWidth = min((need as NSString).size(withAttributes: [.font: PatchStyle.subtitleFont]).width + 2, titleRect.width * 0.62)
            PatchStyle.draw(
                store.title(for: node), in: CGRect(x: titleRect.minX, y: titleRect.minY, width: titleRect.width - needWidth - 6, height: titleRect.height),
                font: PatchStyle.titleFont, color: .secondaryLabelColor
            )
            PatchStyle.draw(
                need, in: CGRect(x: titleRect.maxX - needWidth, y: titleRect.minY, width: needWidth, height: titleRect.height),
                font: PatchStyle.subtitleFont, color: .secondaryLabelColor, alignment: .right
            )
        } else {
            PatchStyle.draw(store.title(for: node), in: titleRect, font: PatchStyle.titleFont, color: .labelColor)
        }

        let runtime = store.runtime

        for (index, port) in layout.ports.inputs.enumerated() {
            let ref = PortRef(node: node.id, port: port.id)
            let row = layout.inputRow(index)
            let connected = isConnected(input: ref)
            drawPort(at: layout.inputPort(index), type: port.type, filled: connected)
            PatchStyle.draw(
                port.name,
                in: CGRect(x: row.minX + 12, y: row.minY, width: row.width - PatchLayout.valueWidth - 26, height: row.height),
                font: PatchStyle.labelFont, color: .labelColor
            )
            let valueRect = layout.inputValueRect(index)
            if connected {
                if let values = runtime?.inputValues(ref), values.count != 1 {
                    // A loop arrives here: show how long it is rather than one of its values.
                    PatchStyle.draw(
                        "×\(values.count)", in: valueRect.insetBy(dx: 4, dy: 2), font: PatchStyle.valueFont,
                        color: .secondaryLabelColor, alignment: .right
                    )
                } else if let value = runtime?.inputValue(ref) {
                    drawValue(value, in: valueRect, editable: false)
                }
            } else if port.type != .pulse {
                // On a view's patch this is the view's own value: editing it here is the
                // same as editing it in the Inspector.
                drawValue(
                    node.kind == PatchKind.view && port.id == ShaderUse.codePort ? .text("Edit…") : store.literal(for: port, of: node),
                    in: valueRect, editable: isEditable(node, port)
                )
            }
        }

        for (index, port) in layout.ports.outputs.enumerated() {
            let ref = PortRef(node: node.id, port: port.id)
            let row = layout.outputRow(index)
            let connected = !graph.connections(from: ref).isEmpty
            drawPort(at: layout.outputPort(index), type: port.type, filled: connected)
            PatchStyle.draw(
                port.name,
                in: CGRect(x: row.midX - 8, y: row.minY, width: row.width / 2 - 4, height: row.height),
                font: PatchStyle.labelFont, color: .labelColor, alignment: .right
            )
            let loop = runtime?.outputValues(ref) ?? []
            let rect = CGRect(x: row.minX + 10, y: row.minY + 2, width: row.width / 2 - 20, height: row.height - 4)
            if loop.count != 1, runtime != nil {
                let active = loop.contains { $0 == .pulse(true) || $0 == .bool(true) }
                PatchStyle.draw(
                    "×\(loop.count)", in: rect, font: PatchStyle.valueFont,
                    color: active ? PatchStyle.color(for: port.type) : .secondaryLabelColor
                )
            } else if let value = runtime?.outputValue(ref) {
                // A pulse is there for one frame; the rest of the time there is nothing to say.
                if value == .pulse(false) { continue }
                if case let .color(color) = value {
                    drawSwatch(color, in: CGRect(x: rect.minX, y: rect.minY + 2, width: 22, height: rect.height - 4))
                } else {
                    let active = value == .pulse(true) || value == .bool(true)
                    PatchStyle.draw(
                        value.summary, in: rect, font: PatchStyle.valueFont,
                        color: active ? PatchStyle.color(for: port.type) : .secondaryLabelColor
                    )
                }
            }
        }
    }

    private func drawPort(at center: CGPoint, type: PortType, filled: Bool) {
        let radius = PatchLayout.portRadius
        let circle = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        if filled {
            // A ring in the patch's own color sets a connected port apart from its cable.
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(ovalIn: CGRect(x: center.x - radius - 2, y: center.y - radius - 2, width: radius * 2 + 4, height: radius * 2 + 4)).fill()
            PatchStyle.color(for: type).setFill()
            circle.fill()
        } else {
            NSColor.controlBackgroundColor.setFill()
            circle.fill()
            PatchStyle.color(for: type).setStroke()
            circle.lineWidth = 1.5
            circle.stroke()
        }
    }

    private func drawSwatch(_ color: ColorValue, in rect: CGRect) {
        let swatch = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha).setFill()
        swatch.fill()
        NSColor.separatorColor.setStroke()
        swatch.lineWidth = 1
        swatch.stroke()
    }

    private func drawValue(_ value: Value, in rect: CGRect, editable: Bool) {
        // A pulse that is not firing has no value to show.
        if value == .pulse(false) { return }
        if editable {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }
        if case let .color(color) = value {
            drawSwatch(color, in: rect.insetBy(dx: 4, dy: 3))
            return
        }
        PatchStyle.draw(
            value.summary,
            in: rect.insetBy(dx: 5, dy: 0),
            font: PatchStyle.valueFont,
            color: editable ? .labelColor : .secondaryLabelColor,
            alignment: .right
        )
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) {
        // AppKit can re-deliver a press late, after its release was already handled.
        // Acting on it would start a second, phantom interaction.
        guard event.timestamp > lastMouseUp else { return }
        endEditing(commit: true)
        window?.makeFirstResponder(self)
        hasFramedContent = true
        let point = graphPoint(event)
        lastMouseGraphPoint = point

        switch hit(at: point) {
        case let .output(ref):
            drag = .cable(source: ref, point: point, rerouting: nil)

        case let .input(ref):
            if let existing = graph.connection(into: ref) {
                // Pull the cable off the input; it can be dropped elsewhere or let go.
                drag = .cable(source: existing.from, point: point, rerouting: ref)
            } else {
                drag = .cableFromInput(input: ref, point: point)
            }

        case let .value(nodeID, port):
            guard let node = graph.node(nodeID) else { return }
            // A shader view's code is edited in its own pane, not in the row.
            if node.kind == PatchKind.view, port.id == ShaderUse.codePort, let layer = node.layerID {
                store.editingShader = layer
                return
            }
            let literal = store.literal(for: port, of: node)
            switch port.type {
            case .number:
                let start = literal.numberValue
                let step = start == start.rounded() ? 1.0 : 0.01
                drag = .scrub(node: nodeID, port: port, start: start, startX: event.locationInWindow.x, step: step, moved: false)
            case .bool:
                store.setLiteral(.bool(!literal.boolValue), node: nodeID, port: port.id)
            case .color:
                pickColor(node: nodeID, port: port, current: literal.colorValue)
            case .text where !port.options.isEmpty:
                showOptions(node: nodeID, port: port, current: literal.textValue, event: event)
            default:
                drag = .pendingEdit(node: nodeID, port: port)
            }

        case let .header(nodeID), let .body(nodeID):
            // A double-click on a view that holds others steps into it; on a component, into
            // the component.
            if event.clickCount == 2, let node = graph.node(nodeID), node.kind == PatchKind.view,
               let layer = node.layerID.flatMap({ store.document.layer($0) }) {
                if let use = layer.component {
                    store.enterComponent(use.id)
                    return
                }
                if layer.kind.canHaveChildren, layer.id != store.openContainer.id {
                    store.open(layer.id)
                    return
                }
            }
            if event.clickCount == 2, case .header = hit(at: point) {
                beginRename(nodeID)
                return
            }
            if event.clickCount == 2, graph.node(nodeID)?.kind == PatchKind.javascript {
                store.editingScript = nodeID
                return
            }
            if event.modifierFlags.contains(.shift) {
                if store.selectedNodes.contains(nodeID) {
                    store.selectedNodes.remove(nodeID)
                } else {
                    store.selectedNodes.insert(nodeID)
                }
            } else if !store.selectedNodes.contains(nodeID) {
                store.selectedNodes = [nodeID]
            }
            var originals: [NodeID: Point2] = [:]
            for id in store.selectedNodes {
                if let node = graph.node(id) { originals[id] = node.position }
            }
            drag = .moveNodes(start: point, originals: originals)

        case let .commentTitle(id):
            guard let comment = graph.comments.first(where: { $0.id == id }) else { return }
            if event.clickCount == 2 {
                beginEditing(
                    in: CGRect(x: comment.origin.x + 6, y: comment.origin.y + 3, width: comment.size.width - 12, height: 22),
                    text: comment.text, alignment: .left
                ) { [store] text in store.renameComment(id, to: text) }
                return
            }
            let area = frame(of: comment)
            var originals: [NodeID: Point2] = [:]
            for node in graph.nodes {
                if let layout = layouts[node.id], area.contains(layout.frame) { originals[node.id] = node.position }
            }
            drag = .moveComment(id: id, start: point, origin: comment.origin, originals: originals)

        case let .commentCorner(id):
            guard let comment = graph.comments.first(where: { $0.id == id }) else { return }
            drag = .resizeComment(id: id, start: point, size: comment.size)

        case .empty:
            if event.clickCount == 2 {
                showLibrary(at: point)
                return
            }
            let base = event.modifierFlags.contains(.shift) ? store.selectedNodes : []
            if base.isEmpty { store.selectedNodes = [] }
            drag = .marquee(start: point, current: point, base: base)
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        let point = graphPoint(event)
        lastMouseGraphPoint = point
        switch drag {
        case .none, .pendingEdit:
            break

        case let .moveNodes(start, originals):
            let dx = point.x - start.x
            let dy = point.y - start.y
            // Patches land on the grid. Holding Command places them freely.
            let free = event.modifierFlags.contains(.command)
            store.interactive { document in
                for (id, original) in originals {
                    let moved = Point2(x: (original.x + dx).rounded(), y: (original.y + dy).rounded())
                    document.graph.update(id) { $0.position = free ? moved : PatchGrid.snap(moved) }
                }
            }

        case let .moveComment(id, start, origin, originals):
            let free = event.modifierFlags.contains(.command)
            let dx = free ? (point.x - start.x).rounded() : PatchGrid.snap(point.x - start.x)
            let dy = free ? (point.y - start.y).rounded() : PatchGrid.snap(point.y - start.y)
            store.interactive { document in
                if let index = document.graph.comments.firstIndex(where: { $0.id == id }) {
                    document.graph.comments[index].origin = Point2(x: origin.x + dx, y: origin.y + dy)
                }
                for (node, original) in originals {
                    document.graph.update(node) { $0.position = Point2(x: original.x + dx, y: original.y + dy) }
                }
            }

        case let .resizeComment(id, start, size):
            store.interactive { document in
                if let index = document.graph.comments.firstIndex(where: { $0.id == id }) {
                    document.graph.comments[index].size = Size2(
                        width: max(PatchGrid.snap(size.width + point.x - start.x), 120),
                        height: max(PatchGrid.snap(size.height + point.y - start.y), 60)
                    )
                }
            }

        case let .marquee(start, _, base):
            drag = .marquee(start: start, current: point, base: base)
            let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(start.x - point.x), height: abs(start.y - point.y))
            let inside = layouts.filter { $0.value.frame.intersects(rect) }.map(\.key)
            store.selectedNodes = base.union(inside)
            needsDisplay = true

        case let .cable(source, _, rerouting):
            drag = .cable(source: source, point: point, rerouting: rerouting)
            store.cableDropProperty = propertyDropTarget(for: event, source: source)
            needsDisplay = true

        case let .cableFromInput(input, _):
            drag = .cableFromInput(input: input, point: point)
            needsDisplay = true

        case let .scrub(node, port, start, startX, step, _):
            let distance = event.locationInWindow.x - startX
            guard abs(distance) >= 2 else { return }
            let fine = event.modifierFlags.contains(.option) ? 0.1 : 1.0
            let unit = step * fine
            let value = ((start + Double(distance) * unit) / unit).rounded() * unit
            drag = .scrub(node: node, port: port, start: start, startX: startX, step: step, moved: true)
            store.setLiteral(.number(value), node: node, port: port.id, interactive: true)
        }
    }

    public override func mouseUp(with event: NSEvent) {
        lastMouseUp = event.timestamp
        let point = graphPoint(event)
        let finished = drag
        drag = .none
        needsDisplay = true

        switch finished {
        case .none, .marquee:
            break

        case .moveNodes:
            store.endInteractive("Move Patch")

        case .moveComment:
            store.endInteractive("Move Comment")

        case .resizeComment:
            store.endInteractive("Resize Comment")

        case let .cable(source, _, rerouting):
            store.cableDropProperty = nil
            if case let .input(target) = hit(at: point) {
                if target == rerouting { return }
                if !store.connect(from: source, to: target, replacing: rerouting) { NSSound.beep() }
            } else if let input = propertyDropTarget(for: event, source: source), let layer = store.selectedLayer {
                if let rerouting { store.disconnect(input: rerouting) }
                store.connect(from: source, to: input, of: layer.id)
            } else if let rerouting {
                store.disconnect(input: rerouting)
            }

        case let .cableFromInput(input, _):
            if case let .output(source) = hit(at: point) {
                if !store.connect(from: source, to: input) { NSSound.beep() }
            }

        case let .scrub(node, port, _, _, _, moved):
            if moved {
                store.endInteractive("Change Value")
            } else {
                beginValueEdit(node: node, port: port)
            }

        case let .pendingEdit(node, port):
            beginValueEdit(node: node, port: port)
        }
    }

    /// The Inspector property under the cursor that could accept this cable, if any.
    private func propertyDropTarget(for event: NSEvent, source: PortRef) -> ViewInput? {
        guard let layer = store.selectedLayer, let type = port(source, output: true)?.type else { return nil }
        let location = event.locationInWindow
        let shown = Set(layer.inputs)
        for (input, frame) in store.propertyDropTargets where shown.contains(input) {
            if let rect = frame(), rect.contains(location), Value.canConnect(from: type, to: input.type) {
                return input
            }
        }
        return nil
    }

    public override func rightMouseDown(with event: NSEvent) {
        endEditing(commit: true)
        let point = graphPoint(event)
        lastMouseGraphPoint = point
        guard let menu = contextMenu(at: point) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Where a port is drawn, in the graph's own coordinates.
    func portPoint(_ ref: PortRef, output: Bool) -> CGPoint? {
        output ? layouts[ref.node]?.outputPortCenter(id: ref.port) : layouts[ref.node]?.inputPortCenter(id: ref.port)
    }

    /// The menu a right-click at a place in the graph opens; nil when there is nothing to offer.
    func contextMenu(at point: CGPoint) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false

        switch hit(at: point) {
        case let .input(ref):
            if isConnected(input: ref) {
                menu.addAction("Disconnect") { [store] in store.disconnect(input: ref) }
                // A cable from another view's level: the way to where it comes from.
                if let source = graph.connection(into: ref)?.from.node, layouts[source] == nil,
                   let other = store.document.graph.node(source) {
                    menu.addAction("Go to \(store.title(for: other))") { [store] in store.show(source) }
                }
            }
            addPublishing(to: menu, for: ref, output: false)
            if menu.items.isEmpty { return nil }

        case let .output(ref):
            addPublishing(to: menu, for: ref, output: true)
            if menu.items.isEmpty { return nil }

        case let .header(nodeID), let .body(nodeID), let .value(nodeID, _):
            if !store.selectedNodes.contains(nodeID) { store.selectedNodes = [nodeID] }
            guard let node = graph.node(nodeID) else { return nil }
            if node.kind == PatchKind.view, let layer = node.layerID.flatMap({ store.document.layer($0) }),
               layer.kind.canHaveChildren, layer.component == nil, layer.id != store.openContainer.id {
                menu.addAction("Step Into \(layer.name)") { [store] in store.open(layer.id) }
            }
            menu.addAction("Rename…") { [weak self] in self?.beginRename(nodeID) }
            if let source = store.broadcaster(for: node) {
                menu.addAction("Go to Broadcast") { [store] in store.show(source.id) }
            }
            if let definition = store.registry.definition(node.kind), definition.isGeneric {
                let types = NSMenu()
                let current = store.registry.valueType(for: node)
                for type in definition.genericTypes {
                    types.addAction(type.displayName, checked: type == current) { [store] in
                        store.setValueType(type, node: nodeID)
                    }
                }
                let item = NSMenuItem(title: "Type", action: nil, keyEquivalent: "")
                item.submenu = types
                menu.addItem(item)
            }
            if node.kind == PatchKind.javascript {
                menu.addAction("Edit Script…") { [store] in store.editingScript = nodeID }
            }
            if node.kind == PatchKind.view, let layer = node.layerID, store.document.layer(layer)?.shader != nil {
                menu.addAction("Edit Shader…") { [store] in store.editingShader = layer }
            }
            if node.isInstance, let id = node.componentID {
                menu.addAction("Edit Component") { [store] in store.enterComponent(id) }
            }
            // Where layout put the view, as outputs: shown like inputs, when chosen or cabled.
            // Not the screen's: it fills the device, as the Inspector says by leaving it out.
            if node.kind == PatchKind.view, let layer = node.layerID, layer != store.document.screen.id {
                let outputs = NSMenu()
                let shown = store.shownOutputs(on: node)
                for output in ViewOutput.allCases {
                    outputs.addAction(output.name, checked: shown.contains(output)) { [store] in
                        store.setOutputPort(output, of: layer, shown: !shown.contains(output))
                    }
                }
                let item = NSMenuItem(title: "Frame Outputs", action: nil, keyEquivalent: "")
                item.submenu = outputs
                menu.addItem(item)
            }
            if let inputs = store.registry.variableInputCount(for: node) {
                if inputs.count < inputs.range.upperBound {
                    menu.addAction("Add Input") { [store] in store.changeInputCount(of: nodeID, by: 1) }
                }
                if inputs.count > inputs.range.lowerBound {
                    menu.addAction("Remove Input") { [store] in store.changeInputCount(of: nodeID, by: -1) }
                }
            }
            menu.addItem(.separator())
            menu.addAction(store.selectedNodes.count > 1 ? "Add \(store.selectedNodes.count) to Assistant" : "Add to Assistant") { [store] in
                store.addToAssistant()
            }
            menu.addItem(.separator())
            menu.addAction("Delete") { [store] in store.deleteSelectedPatches() }

        case let .commentTitle(id), let .commentCorner(id):
            menu.addAction("Rename Comment") { [weak self] in
                guard let self, let comment = self.graph.comments.first(where: { $0.id == id }) else { return }
                self.beginEditing(
                    in: CGRect(x: comment.origin.x + 6, y: comment.origin.y + 3, width: comment.size.width - 12, height: 22),
                    text: comment.text, alignment: .left
                ) { [store = self.store] text in store.renameComment(id, to: text) }
            }
            menu.addAction("Delete Comment") { [store] in store.deleteComment(id) }

        default:
            if store.openView != nil {
                let outer = store.openPath.dropLast().last?.name ?? "Screen"
                menu.addAction("Step Out to \(outer)") { [store] in store.closeView() }
            }
            menu.addAction("Add View or Patch…") { [weak self] in self?.showLibrary(at: point) }
            menu.addAction(store.selectedNodes.isEmpty ? "Add Comment" : "Add Comment Around Selection") { [store] in
                store.addComment(at: Point2(x: point.x, y: point.y))
            }
            menu.addAction("Show All Patches") { [weak self] in self?.frameContent() }
        }
        return menu
    }

    /// The menu items that publish a port on the view it is in, or take it back. They are
    /// offered on the port inside and on the published port outside.
    private func addPublishing(to menu: NSMenu, for ref: PortRef, output: Bool) {
        let full = store.document.graph
        var found: (node: NodeID, port: PublishedPort)?
        if let outside = full.published(ref, output: output) {
            found = (ref.node, outside)
            if let inner = full.node(outside.inner.node) {
                menu.addAction("Go to \(store.title(for: inner))") { [store] in store.show(inner.id) }
            }
        } else if let inside = store.publication(of: ref, output: output) {
            found = inside
        } else if store.canPublish(ref, output: output), let target = store.publishTarget(for: ref) {
            menu.addAction("Publish to \(store.title(for: target))") { [store] in store.publish(ref, output: output) }
        }
        guard let found else { return }
        menu.addAction("Rename Port…") { [weak self] in self?.renamePublished(found.port, on: found.node) }
        menu.addAction("Unpublish “\(found.port.name)”") { [store] in store.unpublish(found.port.id, on: found.node) }
    }

    private func renamePublished(_ port: PublishedPort, on node: NodeID) {
        let alert = NSAlert()
        alert.messageText = "Rename Port"
        alert.informativeText = "The name this port has on the view's patch."
        let field = NSTextField(string: port.name)
        field.frame = CGRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard let window else { return }
        alert.beginSheetModal(for: window) { [store] response in
            if response == .alertFirstButtonReturn { store.renamePublished(port.id, on: node, to: field.stringValue) }
        }
    }

    // MARK: Scrolling, zooming, keys

    public override func scrollWheel(with event: NSEvent) {
        endEditing(commit: true)
        if event.modifierFlags.contains(.command) {
            zoom(by: 1 + event.scrollingDeltaY * 0.01, around: event)
        } else {
            hasFramedContent = true
            pan.x += event.scrollingDeltaX
            pan.y += event.scrollingDeltaY
            needsDisplay = true
        }
    }

    public override func magnify(with event: NSEvent) {
        endEditing(commit: true)
        zoom(by: 1 + event.magnification, around: event)
    }

    private func zoom(by factor: CGFloat, around event: NSEvent) {
        hasFramedContent = true
        let anchor = graphPoint(event)
        let cursor = convert(event.locationInWindow, from: nil)
        zoom = min(max(zoom * factor, 0.25), 2)
        pan = CGPoint(x: cursor.x - anchor.x * zoom, y: cursor.y - anchor.y * zoom)
        needsDisplay = true
    }

    public override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "a" {
                store.selectedNodes = Set(graph.nodes.map(\.id))
            } else if event.charactersIgnoringModifiers == "d" {
                store.duplicateSelectedPatches()
            } else {
                super.keyDown(with: event)
            }
            return
        }
        switch event.keyCode {
        case 51, 117: store.deleteSelectedPatches()
        case 36, 76: showLibrary(at: lastMouseGraphPoint)
        case 53: store.selectedNodes = []
        default: super.keyDown(with: event)
        }
    }

    // MARK: Copy and paste (the Edit menu's standard actions)

    @objc func copy(_ sender: Any?) {
        store.copyToPasteboard(store.fragmentOfSelectedPatches())
    }

    @objc func cut(_ sender: Any?) {
        copy(sender)
        store.deleteSelectedPatches()
    }

    @objc func paste(_ sender: Any?) {
        if !store.pasteFromPasteboard() { NSSound.beep() }
    }

    // MARK: Editing values and names

    private func beginValueEdit(node nodeID: NodeID, port: PaperEngine.Port) {
        guard let node = graph.node(nodeID), let layout = layouts[nodeID],
              let index = layout.ports.inputs.firstIndex(of: port)
        else { return }
        let literal = store.literal(for: port, of: node)
        let initial: String
        switch literal {
        case let .point(point): initial = "\(Value.format(point.x)), \(Value.format(point.y))"
        case let .size(size): initial = "\(Value.format(size.width)), \(Value.format(size.height))"
        default: initial = literal.summary
        }
        beginEditing(in: layout.inputValueRect(index), text: initial, alignment: .right) { [store] text in
            guard let value = PatchEditorView.parse(text, as: port.type) else {
                NSSound.beep()
                return
            }
            store.setLiteral(value, node: nodeID, port: port.id)
        }
    }

    private func beginRename(_ nodeID: NodeID) {
        guard let node = graph.node(nodeID), let layout = layouts[nodeID] else { return }
        let rect = CGRect(x: layout.frame.minX + 6, y: layout.frame.minY + 3, width: layout.frame.width - 12, height: 20)
        beginEditing(in: rect, text: store.title(for: node), alignment: .left) { [store] text in
            store.renamePatch(nodeID, to: text)
        }
    }

    static func parse(_ text: String, as type: PortType) -> Value? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        func numbers() -> [Double] {
            trimmed
                .replacingOccurrences(of: "×", with: ",")
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "x" })
                .compactMap { Double($0) }
        }
        // "nan", "inf" and "1e400" all read as numbers that a layer cannot be drawn or saved
        // with. One of them spoils the whole value; dropping it would change what was meant.
        if type == .point || type == .size, numbers().contains(where: { !$0.isFinite }) { return nil }
        switch type {
        case .number:
            return Double(trimmed).flatMap { $0.isFinite ? Value.number($0) : nil }
        case .text:
            return .text(text)
        case .point:
            let parts = numbers()
            if parts.count == 2 { return .point(Point2(x: parts[0], y: parts[1])) }
            if parts.count == 1 { return .point(Point2(x: parts[0], y: parts[0])) }
            return nil
        case .size:
            let parts = numbers()
            if parts.count == 2 { return .size(Size2(width: parts[0], height: parts[1])) }
            if parts.count == 1 { return .size(Size2(width: parts[0], height: parts[0])) }
            return nil
        case .color:
            return ColorValue(hex: trimmed).map(Value.color)
        case .bool:
            switch trimmed.lowercased() {
            case "on", "true", "1", "yes": return .bool(true)
            case "off", "false", "0", "no": return .bool(false)
            default: return nil
            }
        case .pulse, .array, .json:
            return nil
        }
    }

    private func beginEditing(in graphRect: CGRect, text: String, alignment: NSTextAlignment, commit: @escaping (String) -> Void) {
        endEditing(commit: true)
        let field = NSTextField(frame: viewRect(graphRect).insetBy(dx: -2, dy: -2))
        field.stringValue = text
        field.font = .systemFont(ofSize: max(11 * zoom, 9))
        field.alignment = alignment
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.delegate = self
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        addSubview(field)
        fieldEditor = field
        commitEdit = commit
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func endEditing(commit: Bool) {
        guard let field = fieldEditor else { return }
        let text = field.stringValue
        let action = commitEdit
        fieldEditor = nil
        commitEdit = nil
        field.delegate = nil
        field.removeFromSuperview()
        if commit { action?(text) }
    }

    public func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === fieldEditor else { return }
        endEditing(commit: true)
        window?.makeFirstResponder(self)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            endEditing(commit: false)
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }

    private func showOptions(node: NodeID, port: PaperEngine.Port, current: String, event: NSEvent) {
        let menu = NSMenu()
        for option in port.options {
            menu.addAction(option, checked: option == current) { [store] in
                store.setLiteral(.text(option), node: node, port: port.id)
            }
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func pickColor(node: NodeID, port: PaperEngine.Port, current: ColorValue) {
        colorTarget = (node, port.id)
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        panel.color = NSColor(srgbRed: current.red, green: current.green, blue: current.blue, alpha: current.alpha)
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ panel: NSColorPanel) {
        guard let target = colorTarget, graph.node(target.node) != nil,
              let color = panel.color.usingColorSpace(.sRGB)
        else { return }
        let value = ColorValue(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent, alpha: color.alphaComponent)
        store.setLiteral(.color(value), node: target.node, port: target.port, interactive: true)
        store.endInteractiveSoon("Change Value")
    }

    // MARK: Patch Library

    /// Opens the Patch Library at a point in the graph; the chosen patch is placed there.
    public func showLibrary(at graphLocation: CGPoint? = nil) {
        popover?.close()
        // Asked for from the menu or Option-Space with the pointer over the graph: open
        // where the pointer is, as Return does. Otherwise in the middle of what is shown.
        var pointer: CGPoint?
        if graphLocation == nil, let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(point) { pointer = CGPoint(x: (point.x - pan.x) / zoom, y: (point.y - pan.y) / zoom) }
        }
        let location = graphLocation ?? pointer ?? CGPoint(
            x: (bounds.midX - pan.x) / zoom - PatchLayout.width / 2,
            y: (bounds.midY - pan.y) / zoom - 60
        )
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PatchLibraryView(
            registry: store.registry,
            shelves: store.componentShelves,
            selectedLayerName: store.selectedLayer.flatMap { $0.kind == .screen ? nil : $0.name },
            selectedLayerKind: store.selectedLayer?.kind,
            selectedLayerIsScreen: store.selectedLayer?.isPage ?? false,
            containerName: store.containerForNewViews.name
        ) { [weak self, weak popover] item in
            popover?.close()
            self?.insert(item, at: location)
        })
        let anchor = viewRect(CGRect(x: location.x, y: location.y, width: 1, height: 1))
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
        self.popover = popover
    }

    private func insert(_ item: LibraryItem, at location: CGPoint) {
        // Step aside until the new patch does not sit exactly on top of another one.
        var spot = CGPoint(x: PatchGrid.snap(location.x), y: PatchGrid.snap(location.y))
        while layouts.values.contains(where: { abs($0.frame.minX - spot.x) < 12 && abs($0.frame.minY - spot.y) < 12 }) {
            spot.x += 24
            spot.y += 24
        }
        let position = Point2(x: spot.x, y: spot.y)
        let definition: PatchDefinition
        switch item {
        case let .view(type):
            // A view is a patch: it appears here in the graph, and in the outline inside
            // the selected container.
            store.addView(type, patchAt: position)
            window?.makeFirstResponder(self)
            return
        case let .custom(view):
            store.addExtensionView(view, patchAt: position)
            window?.makeFirstResponder(self)
            return
        case let .component(component, _):
            store.insertComponent(component)
            window?.makeFirstResponder(self)
            return
        case let .template(template):
            store.insertTemplate(template)
            window?.makeFirstResponder(self)
            return
        case let .patch(chosen):
            definition = chosen
        }
        if DocumentStore.touchPatchKinds.contains(definition.kind) {
            guard let layer = store.selectedLayer, layer.kind != .screen,
                  DocumentStore.fits(definition.kind, layer) else { return }
            store.addTouchPatch(definition.kind, for: layer.id, at: position)
        } else {
            store.addPatch(definition.kind, at: position)
        }
        window?.makeFirstResponder(self)
    }
}

struct PatchEditorRepresentable: NSViewRepresentable {
    let store: DocumentStore
    let graph: Graph
    let selection: Set<NodeID>
    let reveal: NodeID?
    /// Layer names appear on patches, so layer edits must redraw the graph too.
    let layers: Layer
    let libraryRequest: Int
    let fitRequest: Int
    /// Patches are drawn from their definitions, so a change of those redraws the graph too.
    var registryRevision = 0

    final class Coordinator {
        var libraryRequest = 0
        var fitRequest = 0
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.libraryRequest = libraryRequest
        return coordinator
    }

    func makeNSView(context: Context) -> PatchEditorView {
        PatchEditorView(store: store)
    }

    func updateNSView(_ view: PatchEditorView, context: Context) {
        view.update(graph: graph, selection: selection, reveal: reveal)
        if context.coordinator.libraryRequest != libraryRequest {
            context.coordinator.libraryRequest = libraryRequest
            view.showLibrary()
        }
        if context.coordinator.fitRequest != fitRequest {
            context.coordinator.fitRequest = fitRequest
            view.frameContent()
        }
    }
}
