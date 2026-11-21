import Foundation

/// A prototype: its visible layers and the graph that gives them behavior.
public struct Document: Codable, Hashable, Sendable {
    public static let currentVersion = 4

    public var version: Int
    /// The root of the layer tree. Always of kind `.screen`.
    public var screen: Layer
    public var graph: Graph
    /// Components this document defines or has taken from a library.
    public var components: [ComponentDefinition] = []
    /// Set while this document is a sketch of something that lives in code: where it came
    /// from and how it looked when it was brought in.
    public var sketch: Sketch?

    /// `artboard` is what the root was called before version 3.
    private enum CodingKeys: String, CodingKey { case version, screen, artboard, graph, components, sketch }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard version <= Document.currentVersion else { throw LoadError.unsupportedVersion(version) }
        screen = try container.decodeIfPresent(Layer.self, forKey: .screen)
            ?? container.decode(Layer.self, forKey: .artboard)
        graph = try container.decode(Graph.self, forKey: .graph)
        components = try container.decodeIfPresent([ComponentDefinition].self, forKey: .components) ?? []
        sketch = try container.decodeIfPresent(Sketch.self, forKey: .sketch)
        if version < 3 { upgradeToViews() }
        normalize()
        // Before version 4 the whole graph was one level. Each patch now goes in the view
        // whose children it works on.
        if version < 4 { settleHomes() }
        version = Document.currentVersion
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(screen, forKey: .screen)
        try container.encode(graph, forKey: .graph)
        try container.encode(components, forKey: .components)
        try container.encodeIfPresent(sketch, forKey: .sketch)
    }

    public init(screen: Layer = Layer(name: "Screen", kind: .screen), graph: Graph = Graph()) {
        self.version = Document.currentVersion
        self.screen = screen
        self.graph = graph
        normalize()
    }

    public func layer(_ id: LayerID) -> Layer? { screen.find(id) }

    /// Removes a layer and every patch bound to it or to its descendants.
    public mutating func removeLayer(_ id: LayerID) {
        guard id != screen.id else { return }
        screen.remove(id)
        graph.removeNodes(boundToLayersNotIn: Set(screen.flattened.map(\.id)))
    }

    // MARK: Serialization

    public enum LoadError: Error, Equatable {
        case unsupportedVersion(Int)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(from data: Data) throws -> Document {
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version <= Document.currentVersion else {
            throw LoadError.unsupportedVersion(document.version)
        }
        return document
    }
}

// MARK: Views as patches

extension Document {
    /// Makes the graph agree with the layer tree: every layer has exactly one view patch,
    /// and no view patch is left for a layer that is gone. The same holds inside every
    /// component. A patch that has to be made is given a free place on the patch grid.
    ///
    /// Running it on a document that already agrees changes nothing, so it is safe to call
    /// after every edit. `measure` gives the height of a patch that is not a view; without
    /// it a usual height is assumed.
    public mutating func normalize(measure: ((PatchNode) -> Double)? = nil) {
        screen.settleStoredValues()
        screen.settlePages(inRoot: true)
        Document.settleStoredValues(of: &graph)
        for index in components.indices {
            components[index].root.settleStoredValues()
            components[index].root.settlePages(inRoot: false)
            Document.settleStoredValues(of: &components[index].graph)
        }
        let components = self.components
        Document.normalize(root: screen, graph: &graph, components: components, measure: measure)
        for index in self.components.indices {
            Document.normalize(
                root: self.components[index].root, graph: &self.components[index].graph,
                components: components, measure: measure
            )
        }
    }

    /// Keeps every number in the graph one that can be saved: a literal that is not finite
    /// is dropped (the input's default applies), a place that is not is moved to the origin.
    static func settleStoredValues(of graph: inout Graph) {
        for node in graph.nodes {
            let bad = node.inputs.filter { !$0.value.isFinite }.map(\.key)
            let placed = node.position.x.isFinite && node.position.y.isFinite
            guard !bad.isEmpty || !placed else { continue }
            graph.update(node.id) { node in
                for key in bad { node.inputs[key] = nil }
                if !placed { node.position = Point2(x: 0, y: 0) }
            }
        }
    }

