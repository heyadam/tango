import AppKit
import PaperEngine
import PaperHost
import PaperModel
import PaperRender
import QuartzCore
import SwiftUI

/// Where the visible interface is arranged. Every screen of the prototype is drawn as it
/// was designed, side by side (`Board`), and what is on them is edited in place: selected,
/// moved, resized, drawn, retyped. Arrows between screens are the Navigate patches of the
/// graph. It shows the document's own values, not the running prototype.
public final class CanvasView: NSView, NSTextFieldDelegate {
    private let store: DocumentStore
    /// One renderer per frame of the board.
    private var renderers: [LayerRenderer] = []
    /// The document's pictures, decoded once for every screen's renderer.
    private let pictures = PictureStore()
    /// Holds the renderers' layers, under the overlays.
    private let screensLayer = CALayer()
    /// Everything drawn over the screens, in view points, y down.
    private let overlay = CALayer()
    private let levelLayer = CAShapeLayer()
    private let outlineLayer = CAShapeLayer()
    private let handleLayer = CAShapeLayer()
    private let previewLayer = CAShapeLayer()
    private let guideLayer = CAShapeLayer()
    private let flowLayer = CAShapeLayer()
    private let flowHeadLayer = CAShapeLayer()
    private let chosenFlowLayer = CAShapeLayer()
    private let flowHandleLayer = CAShapeLayer()
    private let plusLayer = CAShapeLayer()
    private let startMarkLayer = CAShapeLayer()
    private let flowHandleGlyphLayer = CAShapeLayer()
    /// Under the screens: the paper each one lies on, and its shadow.
    private let underlay = CALayer()
    private let paperLayer = CAShapeLayer()
    private let frameEdgeLayer = CAShapeLayer()
    /// Dims everything but the view one is inside of.
    private let scrimLayer = CAShapeLayer()
    private let hoverLayer = CAShapeLayer()
    private let dropLayer = CAShapeLayer()
    private let relatedFlowLayer = CAShapeLayer()
    /// Ways back, dashed.
    private let backFlowLayer = CAShapeLayer()
    private let relatedBackFlowLayer = CAShapeLayer()
    private let relatedHeadLayer = CAShapeLayer()
    private let addSlotLayer = CAShapeLayer()
    /// Says how large the selected view is, or where it is while it is dragged.
    private let badge = CanvasPill()
    /// Where each arrow's label is, for picking the arrow by it.
    private var flowLabelFrames: [(flow: NodeID, frame: CGRect)] = []
    /// What the pointer is over, for the highlight and the cursor.
    private var hovered: Spot = .outside
    /// Where the pointer last was on the board during a drag.
    private var pointer: CGPoint = .zero
    /// Held while the space bar is: a drag then moves the board.
    private var spaceDown = false
    private var titleLayers: [CATextLayer] = []
    private var flowLabels: [CanvasPill] = []

    /// The document at rest, every screen in it at the device's corner.
    private var resolved: ResolvedLayer
    /// The same, one per frame: the root with only that frame's screen in it.
    private var trees: [ResolvedLayer] = []
    private var board: Board
    private var shown: PaperModel.Document
    private var shownRevision = -1
    private var selection: Set<LayerID> = []
    private var chosenNodes: Set<NodeID> = []
    private var tool: CanvasTool = .select
    private var fitRequest = 0
    /// The screen the Viewer is showing, marked on its title.
    private(set) var viewerScreen: LayerID?
    /// The screen the Viewer starts on, when it is not the first.
    private(set) var startScreen: LayerID?
    private var needsOverlays = false
    /// Says "Viewer" beside the title of the screen the Viewer is showing.
    private let viewerPill = CanvasPill()

