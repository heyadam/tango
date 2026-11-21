import Foundation

public typealias NodeID = UUID

/// Well-known patch kinds that the model itself needs to understand.
public enum PatchKind {
    /// A view in the graph: one per layer, bound by `layerID`. Its inputs are the layer's
    /// properties; for a component instance (`componentID` set) also the component's ports.
    public static let view = "view"
    /// Before views were patches (document version 2): drove one property of one layer
    /// through a single input, `value`. Only read when opening such a document.
    public static let layerProperty = "layer.property"
    /// Reports touches on one layer.
    public static let interaction = "interaction"
    /// Gestures on one layer, each told apart from the others as it happens.
    public static let tap = "tap"
    public static let longPress = "longPress"
    public static let pan = "pan"
    public static let pinch = "pinch"
    public static let rotation = "rotation"
    public static let swipe = "swipe"
    /// Reports where a video's playhead is.
    public static let videoTime = "videoTime"
    /// Shows one of the prototype's screens, the one it is attached to.
    public static let navigate = "navigate"
    /// Goes back to the screen that was showing before.
    public static let navigateBack = "navigateBack"
    /// Before views were patches: stood for a component instance in the graph. Now the
    /// instance's view patch does.
    public static let component = "component"
    /// Inside a component: publishes an input.
    public static let componentInput = "component.input"
    /// Inside a component: publishes an output.
    public static let componentOutput = "component.output"
    /// A patch whose ports and behavior come from a script it carries.
    public static let javascript = "javascript"
    /// The Loops setting of a Component Input that hands a loop to the patches inside
    /// instead of repeating the component.
    public static let passLoopInside = "Pass Inside"
    public static let repeatComponent = "Repeat Component"
}

/// The grid patches sit on in the Patch Editor. Patch sizes and port rows are whole
/// units, so two patches on the grid have ports that line up and cables that run straight.
public enum PatchGrid {
    public static let unit = 12.0

    public static func snap(_ value: Double) -> Double { (value / unit).rounded() * unit }

    public static func snap(_ point: Point2) -> Point2 {
        Point2(x: snap(point.x), y: snap(point.y))
    }

    // The size of a patch, in whole units. Kept here so a document can find room for a
    // patch without the editor.
    public static let nodeWidth = 192.0
    public static let titleHeight = 24.0
    public static let subtitleHeight = 12.0
    public static let rowHeight = 24.0
    public static let bottomPadding = 12.0
    /// The space left between patches placed automatically.
    public static let gap = 24.0

    public static func nodeHeight(rows: Int, subtitle: Bool) -> Double {
        titleHeight + (subtitle ? subtitleHeight : 0) + Double(rows) * rowHeight + bottomPadding
    }
}

/// A port inside a view that also shows on that view's patch, one level out, so values
/// can be cabled into and out of the view. It holds no value: it stands for `inner`.
public struct PublishedPort: Codable, Hashable, Sendable, Identifiable {
    /// The port's id on the view's patch.
    public var id: String
    public var name: String
    /// The port inside the view that it stands for.
    public var inner: PortRef
    public var isOutput: Bool
    /// The inner port's type and choices, kept current whenever the document changes.
    public var type: PortType
    public var options: [String]

    public init(id: String = UUID().uuidString, name: String, inner: PortRef, isOutput: Bool, type: PortType, options: [String] = []) {
        self.id = id
        self.name = name
        self.inner = inner
        self.isOutput = isOutput
        self.type = type
        self.options = options
    }
}