    /// Gives the view patches of `layers` a place again, each in its own level of the graph:
    /// a view's patch goes under the patch of the view before it, and the first one beside
    /// the patch of the view they are in. For documents built in code, where only some
    /// patches were given a place.
    public mutating func arrangeViews(of layers: Set<LayerID>, measure: ((PatchNode) -> Double)? = nil) {
        let order = screen.flattened.filter { layers.contains($0.id) }
        var pending = Set(order.compactMap { graph.viewNode(layer: $0.id)?.id })
        for layer in order {
            guard let node = graph.viewNode(layer: layer.id) else { continue }
            pending.remove(node.id)
            let placed = Document.place(node, for: layer, root: screen, graph: graph, components: components, measure: measure, ignoring: pending.union([node.id]))
            graph.update(node.id) { $0.position = placed }
        }
    }

    /// Moves the view patches of `layers` down until none sits on another patch of its
    /// level. For documents built in code, whose places were chosen before a view patch
    /// had several rows.
    public mutating func separateViews(of layers: Set<LayerID>, measure: ((PatchNode) -> Double)? = nil) {
        let views = graph.nodes.filter { $0.kind == PatchKind.view && $0.layerID.map(layers.contains) == true }
            .sorted { ($0.position.x, $0.position.y) < ($1.position.x, $1.position.y) }
        var settled: Set<NodeID> = []
        let all = Set(views.map(\.id))
        for node in views {
            guard let layer = node.layerID.flatMap({ screen.find($0) }) else { continue }
            let level = screen.parent(of: layer.id) ?? screen
            var placer = Placer(
                root: screen, level: level, graph: graph, components: components, measure: measure,
                ignoring: all.subtracting(settled)
            )
            let placed = placer.take(node.position, height: placer.height(node))
            if placed != node.position { graph.update(node.id) { $0.position = placed } }
            settled.insert(node.id)
        }
    }

