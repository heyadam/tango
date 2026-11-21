import AppKit
import PaperEngine
import PaperModel

/// A piece of a document that can be copied: layers, patches, the cables into them, and
/// the components the layers use.
public struct DocumentFragment: Codable, Sendable {
    public var layers: [Layer] = []
    public var nodes: [PatchNode] = []
    public var connections: [Connection] = []
    public var components: [ComponentDefinition] = []

    public var isEmpty: Bool { layers.isEmpty && nodes.isEmpty }
}

extension DocumentStore {
    static let pasteboardType = NSPasteboard.PasteboardType("com.tango.fragment")

    /// The selected layers (outermost ones only) with the patches bound to them.
    public func fragmentOfSelectedLayers() -> DocumentFragment {
        fragment(ofLayers: selectedLayers, with: [])
    }

    /// The selected patches. A view's patch is the view, so the view comes along with
    /// everything bound to it. Other patches bound to a view (an Interaction) stay behind
    /// unless their view is copied too.
    public func fragmentOfSelectedPatches() -> DocumentFragment {
        let chosen = document.graph.nodes.filter { selectedNodes.contains($0.id) }
        let views = Set(chosen.filter { $0.kind == PatchKind.view }.compactMap(\.layerID))
        return fragment(ofLayers: views, with: chosen.filter { $0.layerID == nil })
    }

    private func fragment(ofLayers ids: Set<LayerID>, with free: [PatchNode]) -> DocumentFragment {
        let screen = document.screen
        let chosen = ids.filter { id in
            id != screen.id && !screen.path(to: id).dropLast().contains { ids.contains($0.id) }
        }
        let layers = screen.flattened.filter { chosen.contains($0.id) }
        let inside = Set(layers.flatMap { $0.flattened.map(\.id) })
        // What is attached to a copied view comes along, and so does what is kept in one:
        // the patches that give a container its behavior, and that it publishes from.
        let nodes = document.graph.nodes.filter { node in
            node.layerID.map(inside.contains) ?? node.home.map(inside.contains) ?? false
        }
        let taken = Set(nodes.map(\.id))
        return fragment(layers: layers, nodes: nodes + free.filter { !taken.contains($0.id) })
    }

    private func fragment(layers: [Layer], nodes: [PatchNode]) -> DocumentFragment {
        let ids = Set(nodes.map(\.id))
        var used: Set<ComponentID> = []
        func collect(_ layer: Layer) {
            if let use = layer.component, let definition = fullDocument.component(use.id), !used.contains(use.id) {
                used.insert(use.id)
                used.formUnion(fullDocument.componentsUsed(by: definition))
            }
            layer.children.forEach(collect)
        }
        layers.forEach(collect)
        return DocumentFragment(
            layers: layers, nodes: nodes,
            connections: document.graph.connections.filter { ids.contains($0.to.node) },
            components: fullDocument.components.filter { used.contains($0.id) }
        )
    }

    /// Adds a copy of `fragment` to what is being edited, with fresh ids, and selects it.
    /// Cables from patches outside the fragment are kept when those patches exist here.
    @discardableResult
    public func insert(_ fragment: DocumentFragment, actionName: String = "Paste") -> Bool {
        guard !fragment.isEmpty else { return false }
        let screen = document.screen
        var layerIDs: [LayerID: LayerID] = [:]
        func copy(_ layer: Layer) -> Layer {
            var clone = layer
            clone.id = LayerID()
            layerIDs[layer.id] = clone.id
            clone.children = layer.children.map(copy)
            return clone
        }
        // A copy lands beside the original when the original is here, else on the screen.
        var placements: [(layer: Layer, parent: LayerID)] = []
        for layer in fragment.layers {
            var clone = copy(layer)
            let parent = screen.parent(of: layer.id)
            let nudge = (parent?.arrangement ?? .view) == .view ? 16.0 : 0
            let position = clone.value(.position).pointValue
            clone.set(.position, .point(Point2(x: position.x + nudge, y: position.y + nudge)))
            // One from elsewhere goes where new views go; a screen stays a screen.
            placements.append((clone, parent?.id ?? (layer.isPage ? screen.id : containerForNewViews.id)))
        }

        var nodeIDs: [NodeID: NodeID] = [:]
        var nodes: [PatchNode] = []
        for node in fragment.nodes {
            var clone = node
            clone.id = NodeID()
            if let layer = node.layerID {
                // Bound patches come along only with their layer.
                guard let mapped = layerIDs[layer] else { continue }
                clone.layerID = mapped
            }
            if node.layerID == nil { clone.home = node.home.flatMap { layerIDs[$0] } ?? openView }
            clone.position = Point2(x: node.position.x + 24, y: node.position.y + 24)
            nodeIDs[node.id] = clone.id
            nodes.append(clone)
        }
        // What a copied view published points at the copies inside it.
        for index in nodes.indices where nodes[index].published != nil {
            let kept = (nodes[index].published ?? []).compactMap { port -> PublishedPort? in
                guard let inner = nodeIDs[port.inner.node] else { return nil }
                // The port keeps its id: cables on it and a port published from it further
                // out are copied with that id.
                var copy = port
                copy.inner.node = inner
                return copy
            }
            nodes[index].published = kept.isEmpty ? nil : kept
        }
        let existing = Set(document.graph.nodes.map(\.id))
        let connections = fragment.connections.compactMap { connection -> Connection? in
            guard let to = nodeIDs[connection.to.node] else { return nil }
            let from = nodeIDs[connection.from.node] ?? (existing.contains(connection.from.node) ? connection.from.node : nil)
            guard let from else { return nil }
            return Connection(
                from: PortRef(node: from, port: connection.from.port), to: PortRef(node: to, port: connection.to.port)
            )
        }
        let usable = fragment.components.filter(canInsert)
        guard usable.count == fragment.components.count else { return false }

        apply(actionName) { document in
            for component in usable { document.adopt(component) }
            for placement in placements { document.screen.insert(placement.layer, into: placement.parent) }
            for node in nodes { document.graph.add(node) }
            for connection in connections { document.graph.connect(from: connection.from, to: connection.to) }
        }
        if !placements.isEmpty { selectedLayers = Set(placements.map(\.layer.id)) }
        if !nodes.isEmpty { selectedNodes = Set(nodes.map(\.id)) }
        return true
    }

    public func duplicateSelectedLayers() { insert(fragmentOfSelectedLayers(), actionName: "Duplicate") }
    public func duplicateSelectedPatches() { insert(fragmentOfSelectedPatches(), actionName: "Duplicate") }

    // MARK: Pasteboard

    func copyToPasteboard(_ fragment: DocumentFragment) {
        guard !fragment.isEmpty, let data = try? JSONEncoder().encode(fragment) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: Self.pasteboardType)
    }

    @discardableResult
    func pasteFromPasteboard() -> Bool {
        guard let data = NSPasteboard.general.data(forType: Self.pasteboardType),
              let fragment = try? JSONDecoder().decode(DocumentFragment.self, from: data)
        else { return false }
        return insert(fragment)
    }

    /// Moves a layer to a new place among its siblings. `index` counts from the back.
    public func moveLayer(_ id: LayerID, in parent: LayerID, to index: Int) {
        guard let container = document.layer(parent),
              let current = container.children.firstIndex(where: { $0.id == id })
        else { return }
        let target = min(max(index > current ? index - 1 : index, 0), container.children.count - 1)
        guard target != current else { return }
        apply("Reorder View") { document in
            document.screen.update(parent) { parent in
                let layer = parent.children.remove(at: current)
                parent.children.insert(layer, at: target)
            }
        }
    }
}
