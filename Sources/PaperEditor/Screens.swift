import Foundation
import PaperEngine
import PaperModel

/// Screens and the flows between them. A screen is a view directly in the root with
/// `Layer.page` set: it fills the device, and the runtime shows one at a time. A document
/// with none has one screen, the root itself.
extension DocumentStore {
    /// The prototype's screens, in order. Empty while the root is the only one.
    public var screens: [Layer] { scope == nil ? document.screen.pages : [] }

    public func isScreen(_ id: LayerID) -> Bool { document.layer(id)?.isPage ?? false }

    /// The screen a view is in (or is), when the document has screens.
    public func screen(holding id: LayerID) -> Layer? {
        document.screen.path(to: id).dropFirst().first.flatMap { $0.isPage ? $0 : nil }
    }

    /// The screen the Viewer starts on: the one previewed from, or the first.
    public var startScreen: LayerID? {
        if let previewScreen, isScreen(previewScreen) { return previewScreen }
        return screens.first?.id
    }

    /// Restarts the prototype on a screen, as if the person had arrived there: what a
    /// designer working on the third screen of a flow wants to try without tapping through
    /// the first two. nil starts from the first screen again. Not saved, not an undo step.
    public func preview(from screen: LayerID?) {
        // The first screen is where it starts anyway.
        previewScreen = screen.flatMap { isScreen($0) && $0 != screens.first?.id ? $0 : nil }
        showsViewer = true
        restartPrototype()
    }

    /// Where a view can be moved among the screens: to another screen, or to the device so
    /// it shows over every screen (a tab bar, a status bar). Only a view directly on a screen
    /// or directly in the device moves this way, keeping where it is on the screen.
    public func screenMoves(for id: LayerID) -> (screens: [Layer], everyScreen: Bool) {
        guard scope == nil, let view = document.layer(id), !view.isPage, !screens.isEmpty,
              let parent = document.screen.parent(of: id), parent.isPage || parent.id == document.screen.id else { return ([], false) }
        return (screens.filter { $0.id != parent.id }, parent.isPage)
    }

    /// Moves a view to a screen, or with nil to the device, over every screen. One undo step.
    public func move(_ id: LayerID, toScreen target: LayerID?) {
        let moves = screenMoves(for: id)
        let destination = target ?? document.screen.id
        guard target == nil ? moves.everyScreen : moves.screens.contains(where: { $0.id == target }) else { return }
        // Its patch goes to a free place in the level it moves to, not on top of what is there.
        let spot = freeSpot(inLevel: target)
        apply(target == nil ? "Show on Every Screen" : "Move to Screen") { document in
            guard let layer = document.screen.remove(id) else { return }
            document.screen.insert(layer, into: destination)
            if let patch = document.graph.viewNode(layer: id) { document.graph.update(patch.id) { $0.position = spot } }
        }
        selectedLayers = [id]
    }

    /// Adds a screen after the others and selects it. The first time, what the root held
    /// becomes the first screen, so nothing that was built is left outside one.
    @discardableResult
    public func addScreen(name: String? = nil) -> LayerID? {
        guard scope == nil else { return nil }
        var made: LayerID?
        transaction("Add Screen") {
            if document.screen.pages.isEmpty, !document.screen.children.isEmpty { wrapRootInScreen() }
            // Numbered in the order they are on the board.
            let layer = Layer.newPage(name: name ?? uniqueLayerName("Screen \(document.screen.pages.count + 1)"))
            made = layer.id
            // Screens are made to be seen side by side.
            showsCanvas = true
            apply("Add Screen") { document in
                // After the last screen, under whatever floats over all of them.
                let index = document.screen.children.lastIndex(where: \.isPage).map { $0 + 1 } ?? 0
                document.screen.children.insert(layer, at: index)
            }
        }
        if let made { selectedLayers = [made] }
        return made
    }

    /// Moves everything in the root into a new first screen, with the root's fill and
    /// arrangement, and the patches kept at the top with it.
    private func wrapRootInScreen() {
        let root = document.screen
        var first = Layer.newPage(name: uniqueLayerName(root.name == "Screen" ? "Screen 1" : root.name))
        first.children = root.children
        let carried: [LayerProperty] = [.fill, .layout, .axis, .columns, .spacing, .alignment, .distribution, .scrolls,
                                        .paddingHorizontal, .paddingVertical, .paddingTop, .paddingBottom, .paddingLeft, .paddingRight]
        for property in carried {
            if let value = root.properties[property] { first.properties[property] = value }
        }
        apply("Add Screen") { document in
            document.screen.children = [first]
            // What is left is the device the screens are shown on.
            document.screen.name = "Device"
            for property in carried where property != .fill { document.screen.properties[property] = nil }
            for index in document.graph.nodes.indices
            where document.graph.nodes[index].layerID == nil && document.graph.nodes[index].home == nil {
                document.graph.nodes[index].home = first.id
            }
            for index in document.graph.comments.indices where document.graph.comments[index].home == nil {
                document.graph.comments[index].home = first.id
            }
        }
    }