    private var zoom: CGFloat = 1
    /// The board's origin in view coordinates measured from the top-left (y-down).
    private var offset: CGPoint = .zero
    private var hasFitted = false

    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var unit: CGPoint {
            switch self {
            case .topLeft: CGPoint(x: 0, y: 0)
            case .top: CGPoint(x: 0.5, y: 0)
            case .topRight: CGPoint(x: 1, y: 0)
            case .right: CGPoint(x: 1, y: 0.5)
            case .bottomRight: CGPoint(x: 1, y: 1)
            case .bottom: CGPoint(x: 0.5, y: 1)
            case .bottomLeft: CGPoint(x: 0, y: 1)
            case .left: CGPoint(x: 0, y: 0.5)
            }
        }
    }

    /// What a press has become. Points are on the board unless they say otherwise.
    private enum Drag {
        case none
        /// Views that are free to be put anywhere follow the pointer.
        case move(start: CGPoint, originals: [LayerID: Point2], moved: Bool)
        /// A view its stack or grid places is moved among its siblings.
        case reorder(layer: LayerID, moved: Bool)
        case resize(handle: Handle, layer: LayerID, frame: CGRect, start: CGPoint)
        case create(kind: LayerKind, frame: Int, start: CGPoint, current: CGPoint)
        /// From empty room: a rectangle that selects what it touches. `screen` is what a
        /// click without a drag selects.
        case marquee(frame: Int, start: CGPoint, current: CGPoint, screen: LayerID?)
        /// From a screen's title: the screen is moved among the others.
        case screen(LayerID, start: CGPoint, moved: Bool)
        /// From the handle beside a selected view: an arrow to the screen it should show.
        case flow(from: LayerID, current: CGPoint)
        /// With the space bar held: the board itself. Points are the overlay's.
        case pan(start: CGPoint, origin: CGPoint)
    }

    /// What is at a place on the Canvas: what a press there would take hold of.
    enum Spot: Equatable {
        case addScreen
        /// A screen's title, by frame.
        case title(Int)
        case flowHandle(LayerID)
        case resize(Handle, LayerID)
        /// A flow's arrow or its label.
        case arrow(NodeID)
        /// The view a click selects.
        case view(LayerID, frame: Int)
        /// Empty room on a screen.
        case room(frame: Int)
        case outside
    }

    /// Layers that exist in the document. A component instance draws layers of its own
    /// that are not among them and cannot be selected from outside.
    private var documentLayers: Set<LayerID> = []

    /// The picture of a document at rest. Layers show their own stored values, so what is
    /// dragged on the Canvas is what changes; the document's graph is left out. Component
    /// instances do run their own patches, so each shows the title, state and repeated
    /// parts its inputs give it. Every screen is in it, each at the device's corner.
    /// `painter` draws the views of extensions. The Canvas keeps one, so their scripts
    /// are not loaded again every time something is dragged.
    static func resolve(
        _ document: PaperModel.Document, registry: PatchRegistry = .standard, painter: ViewPainter = ViewPainter()
    ) -> ResolvedLayer {
        guard document.screen.flattened.contains(where: { $0.kind == .component }) else {
            var tree = ResolvedLayer(document.screen).laidOut()
            if document.screen.flattened.contains(where: { $0.custom != nil }) {
                painter.paint(&tree, registry: registry, time: 0)
            }
            return tree
        }
        var still = document
        still.graph = Graph()
        let runtime = Runtime(document: still, registry: registry, painter: painter)
        runtime.showsEveryScreen = true
        // A few frames let loops and measured sizes inside components settle.
        for _ in 0..<3 { runtime.tick(dt: 0) }
        return runtime.resolved
    }

    /// What each frame of the board shows: the root with one screen in it, and whatever
    /// floats over every screen.
    static func trees(of resolved: ResolvedLayer, on board: Board) -> [ResolvedLayer] {
        board.frames.map { frame in
            guard frame.isPage else { return resolved }
            var tree = resolved
            tree.children = resolved.children.filter { !$0.isPage || $0.id == frame.id }
            return tree
        }
    }

    private var drag: Drag = .none
    private var lastMouseUp: TimeInterval = 0
    private var guides: (x: [CGFloat], y: [CGFloat], frame: Int, parent: LayerID)?

    private let painter: ViewPainter
    /// The field a text is retyped in, and whose text it is.
    private(set) var textField: NSTextField?
    private var editedText: LayerID?
    /// Or the screen whose title is retyped in it.
    private(set) var editedName: LayerID?

    public init(store: DocumentStore) {
        self.store = store
        let painter = ViewPainter()
        self.painter = painter
        shown = store.document
        resolved = CanvasView.resolve(store.document, registry: store.runtimeRegistry, painter: painter)
        board = Board(store.document)
        trees = CanvasView.trees(of: resolved, on: board)
        documentLayers = Set(store.document.screen.flattened.map(\.id))
        super.init(frame: .zero)
        wantsLayer = true
        underlay.isGeometryFlipped = true
        underlay.masksToBounds = true
        layer?.addSublayer(underlay)
        // Falling a little below each sheet, and leaving the titles above them clear.
        paperLayer.shadowOpacity = 0.16
        paperLayer.shadowRadius = 12
        paperLayer.shadowOffset = CGSize(width: 0, height: -5)
        underlay.addSublayer(paperLayer)
        screensLayer.masksToBounds = true
        layer?.addSublayer(screensLayer)
        overlay.isGeometryFlipped = true
        overlay.masksToBounds = true
        layer?.addSublayer(overlay)
        for shape in [frameEdgeLayer, scrimLayer, levelLayer, addSlotLayer, flowLayer, backFlowLayer, flowHeadLayer, relatedFlowLayer, relatedBackFlowLayer, relatedHeadLayer,
                      chosenFlowLayer, hoverLayer, outlineLayer, dropLayer, guideLayer, previewLayer, handleLayer, flowHandleLayer,
                      flowHandleGlyphLayer, plusLayer, startMarkLayer] {
            shape.fillColor = nil
            shape.lineWidth = 1.5
            overlay.addSublayer(shape)
        }
        handleLayer.fillColor = NSColor.white.cgColor
        handleLayer.lineWidth = 1
        previewLayer.lineDashPattern = [4, 3]
        levelLayer.lineDashPattern = [2, 3]
        levelLayer.lineWidth = 1
        guideLayer.lineWidth = 1
        flowLayer.lineWidth = 2
        flowLayer.lineCap = .round
        chosenFlowLayer.lineWidth = 4
        chosenFlowLayer.lineCap = .round
        flowHandleLayer.lineWidth = 1.5
        relatedFlowLayer.lineWidth = 2
        relatedFlowLayer.lineCap = .round
        for back in [backFlowLayer, relatedBackFlowLayer] {
            back.lineWidth = 2
            back.lineDashPattern = [5, 4]
        }
        frameEdgeLayer.lineWidth = 1
        scrimLayer.fillRule = .evenOdd
        scrimLayer.lineWidth = 0
        hoverLayer.lineWidth = 1
        dropLayer.lineWidth = 3
        addSlotLayer.lineWidth = 1
        addSlotLayer.lineDashPattern = [5, 4]
        outlineLayer.lineWidth = 1
        dropLayer.lineWidth = 2
        flowHandleLayer.lineWidth = 0
        flowHandleGlyphLayer.lineWidth = 1.5
        flowHandleGlyphLayer.lineCap = .round
        plusLayer.lineWidth = 1.5
        plusLayer.lineCap = .round
        startMarkLayer.lineWidth = 0
        overlay.addSublayer(badge.layer)
        overlay.addSublayer(viewerPill.layer)
        // A font or an icon that arrived is laid out and drawn with at once.
        arrivalObserver = NotificationCenter.default.addObserver(forName: WebAssets.didArrive, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.webAssetArrived() }
        }
    }

    private var arrivalObserver: NSObjectProtocol?

    private func webAssetArrived() {
        resolved = CanvasView.resolve(shown, registry: store.runtimeRegistry, painter: painter)
        trees = CanvasView.trees(of: resolved, on: board)
        redraw()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var acceptsFirstResponder: Bool { true }
    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        let accent = NSColor.controlAccentColor.cgColor
        for shape in [outlineLayer, handleLayer, previewLayer, chosenFlowLayer, relatedFlowLayer, relatedBackFlowLayer, dropLayer] { shape.strokeColor = accent }
        backFlowLayer.strokeColor = NSColor.secondaryLabelColor.cgColor
        flowHandleLayer.strokeColor = nil
        flowHandleLayer.fillColor = accent
        flowHandleGlyphLayer.strokeColor = NSColor.white.cgColor
        startMarkLayer.strokeColor = nil
        hoverLayer.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        relatedHeadLayer.fillColor = accent
        relatedHeadLayer.strokeColor = nil
        paperLayer.fillColor = NSColor.white.cgColor
        paperLayer.shadowColor = NSColor.black.cgColor
        frameEdgeLayer.strokeColor = NSColor.separatorColor.cgColor
        scrimLayer.fillColor = NSColor.underPageBackgroundColor.withAlphaComponent(0.4).cgColor
        scrimLayer.strokeColor = nil
        addSlotLayer.strokeColor = NSColor.tertiaryLabelColor.cgColor
        levelLayer.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
        guideLayer.strokeColor = NSColor.systemPink.cgColor
        flowLayer.strokeColor = NSColor.secondaryLabelColor.cgColor
        flowHeadLayer.fillColor = NSColor.secondaryLabelColor.cgColor
        flowHeadLayer.strokeColor = nil
        drawOverlays()
    }

    // MARK: Updates

    func update(
        document: PaperModel.Document, selection: Set<LayerID>, selectedNodes: Set<NodeID> = [],
        tool: CanvasTool, registryRevision: Int = 0, fitRequest: Int = 0, viewerScreen: LayerID? = nil, startScreen: LayerID? = nil
    ) {
        if startScreen != self.startScreen {
            self.startScreen = startScreen
            needsOverlays = true
        }
        if viewerScreen != self.viewerScreen {
            self.viewerScreen = viewerScreen
            needsOverlays = true
        }
        // Entering or leaving a component shows a different screen: frame it afresh.
        if document.screen.id != resolved.id {
            hasFitted = false
            needsLayout = true
        }
        // The picture is made again only when what it shows changed, not for a selection.
        if document != shown || registryRevision != shownRevision {
            let before = board
            shown = document
            shownRevision = registryRevision
            resolved = CanvasView.resolve(document, registry: store.runtimeRegistry, painter: painter)
            board = Board(document)
            trees = CanvasView.trees(of: resolved, on: board)
            documentLayers = Set(document.screen.flattened.map(\.id))
            // A screen added or removed: show them all again, unless the person has taken over.
            if before.frames.count != board.frames.count, !hasFitted { needsLayout = true }
            if let edited = editedText ?? editedName, document.layer(edited) == nil { endTextEditing(commit: false) }
        }
        self.selection = selection
        chosenNodes = selectedNodes
        self.tool = tool
        if needsOverlays {
            needsOverlays = false
            drawOverlays()
        }
        if fitRequest != self.fitRequest {
            self.fitRequest = fitRequest
            zoomToFit()
        }
        redraw()
    }

    public override func layout() {
        super.layout()
        // Keep the board fitted while panes settle and resize, until the person takes
        // over by panning or zooming.
        if !hasFitted, bounds.width > 40, bounds.height > 40 {
            zoomToFit()
        }
        redraw()
    }

    /// Room kept above the screens for their titles, in view points.
    private static let titleRoom: CGFloat = 26
    /// How wide the slot that adds a screen is, in view points.
    private static let slotWidth: CGFloat = 64

    public func zoomToFit() {
        let all = board.bounds
        guard all.width > 0, all.height > 0 else { return }
        // With three screens or more an arrow may go round underneath them: room for it.
        let under: CGFloat = board.frames.count > 2 ? 90 : 0
        // And for the slot after the last screen that adds one.
        let slot: CGFloat = store.scope == nil ? CanvasView.slotWidth + 28 : 0
        var available = bounds.insetBy(dx: 40, dy: 40 + CanvasView.titleRoom / 2)
        available.size.height = max(available.height - under, 40)
        available.size.width = max(available.width - slot, 40)
        zoom = max(min(1, available.width / all.width, available.height / all.height), 0.05)
        offset = CGPoint(
            x: (bounds.width - slot - all.width * zoom) / 2 - all.minX * zoom,
            y: (bounds.height - under - all.height * zoom) / 2 - all.minY * zoom + CanvasView.titleRoom / 2
        )
        redraw()
    }

    private func redraw() {
        // The board's corner is on a whole pixel, so every screen starts on one.
        offset = pixel(offset)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        underlay.frame = bounds
        screensLayer.frame = bounds
        overlay.frame = bounds
        while renderers.count < board.frames.count {
            let renderer = LayerRenderer()
            renderer.imageProvider = { [weak store, pictures] name in
                pictures.picture(named: name, assets: store?.assets ?? [:], registry: store?.runtimeRegistry)
            }
            // A video shows the frame its Time names.
            renderer.videoURL = { [weak store] source in VideoFiles.url(for: source, assets: store?.assets ?? [:]) }
            WebAssetClient(assets: { [weak store] in store?.assets ?? [:] }, fetches: true, used: { [weak store] in store?.noteWebAsset($0) })
                .attach(to: renderer)
            screensLayer.addSublayer(renderer.rootLayer)
            renderers.append(renderer)
        }
        while renderers.count > board.frames.count { renderers.removeLast().rootLayer.removeFromSuperlayer() }
        CATransaction.commit()
        for (index, renderer) in renderers.enumerated() {
            let rect = board.frames[index].rect
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            renderer.rootLayer.frame = bounds
            CATransaction.commit()
            renderer.contentsScale = (window?.backingScaleFactor ?? 2) * max(zoom, 1)
            renderer.setViewport(scale: zoom, offset: CGPoint(x: offset.x + rect.minX * zoom, y: offset.y + rect.minY * zoom))
            renderer.render(trees[index])
        }
        drawOverlays()
        placeTextField()
    }

    // MARK: Coordinates

    /// Where an event is on the board.
    private func boardPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: (point.x - offset.x) / zoom, y: (bounds.height - point.y - offset.y) / zoom)
    }

    /// Where an event is in the overlay (view points, y down).
    private func viewPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x, y: bounds.height - point.y)
    }

    /// Board coordinates to the overlay's coordinates (y-down, view points).
    private func overlayPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * zoom + offset.x, y: point.y * zoom + offset.y)
    }

    private func overlayRect(_ rect: CGRect) -> CGRect {
        CGRect(origin: overlayPoint(rect.origin), size: CGSize(width: rect.width * zoom, height: rect.height * zoom))
    }

    /// The frame a view is shown in.
    private func frameIndex(of id: LayerID) -> Int { min(board.index(holding: id, in: shown), board.frames.count - 1) }

    /// The corners of a layer on the board: top-left, top-right, bottom-right, bottom-left.
    private func corners(of id: LayerID) -> [CGPoint]? {
        let index = frameIndex(of: id)
        guard let layer = trees[index].find(id), let transform = trees[index].transform(toRootFrom: id) else { return nil }
        let size = layer.size
        return [
            CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0),
            CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height),
        ].map { board.boardPoint($0.applying(transform), inFrame: index) }
    }

    /// The box around a layer on the board.
    private func boardRect(of id: LayerID) -> CGRect? {
        guard let corners = corners(of: id) else { return nil }
        return corners.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
    }

    /// Maps the coordinates inside a container to its screen's coordinates.
    private func transform(toScreenFrom id: LayerID) -> CGAffineTransform? {
        trees[frameIndex(of: id)].transform(toRootFrom: id)
    }

    /// Converts a movement on the board into the coordinate space that contains `id`.
    private func deltaInParent(of id: LayerID, _ delta: CGPoint) -> CGPoint {
        guard let parent = shown.screen.parent(of: id), let transform = transform(toScreenFrom: parent.id) else { return delta }
        var linear = transform
        linear.tx = 0
        linear.ty = 0
        guard abs(linear.a * linear.d - linear.b * linear.c) > 1e-9 else { return delta }
        return delta.applying(linear.inverted())
    }

    /// A board point in the coordinates inside a container.
    private func point(_ point: CGPoint, inside container: LayerID) -> CGPoint? {
        let index = frameIndex(of: container)
        guard let transform = trees[index].transform(toRootFrom: container),
              abs(transform.a * transform.d - transform.b * transform.c) > 1e-9 else { return nil }
        return board.screenPoint(point, inFrame: index).applying(transform.inverted())
    }

    /// Whether the layer's edges line up with the screen, so resize handles make sense.
    private func isAxisAligned(_ id: LayerID) -> Bool {
        guard let transform = transform(toScreenFrom: id) else { return false }
        return abs(transform.b) < 1e-6 && abs(transform.c) < 1e-6 && transform.a > 0 && transform.d > 0
    }

    /// The container whose views a click in a frame reaches: the open view when it is on
    /// that frame's screen, or else the screen itself.
    private func level(inFrame index: Int) -> LayerID {
        let frame = board.frames[index]
        let open = store.openContainer.id
        if open != shown.screen.id, frameIndex(of: open) == index, shown.layer(open) != nil { return open }
        return frame.id
    }

    /// Where a point of the board is in the window, for an event there.
    func windowPoint(forBoard point: CGPoint) -> CGPoint {
        let shown = overlayPoint(point)
        return convert(CGPoint(x: shown.x, y: bounds.height - shown.y), to: nil)
    }

    /// Where the flow handle of the selected view is in the window, when there is one.
    var flowHandleWindowPoint: CGPoint? {
        flowHandleCenter.map { convert(CGPoint(x: $0.x, y: bounds.height - $0.y), to: nil) }
    }

    /// The arrow being drawn out of a view, while one is.
    var flowBeingDrawn: (from: LayerID, to: CGPoint)? {
        if case let .flow(from, current) = drag { return (from, current) }
        return nil
    }

    // MARK: Overlays

    private var resizableSelection: LayerID? {
        guard selection.count == 1, let id = selection.first, id != resolved.id,
              shown.layer(id)?.isPage != true, isAxisAligned(id) else { return nil }
        return id
    }

    // MARK: Whole pixels

    /// Pixels per point of the screen the Canvas is on.
    private var pixelScale: CGFloat { window?.backingScaleFactor ?? 2 }

    /// A coordinate of the overlay, moved to the nearest pixel edge.
    private func pixel(_ value: CGFloat) -> CGFloat { (value * pixelScale).rounded() / pixelScale }

    private func pixel(_ point: CGPoint) -> CGPoint { CGPoint(x: pixel(point.x), y: pixel(point.y)) }

    /// A box of the overlay with every side on a pixel edge.
    private func pixel(_ rect: CGRect) -> CGRect {
        let minX = pixel(rect.minX), minY = pixel(rect.minY)
        return CGRect(x: minX, y: minY, width: pixel(rect.maxX) - minX, height: pixel(rect.maxY) - minY)
    }

    /// The same box moved so that a line of a width drawn round it fills whole pixels: a
    /// line an odd number of pixels wide has its middle in the middle of a pixel.
    private func crisp(_ rect: CGRect, lineWidth: CGFloat) -> CGRect {
        let snapped = pixel(rect)
        let odd = Int((lineWidth * pixelScale).rounded()) % 2 == 1
        return odd ? snapped.insetBy(dx: 0.5 / pixelScale, dy: 0.5 / pixelScale) : snapped
    }

    /// A screen's frame in the overlay, on whole pixels.
    private func sheetRect(_ index: Int) -> CGRect { pixel(overlayRect(board.frames[index].rect)) }

    /// The outline of a view in the overlay: a box on whole pixels when it stands
    /// straight, its four corners as they are when it is turned.
    private func outline(of id: LayerID, lineWidth: CGFloat, into path: CGMutablePath) {
        guard let corners = corners(of: id) else { return }
        if isAxisAligned(id), let rect = boardRect(of: id) {
            path.addRect(crisp(overlayRect(rect), lineWidth: lineWidth))
        } else {
            path.addLines(between: corners.map(overlayPoint))
            path.closeSubpath()
        }
    }

    // MARK: Handles

    /// The selected view's box in the overlay, when it can be resized.
    private var resizeBox: CGRect? {
        guard let id = resizableSelection, let rect = boardRect(of: id) else { return nil }
        return pixel(overlayRect(rect))
    }

    /// The handles that are drawn: the four corners. The sides are taken hold of along
    /// their whole length and need no mark, which keeps a view's edge clear for the
    /// point its flows start from. A view so small on screen that handles would cover it
    /// and its neighbors has none: zoom in to resize it, or use the Inspector.
    private func drawnHandles(of box: CGRect) -> [(Handle, CGPoint)] {
        guard min(box.width, box.height) >= 16 else { return [] }
        let corners: [Handle] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
        return corners.map { ($0, CGPoint(x: box.minX + box.width * $0.unit.x, y: box.minY + box.height * $0.unit.y)) }
    }

    /// The handle a press at a point of the overlay takes hold of: a corner, or a side
    /// anywhere along it.
    private func resizeHandle(at cursor: CGPoint) -> Handle? {
        guard let box = resizeBox else { return nil }
        for (handle, center) in drawnHandles(of: box) where abs(center.x - cursor.x) <= 6 && abs(center.y - cursor.y) <= 6 {
            return handle
        }
        guard min(box.width, box.height) >= 16 else { return nil }
        let reach: CGFloat = 4
        let alongX = cursor.x > box.minX + 6 && cursor.x < box.maxX - 6
        let alongY = cursor.y > box.minY + 6 && cursor.y < box.maxY - 6
        if alongX, abs(cursor.y - box.minY) <= reach { return .top }
        if alongX, abs(cursor.y - box.maxY) <= reach { return .bottom }
        if alongY, abs(cursor.x - box.minX) <= reach { return .left }
        if alongY, abs(cursor.x - box.maxX) <= reach { return .right }
        return nil
    }

    /// The view a flow can be drawn from: the one selected, when it is not a whole screen.
    private var flowSource: LayerID? {
        guard store.scope == nil, selection.count == 1, let id = selection.first, id != resolved.id,
              shown.layer(id)?.isPage != true else { return nil }
        return id
    }

    /// How large the point is that flows start from.
    private static let nodeRadius: CGFloat = 6

    /// Where the flow handle of the selected view is, in the overlay: on the middle of
    /// its right edge, where its arrows leave from.
    private var flowHandleCenter: CGPoint? {
        guard let id = flowSource, let rect = boardRect(of: id) else { return nil }
        let box = pixel(overlayRect(rect))
        // On a view too small to carry it, it stands just outside, clear of what the view shows.
        let fits = box.height >= CanvasView.nodeRadius * 2 + 8 && box.width >= 24
        return pixel(CGPoint(x: box.maxX + (fits ? 0 : CanvasView.nodeRadius + 10), y: box.midY))
    }

    // MARK: Arrows

    /// An arrow as it is drawn, in the overlay.
    struct Arrow {
        /// The line, which stops where the head begins.
        var path: CGPath
        var start: CGPoint
        var tip: CGPoint
        /// Which way the head points.
        var angle: CGFloat
        /// Where its label sits: on the line.
        var label: CGPoint
    }

    /// How long an arrow's head is: the line stops this far short of the tip.
    static let headLength: CGFloat = 9

    /// The arrows on the board: each flow that starts at a view and shows a screen.
    /// One arrow on the board: a flow to the screen it shows, or a way back drawn to each
    /// screen that leads here, dashed.
    struct FlowArrow {
        var flow: DocumentStore.Flow
        var arrow: Arrow
        /// What its label says: the style, or Back.
        var title: String
        var isBack: Bool
    }

    /// The arrows on the board.
    private func arrows() -> [FlowArrow] {
        store.flows.flatMap { flow -> [FlowArrow] in
            guard let source = flow.source else { return [] }
            if let target = flow.target {
                guard let to = board.frames.firstIndex(where: { $0.id == target }),
                      let arrow = arrow(from: source, to: to) else { return [] }
                return [FlowArrow(flow: flow, arrow: arrow, title: flow.style.rawValue, isBack: false)]
            }
            // Going back leads to whichever screen was showing before: each screen that has
            // a flow to this one. With none known, a short mark out of the screen.
            let own = store.screen(holding: source)?.id
            var parents: [Int] = []
            for other in store.flows where other.target == own && own != nil {
                guard let from = other.source, let parent = store.screen(holding: from)?.id, parent != own,
                      let index = board.frames.firstIndex(where: { $0.id == parent }), !parents.contains(index) else { continue }
                parents.append(index)
            }
            // A screen right beside it gets an arrow, as its way here has. One further away
            // would have to go round underneath and tangle with the arrows there: a short
            // mark out of the screen says where instead.
            let near = parents.filter { abs($0 - frameIndex(of: source)) == 1 }
            if parents.count == near.count, !near.isEmpty {
                return near.compactMap { index in
                    arrow(from: source, to: index).map { FlowArrow(flow: flow, arrow: $0, title: "Back", isBack: true) }
                }
            }
            let title = parents.count == 1 ? "Back to \(board.frames[parents[0]].name)" : "Back"
            return backMark(of: flow).map { [FlowArrow(flow: flow, arrow: $0, title: title, isBack: true)] } ?? []
        }
    }

    /// What each arrow on the board says, by its flow: for tests and for reading.
    var arrowTitles: [(flow: NodeID, title: String, dashed: Bool)] { arrows().map { ($0.flow.id, $0.title, $0.isBack) } }

    /// The arrow from a view to a screen's frame.
    private func arrow(from source: LayerID, to: Int) -> Arrow? {
        guard var from = boardRect(of: source) else { return nil }
        let frame = board.frames[to]
        // A view over every screen (a tab) is drawn on each: its arrow leaves from the copy
        // on the screen beside the one it shows, so it never points at its own screen.
        var sourceFrame = frameIndex(of: source)
        if store.screen(holding: source) == nil, board.frames.count > 1, board.frames.first?.isPage == true {
            sourceFrame = to > 0 ? to - 1 : 1
            from = from.offsetBy(dx: board.frames[sourceFrame].rect.minX - board.frames[0].rect.minX, dy: 0)
        }
        // A screen between the two would be crossed: the arrow goes round underneath.
        let between = board.frames.contains { other in
            other.id != frame.id && !other.rect.intersects(from)
                && other.rect.midX > min(from.midX, frame.rect.midX) && other.rect.midX < max(from.midX, frame.rect.midX)
        }
        let box = pixel(overlayRect(from)), sheet = sheetRect(to)
        if between {
            return CanvasView.arrowUnder(from: box, to: sheet, below: pixel(overlayRect(board.bounds)).maxY)
        }
        // The label goes in the room between the two screens.
        let own = sheetRect(sourceFrame)
        let rightward = sheet.midX >= box.midX
        let room = rightward ? (own.maxX + sheet.minX) / 2 : (own.minX + sheet.maxX) / 2
        return CanvasView.arrow(from: box, to: sheet, labelAt: own.intersects(sheet) ? nil : room)
    }

    /// A curve from the side of one box to the side of another that faces it. With
    /// `labelAt`, the label goes where the line passes that x; else at its middle.
    static func arrow(from: CGRect, to: CGRect, labelAt x: CGFloat? = nil) -> Arrow {
        let rightward = to.midX >= from.midX
        let start = CGPoint(x: rightward ? from.maxX : from.minX, y: from.midY)
        let end = CGPoint(x: rightward ? to.minX : to.maxX, y: min(max(from.midY, to.minY + 24), to.maxY - 24))
        return arrow(from: start, to: end, rightward: rightward, labelAt: x)
    }

    static func arrow(from start: CGPoint, to tip: CGPoint, rightward: Bool, labelAt x: CGFloat? = nil) -> Arrow {
        let way: CGFloat = rightward ? 1 : -1
        // The line ends at the back of the head, so its round end never shows past the tip.
        let end = CGPoint(x: tip.x - headLength * way, y: tip.y)
        let reach = max(24, abs(end.x - start.x) / 2) * way
        let c1 = CGPoint(x: start.x + reach, y: start.y), c2 = CGPoint(x: end.x - reach, y: end.y)
        let path = CGMutablePath()
        path.move(to: start)
        path.addCurve(to: end, control1: c1, control2: c2)
        // Where the line passes x: its x only ever grows (or only shrinks) along it.
        var t: CGFloat = 0.5
        if let x, (x - start.x) * (x - end.x) < 0 {
            var low: CGFloat = 0, high: CGFloat = 1
            for _ in 0..<24 {
                t = (low + high) / 2
                if (bezier(start, c1, c2, end, t).x - x) * way < 0 { low = t } else { high = t }
            }
        }
        return Arrow(path: path, start: start, tip: tip, angle: rightward ? 0 : .pi, label: bezier(start, c1, c2, end, t))
    }

    /// A curve from the bottom of one box, under everything down to `below`, and up into
    /// the bottom of another. Its label is at its lowest stretch.
    static func arrowUnder(from: CGRect, to: CGRect, below: CGFloat) -> Arrow {
        let start = CGPoint(x: from.midX, y: from.maxY)
        let tip = CGPoint(x: to.midX, y: to.maxY)
        let end = CGPoint(x: tip.x, y: tip.y + headLength)
        let low = max(below, start.y, end.y) + 56
        let c1 = CGPoint(x: start.x, y: low + (low - start.y) * 0.3), c2 = CGPoint(x: end.x, y: low + 40)
        let path = CGMutablePath()
        path.move(to: start)
        path.addCurve(to: end, control1: c1, control2: c2)
        return Arrow(path: path, start: start, tip: tip, angle: -.pi / 2, label: bezier(start, c1, c2, end, 0.5))
    }

    private static func bezier(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let (wa, wb, wc, wd) = (u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t)
        return CGPoint(x: wa * a.x + wb * b.x + wc * c.x + wd * d.x, y: wa * a.y + wb * b.y + wc * c.y + wd * d.y)
    }

    /// The mark of a way back: from the view straight out through the left edge of its
    /// screen, the way a screen leaves when one goes back.
    private func backMark(of flow: DocumentStore.Flow) -> Arrow? {
        guard flow.target == nil, let source = flow.source, let rect = boardRect(of: source) else { return nil }
        let box = pixel(overlayRect(rect)), sheet = sheetRect(frameIndex(of: source))
        let start = CGPoint(x: box.minX, y: pixel(box.midY))
        // Far enough out of the screen for its label to sit on it.
        let tip = CGPoint(x: min(sheet.minX, box.minX) - 28, y: start.y)
        let path = CGMutablePath()
        path.addLines(between: [start, CGPoint(x: tip.x + CanvasView.headLength, y: tip.y)])
        // The label hangs just above the line where it leaves the screen, clear of the view.
        return Arrow(path: path, start: start, tip: tip, angle: .pi, label: CGPoint(x: sheet.minX, y: start.y - CanvasPill.height))
    }

    private static func head(at tip: CGPoint, angle: CGFloat, into path: CGMutablePath) {
        let turn = CGAffineTransform(translationX: tip.x, y: tip.y).rotated(by: angle)
        path.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: -headLength - 1, y: -5), CGPoint(x: -headLength - 1, y: 5)], transform: turn)
        path.closeSubpath()
    }

    // MARK: Drawing the overlay

    private func drawOverlays() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let whole = CGRect(origin: .zero, size: bounds.size)
        for shape in [levelLayer, outlineLayer, handleLayer, previewLayer, guideLayer, flowLayer, flowHeadLayer, chosenFlowLayer, flowHandleLayer,
                      frameEdgeLayer, scrimLayer, hoverLayer, dropLayer, relatedFlowLayer, relatedHeadLayer, addSlotLayer, paperLayer,
                      backFlowLayer, relatedBackFlowLayer,
                      plusLayer, startMarkLayer, flowHandleGlyphLayer] {
            shape.frame = whole
        }
        // A hairline is one pixel, whatever the screen.
        let hairline = 1 / pixelScale
        frameEdgeLayer.lineWidth = hairline

        // Each screen lies on the board like a sheet of paper.
        let sheets = CGMutablePath(), edges = CGMutablePath()
        for index in board.frames.indices {
            sheets.addRect(sheetRect(index))
            edges.addRect(crisp(sheetRect(index), lineWidth: hairline))
        }
        paperLayer.path = sheets
        paperLayer.shadowPath = sheets
        frameEdgeLayer.path = edges

        // Inside a view, everything else steps back, and the view is marked.
        let scrim = CGMutablePath(), level = CGMutablePath()
        let inside = store.openContainer.id
        if inside != shown.screen.id, shown.layer(inside)?.isPage != true, corners(of: inside) != nil {
            scrim.addPath(sheets)
            outline(of: inside, lineWidth: 0, into: scrim)
            outline(of: inside, lineWidth: levelLayer.lineWidth, into: level)
        }
        scrimLayer.path = scrim
        levelLayer.path = level

        // What a click would select.
        let hover = CGMutablePath()
        if case let .view(id, _) = hovered, !selection.contains(id), case .none = drag {
            outline(of: id, lineWidth: hoverLayer.lineWidth, into: hover)
        }
        hoverLayer.path = hover

        // The screen something dragged would land on.
        let drop = CGMutablePath()
        if let index = dropFrame { drop.addRect(sheetRect(index).insetBy(dx: -1, dy: -1)) }
        dropLayer.path = drop

        let selected = CGMutablePath()
        for id in selection {
            // The device that holds screens is all of them.
            if id == shown.screen.id, board.frames.first?.isPage == true {
                for index in board.frames.indices { selected.addRect(crisp(sheetRect(index), lineWidth: outlineLayer.lineWidth)) }
                continue
            }
            outline(of: id, lineWidth: outlineLayer.lineWidth, into: selected)
        }
        outlineLayer.path = selected

        let handles = CGMutablePath()
        if let box = resizeBox {
            for (_, center) in drawnHandles(of: box) {
                handles.addRect(crisp(CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8), lineWidth: handleLayer.lineWidth))
            }
        }
        handleLayer.path = handles

        let preview = CGMutablePath()
        switch drag {
        case let .create(_, _, start, current), let .marquee(_, start, current, _):
            let a = overlayPoint(start)
            let b = overlayPoint(current)
            preview.addRect(crisp(
                CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)), lineWidth: previewLayer.lineWidth
            ))
        case let .flow(from, current):
            if let rect = boardRect(of: from) {
                let box = pixel(overlayRect(rect))
                let end = overlayPoint(current)
                let rightward = end.x >= box.midX
                // Over a screen it would show, the arrow ends at that screen's edge, as it will.
                if let index = dropFrame {
                    preview.addPath(CanvasView.arrow(from: box, to: sheetRect(index)).path)
                } else {
                    preview.addPath(CanvasView.arrow(from: CGPoint(x: rightward ? box.maxX : box.minX, y: box.midY), to: end, rightward: rightward).path)
                }
            }
        default:
            break
        }
        previewLayer.path = preview

        // What a dragged view lines up with.
        let lines = CGMutablePath()
        if let guides, let transform = transform(toScreenFrom: guides.parent), let size = trees[guides.frame].find(guides.parent)?.size {
            func shownPoint(_ point: CGPoint) -> CGPoint { overlayPoint(board.boardPoint(point.applying(transform), inFrame: guides.frame)) }
            let odd = hairline / 2
            for x in guides.x {
                let top = shownPoint(CGPoint(x: x, y: 0)), bottom = shownPoint(CGPoint(x: x, y: size.height))
                lines.addLines(between: [CGPoint(x: pixel(top.x) + odd, y: top.y), CGPoint(x: pixel(bottom.x) + odd, y: bottom.y)])
            }
            for y in guides.y {
                let left = shownPoint(CGPoint(x: 0, y: y)), right = shownPoint(CGPoint(x: size.width, y: y))
                lines.addLines(between: [CGPoint(x: left.x, y: pixel(left.y) + odd), CGPoint(x: right.x, y: pixel(right.y) + odd)])
            }
        }
        guideLayer.lineWidth = hairline
        guideLayer.path = lines

        drawFlows()
        drawTitles()
        drawBadge()
    }

    /// The screen a drag would put something on, when that is another screen than its own:
    /// an arrow being drawn, or a view being carried.
    private var dropFrame: Int? {
        switch drag {
        case let .flow(from, current):
            guard let index = board.index(at: current), board.frames[index].isPage,
                  board.frames[index].id != store.screen(holding: from)?.id else { return nil }
            return index
        case let .move(_, originals, moved):
            guard moved, originals.count == 1, let id = originals.keys.first, let index = board.index(at: pointer),
                  board.frames[index].isPage, index != frameIndex(of: id),
                  let parent = shown.screen.parent(of: id), parent.isPage || parent.id == shown.screen.id else { return nil }
            return index
        default:
            return nil
        }
    }

    /// A small label under the view being dragged: its size while it is resized, where it
    /// is while it moves. At rest there is none, so it never covers what is below the view;
    /// the Inspector says both.
    private func drawBadge() {
        badge.isHidden = true
        // The device that holds screens is all of them; its size is in the Inspector.
        guard selection.count == 1, let id = selection.first, !(id == shown.screen.id && board.frames.first?.isPage == true),
              let rect = boardRect(of: id),
              let layer = trees[frameIndex(of: id)].find(id) else { return }
        func whole(_ value: Double) -> String { value == value.rounded() ? String(Int(value.clampedFinite)) : String(format: "%.1f", value) }
        let text: String
        switch drag {
        case .move, .reorder:
            guard !store.isPlacedByParent(id), let stored = shown.layer(id) else { return }
            let position = stored.value(.position).pointValue
            text = "\(whole(position.x)), \(whole(position.y))"
        case .resize:
            text = "\(whole(layer.size.width)) × \(whole(layer.size.height))"
        default:
            return
        }
        let box = pixel(overlayRect(rect))
        badge.set(text, scale: pixelScale, text: .white, fill: .controlAccentColor, border: nil)
        badge.center(at: CGPoint(x: box.midX, y: box.maxY + 8 + CanvasPill.height / 2), scale: pixelScale)
        badge.isHidden = false
    }

    private func drawFlows() {
        let all = arrows()
        let curves = CGMutablePath(), heads = CGMutablePath()
        let relatedCurves = CGMutablePath(), relatedHeads = CGMutablePath()
        let chosen = CGMutablePath()
        let node = flowHandleCenter
        // An arrow that starts at the selected view, or ends at the selected screen, stands out.
        func related(_ flow: DocumentStore.Flow) -> Bool {
            chosenNodes.contains(flow.id) || flow.source.map(selection.contains) == true || flow.target.map(selection.contains) == true
        }
        let backs = CGMutablePath(), relatedBacks = CGMutablePath()
        func add(_ flow: DocumentStore.Flow, _ arrow: Arrow, back: Bool) {
            let lit = related(flow)
            // A way back is dashed: it goes wherever the person came from.
            (back ? (lit ? relatedBacks : backs) : (lit ? relatedCurves : curves)).addPath(arrow.path)
            let filled = lit ? relatedHeads : heads
            CanvasView.head(at: arrow.tip, angle: arrow.angle, into: filled)
            // A dot where it leaves its view, unless the flow handle is there already.
            if node.map({ hypot($0.x - arrow.start.x, $0.y - arrow.start.y) > 1 }) ?? true {
                filled.addEllipse(in: CGRect(x: arrow.start.x - 3, y: arrow.start.y - 3, width: 6, height: 6))
            }
            if chosenNodes.contains(flow.id) { chosen.addPath(arrow.path) }
        }
        for entry in all { add(entry.flow, entry.arrow, back: entry.isBack) }
        backFlowLayer.path = backs
        relatedBackFlowLayer.path = relatedBacks
        flowLayer.path = curves
        flowHeadLayer.path = heads
        relatedFlowLayer.path = relatedCurves
        relatedHeadLayer.path = relatedHeads
        chosenFlowLayer.path = chosen

        // Each arrow says how its screen arrives, in a pill on the line that picks the arrow too.
        while flowLabels.count < all.count {
            let label = CanvasPill()
            overlay.insertSublayer(label.layer, below: hoverLayer)
            flowLabels.append(label)
        }
        while flowLabels.count > all.count { flowLabels.removeLast().layer.removeFromSuperlayer() }
        flowLabelFrames = []
        for (label, entry) in zip(flowLabels, all) {
            let lit = related(entry.flow)
            label.set(
                entry.title, scale: pixelScale, text: lit ? .white : .secondaryLabelColor,
                fill: lit ? .controlAccentColor : .windowBackgroundColor, border: lit ? nil : .separatorColor
            )
            label.center(at: entry.arrow.label, scale: pixelScale)
            flowLabelFrames.append((entry.flow.id, label.frame))
        }

        // The point flows start from: a disc on the middle of the selected view's right
        // edge, with a plus in it.
        let disc = CGMutablePath(), glyph = CGMutablePath()
        if let center = node, case .none = drag {
            let radius = CanvasView.nodeRadius + (hovered == flowSource.map(Spot.flowHandle) ? 1 : 0)
            disc.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            // An arrow: what dragging from here draws. A plus would read as "add a view".
            glyph.addLines(between: [CGPoint(x: center.x - 3, y: center.y), CGPoint(x: center.x + 3, y: center.y)])
            glyph.addLines(between: [CGPoint(x: center.x + 0.5, y: center.y - 2.5), CGPoint(x: center.x + 3, y: center.y), CGPoint(x: center.x + 0.5, y: center.y + 2.5)])
        }
        flowHandleLayer.path = disc
        flowHandleGlyphLayer.path = glyph
    }

    /// The box of a frame's title, in the overlay.
    private func titleRect(_ index: Int) -> CGRect {
        let sheet = sheetRect(index)
        return CGRect(x: sheet.minX, y: sheet.minY - 24, width: max(sheet.width, 60), height: 16)
    }

    /// The box of the slot that adds a screen, in the overlay; nil inside a component.
    private var addScreenRect: CGRect? {
        guard store.scope == nil, !board.frames.isEmpty else { return nil }
        // A slot the height of a screen, where the next one would go.
        let sheet = sheetRect(board.frames.count - 1)
        return CGRect(x: sheet.maxX + 28, y: sheet.minY, width: CanvasView.slotWidth, height: sheet.height)
    }

    private func drawTitles() {
        while titleLayers.count < board.frames.count {
            let title = CATextLayer()
            title.font = CanvasPill.titleFont
            title.fontSize = CanvasPill.titleFont.pointSize
            title.truncationMode = .end
            overlay.addSublayer(title)
            titleLayers.append(title)
        }
        while titleLayers.count > board.frames.count { titleLayers.removeLast().removeFromSuperlayer() }
        let mark = CGMutablePath()
        for (index, title) in titleLayers.enumerated() {
            let frame = board.frames[index]
            let box = titleRect(index)
            let chosen = selection.contains(frame.id)
            // Where the Viewer starts (the first screen, or one previewed from): a small play
            // mark before its name, in the accent color when it is not the first.
            let starts = frame.isPage && frame.id == (startScreen ?? board.frames.first?.id)
            if starts {
                let middle = pixel(box.midY)
                mark.addLines(between: [CGPoint(x: box.minX, y: middle - 4), CGPoint(x: box.minX + 7, y: middle), CGPoint(x: box.minX, y: middle + 4)])
                mark.closeSubpath()
                startMarkLayer.fillColor = (chosen || index > 0 ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).cgColor
            }
            title.string = frame.name
            title.contentsScale = pixelScale
            title.foregroundColor = (chosen ? NSColor.controlAccentColor
                : hovered == .title(index) ? NSColor.labelColor : NSColor.secondaryLabelColor).cgColor
            title.isHidden = editedName == frame.id
            let inset: CGFloat = starts ? 12 : 0
            // The screen the Viewer is on says so at the right of its title.
            let live = frame.id == viewerScreen && frame.isPage
            title.frame = CGRect(x: box.minX + inset, y: box.minY, width: box.width - inset - (live ? 58 : 0), height: box.height)
        }
        viewerPill.isHidden = true
        if let index = board.frames.firstIndex(where: { $0.id == viewerScreen && $0.isPage }) {
            let box = titleRect(index)
            viewerPill.set("Viewer", scale: pixelScale, text: .white, fill: .systemGreen, border: nil)
            viewerPill.center(at: CGPoint(x: box.maxX - viewerPill.width / 2, y: box.midY), scale: pixelScale)
            viewerPill.isHidden = false
        }
        startMarkLayer.path = mark

        let slot = CGMutablePath(), plus = CGMutablePath()
        if let rect = addScreenRect {
            let lit = hovered == .addScreen
            slot.addRoundedRect(in: crisp(rect, lineWidth: addSlotLayer.lineWidth), cornerWidth: 10, cornerHeight: 10)
            let center = pixel(CGPoint(x: rect.midX, y: rect.midY))
            plus.addLines(between: [CGPoint(x: center.x - 7, y: center.y), CGPoint(x: center.x + 7, y: center.y)])
            plus.addLines(between: [CGPoint(x: center.x, y: center.y - 7), CGPoint(x: center.x, y: center.y + 7)])
            let color = (lit ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).cgColor
            addSlotLayer.strokeColor = color
            addSlotLayer.fillColor = lit ? NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor : nil
            plusLayer.strokeColor = (lit ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).cgColor
        }
        addSlotLayer.path = slot
        plusLayer.path = plus
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) {
        // AppKit can re-deliver a press late, after its release was already handled.
        // Acting on it would start a second, phantom interaction.
        guard event.timestamp > lastMouseUp else { return }
        endTextEditing(commit: true)
        window?.makeFirstResponder(self)
        let point = boardPoint(event)
        let cursor = viewPoint(event)

        pointer = point
        if spaceDown {
            drag = .pan(start: cursor, origin: offset)
            NSCursor.closedHand.set()
            return
        }
        let spot = spot(board: point, cursor: cursor, deepest: event.modifierFlags.contains(.command))
        if spot == .addScreen {
            store.addScreen()
            hasFitted = false
            needsLayout = true
            return
        }
        if case let .title(index) = spot {
            let frame = board.frames[index]
            store.selectedLayers = [frame.id]
            if event.clickCount >= 2 {
                // A double-click on a title renames the screen where it is.
                beginNameEditing(index)
                drag = .none
            } else {
                drag = frame.isPage ? .screen(frame.id, start: point, moved: false) : .none
            }
            return
        }

        if let kind = tool.layerKind {
            drag = .create(kind: kind, frame: board.nearestIndex(to: point), start: point, current: point)
            return
        }

        let target: LayerID
        switch spot {
        case let .flowHandle(source):
            drag = .flow(from: source, current: point)
            return
        case let .resize(handle, id):
            guard let layer = trees[frameIndex(of: id)].find(id) else { return }
            drag = .resize(handle: handle, layer: id, frame: layer.frame, start: point)
            return
        case let .arrow(node):
            // An arrow is picked as the patch it is.
            store.show(node)
            drag = .none
            return
        case .outside:
            if !event.modifierFlags.contains(.shift) { store.selectedLayers = [] }
            drag = .none
            return
        case let .room(index):
            // Empty room on a screen: a drag selects what it touches, a click the screen.
            let frame = board.frames[index]
            drag = .marquee(frame: index, start: point, current: point, screen: frame.isPage ? frame.id : nil)
            return
        case let .view(id, _):
            target = id
        case .addScreen, .title:
            return
        }

        if event.clickCount >= 2, !event.modifierFlags.contains(.command), let layer = shown.layer(target) {
            if layer.kind == .text {
                store.selectedLayers = [target]
                beginTextEditing(target)
                drag = .none
                return
            }
            // A double-click on a view that can hold others steps into it, empty or not,
            // as in the graph: that is how a new stack is filled.
            if layer.kind.canHaveChildren {
                store.open(target)
                store.selectedLayers = []
                drag = .none
                return
            }
        }

        if event.modifierFlags.contains(.shift) {
            if store.selectedLayers.contains(target) {
                store.selectedLayers.remove(target)
            } else {
                store.selectedLayers.insert(target)
            }
        } else if !store.selectedLayers.contains(target) {
            store.selectedLayers = [target]
        }

        // A view its stack or grid places is dragged to another place among its siblings.
        let chosen = store.selectedLayers
        if chosen.count == 1, store.isPlacedByParent(target) {
            drag = .reorder(layer: target, moved: false)
            return
        }
        var originals: [LayerID: Point2] = [:]
        for id in chosen {
            if let layer = store.document.layer(id), layer.kind != .screen, !store.isPlacedByParent(id) {
                originals[id] = layer.value(.position).pointValue
            }
        }
        drag = .move(start: point, originals: originals, moved: false)
    }

    /// What is at a place: `point` on the board, `cursor` the same place in the overlay.
    /// `deepest` reaches the innermost view, as a Command-click does.
    func spot(board point: CGPoint, cursor: CGPoint, deepest: Bool = false) -> Spot {
        if let rect = addScreenRect, rect.contains(cursor) { return .addScreen }
        if let index = board.frames.indices.first(where: { titleRect($0).contains(cursor) }) { return .title(index) }
        // The flow handle and the resize handles take priority over what is underneath them.
        if let center = flowHandleCenter, let source = flowSource, hypot(center.x - cursor.x, center.y - cursor.y) <= CanvasView.nodeRadius + 3 {
            return .flowHandle(source)
        }
        if let id = resizableSelection, let handle = resizeHandle(at: cursor) { return .resize(handle, id) }
        if let arrow = flow(at: cursor) { return .arrow(arrow) }
        guard let index = board.index(at: point) else { return .outside }
        let inFrame = board.screenPoint(point, inFrame: index)
        let hits = trees[index].hitTest(Point2(x: inFrame.x, y: inFrame.y), options: .editing)
            .filter { $0 != resolved.id && documentLayers.contains($0) }
        let level = level(inFrame: index)
        let frame = board.frames[index]
        // A click reaches the views of the level one is in; Command reaches the deepest.
        var target: LayerID?
        if let innermost = hits.first {
            let chain = shown.screen.path(to: innermost).map(\.id)
            if deepest {
                target = innermost
            } else if let at = chain.firstIndex(of: level) {
                target = at + 1 < chain.count ? chain[at + 1] : nil
            } else if frame.isPage, let at = chain.firstIndex(of: frame.id) {
                // Outside the open view: what is directly on the screen.
                target = at + 1 < chain.count ? chain[at + 1] : nil
            } else {
                target = chain.count > 1 ? chain[1] : nil
            }
        }
        guard let target, shown.layer(target)?.isPage != true else { return .room(frame: index) }
        return .view(target, frame: index)
    }

    /// What is at a place in the window.
    func spot(atWindow point: CGPoint, deepest: Bool = false) -> Spot {
        let local = convert(point, from: nil)
        let cursor = CGPoint(x: local.x, y: bounds.height - local.y)
        return spot(board: CGPoint(x: (cursor.x - offset.x) / zoom, y: (cursor.y - offset.y) / zoom), cursor: cursor, deepest: deepest)
    }

    /// The flow whose arrow, or whose label, is under a point of the overlay.
    private func flow(at cursor: CGPoint) -> NodeID? {
        if let label = flowLabelFrames.first(where: { $0.frame.contains(cursor) }) { return label.flow }
        for entry in arrows() {
            let wide = entry.arrow.path.copy(strokingWithWidth: 10, lineCap: .round, lineJoin: .round, miterLimit: 1)
            if wide.contains(cursor) || hypot(entry.arrow.tip.x - cursor.x, entry.arrow.tip.y - cursor.y) <= 8 { return entry.flow.id }
        }
        return nil
    }

    // MARK: Hovering

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    public override func mouseMoved(with event: NSEvent) {
        let spot = spot(board: boardPoint(event), cursor: viewPoint(event), deepest: event.modifierFlags.contains(.command))
        hover(spot)
    }

    public override func mouseExited(with event: NSEvent) {
        hover(.outside)
    }

    /// Shows what the pointer is over: an outline round what a click would select, and
    /// a cursor that says what a press would do.
    func hover(_ spot: Spot) {
        cursor(for: spot).set()
        guard spot != hovered else { return }
        hovered = spot
        toolTip = help(for: spot)
        drawOverlays()
    }

    /// What a press on a spot does, said when the pointer rests there.
    func help(for spot: Spot) -> String? {
        switch spot {
        case .addScreen: return "Add a screen"
        case let .title(index):
            return board.frames[index].isPage
                ? "Drag to reorder screens. Double-click to rename."
                    + (board.frames[index].id == store.startScreen
                        ? (index == 0 ? " The prototype starts on this screen." : " The Viewer starts here, as you previewed from it.")
                        : "")
                    + (board.frames[index].id == viewerScreen ? " The Viewer is showing it." : "")
                : nil
        case .flowHandle: return "Drag to another screen to show it when this view is tapped"
        case let .arrow(node):
            guard let flow = store.flows.first(where: { $0.id == node }) else { return nil }
            let target = flow.target.flatMap { shown.layer($0)?.name }
            return target.map { "A tap shows \($0) (\(flow.style.rawValue)). Right-click to change." }
                ?? "A tap goes back to the screen that was showing before: dashed to each screen that leads here."
        case .resize, .view, .room, .outside: return nil
        }
    }

    func cursor(for spot: Spot) -> NSCursor {
        if spaceDown { return .openHand }
        switch spot {
        case .addScreen, .title, .arrow, .flowHandle: return .pointingHand
        case let .resize(handle, _): return CanvasView.resizeCursor(for: handle)
        case .view, .room, .outside: return tool == .select ? .arrow : .crosshair
        }
    }

    private static func resizeCursor(for handle: Handle) -> NSCursor {
        let position: NSCursor.FrameResizePosition = switch handle {
        case .topLeft: .topLeft
        case .top: .top
        case .topRight: .topRight
        case .right: .right
        case .bottomRight: .bottomRight
        case .bottom: .bottom
        case .bottomLeft: .bottomLeft
        case .left: .left
        }
        return NSCursor.frameResize(position: position, directions: .all)
    }

    // MARK: The menu under a right-click

    public override func menu(for event: NSEvent) -> NSMenu? {
        endTextEditing(commit: true)
        let menu = NSMenu()
        func item(_ title: String, checked: Bool = false, to target: NSMenu? = nil, _ run: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(runMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuAction(run)
            item.state = checked ? .on : .off
            (target ?? menu).addItem(item)
        }
        let store = self.store
        var spot = spot(board: boardPoint(event), cursor: viewPoint(event), deepest: event.modifierFlags.contains(.command))
        // On empty room of a screen the menu is the screen's.
        if case let .room(index) = spot, board.frames[index].isPage { spot = .title(index) }
        switch spot {
        case let .arrow(node):
            store.show(node)
            if let flow = store.flows.first(where: { $0.id == node }), flow.target != nil {
                for style in Navigation.Style.allCases {
                    item(style.rawValue, checked: flow.style == style) { store.setStyle(style, ofFlow: node) }
                }
                menu.addItem(.separator())
            }
            item("Delete Flow") {
                store.selectedNodes = [node]
                store.deleteSelectedPatches()
            }
        case let .view(id, _):
            guard let layer = shown.layer(id) else { return nil }
            if !store.selectedLayers.contains(id) { store.selectedLayers = [id] }
            if layer.kind == .text { item("Edit Text") { [weak self] in self?.beginTextEditing(id) } }
            if layer.kind.canHaveChildren { item("Step Into \(layer.name)") { store.open(id) } }
            // Where a tap on it can lead.
            if store.scope == nil {
                let own = store.screen(holding: id)?.id
                let others = store.screens.filter { $0.id != own }
                if !others.isEmpty || own != nil {
                    let flows = NSMenu()
                    for screen in others { item(screen.name, to: flows) { store.addFlow(from: id, to: screen.id) } }
                    if own != nil {
                        if !others.isEmpty { flows.addItem(.separator()) }
                        item("Back", to: flows) { store.addFlow(from: id, to: nil) }
                    }
                    let parent = NSMenuItem(title: "On Tap, Go To", action: nil, keyEquivalent: "")
                    parent.submenu = flows
                    menu.addItem(parent)
                }
            }
            // Where it shows: on another screen, or over every one.
            let moves = store.screenMoves(for: id)
            if !moves.screens.isEmpty || moves.everyScreen {
                let places = NSMenu()
                if moves.everyScreen { item("Every Screen", to: places) { store.move(id, toScreen: nil) } }
                if moves.everyScreen, !moves.screens.isEmpty { places.addItem(.separator()) }
                for screen in moves.screens { item(screen.name, to: places) { store.move(id, toScreen: screen.id) } }
                let parent = NSMenuItem(title: "Move To", action: nil, keyEquivalent: "")
                parent.submenu = places
                menu.addItem(parent)
            }
            menu.addItem(.separator())
            item("Bring Forward") { store.reorderLayer(id, by: 1) }
            item("Send Backward") { store.reorderLayer(id, by: -1) }
            menu.addItem(.separator())
            item("Duplicate") { store.duplicateSelectedLayers() }
            item("Delete") { store.deleteSelectedLayers() }
        case let .title(index):
            let frame = board.frames[index]
            store.selectedLayers = [frame.id]
            guard frame.isPage else {
                if store.scope == nil { item("Add Screen") { store.addScreen() } }
                break
            }
            // On the screen previewed from, the way back to starting at the beginning.
            if store.previewScreen == frame.id {
                item("Preview from the Start") { store.preview(from: nil) }
            } else {
                item("Preview from Here") { store.preview(from: frame.id) }
            }
            menu.addItem(.separator())
            item("Rename") { [weak self] in self?.beginNameEditing(index) }
            if index > 0 { item("Make First Screen") { store.moveScreen(frame.id, to: 0) } }
            item("Duplicate") { store.duplicateSelectedLayers() }
            menu.addItem(.separator())
            item("Add Screen") { store.addScreen() }
            item("Delete Screen") { store.deleteSelectedLayers() }
        case .room, .outside, .addScreen, .flowHandle, .resize:
            guard store.scope == nil else { return nil }
            item("Add Screen") { store.addScreen() }
        }
        return menu.items.isEmpty ? nil : menu
    }

    public override func mouseDragged(with event: NSEvent) {
        let point = boardPoint(event)
        pointer = point
        switch drag {
        case .none:
            break

        case let .pan(start, origin):
            let cursor = viewPoint(event)
            hasFitted = true
            offset = CGPoint(x: origin.x + cursor.x - start.x, y: origin.y + cursor.y - start.y)
            redraw()

        case let .create(kind, frame, start, _):
            drag = .create(kind: kind, frame: frame, start: start, current: point)
            drawOverlays()

        case let .marquee(frame, start, _, screen):
            drag = .marquee(frame: frame, start: start, current: point, screen: screen)
            let box = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(start.x - point.x), height: abs(start.y - point.y))
            if box.width > 2 || box.height > 2, let container = shown.layer(level(inFrame: frame)) {
                store.selectedLayers = Set(container.children.map(\.id).filter { id in
                    shown.layer(id)?.isPage != true && (boardRect(of: id)?.intersects(box) ?? false)
                })
            }
            drawOverlays()

        case let .screen(id, start, _):
            drag = .screen(id, start: start, moved: abs(point.x - start.x) > 4)

        case let .flow(from, _):
            drag = .flow(from: from, current: point)
            drawOverlays()

        case let .reorder(id, _):
            guard let parent = shown.screen.parent(of: id), let inside = self.point(point, inside: parent.id),
                  let tree = trees[frameIndex(of: id)].find(parent.id) else { return }
            // Only the first copy of a repeated view counts; the rest follow it.
            var seen: Set<LayerID> = []
            let siblings = tree.children.filter { seen.insert($0.id).inserted }
            let flow: Snapping.Flow = parent.arrangement == .grid ? .grid
                : parent.value(.axis).textValue == "Horizontal" ? .horizontal : .vertical
            guard let from = siblings.firstIndex(where: { $0.id == id }),
                  let to = Snapping.place(of: inside, among: siblings.map(\.frame), dragged: from, flow: flow), to != from else { return }
            let target = siblings[to].id
            drag = .reorder(layer: id, moved: true)
            store.interactive { document in
                document.screen.update(parent.id) { parent in
                    guard let old = parent.children.firstIndex(where: { $0.id == id }),
                          let new = parent.children.firstIndex(where: { $0.id == target }) else { return }
                    parent.children.insert(parent.children.remove(at: old), at: new)
                }
            }

        case let .move(start, originals, _):
            var delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
            guard abs(delta.x) + abs(delta.y) > 0 else { return }
            drag = .move(start: start, originals: originals, moved: true)
            guides = nil
            if !event.modifierFlags.contains(.command) { delta = snapped(delta, moving: originals) }
            store.interactive { document in
                for (id, original) in originals {
                    let local = self.deltaInParent(of: id, delta)
                    document.screen.update(id) { layer in
                        layer.set(.position, .point(Point2(
                            x: (original.x + local.x).rounded(), y: (original.y + local.y).rounded()
                        )))
                    }
                }
            }

        case let .resize(handle, id, frame, start):
            let delta = deltaInParent(of: id, CGPoint(x: point.x - start.x, y: point.y - start.y))
            var minX = frame.minX, minY = frame.minY, maxX = frame.maxX, maxY = frame.maxY
            if handle.unit.x == 0 { minX = min(frame.minX + delta.x, maxX - 1) }
            if handle.unit.x == 1 { maxX = max(frame.maxX + delta.x, minX + 1) }
            if handle.unit.y == 0 { minY = min(frame.minY + delta.y, maxY - 1) }
            if handle.unit.y == 1 { maxY = max(frame.maxY + delta.y, minY + 1) }
            let width = (maxX - minX).rounded()
            let height = (maxY - minY).rounded()
            // Where a stack or grid puts the view is not the view's to say.
            let placed = store.isPlacedByParent(id)
            store.interactive { document in
                document.screen.update(id) { layer in
                    let anchor = layer.value(.anchor).pointValue
                    layer.set(.size, .size(Size2(width: width, height: height)))
                    guard !placed else { return }
                    layer.set(.position, .point(Point2(
                        x: minX.rounded() + anchor.x * width, y: minY.rounded() + anchor.y * height
                    )))
                }
            }
        }
    }

    /// A movement on the board, changed a little so that the views it moves line up with
    /// their siblings and with what they are in. Only for views that share a container
    /// and stand straight in it.
    private func snapped(_ delta: CGPoint, moving originals: [LayerID: Point2]) -> CGPoint {
        guard let first = originals.keys.first, let parent = shown.screen.parent(of: first),
              originals.keys.allSatisfy({ shown.screen.parent(of: $0)?.id == parent.id }),
              isAxisAligned(parent.id), let transform = transform(toScreenFrom: parent.id) else { return delta }
        let index = frameIndex(of: parent.id)
        guard let tree = trees[index].find(parent.id) else { return delta }
        let local = deltaInParent(of: first, delta)
        var moving = CGRect.null
        var others: [CGRect] = []
        for child in tree.children where child.instance == 0 {
            if let original = originals[child.id] {
                let size = child.size
                let anchor = child.anchor
                moving = moving.union(CGRect(
                    x: original.x - anchor.x * size.width + local.x, y: original.y - anchor.y * size.height + local.y,
                    width: size.width, height: size.height
                ))
            } else {
                others.append(child.frame)
            }
        }
        guard !moving.isNull else { return delta }
        let size = tree.size
        let result = Snapping.snap(moving, to: others, in: CGSize(width: size.width, height: size.height), threshold: 6 / (zoom * max(transform.a, 0.01)))
        guard result.dx != 0 || result.dy != 0 || !result.linesX.isEmpty || !result.linesY.isEmpty else { return delta }
        guides = (result.linesX, result.linesY, index, parent.id)
        // Back out to the board's scale.
        return CGPoint(x: delta.x + result.dx * transform.a, y: delta.y + result.dy * transform.d)
    }

    public override func mouseUp(with event: NSEvent) {
        lastMouseUp = event.timestamp
        let point = boardPoint(event)
        let ended = drag
        drag = .none
        guides = nil
        defer { drawOverlays() }
        switch ended {
        case .none:
            break
        case .pan:
            cursor(for: hovered).set()
        case let .move(_, originals, moved):
            // Let go over another screen, a view goes to that screen.
            if moved, originals.count == 1, let id = originals.keys.first { carry(id, to: point) }
            store.endInteractive("Move")
        case .reorder:
            store.endInteractive("Reorder")
        case .resize:
            store.endInteractive("Resize")
        case let .marquee(frame, start, current, screen):
            if abs(start.x - current.x) <= 2, abs(start.y - current.y) <= 2 {
                // A click on empty room: the screen itself, or nothing; and out of a view one was in.
                if level(inFrame: frame) != board.frames[frame].id { store.open(board.frames[frame].isPage ? board.frames[frame].id : nil) }
                store.selectedLayers = screen.map { [$0] } ?? []
            }
        case let .screen(id, _, moved):
            if moved { store.moveScreen(id, to: board.nearestIndex(to: point)) }
        case let .flow(from, _):
            endFlow(from: from, at: point, event: event)
        case let .create(kind, index, start, current):
            var frame = CGRect(
                x: min(start.x, current.x), y: min(start.y, current.y),
                width: abs(start.x - current.x), height: abs(start.y - current.y)
            )
            if frame.width < 4 || frame.height < 4 {
                // A click without a drag places a layer of the default size.
                let size = LayerProperty.size.defaultValue(for: kind).sizeValue
                frame = CGRect(x: start.x - size.width / 2, y: start.y - size.height / 2, width: size.width, height: size.height)
            }
            // It goes into the view one is in, where it was drawn.
            let container = level(inFrame: index)
            if let inside = self.point(frame.origin, inside: container), let transform = transform(toScreenFrom: container),
               transform.a > 0, transform.d > 0 {
                frame = CGRect(x: inside.x, y: inside.y, width: frame.width / transform.a, height: frame.height / transform.d)
            } else {
                frame.origin = board.screenPoint(frame.origin, inFrame: index)
            }
            store.addLayer(kind, frame: frame, into: container)
            store.tool = .select
        }
    }

    /// Moves a view that was let go over another screen to that screen, where it was let go.
    private func carry(_ id: LayerID, to point: CGPoint) {
        guard let index = board.index(at: point), index != frameIndex(of: id), board.frames[index].isPage,
              let parent = shown.screen.parent(of: id), parent.isPage || parent.id == shown.screen.id,
              let rect = boardRect(of: id) else { return }
        let target = board.frames[index].id
        let origin = board.screenPoint(rect.origin, inFrame: index)
        store.interactive { document in
            guard var layer = document.screen.remove(id) else { return }
            let size = layer.value(.size).sizeValue
            let anchor = layer.value(.anchor).pointValue
            layer.set(.position, .point(Point2(
                x: (origin.x + anchor.x * size.width).rounded(), y: (origin.y + anchor.y * size.height).rounded()
            )))
            document.screen.insert(layer, into: target)
        }
    }

    /// What an arrow let go at a board point can become: over another screen a flow to it
    /// in each style, over its own screen a way back, and over empty room a new screen to
    /// go to.
    func flowChoices(from source: LayerID, at point: CGPoint) -> [(title: String, run: () -> Void)] {
        let own = store.screen(holding: source)?.id
        if let index = board.index(at: point), board.frames[index].isPage, board.frames[index].id != own {
            let target = board.frames[index].id
            return Navigation.Style.allCases.map { style in
                (style.rawValue, { [store] in _ = store.addFlow(from: source, to: target, style: style) })
            }
        }
        if board.index(at: point) != nil {
            guard own != nil else { return [] }
            return [("Go Back", { [store] in _ = store.addFlow(from: source, to: nil) })]
        }
        return Navigation.Style.allCases.map { style in
            ("\(style.rawValue) to a New Screen", { [weak self, store] in
                store.transaction("Add Flow") {
                    guard let made = store.addScreen() else { return }
                    store.addFlow(from: source, to: made, style: style)
                }
                self?.hasFitted = false
                self?.needsLayout = true
            })
        }
    }

    private func endFlow(from source: LayerID, at point: CGPoint, event: NSEvent) {
        let choices = flowChoices(from: source, at: point)
        guard !choices.isEmpty else { return }
        let menu = NSMenu()
        for choice in choices {
            let item = NSMenuItem(title: choice.title, action: #selector(runMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuAction(choice.run)
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private final class MenuAction: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    @objc private func runMenuAction(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.run()
    }

    // MARK: Typing into a text

    /// Puts a field over a text view, so what it says can be retyped where it is.
    private func beginTextEditing(_ id: LayerID) {
        guard let layer = shown.layer(id) else { return }
        let field = NSTextField(string: layer.value(.text).textValue)
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.delegate = self
        field.cell?.wraps = !layer.value(.singleLine).boolValue
        field.cell?.isScrollable = layer.value(.singleLine).boolValue
        addSubview(field)
        textField = field
        editedText = id
        placeTextField()
        window?.makeFirstResponder(field)
    }

    /// Puts a field over a screen's title, to rename the screen where its name is.
    func beginNameEditing(_ index: Int) {
        guard board.frames.indices.contains(index), board.frames[index].isPage else { return }
        endTextEditing(commit: true)
        let field = NSTextField(string: board.frames[index].name)
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.font = .systemFont(ofSize: 12)
        field.delegate = self
        field.cell?.isScrollable = true
        addSubview(field)
        textField = field
        editedName = board.frames[index].id
        placeTextField()
        drawOverlays()
        window?.makeFirstResponder(field)
    }

    private func placeTextField() {
        if let field = textField, let id = editedName, let index = board.frames.firstIndex(where: { $0.id == id }) {
            let title = titleRect(index)
            field.frame = CGRect(x: title.minX - 2, y: bounds.height - title.maxY - 1, width: min(max(title.width, 120), 220), height: 20)
            return
        }
        guard let field = textField, let id = editedText, let rect = boardRect(of: id), let layer = shown.layer(id) else { return }
        let box = overlayRect(rect)
        let size = max(layer.value(.fontSize).numberValue * zoom, 6)
        field.font = NSFont.systemFont(ofSize: size, weight: layer.value(.fontWeight).numberValue >= 600 ? .bold : .regular)
        let width = max(box.width, 80)
        let height = max(box.height, size * 1.4)
        field.frame = CGRect(x: box.minX, y: bounds.height - box.minY - height, width: width, height: height)
    }

    func endTextEditing(commit: Bool) {
        guard let field = textField, let id = editedText ?? editedName else { return }
        let renames = editedName != nil
        textField = nil
        editedText = nil
        editedName = nil
        let text = field.stringValue
        field.delegate = nil
        field.removeFromSuperview()
        if renames {
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if commit, !name.isEmpty, shown.layer(id)?.name != name { store.renameLayer(id, to: name) }
            drawOverlays()
        } else if commit, shown.layer(id)?.value(.text).textValue != text {
            store.setInput(ViewInput(.text), of: id, to: .text(text))
        }
        window?.makeFirstResponder(self)
    }

    public func controlTextDidEndEditing(_ notification: Notification) {
        endTextEditing(commit: true)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            endTextEditing(commit: false)
            return true
        }
        return false
    }

    // MARK: Scrolling and zooming

    public override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            zoom(by: 1 + event.scrollingDeltaY * 0.01, around: event)
        } else {
            hasFitted = true
            offset.x += event.scrollingDeltaX
            offset.y += event.scrollingDeltaY
            redraw()
        }
    }

    public override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, around: event)
    }

    private func zoom(by factor: CGFloat, around event: NSEvent) {
        hasFitted = true
        let anchor = boardPoint(event)
        let cursor = overlayPoint(anchor)
        zoom = min(max(zoom * factor, 0.05), 16)
        offset = CGPoint(x: cursor.x - anchor.x * zoom, y: cursor.y - anchor.y * zoom)
        redraw()
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.command) else {
            switch event.charactersIgnoringModifiers {
            // Command-0 shows every screen, Command-1 the true size, and = and - step between.
            case "0":
                hasFitted = false
                zoomToFit()
                return
            case "1": return zoom(to: 1)
            case "2": return zoomToSelection()
            case "=", "+": return zoom(to: zoom * 1.25)
            case "-": return zoom(to: zoom / 1.25)
            default: break
            }
            if event.charactersIgnoringModifiers == "d" {
                store.duplicateSelectedLayers()
            } else if event.charactersIgnoringModifiers == "a" {
                // Everything in the view one is in.
                store.selectedLayers = Set(store.openContainer.children.filter { !$0.isPage }.map(\.id))
            } else {
                super.keyDown(with: event)
            }
            return
        }
        let step: Double = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 51, 117:
            // A selected arrow is a patch; a selected view takes its patch with it.
            if store.selectedLayers.isEmpty { store.deleteSelectedPatches() } else { store.deleteSelectedLayers() }
        case 123: nudge(dx: -step, dy: 0)
        case 124: nudge(dx: step, dy: 0)
        case 125: nudge(dx: 0, dy: step)
        case 126: nudge(dx: 0, dy: -step)
        case 49:
            // The space bar held: a drag moves the board.
            if !spaceDown {
                spaceDown = true
                NSCursor.openHand.set()
            }
        case 36, 76:
            // Return steps into the selected view, or retypes the selected text.
            guard let layer = store.selectedLayer else { return }
            if layer.kind == .text {
                beginTextEditing(layer.id)
            } else if layer.kind.canHaveChildren {
                store.open(layer.id)
            }
        case 53:
            // Escape: out of the tool, then out of the selection, then out of the view.
            if store.tool != .select {
                store.tool = .select
            } else if !store.selectedNodes.isEmpty {
                store.selectedNodes = []
            } else {
                store.closeView()
            }
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v": store.tool = .select
            case "r": store.tool = .view
            case "o": store.tool = .ellipse
            case "t": store.tool = .text
            default: super.keyDown(with: event)
            }
        }
    }

    public override func keyUp(with event: NSEvent) {
        guard event.keyCode == 49 else { return super.keyUp(with: event) }
        spaceDown = false
        if case .pan = drag { return }
        cursor(for: hovered).set()
    }

    /// Fits what is selected in view, or the screen it is on when that is small: the way
    /// to look closely at one screen of many.
    func zoomToSelection() {
        let ids = selection.isEmpty ? [] : Array(selection)
        var box = ids.compactMap { boardRect(of: $0) }.reduce(CGRect.null) { $0.union($1) }
        if box.isNull || (box.width < 80 && box.height < 80), let first = ids.first {
            box = board.frames[frameIndex(of: first)].rect
        }
        guard !box.isNull, box.width > 0, box.height > 0 else { return zoomToFit() }
        hasFitted = true
        let available = bounds.insetBy(dx: 48, dy: 48)
        zoom = min(max(min(available.width / box.width, available.height / box.height, 4), 0.05), 16)
        offset = CGPoint(x: bounds.midX - box.midX * zoom, y: bounds.midY - box.midY * zoom)
        redraw()
    }

    /// Zooms to a scale, keeping the middle of what is in view where it is.
    private func zoom(to scale: CGFloat) {
        hasFitted = true
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        let anchor = CGPoint(x: (middle.x - offset.x) / zoom, y: (middle.y - offset.y) / zoom)
        zoom = min(max(scale, 0.05), 16)
        offset = CGPoint(x: middle.x - anchor.x * zoom, y: middle.y - anchor.y * zoom)
        redraw()
    }

    /// How much the board is magnified, and where its corner is in the view.
    var viewport: (zoom: CGFloat, offset: CGPoint) { (zoom, offset) }

    // The Edit menu's standard actions.
    @objc func copy(_ sender: Any?) {
        store.copyToPasteboard(store.fragmentOfSelectedLayers())
    }

    @objc func cut(_ sender: Any?) {
        copy(sender)
        store.deleteSelectedLayers()
    }

    @objc func paste(_ sender: Any?) {
        if !store.pasteFromPasteboard() { NSSound.beep() }
    }

    private func nudge(dx: Double, dy: Double) {
        // A view its stack or grid places stays where that puts it.
        let ids = store.selectedLayers.filter { $0 != store.document.screen.id && !store.isPlacedByParent($0) }
        guard !ids.isEmpty else { return }
        store.apply("Nudge") { document in
            for id in ids {
                document.screen.update(id) { layer in
                    let position = layer.value(.position).pointValue
                    layer.set(.position, .point(Point2(x: position.x + dx, y: position.y + dy)))
                }
            }
        }
    }
}

