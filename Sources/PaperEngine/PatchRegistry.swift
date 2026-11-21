import Foundation
import PaperModel

/// The set of patch definitions a runtime and editor work with.
public struct PatchRegistry: Sendable {
    public private(set) var definitions: [String: PatchDefinition] = [:]
    /// Definitions in the order they were registered, for the Patch Library.
    public private(set) var ordered: [PatchDefinition] = []

    /// The components of the document being edited, so instance patches know their ports.
    public var components: [ComponentID: ComponentDefinition] = [:]

    /// The extensions whose patches are among the definitions.
    public internal(set) var extensions = ExtensionSet.empty
    /// The views extensions add, by kind, and the order they were added in.
    public internal(set) var views: [String: CustomViewDefinition] = [:]
    var orderedViews: [String] = []
    /// The components extensions ship, a shelf for each extension that has any.
    public internal(set) var shelves: [ComponentShelf] = []

    public func with(components: [ComponentDefinition]) -> PatchRegistry {
        var copy = self
        copy.components = Dictionary(components.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return copy
    }

    public init(_ definitions: [PatchDefinition] = []) {
        for definition in definitions { register(definition) }
    }

    public static let standard = PatchRegistry(StandardPatches.all)

    public mutating func register(_ definition: PatchDefinition) {
        if definitions[definition.kind] == nil {
            ordered.append(definition)
        } else if let index = ordered.firstIndex(where: { $0.kind == definition.kind }) {
            ordered[index] = definition
        }
        definitions[definition.kind] = definition
    }

    public func definition(_ kind: String) -> PatchDefinition? { definitions[kind] }

    /// Definitions a person can insert from the Patch Library.
    /// The Scroll patch still runs in documents that have one, but a Scroll View replaced it.
    /// Nor is a patch whose extension is missing or switched off offered.
    public var library: [PatchDefinition] { ordered.filter { $0.kind != "scroll" && $0.isAvailable } }

    /// Whether the ports of a patch are known. They are not for a patch from an extension
    /// that is neither installed nor carried by the document: nothing is known about it but
    /// its kind, and nothing may be concluded from its having no ports.
    public func knows(_ node: PatchNode) -> Bool {
        // A view an extension draws has inputs only its extension can name.
        if node.kind == PatchKind.view { return node.custom.map { views[$0] != nil } ?? true }
        return node.kind == PatchKind.javascript || definitions[node.kind] != nil
    }

    /// Types a published component port can carry.
    public static let publishedTypes: [PortType] = [.number, .bool, .pulse, .text, .color, .point, .size, .array]

    /// The type a generic patch currently works on.
    public func valueType(for node: PatchNode) -> PortType {
        guard let definition = definitions[node.kind], definition.isGeneric else { return .number }
        if let chosen = node.valueType, definition.genericTypes.contains(chosen) { return chosen }
        return definition.genericTypes[0]
    }

    /// The concrete ports of a patch, with generic types resolved.
    public func ports(for node: PatchNode) -> NodePorts {
        func port(_ published: ComponentPort) -> Port {
            Port(id: published.id, name: published.name, type: published.type,
                 defaultValue: published.defaultValue, options: published.options)
        }
        if node.kind == PatchKind.view {
            // Every input any view can have, so the ports do not depend on the layer; which
            // of them a view shows is the editor's business.
            var ports = NodePorts(inputs: PatchRegistry.viewInputs, outputs: PatchRegistry.scrollOutputs + PatchRegistry.frameOutputs)
            if let id = node.componentID {
                // An instance has its own frame, then the component's ports.
                let component = components[id]
                ports.inputs += component?.inputs.map(port) ?? []
                ports.outputs = PatchRegistry.frameOutputs + (component?.outputs.map(port) ?? [])
            }
            // A shader view's patch has the inputs its source declares.
            if let source = node.script, node.componentID == nil {
                ports.inputs.append(Port(id: ShaderUse.codePort, name: "Code", type: .text))
                ports.inputs += ShaderSource.uniforms(of: source, arriving: node.arrivingScript).map(\.port)
            }
            // The patch of a view an extension draws has the inputs its extension declares.
            if let kind = node.custom, node.componentID == nil, let view = views[kind] {
                ports.inputs += view.ports
            }
            for published in node.published ?? [] {
                let port = Port(id: published.id, name: published.name, type: published.type, options: published.options)
                if published.isOutput { ports.outputs.append(port) } else { ports.inputs.append(port) }
            }
            return ports
        }
        if node.kind == PatchKind.javascript {
            return Script.interface(of: node.script ?? "").ports
        }
        guard let definition = definitions[node.kind] else { return NodePorts() }
        let generic = valueType(for: node)
        func resolve(_ spec: PortSpec) -> Port {
            let type: PortType
            switch spec.type {
            case let .fixed(fixed): type = fixed
            case .generic: type = generic
            }
            return Port(id: spec.id, name: spec.name, type: type, defaultValue: spec.defaultValue, options: spec.options)
        }
        var inputs = definition.inputs.map(resolve)
        if let variable = definition.variableInputs, let template = inputs.popLast() {
            for index in 0..<inputCount(for: node, variable) {
                inputs.append(Port(
                    id: "\(template.id)\(index)", name: "\(template.name) \(index)",
                    type: template.type, defaultValue: template.defaultValue, options: template.options
                ))
            }
        }
        return NodePorts(inputs: inputs, outputs: definition.outputs.map(resolve))
    }

    /// What a scroll view reports. Every view's patch has these outputs; only a scroll
    /// view's shows them and gives them values.
    public static let scrollOutputs: [Port] = [
        Port(id: "offset", name: "Offset", type: .number),
        Port(id: "velocity", name: "Velocity", type: .number),
        Port(id: "dragging", name: "Dragging", type: .bool),
    ]

    /// Where layout put the view on the last frame: x, y, width and height. Every view's
    /// patch has them; the runtime fills them only for patches that cable or show one.
    public static let frameOutputs: [Port] = ViewOutput.allCases.map {
        Port(id: $0.id, name: $0.name, type: $0.type)
    }

    static let viewInputs: [Port] = ViewInput.all.map {
        Port(id: $0.id, name: $0.name, type: $0.type, options: $0.options)
    }

    private func inputCount(for node: PatchNode, _ variable: VariableInputs) -> Int {
        min(max(node.inputCount ?? variable.standard, variable.range.lowerBound), variable.range.upperBound)
    }

    /// How many repeated inputs a patch has, and the range it may have; nil when fixed.
    public func variableInputCount(for node: PatchNode) -> (count: Int, range: ClosedRange<Int>)? {
        guard let variable = definitions[node.kind]?.variableInputs else { return nil }
        return (inputCount(for: node, variable), variable.range)
    }

    /// The literal an unconnected input currently holds.
    public func literal(for port: Port, of node: PatchNode) -> Value {
        node.inputs[port.id]?.coerced(to: port.type) ?? port.defaultValue
    }

    /// How tall a patch that is not a view is drawn, for finding room beside it.
    public func height(of node: PatchNode) -> Double {
        let ports = ports(for: node)
        return PatchGrid.nodeHeight(rows: ports.inputs.count + ports.outputs.count, subtitle: node.layerID != nil)
    }

    /// The name shown on a patch that has no custom name.
    public func defaultTitle(for node: PatchNode) -> String {
        if node.isInstance {
            return node.componentID.flatMap { components[$0]?.name } ?? "Component"
        }
        if node.kind == PatchKind.view { return "View" }
        return definitions[node.kind]?.name ?? node.kind
    }

    /// Whether a cable from `from` to `to` is allowed in `graph`.
    public func canConnect(from: PortRef, to: PortRef, in graph: Graph) -> Bool {
        guard from.node != to.node,
              let source = graph.node(from.node),
              let destination = graph.node(to.node),
              let output = ports(for: source).output(from.port),
              let input = ports(for: destination).input(to.port)
        else { return false }
        return Value.canConnect(from: output.type, to: input.type)
    }

    // MARK: Published ports

    /// Keeps published ports true to what they stand for, in the document and in every
    /// component: one whose inner port is gone, or is no longer in the view's level, is
    /// removed; the rest take the inner port's type. Cables left on a port that a view's
    /// patch no longer has, or that no longer fit, go with it. Changes nothing when all is
    /// in order, so it runs after every edit.
    public func settlePublished(in document: inout Document) {
        let registry = with(components: document.components)
        registry.settlePublished(root: document.screen, graph: &document.graph)
        for index in document.components.indices {
            registry.settlePublished(root: document.components[index].root, graph: &document.components[index].graph)
        }
    }

    private func settlePublished(root: Layer, graph: inout Graph) {
        // Views deepest first, so a port published twice is refreshed from the inside out.
        let holders = graph.nodes.filter { $0.published != nil }
            .map { (node: $0, depth: $0.layerID.map { root.path(to: $0).count } ?? 0) }
            .sorted { $0.depth > $1.depth }
        for (holder, _) in holders {
            var kept: [PublishedPort] = []
            if holder.kind == PatchKind.view, !holder.isInstance, let container = holder.layerID.flatMap({ root.find($0) }),
               container.kind.canHaveChildren, container.id != root.id {
                for var port in holder.published ?? [] {
                    guard let inner = graph.node(port.inner.node), Document.shows(inner, in: container, root: root),
                          !kept.contains(where: { $0.inner == port.inner && $0.isOutput == port.isOutput }) else { continue }
                    // A port of a patch nothing is known about is kept as it was.
                    guard knows(inner) else { kept.append(port); continue }
                    let ports = self.ports(for: inner)
                    guard let real = port.isOutput ? ports.output(port.inner.port) : ports.input(port.inner.port) else { continue }
                    port.type = real.type
                    port.options = real.options
                    kept.append(port)
                }
            }
            let settled = kept.isEmpty ? nil : kept
            if settled != holder.published { graph.update(holder.id) { $0.published = settled } }
        }

        // A plain view's patch has its view inputs, the scroll and frame outputs and what is published.
        let views = Dictionary(
            graph.nodes.filter { $0.kind == PatchKind.view && !$0.isInstance }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard !views.isEmpty else { return }
        let fixed = Set(PatchRegistry.scrollOutputs.map(\.id)).union(ViewOutput.ids)
        for connection in graph.connections {
            var fits = true
            if let view = views[connection.to.node], ViewInput(id: connection.to.port) == nil {
                if ShaderUse.inputName(port: connection.to.port) != nil || connection.to.port == ShaderUse.codePort {
                    // An input of the view's shader: there as long as the source declares it.
                    fits = canConnect(from: connection.from, to: connection.to, in: graph)
                } else if CustomViewUse.inputName(port: connection.to.port) != nil {
                    // An input of a view an extension draws: there as long as the extension
                    // declares it. Without the extension, nothing can be said and it stays.
                    fits = !knows(view) || canConnect(from: connection.from, to: connection.to, in: graph)
                } else {
                    fits = view.published?.contains { !$0.isOutput && $0.id == connection.to.port } ?? false
                }
            }
            if fits, let view = views[connection.from.node], !fixed.contains(connection.from.port) {
                fits = view.published?.contains { $0.isOutput && $0.id == connection.from.port } ?? false
            }
            let published = views[connection.to.node]?.published != nil || views[connection.from.node]?.published != nil
            // Whether a cable fits cannot be told when the patch at one end is not known.
            let known = [connection.from.node, connection.to.node].allSatisfy { graph.node($0).map(knows) ?? true }
            if fits, published, known { fits = canConnect(from: connection.from, to: connection.to, in: graph) }
            if !fits { graph.disconnect(input: connection.to) }
        }
    }
}