    private static func normalize(
        root: Layer, graph: inout Graph, components: [ComponentDefinition], measure: ((PatchNode) -> Double)?
    ) {
        let layers = root.flattened
        let known = Dictionary(layers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // One view patch per layer: drop those for layers that are gone, and any second one.
        var viewOf: [LayerID: NodeID] = [:]
        var stale: [NodeID] = []
        for node in graph.nodes where node.kind == PatchKind.view {
            if let layer = node.layerID, known[layer] != nil, viewOf[layer] == nil {
                viewOf[layer] = node.id
                // The patch of a component instance carries the component's ports.
                if node.componentID != known[layer]?.component?.id {
                    graph.update(node.id) { $0.componentID = known[layer]?.component?.id }
                }
                // The patch of a shader view carries the source, which declares its inputs.
                if node.script != known[layer]?.shader?.source || node.arrivingScript != known[layer]?.shader?.arriving {
                    graph.update(node.id) {
                        $0.script = known[layer]?.shader?.source
                        $0.arrivingScript = known[layer]?.shader?.arriving
                    }
                }
                // The patch of a view an extension draws carries which view it is.
                if node.custom != known[layer]?.custom?.kind {
                    graph.update(node.id) { $0.custom = known[layer]?.custom?.kind }
                }
            } else {
                stale.append(node.id)
            }
        }
        for id in stale { graph.remove(id) }
        guard viewOf.count < known.count else { return }

        for layer in layers where viewOf[layer.id] == nil {
            var node = PatchNode.view(of: layer.id, component: layer.component?.id)
            node.script = layer.shader?.source
            node.arrivingScript = layer.shader?.arriving
            node.custom = layer.custom?.kind
            node.position = place(node, for: layer, root: root, graph: graph, components: components, measure: measure, ignoring: [])
            graph.add(node)
            viewOf[layer.id] = node.id
        }
    }

    /// A free place for a view's patch in the level it shows in: under the patch of the
    /// view before it, or beside the patch of the view it is in when it is the first.
    private static func place(
        _ node: PatchNode, for layer: Layer, root: Layer, graph: Graph, components: [ComponentDefinition],
        measure: ((PatchNode) -> Double)?, ignoring: Set<NodeID>
    ) -> Point2 {
        let parent = root.parent(of: layer.id)
        var placer = Placer(root: root, level: parent ?? root, graph: graph, components: components, measure: measure, ignoring: ignoring)
        let height = placer.height(node, layer: layer)
        guard let parent else { return placer.take(placer.besideEverything(), height: height) }

        func placed(_ id: LayerID) -> PatchNode? {
            graph.viewNode(layer: id).flatMap { ignoring.contains($0.id) ? nil : $0 }
        }
        let siblings = parent.children.prefix { $0.id != layer.id }.compactMap { placed($0.id) }
        var spot: Point2
        if let before = siblings.last {
            spot = Point2(x: before.position.x, y: before.position.y + placer.height(before) + PatchGrid.gap)
            // A long run of views starts another column beside the first.
            let top = siblings.filter { $0.position.x == before.position.x }.map(\.position.y).min() ?? before.position.y
            if spot.y + height - top > Placer.columnHeight {
                spot = Point2(x: before.position.x + PatchGrid.nodeWidth + PatchGrid.gap * 2, y: top)
            }
        } else if parent.id == root.id, let own = placed(root.id) {
            // The first view on the screen goes beside the screen's own patch.
            spot = Point2(x: own.position.x + PatchGrid.nodeWidth + PatchGrid.gap * 4, y: own.position.y)
        } else {
            spot = placer.besideEverything()
        }
        return placer.take(spot, height: height)
    }

    /// Finds room for patches among the ones one level of a graph already has.
    private struct Placer {
        static let columnHeight = 960.0

        let layers: [LayerID: Layer]
        let graph: Graph
        let components: [ComponentDefinition]
        let measure: ((PatchNode) -> Double)?
        var taken: [(origin: Point2, height: Double)] = []

        init(
            root: Layer, level: Layer, graph: Graph, components: [ComponentDefinition],
            measure: ((PatchNode) -> Double)?, ignoring: Set<NodeID>
        ) {
            layers = Dictionary(root.flattened.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            self.graph = graph
            self.components = components
            self.measure = measure
            for node in graph.nodes where !ignoring.contains(node.id) && Document.shows(node, in: level, root: root) {
                taken.append((node.position, height(node)))
            }
        }

        func height(_ node: PatchNode, layer: Layer? = nil) -> Double {
            guard node.kind == PatchKind.view else {
                return measure?(node) ?? PatchGrid.nodeHeight(rows: 4, subtitle: node.layerID != nil)
            }
            guard let layer = layer ?? node.layerID.flatMap({ layers[$0] }) else {
                return PatchGrid.nodeHeight(rows: 1, subtitle: true)
            }
            let cabled = Set(graph.connections.filter { $0.to.node == node.id }.map(\.to.port))
            var rows = layer.shownInputs(chosen: node.shownPorts, cabled: cabled).count
            let cabledOut = Set(graph.connections.filter { $0.from.node == node.id }.map(\.from.port))
            rows += ViewOutput.shown(chosen: node.shownPorts, cabled: cabledOut).count
            if let use = layer.component, let definition = components.first(where: { $0.id == use.id }) {
                rows += definition.inputs.count + definition.outputs.count
            } else if layer.arrangement == .scrollView {
                rows += 3
            }
            rows += node.published?.count ?? 0
            rows += layer.shader.map { $0.inputCount + 1 } ?? 0
            rows += layer.custom?.inputCount ?? 0
            return PatchGrid.nodeHeight(rows: rows, subtitle: true)
        }

        /// The top of a new column to the right of every patch in the level.
        func besideEverything() -> Point2 {
            guard let right = taken.map(\.origin.x).max(), let top = taken.map(\.origin.y).min() else {
                return Point2(x: PatchGrid.unit * 4, y: PatchGrid.unit * 4)
            }
            return PatchGrid.snap(Point2(x: right + PatchGrid.nodeWidth + PatchGrid.gap * 4, y: top))
        }

        /// The nearest free place at or below `spot` for a patch of this height, which is
        /// then taken.
        mutating func take(_ spot: Point2, height: Double) -> Point2 {
            var place = PatchGrid.snap(spot)
            var moved = true
            while moved {
                moved = false
                for other in taken
                where abs(other.origin.x - place.x) < PatchGrid.nodeWidth + PatchGrid.gap
                    && place.y < other.origin.y + other.height + PatchGrid.gap
                    && other.origin.y < place.y + height + PatchGrid.gap {
                    place.y = PatchGrid.snap(other.origin.y + other.height + PatchGrid.gap)
                    moved = true
                }
            }
            taken.append((place, height))
            return place
        }
    }

    // MARK: Documents from before views were patches (version 2)

    /// Then a property was driven through a patch of its own, one per layer and property,
    /// and a component instance had a separate, optional patch. Both become the view's patch.
    private mutating func upgradeToViews() {
        Document.upgrade(root: screen, graph: &graph)
        for index in components.indices {
            Document.upgrade(root: components[index].root, graph: &components[index].graph)
        }
    }

    private static func upgrade(root: Layer, graph: inout Graph) {
        for index in graph.nodes.indices where graph.nodes[index].kind == PatchKind.component {
            graph.nodes[index].kind = PatchKind.view
        }
        for node in graph.nodes where node.kind == PatchKind.layerProperty {
            defer { graph.remove(node.id) }
            guard let layerID = node.layerID, let property = node.property, let layer = root.find(layerID) else { continue }
            let view: NodeID
            if let existing = graph.viewNode(layer: layerID) {
                view = existing.id
            } else {
                // It shows only what the old patches did, so the graph keeps its shape.
                view = graph.add(PatchNode(
                    kind: PatchKind.view, position: node.position, layerID: layerID,
                    componentID: layer.component?.id, shownPorts: []
                ))
            }
            if let cable = graph.connection(into: PortRef(node: node.id, port: "value")) {
                graph.connect(from: cable.from, to: PortRef(node: view, port: property.rawValue))
            } else {
                let ports: [String]
                switch property {
                case .position: ports = ["x", "y"]
                case .size: ports = ["width", "height"]
                default: ports = [property.rawValue]
                }
                graph.update(view) { patch in
                    let shown = patch.shownPorts ?? layer.type.preset
                    patch.shownPorts = shown + ports.filter { !shown.contains($0) }
                }
            }
        }
    }
}

// MARK: The graph, one view at a time

/// The graph is shown one container at a time, the way an app is built one view controller
/// at a time. A level is the patches of the views directly in a container, whatever is
/// attached to those, and the patches kept there (`PatchNode.home`). The container's own
/// patch is not in its level: it is one level out, among its siblings.
/// Stepping into a child shows that child's level. A cable may leave a level; nothing
/// about how the prototype runs depends on levels.
extension Document {
    /// The container a level belongs to: `id` if it is a view that can hold others, else the screen.
    public func container(_ id: LayerID?) -> Layer {
        if let id, let layer = screen.find(id), layer.kind.canHaveChildren { return layer }
        return screen
    }

    /// Whether a patch is part of a container's level.
    public func shows(_ node: PatchNode, in container: Layer) -> Bool {
        Document.shows(node, in: container, root: screen)
    }

    public static func shows(_ node: PatchNode, in container: Layer, root: Layer) -> Bool {
        if let layer = node.layerID {
            // Inside a view only what is nested in it shows, not the view itself: its own
            // patch is one level out. The screen has no level outside it, so it shows at the top.
            if layer == container.id { return container.id == root.id }
            return container.children.contains { $0.id == layer }
        }
        if let home = node.home, let kept = root.find(home), kept.kind.canHaveChildren { return kept.id == container.id }
        return container.id == root.id
    }

    /// One level of the graph: its patches, every cable that touches one of them (so a
    /// cable that leaves the level is still known), and its comments.
    public func levelGraph(of id: LayerID?) -> Graph {
        let container = container(id)
        let nodes = graph.nodes.filter { shows($0, in: container) }
        let ids = Set(nodes.map(\.id))
        var level = Graph(
            nodes: nodes,
            connections: graph.connections.filter { ids.contains($0.from.node) || ids.contains($0.to.node) }
        )
        level.comments = graph.comments.filter { self.container($0.home).id == container.id }
        return level
    }

    /// The level at which all of these views have their patch showing: the view they are
    /// all directly in. When there is no such level, the nearest view that holds them all.
    public func level(showing layers: Set<LayerID>) -> LayerID {
        guard let first = layers.first else { return screen.id }
        func fits(_ candidate: Layer) -> Bool {
            layers.allSatisfy { id in
                (id == candidate.id && id == screen.id) || candidate.children.contains { $0.id == id }
            }
        }
        if let parent = screen.parent(of: first), fits(parent) { return parent.id }
        if fits(screen) { return screen.id }
        var common: [Layer]?
        for id in layers {
            let path = Array(screen.path(to: id).dropLast())
            common = common.map { Array(zip($0, path).prefix { $0.id == $1.id }.map(\.0)) } ?? path
        }
        return common?.last?.id ?? screen.id
    }

    /// Puts patches that are not views in the level of the views they work on, following
    /// cables through other such patches. A group of patches that reaches no view stays
    /// where it is. With `only`, just those patches are moved.
    public mutating func settleHomes(only: Set<NodeID>? = nil) {
        let screenID = screen.id
        Document.settleHomes(in: &graph, only: only) { [self] in level(showing: $0) == screenID ? nil : level(showing: $0) }
        for index in components.indices {
            let inside = Document(screen: components[index].root, graph: components[index].graph)
            let rootID = inside.screen.id
            var graph = inside.graph
            Document.settleHomes(in: &graph, only: only) { inside.level(showing: $0) == rootID ? nil : inside.level(showing: $0) }
            components[index].graph = graph
        }
    }

    private static func settleHomes(in graph: inout Graph, only: Set<NodeID>?, level: (Set<LayerID>) -> LayerID?) {
        let byID = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var neighbors: [NodeID: [NodeID]] = [:]
        for connection in graph.connections {
            neighbors[connection.from.node, default: []].append(connection.to.node)
            neighbors[connection.to.node, default: []].append(connection.from.node)
        }
        var seen: Set<NodeID> = []
        var homes: [NodeID: LayerID?] = [:]
        for start in graph.nodes where start.layerID == nil && !seen.contains(start.id) {
            // Everything joined to this patch by cables that pass only through free patches.
            var group: [NodeID] = []
            var reached: Set<LayerID> = []
            var frontier = [start.id]
            seen.insert(start.id)
            while let id = frontier.popLast() {
                group.append(id)
                for next in neighbors[id] ?? [] {
                    guard let node = byID[next] else { continue }
                    if let layer = node.layerID {
                        reached.insert(layer)
                    } else if seen.insert(next).inserted {
                        frontier.append(next)
                    }
                }
            }
            guard !reached.isEmpty else { continue }
            let home = level(reached)
            for id in group where only?.contains(id) ?? true { homes[id] = home }
        }
        guard !homes.isEmpty else { return }
        for index in graph.nodes.indices {
            if let home = homes[graph.nodes[index].id] { graph.nodes[index].home = home }
        }
        // A comment goes where the patches it is drawn around went.
        for index in graph.comments.indices {
            let comment = graph.comments[index]
            let inside = graph.nodes.first { node in
                homes[node.id] != nil
                    && node.position.x >= comment.origin.x && node.position.x <= comment.origin.x + comment.size.width
                    && node.position.y >= comment.origin.y && node.position.y <= comment.origin.y + comment.size.height
            }
            if let inside { graph.comments[index].home = inside.home }
        }
    }
}
