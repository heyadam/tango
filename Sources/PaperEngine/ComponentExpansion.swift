import Foundation
import PaperModel

/// A document with every component instance replaced by a private copy of the component's
/// layers and patches. This is what actually runs: the runtime never sees components, only
/// the flat tree and graph they expand to.
public struct ExpandedDocument: Sendable {
    public var screen: Layer
    public var graph: Graph
    /// Where the ports of instance patches ended up, for showing their live values.
    public var aliases: [PortRef: PortRef] = [:]
}

public enum ComponentExpansion {
    /// How deep components may nest. Also stops a component that contains itself.
    static let depthLimit = 8

    public static func expand(_ document: Document) -> ExpandedDocument {
        var expander = Expander(document: document)
        let screen = expander.expand(
            root: document.screen, graph: document.graph, map: { $0 }, scope: [], depth: 0
        )
        expander.resolveVariables()
        return ExpandedDocument(
            screen: screen,
            graph: Graph(nodes: expander.nodes, connections: expander.connections),
            aliases: expander.aliases
        )
    }

    /// The id a layer or patch inside a component gets in one instance. It depends only on
    /// the instance and the inner id, so state survives edits elsewhere in the document.
    public static func derive(_ instance: UUID, _ inner: UUID) -> UUID {
        func hash(_ seed: UInt64) -> UInt64 {
            var value = seed
            for uuid in [instance, inner] {
                withUnsafeBytes(of: uuid.uuid) { bytes in
                    for byte in bytes {
                        value ^= UInt64(byte)
                        value = value &* 0x0000_0100_0000_01B3
                    }
                }
            }
            return value
        }
        var bytes = [UInt8]()
        for part in [hash(0xCBF2_9CE4_8422_2325), hash(0x9E37_79B9_7F4A_7C15)] {
            withUnsafeBytes(of: part) { bytes.append(contentsOf: $0) }
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private struct Expander {
        let document: Document
        var nodes: [PatchNode] = []
        var connections: [Connection] = []
        var aliases: [PortRef: PortRef] = [:]
        /// Per expanded instance layer: published port id → the patch standing for it.
        var instancePorts: [LayerID: [String: NodeID]] = [:]
        /// The component nesting each Broadcast and Receive sits in, outermost first.
        var variableScopes: [NodeID: [String]] = [:]

        mutating func expand(
            root: Layer, graph: Graph, map: (UUID) -> UUID, scope: [String], depth: Int
        ) -> Layer {
            let layer = expand(layer: root, map: map, scope: scope, depth: depth)

            // An instance's patch carries two kinds of cable: those on the component's
            // published ports, which go to the patches inside, and those on its own view
            // inputs (x, opacity, ...), which stay on a view patch for the expanded layer.
            var instanceLayers: [NodeID: LayerID] = [:]
            for node in graph.nodes {
                if node.isInstance, let layerID = node.layerID { instanceLayers[node.id] = map(layerID) }
                var copy = node
                copy.id = map(node.id)
                copy.layerID = node.layerID.map(map)
                if node.kind == "broadcast" || node.kind == "receive" { variableScopes[copy.id] = scope }
                nodes.append(copy)
            }
            // A cable on a published port really joins the port inside the view. One that
            // comes from outside wins over a cable the inner input has of its own.
            var cables: [Connection] = []
            var driven: Set<PortRef> = []
            for connection in graph.connections {
                let from = graph.resolved(connection.from, output: true)
                let to = graph.resolved(connection.to, output: false)
                if to != connection.to { driven.insert(to) }
                cables.append(Connection(from: from, to: to))
            }
            if !driven.isEmpty {
                cables = zip(cables, graph.connections).filter { !driven.contains($1.to) }.map(\.0)
            }
            for connection in cables {
                var from = PortRef(node: map(connection.from.node), port: connection.from.port)
                var to = PortRef(node: map(connection.to.node), port: connection.to.port)
                if let instance = instanceLayers[connection.from.node] {
                    if let inner = instancePorts[instance]?[connection.from.port] {
                        from = PortRef(node: inner, port: "value")
                    }
                }
                if let instance = instanceLayers[connection.to.node] {
                    if let inner = instancePorts[instance]?[connection.to.port] {
                        to = PortRef(node: inner, port: "value")
                    } else if ViewInput(id: connection.to.port) == nil {
                        continue
                    }
                }
                connections.append(Connection(from: from, to: to))
            }
            for (nodeID, instance) in instanceLayers {
                for (port, inner) in instancePorts[instance] ?? [:] {
                    aliases[PortRef(node: map(nodeID), port: port)] = PortRef(node: inner, port: "value")
                }
            }
            // Published ports show the live value of what they stand for.
            for node in graph.nodes {
                for port in node.published ?? [] {
                    let inner = graph.resolved(port.inner, output: port.isOutput)
                    let mapped = PortRef(node: map(inner.node), port: inner.port)
                    aliases[PortRef(node: map(node.id), port: port.id)] = aliases[mapped] ?? mapped
                }
            }
            return layer
        }

        private mutating func expand(layer: Layer, map: (UUID) -> UUID, scope: [String], depth: Int) -> Layer {
            let id = map(layer.id)
            guard layer.kind == .component, let use = layer.component,
                  let definition = document.component(use.id), depth < ComponentExpansion.depthLimit
            else {
                var copy = layer
                copy.id = id
                copy.children = layer.children.map { expand(layer: $0, map: map, scope: scope, depth: depth) }
                return copy
            }

            // Inside the instance every id is derived from the instance's own id; the
            // component's root layer becomes the instance layer itself.
            let rootID = definition.root.id
            let inner: (UUID) -> UUID = { $0 == rootID ? id : ComponentExpansion.derive(id, $0) }
            let firstNode = nodes.count
            let body = expand(
                root: definition.root, graph: definition.graph, map: inner,
                scope: scope + [id.uuidString], depth: depth + 1
            )

            var ports: [String: NodeID] = [:]
            for node in definition.graph.nodes
            where node.kind == PatchKind.componentInput || node.kind == PatchKind.componentOutput {
                ports[node.id.uuidString] = inner(node.id)
            }
            instancePorts[id] = ports
            // Published inputs take this use's values and remember whose instance they feed.
            let inputIDs = Set(definition.graph.nodes.filter { $0.kind == PatchKind.componentInput }.map { inner($0.id) })
            for index in firstNode..<nodes.count where inputIDs.contains(nodes[index].id) {
                nodes[index].layerID = id
                if let port = ports.first(where: { $0.value == nodes[index].id })?.key, let value = use.inputs[port] {
                    nodes[index].inputs["value"] = value
                }
            }

            var result = Layer(id: id, name: layer.name, kind: .view, properties: body.properties, children: body.children)
            // A component's root may itself be drawn by a shader or an extension.
            result.shader = body.shader
            result.custom = body.custom
            result.scene = body.scene
            for property in LayerProperty.instanceOwned {
                result.properties[property] = layer.properties[property]
            }
            return result
        }

        /// A Receive listens to the nearest Broadcast of its name and type: one in its own
        /// component first, then in whatever contains it, out to the document. So values
        /// cascade into components, and a component can override one with its own Broadcast.
        mutating func resolveVariables() {
            func name(_ node: PatchNode) -> String { node.inputs["name"]?.textValue ?? "Variable" }
            func scoped(_ scope: [String], _ name: String) -> String {
                scope.isEmpty ? name : scope.joined(separator: "/") + "›" + name
            }
            struct Key: Hashable {
                let scope: [String]
                let name: String
                let type: PortType
            }
            var broadcasts: Set<Key> = []
            for node in nodes where node.kind == "broadcast" {
                broadcasts.insert(Key(scope: variableScopes[node.id] ?? [], name: name(node), type: node.valueType ?? .number))
            }
            for index in nodes.indices {
                let node = nodes[index]
                guard let scope = variableScopes[node.id], !scope.isEmpty else { continue }
                if node.kind == "broadcast" {
                    nodes[index].inputs["name"] = .text(scoped(scope, name(node)))
                } else if node.kind == "receive" {
                    var found = scope
                    while !broadcasts.contains(Key(scope: found, name: name(node), type: node.valueType ?? .number)), !found.isEmpty {
                        found.removeLast()
                    }
                    nodes[index].inputs["name"] = .text(scoped(found, name(node)))
                }
            }
        }
    }
}