/// One patch placed in a graph.
public struct PatchNode: Codable, Identifiable, Hashable, Sendable {
    public var id: NodeID
    /// Registry key of the patch definition.
    public var kind: String
    /// Location in the Patch Editor.
    public var position: Point2
    /// A name given by the author; nil shows the definition's name.
    public var name: String?
    /// Literal values for inputs that have no cable, keyed by port id.
    public var inputs: [String: Value]
    /// The chosen type for patches that work on several types (Transition, If, ...).
    public var valueType: PortType?
    /// The layer this patch is bound to: the view it is, or the view it attaches to.
    public var layerID: LayerID?
    /// In a version 2 document, the property a layer property patch drove.
    public var property: LayerProperty?
    /// How many inputs a patch with a variable number of them has (Loop Builder); nil uses
    /// the definition's default.
    public var inputCount: Int?
    /// On the view patch of a component instance: the component.
    public var componentID: UUID?
    /// The source of a JavaScript patch.
    public var script: String?
    /// On the patch of a shader view: the code that last arrived by cable, whose inputs the
    /// patch has too. Mirrors `ShaderUse.arriving`, as `script` mirrors its source.
    public var arrivingScript: String?
    /// On the patch of a view an extension draws: which view of which extension, so the
    /// patch's inputs are known without the layer. Mirrors `CustomViewUse.kind`.
    public var custom: String?
    /// The inputs a view patch shows besides those with a cable; nil shows its type's usual set.
    public var shownPorts: [String]?
    /// For a patch that is not a view and not attached to one: the view it is kept in. The
    /// graph is shown one view at a time, and this patch shows inside that view. nil is the screen.
    public var home: LayerID?
    /// On the patch of a view that holds others: the ports from inside it that show here.
    public var published: [PublishedPort]?
    /// Where this patch came from when the screen was sketched from code, as on `Layer.source`.
    public var source: String?

    public init(
        id: NodeID = NodeID(),
        kind: String,
        position: Point2 = .zero,
        name: String? = nil,
        inputs: [String: Value] = [:],
        valueType: PortType? = nil,
        layerID: LayerID? = nil,
        property: LayerProperty? = nil,
        inputCount: Int? = nil,
        componentID: UUID? = nil,
        script: String? = nil,
        shownPorts: [String]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.position = position
        self.name = name
        self.inputs = inputs
        self.valueType = valueType
        self.layerID = layerID
        self.property = property
        self.inputCount = inputCount
        self.componentID = componentID
        self.script = script
        self.shownPorts = shownPorts
    }

    /// The patch that is a view in the graph.
    public static func view(of layerID: LayerID, component: UUID? = nil, position: Point2 = .zero) -> PatchNode {
        PatchNode(kind: PatchKind.view, position: position, layerID: layerID, componentID: component)
    }

    /// Whether this patch is a component instance: its ports include the component's.
    public var isInstance: Bool { kind == PatchKind.view && componentID != nil }

    /// The patch that connects a component instance to the graph around it.
    public static func component(_ id: UUID, on layerID: LayerID, position: Point2 = .zero) -> PatchNode {
        .view(of: layerID, component: id, position: position)
    }

    public static func interaction(on layerID: LayerID, position: Point2 = .zero) -> PatchNode {
        PatchNode(kind: PatchKind.interaction, position: position, layerID: layerID)
    }
}

public struct PortRef: Codable, Hashable, Sendable {
    public var node: NodeID
    public var port: String

    public init(node: NodeID, port: String) {
        self.node = node
        self.port = port
    }
}

/// A cable: the value of an output flows into an input.
public struct Connection: Codable, Hashable, Sendable {
    public var from: PortRef
    public var to: PortRef

    public init(from: PortRef, to: PortRef) {
        self.from = from
        self.to = to
    }
}

/// A titled box drawn behind patches to say what a part of the graph is for.
public struct GraphComment: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var origin: Point2
    public var size: Size2
    /// The view whose level of the graph the comment is in; nil is the screen.
    public var home: LayerID?

    public init(id: UUID = UUID(), text: String = "Comment", origin: Point2, size: Size2) {
        self.id = id
        self.text = text
        self.origin = origin
        self.size = size
    }
}

