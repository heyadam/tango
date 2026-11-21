import Foundation

public typealias ComponentID = UUID

/// One use of a component: which definition, and the values this use gives its inputs.
public struct ComponentUse: Codable, Hashable, Sendable {
    public var id: ComponentID
    /// Values for published inputs, keyed by port id. Missing ones use the port's default.
    public var inputs: [String: Value]

    public init(id: ComponentID, inputs: [String: Value] = [:]) {
        self.id = id
        self.inputs = inputs
    }
}

/// A published input or output of a component.
public struct ComponentPort: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let type: PortType
    public let defaultValue: Value
    /// The choices of a text input that picks from a list; empty for free text.
    public let options: [String]
    /// For inputs: whether a loop arriving here repeats the whole component (true) or is
    /// handed to the patches inside as a loop (false).
    public let repeatsComponent: Bool
}

/// A reusable piece of interface: layers and the patches that give them behavior, behind a
/// published set of inputs and outputs.
///
/// The interface is not stored separately. Every Component Input patch in the graph is a
/// published input and every Component Output patch a published output, so editing the
/// inside is editing the interface.
public struct ComponentDefinition: Codable, Hashable, Sendable, Identifiable {
    public var id: ComponentID
    public var name: String
    /// The component's layers. Always a group; an instance takes its place in the layer tree.
    public var root: Layer
    public var graph: Graph
    /// The library a prebuilt component came from ("iOS"); nil for components made in the document.
    public var library: String?
    /// One sentence shown where components are picked.
    public var summary: String?
    /// Where it belongs on the screen: a new use is given the screen's width and put at
    /// that edge, or covers the screen. Nil for everything that goes wherever it is put.
    public var placement: Placement?

    /// The edge of the screen a bar spans, or the whole of it for what is presented over
    /// everything: an alert, a sheet.
    public enum Placement: String, Codable, Hashable, Sendable {
        case top, bottom, fill
        /// Along the bottom edge over whatever is there, as the home indicator is: it
        /// takes no room from the bars, and they take none from it.
        case bottomOverlay
    }

    public init(
        id: ComponentID = ComponentID(), name: String, root: Layer, graph: Graph = Graph(),
        library: String? = nil, summary: String? = nil, placement: Placement? = nil
    ) {
        self.id = id
        self.name = name
        self.root = root
        self.graph = graph
        self.library = library
        self.summary = summary
        self.placement = placement
    }

    private func ports(_ kind: String) -> [ComponentPort] {
        graph.nodes
            .filter { $0.kind == kind }
            .sorted { ($0.position.y, $0.position.x) < ($1.position.y, $1.position.x) }
            .map { node in
                let type = node.valueType ?? .number
                let choices = (node.inputs["options"]?.textValue ?? "")
                    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                return ComponentPort(
                    id: node.id.uuidString,
                    name: node.name ?? (kind == PatchKind.componentInput ? "Input" : "Output"),
                    type: type,
                    defaultValue: node.inputs["value"]?.coerced(to: type) ?? Value.defaultValue(for: type),
                    options: type == .text ? choices : [],
                    repeatsComponent: node.inputs["loops"]?.textValue != PatchKind.passLoopInside
                )
            }
    }

    /// Published inputs, in the order their patches are placed top to bottom.
    public var inputs: [ComponentPort] { ports(PatchKind.componentInput) }
    public var outputs: [ComponentPort] { ports(PatchKind.componentOutput) }

    /// A new layer that uses this component, sized like its definition.
    public func instance(name: String? = nil, at position: Point2 = .zero, inputs: [String: Value] = [:]) -> Layer {
        var layer = Layer(name: name ?? self.name, kind: .component, component: ComponentUse(id: id, inputs: inputs))
        layer.set(.position, .point(position))
        layer.set(.size, root.value(.size))
        for property in [LayerProperty.widthMode, .heightMode] {
            if let value = root.properties[property] { layer.set(property, value) }
        }
        return layer
    }

    /// The port id of the published input with this name. Ids, not names, are what
    /// documents store, so a port can be renamed without breaking its uses.
    public func input(named name: String) -> String? { inputs.first { $0.name == name }?.id }
    public func output(named name: String) -> String? { outputs.first { $0.name == name }?.id }
}

extension Document {
    public func component(_ id: ComponentID) -> ComponentDefinition? {
        components.first { $0.id == id }
    }

    /// Adds a component definition unless the document already has it.
    public mutating func adopt(_ definition: ComponentDefinition) {
        if component(definition.id) == nil { components.append(definition) }
    }

    /// Components used, directly or through other components, by `definition`.
    public func componentsUsed(by definition: ComponentDefinition) -> Set<ComponentID> {
        var found: Set<ComponentID> = []
        func visit(_ layer: Layer) {
            if let use = layer.component, !found.contains(use.id) {
                found.insert(use.id)
                if let inner = component(use.id) { visit(inner.root) }
            }
            layer.children.forEach(visit)
        }
        visit(definition.root)
        return found
    }

    // MARK: Editing inside a component

    /// A document showing only the inside of a component: its root layer stands in as the
    /// screen and its graph as the graph. Editing code written for documents then works
    /// on a component unchanged. Write the result back with `merging(inside:of:)`.
    public func inside(of id: ComponentID) -> Document? {
        guard let definition = component(id) else { return nil }
        var screen = definition.root
        screen.kind = .screen
        // An screen is white unless told otherwise; a component's root is see-through.
        if screen.properties[.fill] == nil { screen.properties[.fill] = .color(.clear) }
        var view = Document(screen: screen, graph: definition.graph)
        view.components = components
        return view
    }

    /// This document with component `id` replaced by what `inside` (from `inside(of:)`) now holds.
    public func merging(inside view: Document, of id: ComponentID) -> Document {
        var result = self
        result.components = view.components
        guard let index = result.components.firstIndex(where: { $0.id == id }) else { return self }
        var root = view.screen
        root.kind = .view
        if root.properties[.fill] == .color(.clear) { root.properties[.fill] = nil }
        result.components[index].root = root
        result.components[index].graph = view.graph
        return result
    }
}