    /// Makes a plain view directly in the root a screen, or a screen a plain view again.
    public func setScreen(_ id: LayerID, _ isScreen: Bool) {
        guard scope == nil, document.screen.children.contains(where: { $0.id == id && $0.kind == .view }) else { return }
        apply(isScreen ? "Make Screen" : "Make View") { document in
            document.screen.update(id) { $0.page = isScreen ? true : nil }
        }
    }

    /// Moves a screen to a place among the screens (0 is the first, where a prototype starts).
    public func moveScreen(_ id: LayerID, to place: Int) {
        let pages = document.screen.pages.map(\.id)
        guard scope == nil, let from = pages.firstIndex(of: id) else { return }
        var order = pages
        order.remove(at: from)
        order.insert(id, at: min(max(place, 0), order.count))
        guard order != pages else { return }
        apply("Reorder Screens") { document in
            let byID = Dictionary(document.screen.children.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var next = order.makeIterator()
            document.screen.children = document.screen.children.map { child in
                child.isPage ? next.next().flatMap { byID[$0] } ?? child : child
            }
        }
    }

    // MARK: Flows

    /// One way from a view to a screen: a Navigate or Navigate Back patch, and where the
    /// pulse into its Go comes from. Nothing of it is stored; the graph is the truth.
    public struct Flow: Hashable, Sendable, Identifiable {
        /// The Navigate (or Navigate Back) patch.
        public var id: NodeID
        /// The view whose touch starts it, when the pulse can be followed back to one.
        public var source: LayerID?
        /// The screen it shows; nil for going back.
        public var target: LayerID?
        public var style: Navigation.Style
    }

    /// Every flow in the document, in the graph's order.
    public var flows: [Flow] {
        let graph = document.graph
        return graph.nodes.compactMap { node -> Flow? in
            guard node.kind == PatchKind.navigate || node.kind == PatchKind.navigateBack else { return nil }
            if node.kind == PatchKind.navigate, node.layerID.map(isScreen) != true { return nil }
            let style = Navigation.Style.named(node.inputs["style"]?.textValue ?? "") ?? .push
            return Flow(id: node.id, source: Self.touched(before: node.id, in: graph), target: node.layerID, style: style)
        }
    }

    /// The view a pulse into a patch's Go comes from: back along the cables to the first
    /// patch that is attached to a view.
    private static func touched(before node: NodeID, in graph: Graph) -> LayerID? {
        var seen: Set<NodeID> = [node]
        var next = graph.connection(into: PortRef(node: node, port: "go")).map { [$0.from.node] } ?? []
        while let id = next.popLast() {
            guard seen.insert(id).inserted, let patch = graph.node(id) else { continue }
            if let layer = patch.layerID { return layer }
            next.append(contentsOf: graph.connections.filter { $0.to.node == id }.map(\.from.node))
        }
        return nil
    }

    /// Makes a tap on a view show a screen: a Tap patch on the view (the one it has, if it
    /// has one), a Navigate patch on the screen, and a cable between them. One undo step.
    /// `target` nil goes back instead.
    @discardableResult
    public func addFlow(from source: LayerID, to target: LayerID?, style: Navigation.Style = .push) -> NodeID? {
        guard scope == nil, let view = document.layer(source), view.kind != .screen else { return nil }
        if let target { guard isScreen(target), screen(holding: source)?.id != target else { return nil } }
        var made: NodeID?
        let selection = selectedNodes
        transaction(target == nil ? "Add Back" : "Add Flow") {
            let tap = document.graph.nodes.first { $0.kind == PatchKind.tap && $0.layerID == source }?.id
                ?? addTouchPatch(PatchKind.tap, for: source, at: freeSpot(inLevel: document.screen.parent(of: source)?.id))
            var node: PatchNode
            if let target {
                node = PatchNode(kind: PatchKind.navigate, position: freeSpot(inLevel: nil), layerID: target)
                if style != .push { node.inputs["style"] = .text(style.rawValue) }
            } else {
                let level = document.screen.parent(of: source)?.id
                node = PatchNode(kind: PatchKind.navigateBack, position: freeSpot(inLevel: level))
                node.home = level == document.screen.id ? nil : level
            }
            made = node.id
            apply("Add Flow") { document in
                document.graph.add(node)
                document.graph.connect(from: PortRef(node: tap, port: "tapped"), to: PortRef(node: node.id, port: "go"))
            }
        }
        selectedNodes = made.map { [$0] } ?? selection
        return made
    }

    /// Changes how a flow's screen arrives.
    public func setStyle(_ style: Navigation.Style, ofFlow id: NodeID) {
        setLiteral(.text(style.rawValue), node: id, port: "style")
    }

    /// A free place for a patch in a level of the graph: under everything that is there.
    func freeSpot(inLevel level: LayerID?) -> Point2 {
        let nodes = document.levelGraph(of: level).nodes
        guard !nodes.isEmpty else { return Point2(x: 60, y: 60) }
        let left = nodes.map(\.position.x).min() ?? 60
        let bottom = nodes.map { node in
            node.position.y + PatchLayout(node: node, ports: visiblePorts(for: node)).size.height
        }.max() ?? 60
        return PatchGrid.snap(Point2(x: left, y: bottom + 24))
    }
}