struct CanvasRepresentable: NSViewRepresentable {
    let store: DocumentStore
    let document: PaperModel.Document
    let selection: Set<LayerID>
    var selectedNodes: Set<NodeID> = []
    let tool: CanvasTool
    /// The view one is inside of is marked, so stepping in or out redraws.
    var openView: LayerID?
    /// The screen the Viewer is showing, marked on its title.
    var viewerScreen: LayerID?
    /// The screen the Viewer starts on, when the person previewed from one.
    var startScreen: LayerID?
    /// What extensions draw is drawn from their definitions, so a change of those
    /// redraws the Canvas too, as it does the Patch Editor.
    var registryRevision = 0
    var fitRequest = 0

    func makeNSView(context: Context) -> CanvasView {
        CanvasView(store: store)
    }

    func updateNSView(_ view: CanvasView, context: Context) {
        view.update(
            document: document, selection: selection, selectedNodes: selectedNodes, tool: tool,
            registryRevision: registryRevision, fitRequest: fitRequest, viewerScreen: viewerScreen,
            startScreen: startScreen
        )
    }
}

/// A small rounded label on the Canvas: a flow's style, a view's size. It is as wide as
/// its text and its text sits in its middle, both worked out from the font, and it is
/// put on whole pixels.
final class CanvasPill {
    let layer = CALayer()
    static let font = NSFont.systemFont(ofSize: 10, weight: .medium)
    static let titleFont = NSFont.systemFont(ofSize: 12)
    static let height: CGFloat = 16
    private let label = CATextLayer()
    private var size = CGSize(width: 0, height: CanvasPill.height)

