import Foundation
import PaperModel

/// A prebuilt piece of interface that holds a person's own views: a sheet, a grouped
/// section, a form. A component cannot hold views, so a template is not one. It is a tree
/// of ordinary views with the patches that run it and the ports its root publishes, and
/// inserting it puts a copy in the document, under new ids, to fill and change freely.
public struct ViewTemplate: Identifiable, Sendable, Equatable {
    /// Stable, for agents and the Patch Library ("iOS/Sheet").
    public let id: String
    public let name: String
    public let summary: String
    public let root: Layer
    /// Every patch of the template: the views' own, which carry what the root publishes,
    /// and the ones that give it behavior.
    public let nodes: [PatchNode]
    public let connections: [Connection]
    /// The library components used inside it.
    public let components: [ComponentDefinition]
    /// The edge of the screen it spans, as for a bar.
    public let placement: ComponentDefinition.Placement?
    /// The name of the view inside it that a person's content goes in, to say so.
    public let contentName: String?

    public var publishedInputs: [PublishedPort] { published.filter { !$0.isOutput } }
    public var publishedOutputs: [PublishedPort] { published.filter(\.isOutput) }

    private var published: [PublishedPort] {
        nodes.first { $0.kind == PatchKind.view && $0.layerID == root.id }?.published ?? []
    }
}

extension ComponentLibrary {
    /// Containers that look and behave like the standard iOS ones.
    public static let templates: [ViewTemplate] = groups.flatMap(\.templates)

    public static func template(_ name: String) -> ViewTemplate? {
        templates.first { $0.name.lowercased() == name.lowercased() }
    }

    /// Builds a template: `root` is put on an empty screen, `build` adds its patches, and
    /// what is left is everything but that screen.
    static func template(
        _ name: String, _ summary: String, root: Layer, placement: ComponentDefinition.Placement? = nil,
        content: String? = nil, _ build: (inout Builder) -> Void
    ) -> ViewTemplate {
        var screen = Layer(name: "Screen", kind: .screen)
        screen.children = [root]
        var builder = Builder(screen: screen)
        build(&builder)
        let document = builder.document
        // Everything that runs the template is kept inside its root, so the root can publish
        // from it and the level outside shows one patch. (A patch cabled to something
        // attached to the root itself would otherwise be kept beside the root.)
        let nodes = document.graph.nodes.filter { !($0.kind == PatchKind.view && $0.layerID == document.screen.id) }.map { node in
            var kept = node
            if node.layerID == nil, node.home == nil { kept.home = root.id }
            return kept
        }
        let kept = Set(nodes.map(\.id))
        return ViewTemplate(
            id: "iOS/\(name)", name: name, summary: summary, root: document.screen.children[0], nodes: nodes,
            connections: document.graph.connections.filter { kept.contains($0.from.node) && kept.contains($0.to.node) },
            components: document.components, placement: placement, contentName: content
        )
    }
}

extension SampleDocuments.Builder {
    /// Publishes a port of a patch on the patch of the view it is in, one level out, as a
    /// person does with a right-click. `on` is the view that publishes it.
    public mutating func publish(_ name: String, _ ref: PortRef, on container: LayerID, output: Bool, type: PortType, options: [String] = []) {
        let patch = view(container)
        var document = self.document
        document.graph.update(patch) { node in
            node.published = (node.published ?? []) + [PublishedPort(name: name, inner: ref, isOutput: output, type: type, options: options)]
        }
        self.document = document
    }
}