/// A set of patches and the cables between them. Kept as its own type so a component can
/// own a nested graph later.
public struct Graph: Codable, Hashable, Sendable {
    public var nodes: [PatchNode]
    public private(set) var connections: [Connection]
    public var comments: [GraphComment] = []

    public init(nodes: [PatchNode] = [], connections: [Connection] = []) {
        self.nodes = nodes
        self.connections = []
        for connection in connections {
            connect(from: connection.from, to: connection.to)
        }
    }

    public func node(_ id: NodeID) -> PatchNode? {
        nodes.first { $0.id == id }
    }

    @discardableResult
    public mutating func add(_ node: PatchNode) -> NodeID {
        nodes.append(node)
        return node.id
    }

    @discardableResult
    public mutating func update(_ id: NodeID, _ change: (inout PatchNode) -> Void) -> Bool {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return false }
        change(&nodes[index])
        return true
    }

    /// Removes a patch together with every cable attached to it.
    public mutating func remove(_ id: NodeID) {
        nodes.removeAll { $0.id == id }
        connections.removeAll { $0.from.node == id || $0.to.node == id }
    }

    /// Adds a cable. An input accepts one cable, so any existing cable into `to` is replaced.
    public mutating func connect(from: PortRef, to: PortRef) {
        connections.removeAll { $0.to == to }
        connections.append(Connection(from: from, to: to))
    }

    public mutating func disconnect(input: PortRef) {
        connections.removeAll { $0.to == input }
    }

    public func connection(into input: PortRef) -> Connection? {
        connections.first { $0.to == input }
    }

    public func connections(from output: PortRef) -> [Connection] {
        connections.filter { $0.from == output }
    }

    /// The patches that are not views: what a person added to give the views behavior.
    public var patches: [PatchNode] { nodes.filter { $0.kind != PatchKind.view } }

    /// The patch that is this layer in the graph, if it has one.
    public func viewNode(layer: LayerID) -> PatchNode? {
        nodes.first { $0.kind == PatchKind.view && $0.layerID == layer }
    }

    /// The published port a view's patch has under this id.
    public func published(_ ref: PortRef, output: Bool) -> PublishedPort? {
        node(ref.node)?.published?.first { $0.id == ref.port && $0.isOutput == output }
    }

    /// The real port a published port stands for, through every view it was published from.
    /// Any other port is returned as it is.
    public func resolved(_ ref: PortRef, output: Bool) -> PortRef {
        var current = ref
        for _ in 0..<32 {
            guard let port = published(current, output: output) else { break }
            current = port.inner
        }
        return current
    }

    /// Where a port is published, if it is: the view patch and the port it has there.
    public func publication(of inner: PortRef, output: Bool) -> (node: NodeID, port: PublishedPort)? {
        for node in nodes {
            if let port = node.published?.first(where: { $0.inner == inner && $0.isOutput == output }) {
                return (node.id, port)
            }
        }
        return nil
    }

    /// Removes patches bound to layers that no longer exist, and what was kept inside them.
    public mutating func removeNodes(boundToLayersNotIn existing: Set<LayerID>) {
        let orphaned = nodes.filter { node in
            if let layerID = node.layerID { return !existing.contains(layerID) }
            if let home = node.home { return !existing.contains(home) }
            return false
        }
        for node in orphaned { remove(node.id) }
        comments.removeAll { $0.home.map { !existing.contains($0) } ?? false }
    }

    // MARK: Codable (re-validates the one-cable-per-input rule on load)

    private enum CodingKeys: String, CodingKey { case nodes, connections, comments }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let nodes = try container.decode([PatchNode].self, forKey: .nodes)
        let connections = try container.decode([Connection].self, forKey: .connections)
        self.init(nodes: nodes, connections: connections)
        comments = try container.decodeIfPresent([GraphComment].self, forKey: .comments) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(nodes, forKey: .nodes)
        try container.encode(connections, forKey: .connections)
        if !comments.isEmpty { try container.encode(comments, forKey: .comments) }
    }
}