    init() {
        label.font = CanvasPill.font
        label.fontSize = CanvasPill.font.pointSize
        label.alignmentMode = .center
        layer.cornerRadius = CanvasPill.height / 2
        layer.addSublayer(label)
    }

    var isHidden: Bool {
        get { layer.isHidden }
        set { layer.isHidden = newValue }
    }

    var frame: CGRect { layer.frame }

    /// How wide it is for the text it was last given.
    var width: CGFloat { size.width }

    func set(_ text: String, scale: CGFloat, text color: NSColor, fill: NSColor, border: NSColor?) {
        let measured = (text as NSString).size(withAttributes: [.font: CanvasPill.font])
        // A whole number of points, and an even one, so the middle is on a pixel too.
        let width = (ceil(measured.width) + 14).rounded(.up)
        size = CGSize(width: width + width.truncatingRemainder(dividingBy: 2), height: CanvasPill.height)
        let line = ceil(CanvasPill.font.ascender - CanvasPill.font.descender)
        label.string = text
        label.contentsScale = scale
        label.foregroundColor = color.cgColor
        label.frame = CGRect(x: 0, y: ((CanvasPill.height - line) / 2 * scale).rounded() / scale, width: size.width, height: line)
        layer.backgroundColor = fill.cgColor
        layer.borderColor = border?.cgColor
        layer.borderWidth = border == nil ? 0 : 1 / scale
    }

    /// Puts its middle at a point, on whole pixels.
    func center(at point: CGPoint, scale: CGFloat) {
        layer.frame = CGRect(
            x: ((point.x - size.width / 2) * scale).rounded() / scale, y: ((point.y - size.height / 2) * scale).rounded() / scale,
            width: size.width, height: size.height
        )
    }
}
