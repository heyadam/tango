import CoreGraphics
import Foundation
import PaperEngine
import PaperModel

/// Named edits the interface performs. Each is one undo step unless marked interactive.
extension DocumentStore {
    // MARK: Panels

    /// Shows the assistant in the sidebar, or goes back to the views when it is showing.
    public func toggleAssistant() {
        if showsSidebar, sidebarMode == .assistant {
            sidebarMode = .views
        } else {
            sidebarMode = .assistant
            showsSidebar = true
        }
    }

    /// Points the assistant at views and patches (the selection when none are given) for
    /// the next message, and opens its panel. A view's patch counts as the view.
    public func addToAssistant(_ nodes: Set<NodeID>? = nil) {
        let wanted = nodes ?? selectedNodes
        for node in document.graph.nodes where wanted.contains(node.id) {
            let target: AssistantReference.Target =
                node.kind == PatchKind.view ? node.layerID.map { .view($0) } ?? .patch(node.id) : .patch(node.id)
            if !assistantReferences.contains(where: { $0.target == target }) {
                assistantReferences.append(AssistantReference(target))
            }
        }
        sidebarMode = .assistant
        showsSidebar = true
        requestAssistantFocus()
    }

    // MARK: Layers

    public var selectedLayer: Layer? {
        guard selectedLayers.count == 1, let id = selectedLayers.first else { return nil }
        return document.layer(id)
    }

    /// Adds a layer on top of everything in a container (the root unless one is named)
    /// and selects it. `frame` is in that container's coordinates.
    @discardableResult
    public func addLayer(_ kind: LayerKind, frame: CGRect, name: String? = nil, into container: LayerID? = nil) -> LayerID {
        // A plain view is given a fill, so it can be seen and picked.
        var layer = kind == .view
            ? Layer.new(.view, name: name ?? uniqueLayerName(kind.displayName))
            : Layer(name: name ?? uniqueLayerName(kind.displayName), kind: kind)
        layer.set(.position, .point(Point2(x: frame.minX.rounded(), y: frame.minY.rounded())))
        layer.set(.size, .size(Size2(width: frame.width.rounded(), height: frame.height.rounded())))
        let screen = container.flatMap { document.layer($0) }.flatMap { $0.kind.canHaveChildren ? $0.id : nil } ?? document.screen.id
        apply("Add \(kind.displayName)") { document in
            document.screen.insert(layer, into: screen)
        }
        selectedLayers = [layer.id]
        return layer.id
    }

    /// Where a new view goes: inside the view whose level of the graph is open. Step into
    /// a view to put views in it.
    /// At the top of a document with screens that is a screen, not the device: the one
    /// selected (or holding what is selected), else the first. What is put in the device
    /// itself floats over every screen, which is rarely what was meant.
    public var containerForNewViews: Layer {
        let open = openContainer
        guard scope == nil, open.id == document.screen.id, let first = open.pages.first else { return open }
        return selectedLayers.lazy.compactMap { self.screen(holding: $0) }.first ?? first
    }

    /// Adds a view of a type inside the open view and selects it. `patchAt` is
    /// where its patch goes in the graph; without it the patch goes under its neighbor's.
    @discardableResult
    public func addView(_ type: ViewType, name: String? = nil, patchAt: Point2? = nil) -> LayerID {
        let parent = containerForNewViews
        let room = parent.value(.size).sizeValue
        var layer = Layer.new(type, name: name ?? uniqueLayerName(type.displayName))
        switch type {
        case .stack, .grid: layer.set(.size, .size(Size2(width: min(240, room.width), height: min(160, room.height))))
        // A scroll view usually fills what it is in.
        case .scrollView: layer.set(.size, .size(room))
        default: break
        }
        return insert(layer, named: type.displayName, centered: type != .scrollView, patchAt: patchAt)
    }

    /// Puts a new view inside the open view and selects it.
    private func insert(_ made: Layer, named name: String, centered: Bool, patchAt: Point2?) -> LayerID {
        var layer = made
        let parent = containerForNewViews
        let room = parent.value(.size).sizeValue
        // In the middle of a container that leaves its children where they are put.
        let size = layer.value(.size).sizeValue
        if parent.arrangement == .view, centered {
            layer.set(.position, .point(Point2(
                x: max(((room.width - size.width) / 2).rounded(), 0), y: max(((room.height - size.height) / 2).rounded(), 0)
            )))
        }
        apply("Add \(name)") { document in
            document.screen.insert(layer, into: parent.id)
            if let patchAt {
                document.graph.add(.view(of: layer.id, position: PatchGrid.snap(patchAt)))
            }
        }
        selectedLayers = [layer.id]
        return layer.id
    }

    /// Adds a view that an extension provides. One drawn by a script refers to the
    /// extension, which draws it. A packaged shader is copied in as an ordinary shader
    /// view, as a library component is copied: it goes on working without the extension,
    /// and a later version of the extension does not change it.
    @discardableResult
    public func addExtensionView(_ view: CustomViewDefinition, name: String? = nil, patchAt: Point2? = nil) -> LayerID {
        let room = containerForNewViews.value(.size).sizeValue
        var layer = view.layer(named: name ?? uniqueLayerName(view.name))
        // No larger than what it is put in.
        layer.set(.size, .size(Size2(width: min(view.size.width, max(room.width, 1)), height: min(view.size.height, max(room.height, 1)))))
        return insert(layer, named: view.name, centered: true, patchAt: patchAt)
    }

    /// The view an extension draws for this layer, when its extension is known.
    public func customView(of layer: Layer) -> CustomViewDefinition? {
        layer.custom.flatMap { registry.view($0.kind) }
    }

    /// Stores a value for an input of a view an extension draws.
    public func setCustomInput(_ name: String, of id: LayerID, to value: Value, interactive: Bool = false) {
        guard let layer = document.layer(id), let port = customView(of: layer)?.inputs.first(where: { $0.id == name }),
              let coerced = value.coerced(to: port.type) else { return }
        let change: (inout PaperModel.Document) -> Void = { $0.screen.update(id) { $0.custom?.inputs[name] = coerced } }
        if interactive {
            self.interactive(change)
        } else {
            apply("Change \(port.name)", change)
        }
    }

    /// The types a view can be changed to and from without losing anything: they are one
    /// stored kind with different settings.
    public static let convertibleTypes: [ViewType] = [.view, .stack, .grid, .scrollView, .shader, .scene]

    /// Makes a view a stack, a grid, a scroll view or a plain view again. Its patch, its
    /// cables and its children stay.
    public func convert(_ id: LayerID, to type: ViewType) {
        guard let layer = document.layer(id), layer.kind == .view, layer.type != type,
              DocumentStore.convertibleTypes.contains(type) else { return }
        apply("Change to \(type.displayName)") { document in
            document.screen.update(id) { view in
                // What an extension drew there goes; the view and what is in it stay.
                view.custom = nil
                // A shader view keeps arranging what is in it the way it did.
                if type == .shader {
                    view.scene = nil
                    view.shader = ShaderUse(source: ShaderUse.template)
                    return
                }
                view.shader = nil
                // A scene view too keeps arranging what is in it.
                if type == .scene {
                    view.scene = SceneUse.template
                    return
                }
                view.scene = nil
                switch type {
                case .stack, .scrollView: view.set(.layout, .text("Stack"))
                case .grid: view.set(.layout, .text("Grid"))
                default: view.properties[.layout] = nil
                }
                view.properties[.scrolls] = type == .scrollView ? .bool(true) : nil
                if type == .scrollView { view.set(.clips, .bool(true)) }
            }
        }
    }

    func uniqueLayerName(_ base: String) -> String {
        let names = Set(document.screen.flattened.map(\.name))
        if !names.contains(base) { return base }
        var index = 2
        while names.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    public func deleteSelectedLayers() {
        let ids = selectedLayers.filter { $0 != document.screen.id }
        guard !ids.isEmpty else { return }
        apply(ids.count == 1 ? "Delete View" : "Delete Views") { document in
            for id in ids { document.removeLayer(id) }
        }
    }

    public func renameLayer(_ id: LayerID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        apply("Rename View") { $0.screen.update(id) { $0.name = trimmed } }
    }

    public func setProperty(_ property: LayerProperty, of id: LayerID, to value: Value, interactive: Bool = false) {
        let change: (inout Document) -> Void = { $0.screen.update(id) { $0.set(property, value) } }
        if interactive {
            self.interactive(change)
        } else {
            apply("Change \(property.displayName)", change)
        }
    }

    /// Sizes the screen for a device. Only the screen's size changes; its views keep their
    /// places, and the Viewer takes the new proportions.
    public func setDevice(_ template: DeviceTemplate) {
        guard scope == nil else { return }
        apply("Change Device") { $0.screen.set(.size, .size(template.size)) }
    }

    /// Sets one input of a view: a property, or one of x, y, width and height.
    public func setInput(_ input: ViewInput, of id: LayerID, to value: Value, interactive: Bool = false) {
        let change: (inout Document) -> Void = { $0.screen.update(id) { input.set(value, on: &$0) } }
        if interactive {
            self.interactive(change)
        } else {
            apply("Change \(input.name)", change)
        }
    }

    // MARK: Views in the graph

    /// The patch that is this view in the graph.
    public func viewNode(for layer: LayerID) -> PatchNode? {
        document.graph.viewNode(layer: layer)
    }

    /// The inputs a view's patch shows, in order: the chosen ones and every cabled one.
    public func shownInputs(of layer: Layer, on node: PatchNode) -> [ViewInput] {
        var cabled = Set(document.graph.connections.filter { $0.to.node == node.id }.map(\.to.port))
        // An input published on the view outside shows here too, so it can be seen and unpublished.
        for holder in document.graph.nodes {
            for port in holder.published ?? [] where !port.isOutput && port.inner.node == node.id { cabled.insert(port.inner.port) }
        }
        return layer.shownInputs(chosen: node.shownPorts, cabled: cabled)
    }

    /// The ports a patch is drawn with. A view's patch has an input for every property;
    /// it shows the chosen and the cabled ones, and all of a component's own ports.
    public func visiblePorts(for node: PatchNode) -> NodePorts {
        let all = registry.ports(for: node)
        guard node.kind == PatchKind.view, let layer = node.layerID.flatMap({ document.layer($0) }) else { return all }
        var inputs = shownInputs(of: layer, on: node).compactMap { all.input($0.id) }
        // A scene has an input for everything about every object in it: like the view's own
        // inputs they show when chosen or cabled.
        let scene = shownScenePorts(of: layer, on: node)
        inputs += all.inputs.filter { ViewInput(id: $0.id) == nil && (SceneUse.key(port: $0.id) == nil || scene.contains($0.id)) }
        // Offset, velocity and dragging are a scroll view's; a component shows its own outputs.
        // The frame outputs show when chosen or cabled, like inputs. What is published from
        // inside always shows.
        let published = Set((node.published ?? []).map(\.id))
        let frame = Set(shownOutputs(on: node).map(\.id))
        let scroll = Set(PatchRegistry.scrollOutputs.map(\.id))
        let outputs = all.outputs.filter { port in
            if ViewOutput.ids.contains(port.id) { return frame.contains(port.id) }
            if published.contains(port.id) { return true }
            if scroll.contains(port.id) && !node.isInstance { return layer.arrangement == .scrollView }
            return node.isInstance
        }
        return NodePorts(inputs: inputs, outputs: outputs)
    }

    /// The frame outputs a view's patch shows, in order: the chosen ones and every cabled one.
    public func shownOutputs(on node: PatchNode) -> [ViewOutput] {
        var cabled = Set(document.graph.connections.filter { $0.from.node == node.id }.map(\.from.port))
        // An output published on the view outside shows here too, so it can be unpublished.
        for holder in document.graph.nodes {
            for port in holder.published ?? [] where port.isOutput && port.inner.node == node.id { cabled.insert(port.inner.port) }
        }
        return ViewOutput.shown(chosen: node.shownPorts, cabled: cabled)
    }

    /// Whether a view's patch shows this frame output as a port.
    public func showsOutput(_ output: ViewOutput, of layer: LayerID) -> Bool {
        guard let node = viewNode(for: layer) else { return false }
        return shownOutputs(on: node).contains(output)
    }

    /// Shows or hides a frame output on a view's patch. An output with a cable always shows.
    public func setOutputPort(_ output: ViewOutput, of layer: LayerID, shown: Bool) {
        guard let view = document.layer(layer), let node = viewNode(for: layer) else { return }
        apply(shown ? "Show \(output.name) Output" : "Hide \(output.name) Output") { document in
            document.graph.update(node.id) { patch in
                var ports = patch.shownPorts ?? view.preset
                ports.removeAll { $0 == output.id }
                if shown { ports.append(output.id) }
                patch.shownPorts = ports
            }
        }
    }

    /// Where the running prototype's last layout put a view, which is what its frame
    /// outputs report on the next frame.
    public func liveFrame(_ output: ViewOutput, of layer: LayerID) -> Value? {
        guard let resolved = runtime?.resolvedLayer(layer) else { return nil }
        switch output {
        case .x: return .number(resolved.position.x)
        case .y: return .number(resolved.position.y)
        case .width: return .number(resolved.size.width)
        case .height: return .number(resolved.size.height)
        }
    }

    /// Whether the stack or grid a view is in decides where it goes, so that its x and y
    /// are not its own to set.
    public func isPlacedByParent(_ layer: LayerID) -> Bool {
        guard let view = document.layer(layer) else { return false }
        // A screen fills the device.
        if view.isPage { return true }
        guard !view.value(.absolute).boolValue, let parent = document.screen.parent(of: layer) else { return false }
        return parent.arrangement != .view
    }

    /// Whether a view's patch shows this input as a port.
    public func showsPort(_ input: ViewInput, of layer: LayerID) -> Bool {
        guard let view = document.layer(layer), let node = viewNode(for: layer) else { return false }
        return shownInputs(of: view, on: node).contains(input)
    }

    /// Shows or hides an input on a view's patch. An input with a cable always shows.
    public func setPort(_ input: ViewInput, of layer: LayerID, shown: Bool) {
        guard let view = document.layer(layer), let node = viewNode(for: layer) else { return }
        apply(shown ? "Show \(input.name) Port" : "Hide \(input.name) Port") { document in
            document.graph.update(node.id) { patch in
                var ports = patch.shownPorts ?? view.preset
                ports.removeAll { $0 == input.id }
                if shown { ports.append(input.id) }
                patch.shownPorts = ports
            }
        }
    }

    /// The inputs of a scene its view's patch shows: the chosen ones and every cabled one.
    public func shownScenePorts(of layer: Layer, on node: PatchNode) -> Set<String> {
        guard layer.scene != nil else { return [] }
        var shown = Set((node.shownPorts ?? layer.preset).filter { SceneUse.key(port: $0) != nil })
        for connection in document.graph.connections where connection.to.node == node.id && SceneUse.key(port: connection.to.port) != nil {
            shown.insert(connection.to.port)
        }
        for holder in document.graph.nodes {
            for port in holder.published ?? [] where !port.isOutput && port.inner.node == node.id && SceneUse.key(port: port.inner.port) != nil {
                shown.insert(port.inner.port)
            }
        }
        return shown
    }

    /// Shows or hides the port of one of a scene's inputs on its view's patch.
    public func setScenePort(_ port: String, of layer: LayerID, shown: Bool) {
        guard let view = document.layer(layer), let node = viewNode(for: layer), let key = SceneUse.key(port: port),
              let input = view.scene?.input(for: key) else { return }
        apply(shown ? "Show \(input.name) Port" : "Hide \(input.name) Port") { document in
            document.graph.update(node.id) { patch in
                var ports = patch.shownPorts ?? view.preset
                ports.removeAll { $0 == port }
                if shown { ports.append(port) }
                patch.shownPorts = ports
            }
        }
    }

    // MARK: Published ports

    /// The view a port would be published on: the one whose level the port's patch is in.
    /// Nothing is published on the screen.
    public func publishTarget(for ref: PortRef) -> PatchNode? {
        guard let node = document.graph.node(ref.node) else { return nil }
        let container = node.layerID.map { document.screen.parent(of: $0) } ?? document.container(node.home)
        guard let container, container.id != document.screen.id, document.shows(node, in: container),
              let patch = viewNode(for: container.id), !patch.isInstance else { return nil }
        return patch
    }

    /// Where a port is published, if it is.
    public func publication(of ref: PortRef, output: Bool) -> (node: NodeID, port: PublishedPort)? {
        document.graph.publication(of: ref, output: output)
    }

    public func canPublish(_ ref: PortRef, output: Bool) -> Bool {
        guard publishTarget(for: ref) != nil, publication(of: ref, output: output) == nil,
              let node = document.graph.node(ref.node) else { return false }
        let ports = registry.ports(for: node)
        return (output ? ports.output(ref.port) : ports.input(ref.port)) != nil
    }

    /// Shows a port on the patch of the view it is in, one level out, so it can be cabled
    /// from there. Returns the port's id on that patch.
    @discardableResult
    public func publish(_ ref: PortRef, output: Bool, name: String? = nil) -> String? {
        guard canPublish(ref, output: output), let target = publishTarget(for: ref),
              let node = document.graph.node(ref.node) else { return nil }
        let ports = registry.ports(for: node)
        guard let port = output ? ports.output(ref.port) : ports.input(ref.port) else { return nil }
        let published = PublishedPort(
            name: uniquePortName(name ?? "\(title(for: node)) \(port.name)", on: target),
            inner: ref, isOutput: output, type: port.type, options: port.options
        )
        apply("Publish \(port.name)") { document in
            document.graph.update(target.id) { $0.published = ($0.published ?? []) + [published] }
        }
        return published.id
    }

    public func unpublish(_ id: String, on node: NodeID) {
        guard document.graph.node(node)?.published?.contains(where: { $0.id == id }) == true else { return }
        apply("Unpublish Port") { document in
            document.graph.update(node) { $0.published?.removeAll { $0.id == id } }
        }
    }

    public func renamePublished(_ id: String, on node: NodeID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let patch = document.graph.node(node),
              let current = patch.published?.first(where: { $0.id == id }), current.name != trimmed else { return }
        let unique = uniquePortName(trimmed, on: patch, except: id)
        apply("Rename Port") { document in
            document.graph.update(node) { patch in
                guard let index = patch.published?.firstIndex(where: { $0.id == id }) else { return }
                patch.published?[index].name = unique
            }
        }
    }

    /// A name no other port of the patch has, so a port can be told apart by name.
    func uniquePortName(_ base: String, on node: PatchNode, except: String? = nil) -> String {
        let ports = registry.ports(for: node)
        let taken = Set((ports.inputs + ports.outputs).filter { $0.id != except }.flatMap { [$0.name.lowercased(), $0.id.lowercased()] })
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }

    /// Moves a layer one step forward (toward the top) or backward among its siblings.
    public func reorderLayer(_ id: LayerID, by offset: Int) {
        guard let parent = document.screen.parent(of: id),
              let index = parent.children.firstIndex(where: { $0.id == id })
        else { return }
        let target = min(max(index + offset, 0), parent.children.count - 1)
        guard target != index else { return }
        apply(offset > 0 ? "Bring Forward" : "Send Backward") { document in
            document.screen.update(parent.id) { parent in
                let layer = parent.children.remove(at: index)
                parent.children.insert(layer, at: target)
            }
        }
    }

    /// Wraps the selected sibling layers in a new group that covers them.
    public func groupSelectedLayers() {
        let screen = document.screen
        let chosen = selectedLayers.filter { $0 != screen.id }
        guard let first = chosen.first, let parent = screen.parent(of: first) else { return }
        let members = parent.children.filter { chosen.contains($0.id) }
        // Only siblings can be grouped. Grouping some of a mixed selection would be a surprise.
        guard members.count == chosen.count else { return }
        guard !members.isEmpty, let topIndex = parent.children.lastIndex(where: { chosen.contains($0.id) }) else { return }

        let bounds = members
            .map { ResolvedLayer($0).frame }
            .reduce(CGRect.null) { $0.union($1) }
        var group = Layer(name: uniqueLayerName("Group"), kind: .view)
        group.set(.position, .point(Point2(x: bounds.minX, y: bounds.minY)))
        group.set(.size, .size(Size2(width: bounds.width, height: bounds.height)))
        group.children = members.map { member in
            var moved = member
            let position = member.value(.position).pointValue
            moved.set(.position, .point(Point2(x: position.x - bounds.minX, y: position.y - bounds.minY)))
            return moved
        }
        let insertIndex = topIndex - (members.count - 1)

        apply("Group") { document in
            document.screen.update(parent.id) { parent in
                parent.children.removeAll { chosen.contains($0.id) }
                parent.children.insert(group, at: min(max(insertIndex, 0), parent.children.count))
            }
            // What the view outside published from these views now comes through the group:
            // the group publishes it, and the port outside stands for the group's.
            document.normalize()
            let moved = Set(members.map(\.id))
            let inside = Set(document.graph.nodes.filter { $0.layerID.map(moved.contains) ?? false }.map(\.id))
            guard let outer = document.graph.viewNode(layer: parent.id), let through = document.graph.viewNode(layer: group.id) else { return }
            var carried: [PublishedPort] = []
            var ports = outer.published ?? []
            for index in ports.indices where inside.contains(ports[index].inner.node) {
                var port = ports[index]
                port.id = UUID().uuidString
                carried.append(port)
                ports[index].inner = PortRef(node: through.id, port: port.id)
            }
            guard !carried.isEmpty else { return }
            document.graph.update(through.id) { $0.published = carried }
            document.graph.update(outer.id) { $0.published = ports }
        }
        selectedLayers = [group.id]
    }

    /// Replaces a group with its children, keeping them where they appear.
    public func ungroup(_ id: LayerID) {
        let outer = document.screen.parent(of: id).flatMap { $0.id == document.screen.id ? nil : $0.id }
        guard let group = document.layer(id), group.kind == .view,
              let parent = document.screen.parent(of: id),
              let index = parent.children.firstIndex(where: { $0.id == id })
        else { return }
        let origin = ResolvedLayer(group).origin
        let children = group.children.map { child in
            var moved = child
            let position = child.value(.position).pointValue
            moved.set(.position, .point(Point2(x: position.x + origin.x, y: position.y + origin.y)))
            return moved
        }
        apply("Ungroup") { document in
            document.screen.update(parent.id) { parent in
                parent.children.remove(at: index)
                parent.children.insert(contentsOf: children, at: index)
            }
            // Cables on what the group published go straight to the ports inside.
            if let patch = document.graph.viewNode(layer: id) {
                for port in patch.published ?? [] {
                    let outside = PortRef(node: patch.id, port: port.id)
                    // A port the view outside published from the group now stands for the port inside.
                    for index in document.graph.nodes.indices {
                        for at in (document.graph.nodes[index].published ?? []).indices
                        where document.graph.nodes[index].published?[at].inner == outside
                            && document.graph.nodes[index].published?[at].isOutput == port.isOutput {
                            document.graph.nodes[index].published?[at].inner = port.inner
                        }
                    }
                    if port.isOutput {
                        for cable in document.graph.connections(from: outside) {
                            document.graph.connect(from: port.inner, to: cable.to)
                        }
                    } else if let cable = document.graph.connection(into: outside) {
                        document.graph.connect(from: cable.from, to: port.inner)
                    }
                }
            }
            // What was kept inside the group moves out with its views.
            for index in document.graph.nodes.indices where document.graph.nodes[index].home == id {
                document.graph.nodes[index].home = outer
            }
            for index in document.graph.comments.indices where document.graph.comments[index].home == id {
                document.graph.comments[index].home = outer
            }
            document.graph.removeNodes(boundToLayersNotIn: Set(document.screen.flattened.map(\.id)))
        }
        selectedLayers = Set(children.map(\.id))
    }

    // MARK: Patches

    /// A spot for a new patch: below everything already in the graph.
    func freePatchPosition() -> Point2 {
        guard !levelGraph.nodes.isEmpty else { return Point2(x: 60, y: 60) }
        return PatchGrid.snap(freeSpotBelowGraph())
    }

    private func freeSpotBelowGraph() -> Point2 {
        let nodes = levelGraph.nodes
        let left = nodes.map(\.position.x).min() ?? 60
        let bottom = nodes.map { node in
            node.position.y + PatchLayout(node: node, ports: visiblePorts(for: node)).size.height
        }.max() ?? 60
        return Point2(x: left, y: bottom + 24)
    }

    @discardableResult
    public func addPatch(_ kind: String, at position: Point2? = nil) -> NodeID {
        var node = PatchNode(kind: kind, position: PatchGrid.snap(position ?? freePatchPosition()))
        // It is kept in the view whose level is open.
        node.home = openView
        if kind == PatchKind.javascript { node.script = Script.template }
        apply("Add Patch") { $0.graph.add(node) }
        selectedNodes = [node.id]
        return node.id
    }

    /// Patch kinds that attach to a layer and report touches on it.
    public static let touchPatchKinds = [
        PatchKind.interaction, "scroll", "layerSize", PatchKind.videoTime, "textInput",
        PatchKind.tap, PatchKind.longPress, PatchKind.pan, PatchKind.swipe, PatchKind.pinch, PatchKind.rotation, "hover",
        PatchKind.navigate,
    ]

    /// Whether a patch that attaches to views can attach to this one: Text Input reads a
    /// text field, Video Time a video, and Navigate shows a screen.
    public static func fits(_ patchKind: String, _ layer: Layer) -> Bool {
        if patchKind == PatchKind.navigate { return layer.isPage }
        return viewKind(for: patchKind).map { $0 == layer.kind } ?? true
    }

    /// The one kind of view a patch that attaches to views needs, for those that need one:
    /// Text Input reads a text field, Video Time a video.
    public static func viewKind(for patchKind: String) -> LayerKind? {
        switch patchKind {
        case "textInput": .textField
        case PatchKind.videoTime: .video
        default: nil
        }
    }

    /// Adds an Interaction patch for a layer (the Layer List's Touch menu).
    @discardableResult
    public func addInteraction(for layer: LayerID, at position: Point2? = nil) -> NodeID {
        addTouchPatch(PatchKind.interaction, for: layer, at: position)
    }

    /// Adds a patch that attaches to a layer: an Interaction, a gesture, a Hover.
    @discardableResult
    public func addTouchPatch(_ kind: String, for layer: LayerID, at position: Point2? = nil) -> NodeID {
        let node = PatchNode(kind: kind, position: PatchGrid.snap(position ?? freePatchPosition()), layerID: layer)
        apply("Add \(registry.defaultTitle(for: node))") { $0.graph.add(node) }
        // The view stays selected with it, so another patch can be attached straight away.
        selectedNodes = Set([node.id] + (viewNode(for: layer).map { [$0.id] } ?? []))
        revealNode = node.id
        return node.id
    }

    /// Shows a property as a port on its view's patch, then selects that patch and scrolls
    /// it into view.
    @discardableResult
    public func revealPropertyPatch(_ property: LayerProperty, of layer: LayerID, at position: Point2? = nil) -> NodeID? {
        guard let node = viewNode(for: layer) else { return nil }
        let inputs: [ViewInput]
        switch property {
        case .position: inputs = [ViewInput(.x), ViewInput(.y)]
        case .size: inputs = [ViewInput(.width), ViewInput(.height)]
        default: inputs = [ViewInput(property)]
        }
        for input in inputs where !showsPort(input, of: layer) { setPort(input, of: layer, shown: true) }
        selectedNodes = [node.id]
        revealNode = node.id
        return node.id
    }

    /// Deletes the selected patches. A view's patch is the view, so the view goes too.
    public func deleteSelectedPatches() {
        let ids = selectedNodes
        guard !ids.isEmpty else { return }
        apply(ids.count == 1 ? "Delete Patch" : "Delete Patches") { document in
            for id in ids {
                if let node = document.graph.node(id), node.kind == PatchKind.view, let layer = node.layerID {
                    document.removeLayer(layer)
                } else {
                    document.graph.remove(id)
                }
            }
        }
    }

    public func renamePatch(_ id: NodeID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        // A view has one name, the layer's.
        if let node = document.graph.node(id), node.kind == PatchKind.view, let layer = node.layerID {
            renameLayer(layer, to: trimmed)
            return
        }
        apply("Rename Patch") { $0.graph.update(id) { $0.name = trimmed.isEmpty ? nil : trimmed } }
    }

    public func setLiteral(_ value: Value, node: NodeID, port: String, interactive: Bool = false) {
        // A pulse lasts one frame and is never saved as firing (`Value` writes every pulse as
        // off), so one is not stored as firing either: it would fire every frame until the
        // document was reopened, and then never.
        if case .pulse(true) = value {
            setLiteral(.pulse(false), node: node, port: port, interactive: interactive)
            return
        }
        // A published input has no value of its own: it is the port inside.
        let given = PortRef(node: node, port: port)
        let real = document.graph.resolved(given, output: false)
        if real != given {
            setLiteral(value, node: real.node, port: real.port, interactive: interactive)
            return
        }
        // A view's patch has no values of its own: they are the layer's properties, and
        // for a component instance the inputs set on its layer.
        if let patch = document.graph.node(node), patch.kind == PatchKind.view, let layer = patch.layerID {
            if let input = ViewInput(id: port) {
                setInput(input, of: layer, to: value, interactive: interactive)
            } else if port == ShaderUse.codePort {
                setShader(value.textValue, of: layer, interactive: interactive)
            } else if let name = ShaderUse.inputName(port: port) {
                setShaderInput(name, of: layer, to: value, interactive: interactive)
            } else if let key = SceneUse.key(port: port) {
                setSceneInput(key, of: layer, to: value, interactive: interactive)
            } else if let name = CustomViewUse.inputName(port: port) {
                setCustomInput(name, of: layer, to: value, interactive: interactive)
            } else {
                setComponentInput(port, of: layer, to: value, interactive: interactive)
            }
            return
        }
        let change: (inout Document) -> Void = { $0.graph.update(node) { $0.inputs[port] = value } }
        if interactive {
            self.interactive(change)
        } else {
            apply("Change Value", change)
        }
    }

    /// Changes the type a generic patch works on. Cables that no longer fit are removed.
    public func setValueType(_ type: PortType, node id: NodeID) {
        let registry = self.registry
        apply("Change Type") { document in
            document.graph.update(id) { $0.valueType = type }
            for connection in document.graph.connections
            where connection.from.node == id || connection.to.node == id {
                if !registry.canConnect(from: connection.from, to: connection.to, in: document.graph) {
                    document.graph.disconnect(input: connection.to)
                }
            }
        }
    }

    /// Connects an output to an input when their types allow it. A generic patch with no
    /// other cables on its generic ports adopts the type arriving on the cable.
    /// `replacing` names an input whose cable is removed in the same undo step, for
    /// re-routing a cable from one input to another.
    @discardableResult
    public func connect(from: PortRef, to: PortRef, replacing old: PortRef? = nil) -> Bool {
        let registry = self.registry
        var graph = document.graph
        if let old { graph.disconnect(input: old) }
        adoptType(of: from, for: to, in: &graph)
        guard registry.canConnect(from: from, to: to, in: graph) else { return false }
        graph.connect(from: from, to: to)
        apply("Connect") { $0.graph = graph }
        return true
    }

    private func adoptType(of from: PortRef, for to: PortRef, in graph: inout Graph) {
        guard let destination = graph.node(to.node),
              let definition = registry.definition(destination.kind), definition.isGeneric,
              registry.ports(for: destination).input(to.port)?.type == registry.valueType(for: destination),
              isGenericInput(to.port, of: definition),
              let source = graph.node(from.node),
              let output = registry.ports(for: source).output(from.port),
              definition.genericTypes.contains(output.type),
              output.type != registry.valueType(for: destination)
        else { return }

        let genericOutputs = Set(definition.outputs.filter { $0.type == .generic }.map(\.id))
        let hasOtherGenericCables = graph.connections.contains { connection in
            (connection.to.node == to.node && isGenericInput(connection.to.port, of: definition) && connection.to != to)
                || (connection.from.node == to.node && genericOutputs.contains(connection.from.port))
        }
        if !hasOtherGenericCables {
            graph.update(to.node) { $0.valueType = output.type }
        }
    }

    /// Whether an input follows the patch's chosen type. A repeated input ("value0", "value1"…)
    /// follows its template.
    private func isGenericInput(_ port: String, of definition: PatchDefinition) -> Bool {
        if let spec = definition.inputs.first(where: { $0.id == port }) { return spec.type == .generic }
        if definition.variableInputs != nil, let template = definition.inputs.last, port.hasPrefix(template.id) {
            return template.type == .generic
        }
        return false
    }

    /// Adds (or with a negative `change`, removes) inputs on a patch with a variable number
    /// of them. Cables and values on removed inputs go with them.
    public func changeInputCount(of id: NodeID, by change: Int) {
        guard let node = document.graph.node(id), let current = registry.variableInputCount(for: node) else { return }
        let count = min(max(current.count + change, current.range.lowerBound), current.range.upperBound)
        guard count != current.count else { return }
        let registry = self.registry
        apply(change > 0 ? "Add Input" : "Remove Input") { document in
            document.graph.update(id) { $0.inputCount = count }
            guard let updated = document.graph.node(id) else { return }
            let kept = Set(registry.ports(for: updated).inputs.map(\.id))
            for connection in document.graph.connections where connection.to.node == id && !kept.contains(connection.to.port) {
                document.graph.disconnect(input: connection.to)
            }
            document.graph.update(id) { node in
                node.inputs = node.inputs.filter { kept.contains($0.key) }
            }
        }
    }

    public func disconnect(input: PortRef) {
        apply("Disconnect") { $0.graph.disconnect(input: input) }
    }

    /// Connects an output to an input of a view's patch.
    @discardableResult
    public func connect(from: PortRef, to input: ViewInput, of layer: LayerID) -> Bool {
        guard let node = viewNode(for: layer) else { return false }
        return connect(from: from, to: PortRef(node: node.id, port: input.id))
    }

    /// Connects an output to a whole property of a view.
    @discardableResult
    public func connect(from: PortRef, toProperty property: LayerProperty, of layer: LayerID) -> Bool {
        connect(from: from, to: ViewInput(property), of: layer)
    }

    /// The Broadcast patch a Receive patch listens to, if there is one.
    public func broadcaster(for receiver: PatchNode) -> PatchNode? {
        guard receiver.kind == "receive" else { return nil }
        let name = receiver.inputs["name"]?.textValue ?? "Variable"
        let type = registry.valueType(for: receiver)
        return document.graph.nodes.first {
            $0.kind == "broadcast" && ($0.inputs["name"]?.textValue ?? "Variable") == name
                && registry.valueType(for: $0) == type
        }
    }

    // MARK: Inspecting a patch

    /// The one patch that is selected when it is not a view's, for the Inspector.
    public var selectedPatch: PatchNode? {
        guard selectedNodes.count == 1, let id = selectedNodes.first,
              let node = document.graph.node(id), node.kind != PatchKind.view else { return nil }
        return node
    }

    /// One end of a cable as the Inspector names it: the patch (or view) and its port.
    public struct CableEnd: Hashable, Sendable {
        public let ref: PortRef
        /// The patch's title, or for a view's patch the view's name.
        public let title: String
        public let port: String
        /// For a patch attached to a view (a Tap, a Navigate), that view's name: what a
        /// person knows it by. nil for a view's own patch and for free patches.
        public var owner: String? = nil

        /// How the end is named in a sentence: "Row › Tapped", "Spring › Value".
        public var shortName: String { "\(owner ?? title) › \(port)" }

        /// The same, saying which patch it is when that is not in the short name.
        public var fullName: String { owner.map { "the \(port) output of \(title) on \($0)" } ?? "\(title) › \(port)" }
    }

    /// Where the cable into an input comes from, or nil when the input holds a value.
    public func cableSource(into input: PortRef) -> CableEnd? {
        // A cable into a port that publishes this one, further out, wins over its own.
        for ref in publications(of: input, output: false).reversed() {
            if let cable = document.graph.connection(into: ref) { return cableEnd(cable.from, output: true) }
        }
        return nil
    }

    /// Every input a cable from this output goes to, in the order they were connected,
    /// also from where it is published.
    public func cableTargets(from output: PortRef) -> [CableEnd] {
        let refs = publications(of: output, output: true)
        return document.graph.connections.filter { refs.contains($0.from) }.compactMap { cableEnd($0.to, output: false) }
    }

    /// A port and the ports that publish it, one level out at a time.
    private func publications(of ref: PortRef, output: Bool) -> [PortRef] {
        var chain = [ref]
        while chain.count < 32, let next = document.graph.publication(of: chain[chain.count - 1], output: output) {
            chain.append(PortRef(node: next.node, port: next.port.id))
        }
        return chain
    }

    private func cableEnd(_ ref: PortRef, output: Bool) -> CableEnd? {
        guard let node = document.graph.node(ref.node) else { return nil }
        let ports = registry.ports(for: node)
        let port = output ? ports.output(ref.port) : ports.input(ref.port)
        let published = node.published?.first { $0.id == ref.port }
        let owner = node.kind == PatchKind.view ? nil : node.layerID.flatMap { document.layer($0)?.name }
        return CableEnd(ref: ref, title: title(for: node), port: port?.name ?? published?.name ?? ref.port, owner: owner)
    }

    /// Every value on an output of the running prototype: one, or one per loop index.
    /// Empty when the prototype is not running.
    public func liveValues(of output: PortRef) -> [Value] {
        runtime?.outputValues(output) ?? []
    }

    /// Every value that arrived on an input of the running prototype on the last frame.
    public func liveInputValues(of input: PortRef) -> [Value] {
        runtime?.inputValues(input) ?? []
    }

    // MARK: Tracing

    /// Every patch and cable that feeds into `node`, directly or indirectly.
    public func upstream(of node: NodeID) -> (nodes: Set<NodeID>, connections: Set<Connection>) {
        var nodes: Set<NodeID> = [node]
        var connections: Set<Connection> = []
        var frontier = [node]
        while let current = frontier.popLast() {
            for connection in document.graph.connections where connection.to.node == current {
                connections.insert(connection)
                if nodes.insert(connection.from.node).inserted {
                    frontier.append(connection.from.node)
                }
            }
        }
        return (nodes, connections)
    }

    /// The title shown on a patch: its custom name, or one derived from what it is bound to.
    public func title(for node: PatchNode) -> String {
        if node.kind == PatchKind.view {
            return node.layerID.flatMap { document.layer($0) }?.name ?? "Missing View"
        }
        if let name = node.name { return name }
        // Nothing is known of a patch whose extension is neither here nor carried, but
        // the last part of its kind is the name its author gave it.
        if registry.definition(node.kind) == nil, let item = ExtensionKind.split(node.kind)?.item {
            return Script.title(item.replacingOccurrences(of: "-", with: "_"))
        }
        return registry.defaultTitle(for: node)
    }

    /// For a patch that cannot run because its extension is missing or switched off: the
    /// extension's name, or its id when nothing more is known. nil for every other patch.
    public func missingExtension(for node: PatchNode) -> String? {
        // A view's patch stands for the view: what it needs is what draws the view.
        if node.kind == PatchKind.view {
            guard let kind = node.custom, let id = ExtensionKind.extensionID(of: kind) else { return nil }
            guard let member = registry.extensions.member(id) else { return id }
            return member.isAvailable && registry.view(kind) != nil ? nil : member.package.name
        }
        guard let id = ExtensionKind.extensionID(of: node.kind) else { return nil }
        guard let member = registry.extensions.member(id) else { return id }
        return member.isAvailable && registry.definition(node.kind) != nil ? nil : member.package.name
    }

    /// Under the title: for a view's patch what kind of view it is, for a patch attached to
    /// a view (an Interaction) that view's name.
    public func subtitle(for node: PatchNode) -> String? {
        guard let layerID = node.layerID else { return nil }
        let layer = document.layer(layerID)
        if node.kind == PatchKind.view {
            guard let layer else { return nil }
            if let use = layer.component { return fullDocument.component(use.id)?.name ?? "Component" }
            // A view an extension draws goes by the name the extension gives it.
            if let custom = layer.custom {
                if let missing = missingExtension(for: node) { return "Needs \(missing)" }
                return registry.view(custom.kind)?.name ?? layer.type.displayName
            }
            // Inside a component its root stands in for the screen, but it is not one.
            if scope != nil, layer.id == document.screen.id { return "Component" }
            // One of the prototype's screens, and the device they are shown on.
            if layer.isPage { return layer.type == .view ? "Screen" : "Screen, \(layer.type.displayName)" }
            // Under a title that already says so, nothing.
            if layer.kind == .screen, !layer.pages.isEmpty { return layer.name == "Device" ? nil : "Device" }
            return layer.type.displayName
        }
        return layer?.name ?? "Missing View"
    }

    // MARK: Components

    /// The component a layer is an instance of.
    public func component(of layer: Layer) -> ComponentDefinition? {
        layer.component.flatMap { fullDocument.component($0.id) }
    }

    /// The value an unconnected input of a patch holds. For an instance patch that is the
    /// value set on the component's layer.
    public func literal(for port: PaperEngine.Port, of node: PatchNode) -> Value {
        let given = PortRef(node: node.id, port: port.id)
        let real = document.graph.resolved(given, output: false)
        if real != given {
            guard let inner = document.graph.node(real.node),
                  let innerPort = registry.ports(for: inner).input(real.port) else { return port.defaultValue }
            return literal(for: innerPort, of: inner)
        }
        if node.kind == PatchKind.view {
            let layer = node.layerID.flatMap { document.layer($0) }
            if let input = ViewInput(id: port.id) {
                return layer.map { input.value(in: $0) } ?? port.defaultValue
            }
            if port.id == ShaderUse.codePort { return .text(layer?.shader?.source ?? "") }
            if let name = ShaderUse.inputName(port: port.id) {
                return layer?.shader?.inputs[name]?.coerced(to: port.type) ?? port.defaultValue
            }
            if let name = CustomViewUse.inputName(port: port.id) {
                return layer?.custom?.inputs[name]?.coerced(to: port.type) ?? port.defaultValue
            }
            if let key = SceneUse.key(port: port.id) {
                return layer?.scene?.value(for: key) ?? port.defaultValue
            }
            return layer?.component?.inputs[port.id]?.coerced(to: port.type) ?? port.defaultValue
        }
        return registry.literal(for: port, of: node)
    }

    /// Whether `definition` may be placed in what is being edited. A component cannot go
    /// inside itself, directly or through another component.
    public func canInsert(_ definition: ComponentDefinition) -> Bool {
        guard !scopePath.isEmpty else { return true }
        if scopePath.contains(definition.id) { return false }
        let known = fullDocument.component(definition.id) ?? definition
        return fullDocument.componentsUsed(by: known).isDisjoint(with: scopePath)
    }

    /// Places a component in the middle of the screen and selects it. A library
    /// component is copied into the document the first time it is used.
    @discardableResult
    public func insertComponent(_ definition: ComponentDefinition, at position: Point2? = nil) -> LayerID? {
        guard canInsert(definition) else { return nil }
        var known = fullDocument.component(definition.id) ?? definition
        // A component that comes from a library brings what it is made of: the library
        // components inside it, and from an extension the pictures it shows.
        var others: [ComponentDefinition] = []
        if fullDocument.component(definition.id) == nil {
            let library = libraryComponents
            var waiting = [known]
            while let next = waiting.popLast() {
                for layer in next.root.flattened {
                    guard let id = layer.component?.id, id != known.id, fullDocument.component(id) == nil,
                          !others.contains(where: { $0.id == id }), let inner = library.first(where: { $0.id == id }) else { continue }
                    others.append(inner)
                    waiting.append(inner)
                }
            }
            if let shelf = registry.shelves.first(where: { shelf in shelf.components.contains { $0.id == definition.id } }),
               let package = shelf.extensionID.flatMap({ registry.extensions.member($0) })?.package {
                bringPictures(of: &known, from: package)
                for index in others.indices where shelf.components.contains(where: { $0.id == others[index].id }) {
                    bringPictures(of: &others[index], from: package)
                }
            }
        }
        // Into the view one is in, as other new views go; placed as on the whole screen.
        let parent = containerForNewViews.id
        let board = document.screen.value(.size).sizeValue
        let size = known.root.value(.size).sizeValue
        var layer = known.instance(name: uniqueLayerName(known.name), at: position ?? Point2(
            x: max(((board.width - size.width) / 2).rounded(), 0), y: max(((board.height - size.height) / 2).rounded(), 0)
        ))
        // Full-width bars start at the left edge.
        if size.width >= board.width, position == nil { layer.set(.position, .point(Point2(x: 0, y: layer.value(.position).pointValue.y))) }
        // A bar spans the screen at its edge, whatever device it was drawn for.
        if let edge = known.placement, position == nil {
            layer.set(.size, .size(Size2(width: board.width, height: edge == .fill ? board.height : size.height)))
            layer.set(.position, .point(Point2(x: 0, y: barEdge(edge, in: parent, board: board, height: size.height))))
        }
        apply("Add \(known.name)") { document in
            for other in others { document.adopt(other) }
            document.adopt(known)
            document.screen.insert(layer, into: parent)
        }
        selectedLayers = [layer.id]
        return layer.id
    }

    /// Adds a copy of a library template where new views go and selects it. A template
    /// that spans an edge is given the screen's width there; any other lands in the middle.
    @discardableResult
    public func insertTemplate(_ template: ViewTemplate) -> LayerID? {
        let fragment = DocumentFragment(
            layers: [template.root], nodes: template.nodes, connections: template.connections, components: template.components
        )
        let board = document.screen.value(.size).sizeValue
        let size = template.root.value(.size).sizeValue
        var made: LayerID?
        let name = uniqueLayerName(template.name)
        transaction("Add \(template.name)") {
            // The copy's root is the one new view whose parent was here before.
            let before = Set(document.screen.flattened.map(\.id))
            guard insert(fragment, actionName: "Add \(template.name)"),
                  let id = document.screen.flattened.first(where: { layer in
                      !before.contains(layer.id) && document.screen.parent(of: layer.id).map { before.contains($0.id) } == true
                  })?.id else { return }
            made = id
            let frame: (position: Point2, size: Size2) = switch template.placement {
            case .top: (.zero, Size2(width: board.width, height: size.height))
            case .bottom: (Point2(x: 0, y: max(board.height - size.height, 0)), Size2(width: board.width, height: size.height))
            case .fill: (.zero, board)
            case .bottomOverlay: (Point2(x: 0, y: max(board.height - size.height, 0)), Size2(width: board.width, height: size.height))
            case nil: (Point2(
                x: max(((board.width - size.width) / 2).rounded(), 0), y: max(((board.height - size.height) / 2).rounded(), 0)
            ), size)
            }
            let measure = registry.with(components: fullDocument.components).height
            apply("Add \(template.name)") { document in
                document.screen.update(id) { layer in
                    layer.name = name
                    layer.set(.position, .point(frame.position))
                    layer.set(.size, .size(frame.size))
                }
                // Its patch goes where there is room, as a new view's does: a second copy
                // would otherwise land exactly on the first.
                document.arrangeViews(of: [id], measure: measure)
            }
        }
        if let made { selectedLayers = [made] }
        return made
    }

    /// Where a new bar goes at an edge of the screen: against the bars already there, so a
    /// navigation bar lands under the status bar and a tab bar above the home indicator.
    func barEdge(_ edge: ComponentDefinition.Placement, in parent: LayerID, board: Size2, height: Double) -> Double {
        let bars = (document.layer(parent)?.children ?? []).filter { layer in
            layer.component.flatMap { fullDocument.component($0.id) }?.placement == edge
        }
        switch edge {
        case .top:
            return bars.map { $0.value(.position).pointValue.y + $0.value(.size).sizeValue.height }.max() ?? 0
        case .bottom:
            return max((bars.map { $0.value(.position).pointValue.y }.min() ?? board.height) - height, 0)
        case .fill:
            return 0
        case .bottomOverlay:
            return max(board.height - height, 0)
        }
    }

    /// The shelves components are picked from: the iOS controls, then each extension's.
    public var componentShelves: [ComponentShelf] {
        [ComponentShelf(name: "iOS", components: ComponentLibrary.iOS)] + registry.shelves
    }

    /// Every component a library offers.
    public var libraryComponents: [ComponentDefinition] { componentShelves.flatMap(\.components) }

    /// Keeps a file among the document's assets and returns the name it is kept under. The
    /// same bytes are kept once; another file of a name already taken gets a name of its own
    /// ("clip 2.mov"), so what other views show is never replaced.
    @discardableResult
    public func addAsset(_ data: Data, named file: String) -> String {
        var name = file, count = 2
        while let taken = assets[name], taken != data {
            let url = URL(fileURLWithPath: file)
            name = "\(url.deletingPathExtension().lastPathComponent) \(count)" + (url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)")
            count += 1
        }
        if assets[name] == nil { assets[name] = data }
        return name
    }

    /// A component of an extension names its pictures by their path in the extension.
    /// They are copied among the document's own, and the component told their names here.
    private func bringPictures(of component: inout ComponentDefinition, from package: PaperExtension) {
        for layer in component.root.flattened {
            guard let path = layer.properties[.image]?.textValue, let data = package.files[path] else { continue }
            let name = addAsset(data, named: URL(fileURLWithPath: path).lastPathComponent)
            component.root.update(layer.id) { $0.properties[.image] = .text(name) }
        }
    }

    public func setComponentInput(_ port: String, of layer: LayerID, to value: Value, interactive: Bool = false) {
        let change: (inout Document) -> Void = { $0.screen.update(layer) { $0.component?.inputs[port] = value } }
        if interactive {
            self.interactive(change)
        } else {
            apply("Change Input", change)
        }
    }

    /// The patch that exposes an instance's inputs and outputs to the graph: its view patch.
    public func componentPatch(for layer: LayerID) -> PatchNode? {
        guard document.layer(layer)?.component != nil else { return nil }
        return viewNode(for: layer)
    }

    /// Shows the instance's patch in the Patch Editor.
    @discardableResult
    public func revealComponentPatch(for layer: LayerID) -> NodeID? {
        guard let existing = componentPatch(for: layer) else { return nil }
        selectedNodes = [existing.id]
        revealNode = existing.id
        return existing.id
    }

    public func renameComponent(_ id: ComponentID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        apply("Rename Component") { document in
            if let index = document.components.firstIndex(where: { $0.id == id }) {
                document.components[index].name = trimmed
            }
        }
    }

    /// How many layers anywhere in the document use a component.
    public func useCount(of id: ComponentID) -> Int {
        func count(_ layer: Layer) -> Int {
            (layer.component?.id == id ? 1 : 0) + layer.children.map(count).reduce(0, +)
        }
        return count(fullDocument.screen) + fullDocument.components.map { count($0.root) }.reduce(0, +)
    }

    /// Removes a component that nothing uses.
    public func deleteComponent(_ id: ComponentID) {
        guard useCount(of: id) == 0, !scopePath.contains(id) else { return }
        apply("Delete Component") { $0.components.removeAll { $0.id == id } }
    }

    func uniqueComponentName(_ base: String) -> String {
        let names = Set(fullDocument.components.map(\.name))
        if !names.contains(base) { return base }
        var index = 2
        while names.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    /// Turns the selected sibling layers into a component and replaces them with a use of
    /// it. Patches that belong only to those layers move inside; a cable that crosses the
    /// boundary becomes a published input or output, so the prototype behaves as before.
    @discardableResult
    public func createComponentFromSelection(named name: String? = nil) -> ComponentID? {
        let screen = document.screen
        let chosen = selectedLayers.filter { $0 != screen.id }
        guard let first = chosen.first, let parent = screen.parent(of: first) else { return nil }
        let members = parent.children.filter { chosen.contains($0.id) }
        guard members.count == chosen.count else { return nil }
        guard !members.isEmpty, let topIndex = parent.children.lastIndex(where: { chosen.contains($0.id) }) else { return nil }
        let registry = self.registry
        let graph = document.graph

        // Layers: a root group covering the selection, like Group.
        let bounds = members.map { ResolvedLayer($0).frame }.reduce(CGRect.null) { $0.union($1) }
        let componentName = uniqueComponentName(name ?? (members.count == 1 ? members[0].name : "Component"))
        var root = Layer(name: componentName, kind: .view)
        root.set(.size, .size(Size2(width: bounds.width, height: bounds.height)))
        root.children = members.map { member in
            var moved = member
            let position = member.value(.position).pointValue
            moved.set(.position, .point(Point2(x: position.x - bounds.minX, y: position.y - bounds.minY)))
            return moved
        }
        let movedLayers = Set(members.flatMap { $0.flattened.map(\.id) })

        // Patches: those bound to the moved layers; those that sit between them (fed by one
        // and feeding another); then any that talk only to patches already going inside.
        var inner = Set(graph.nodes.filter { $0.layerID.map(movedLayers.contains) ?? false }.map(\.id))
        func reachable(from start: Set<NodeID>, downstream: Bool) -> Set<NodeID> {
            var seen = start
            var frontier = Array(start)
            while let node = frontier.popLast() {
                for connection in graph.connections {
                    let next = downstream
                        ? (connection.from.node == node ? connection.to.node : nil)
                        : (connection.to.node == node ? connection.from.node : nil)
                    if let next, !seen.contains(next), graph.node(next)?.layerID == nil {
                        seen.insert(next)
                        frontier.append(next)
                    }
                }
            }
            return seen
        }
        inner.formUnion(reachable(from: inner, downstream: true).intersection(reachable(from: inner, downstream: false)))
        var grew = true
        while grew {
            grew = false
            // A Broadcast or Receive talks to its other half by name, not by cable. Inside
            // the component the name would be private to it, so they stay outside.
            for node in graph.nodes
            where !inner.contains(node.id) && node.layerID == nil && !["broadcast", "receive"].contains(node.kind) {
                let neighbors = graph.connections.compactMap { connection -> NodeID? in
                    if connection.from.node == node.id { return connection.to.node }
                    if connection.to.node == node.id { return connection.from.node }
                    return nil
                }
                if !neighbors.isEmpty, neighbors.allSatisfy(inner.contains) {
                    inner.insert(node.id)
                    grew = true
                }
            }
        }

        var innerGraph = Graph(nodes: graph.nodes.filter { inner.contains($0.id) }.map { node in
            // Inside the component a patch stays in its view if that view came along.
            var copy = node
            if let home = node.home, !movedLayers.contains(home) { copy.home = nil }
            return copy
        })
        let instance = Layer(
            name: componentName, kind: .component,
            properties: [
                .position: .point(Point2(x: bounds.minX, y: bounds.minY)),
                .size: .size(Size2(width: bounds.width, height: bounds.height)),
            ],
            component: ComponentUse(id: ComponentID())
        )
        let instancePatch = PatchNode.component(instance.component!.id, on: instance.id, position: Point2(
            x: innerGraph.nodes.map(\.position.x).min() ?? 60, y: innerGraph.nodes.map(\.position.y).min() ?? 60
        ))
        let left = (innerGraph.nodes.map(\.position.x).min() ?? 300) - 240
        let right = (innerGraph.nodes.map(\.position.x).max() ?? 300) + 260
        let top = innerGraph.nodes.map(\.position.y).min() ?? 60

        var outerConnections: [Connection] = []
        var published: [PortRef: NodeID] = [:]
        var inputs = 0.0
        var outputs = 0.0
        func outputPort(_ ref: PortRef) -> PaperEngine.Port? {
            graph.node(ref.node).flatMap { registry.ports(for: $0).output(ref.port) }
        }
        for connection in graph.connections {
            let fromInside = inner.contains(connection.from.node)
            let toInside = inner.contains(connection.to.node)
            if fromInside, toInside {
                innerGraph.connect(from: connection.from, to: connection.to)
            } else if toInside {
                // A value coming in: one published input per source outside.
                guard let source = outputPort(connection.from) else { continue }
                let port: NodeID
                if let existing = published[connection.from] {
                    port = existing
                } else {
                    let destination = graph.node(connection.to.node)
                    let target = destination.flatMap { registry.ports(for: $0).input(connection.to.port) }
                    let named = destination?.kind == PatchKind.view ? target?.name : source.name
                    port = innerGraph.add(PatchNode(
                        kind: PatchKind.componentInput, position: Point2(x: left, y: top + inputs * 130),
                        name: named ?? source.name, inputs: ["value": target?.defaultValue ?? source.defaultValue],
                        valueType: source.type
                    ))
                    published[connection.from] = port
                    inputs += 1
                    outerConnections.append(Connection(
                        from: connection.from, to: PortRef(node: instancePatch.id, port: port.uuidString)
                    ))
                }
                innerGraph.connect(from: PortRef(node: port, port: "value"), to: connection.to)
            } else if fromInside {
                // A value going out: one published output per source inside.
                guard let source = outputPort(connection.from) else { continue }
                let port: NodeID
                if let existing = published[connection.from] {
                    port = existing
                } else {
                    port = innerGraph.add(PatchNode(
                        kind: PatchKind.componentOutput, position: Point2(x: right, y: top + outputs * 110),
                        name: source.name, valueType: source.type
                    ))
                    published[connection.from] = port
                    outputs += 1
                    innerGraph.connect(from: connection.from, to: PortRef(node: port, port: "value"))
                }
                outerConnections.append(Connection(
                    from: PortRef(node: instancePatch.id, port: port.uuidString), to: connection.to
                ))
            }
        }

        let definition = ComponentDefinition(id: instance.component!.id, name: componentName, root: root, graph: innerGraph)
        let insertIndex = topIndex - (members.count - 1)
        apply("Create Component") { document in
            document.components.append(definition)
            document.screen.update(parent.id) { parent in
                parent.children.removeAll { chosen.contains($0.id) }
                parent.children.insert(instance, at: min(max(insertIndex, 0), parent.children.count))
            }
            for id in inner { document.graph.remove(id) }
            document.graph.add(instancePatch)
            for connection in outerConnections { document.graph.connect(from: connection.from, to: connection.to) }
        }
        selectedLayers = [instance.id]
        return definition.id
    }

    // MARK: Scripts

    /// Replaces a JavaScript patch's script. Cables on ports the new script no longer
    /// declares, or declares with another type, are removed.
    public func setScript(_ source: String, node id: NodeID) {
        let registry = self.registry
        apply("Edit Script") { document in
            document.graph.update(id) { $0.script = source }
            guard let node = document.graph.node(id) else { return }
            let ports = registry.ports(for: node)
            for connection in document.graph.connections {
                let stale = (connection.to.node == id && ports.input(connection.to.port) == nil)
                    || (connection.from.node == id && ports.output(connection.from.port) == nil)
                    || ((connection.to.node == id || connection.from.node == id)
                        && !registry.canConnect(from: connection.from, to: connection.to, in: document.graph))
                if stale { document.graph.disconnect(input: connection.to) }
            }
            document.graph.update(id) { node in
                node.inputs = node.inputs.filter { ports.input($0.key) != nil }
            }
        }
    }

    // MARK: Shaders

    /// Replaces a shader view's source. Values and cables of inputs the new source no
    /// longer declares, or declares as another type, go with them.
    public func setShader(_ source: String, of id: LayerID, interactive: Bool = false) {
        guard let layer = document.layer(id), layer.kind == .view, layer.shader?.source != source else { return }
        let change: (inout PaperModel.Document) -> Void = { document in
            document.screen.update(id) { view in
                var use = view.shader ?? ShaderUse(source: source)
                use.source = source
                let uniforms = ShaderSource.uniforms(of: use)
                use.inputs = use.inputs.filter { stored in
                    uniforms.contains { $0.name == stored.key && stored.value.coerced(to: $0.kind.portType) != nil }
                }
                view.shader = use
            }
        }
        if interactive {
            self.interactive(change)
        } else {
            apply("Edit Shader", change)
        }
    }

    /// Sets the value a shader view's input has when no cable drives it.
    public func setShaderInput(_ name: String, of id: LayerID, to value: Value, interactive: Bool = false) {
        guard let shader = document.layer(id)?.shader,
              let uniform = ShaderSource.uniforms(of: shader).first(where: { $0.name == name }),
              let coerced = value.coerced(to: uniform.kind.portType) else { return }
        let change: (inout PaperModel.Document) -> Void = { $0.screen.update(id) { $0.shader?.inputs[name] = coerced } }
        if interactive {
            self.interactive(change)
        } else {
            apply("Change \(Script.title(name))", change)
        }
    }

    // MARK: Scenes

    /// Changes a scene view's scene as a whole. Cables into an object that is gone go with it.
    public func setScene(of id: LayerID, named name: String = "Edit Scene", interactive: Bool = false, _ body: @escaping (inout SceneUse) -> Void) {
        guard let layer = document.layer(id), layer.kind == .view, var scene = layer.scene else { return }
        body(&scene)
        scene.settleStoredValues()
        guard scene != layer.scene else { return }
        let change: (inout PaperModel.Document) -> Void = { [scene] in $0.screen.update(id) { $0.scene = scene } }
        if interactive {
            self.interactive(change)
        } else {
            apply(name, change)
        }
    }

    /// Sets the value an input of a scene, or of an object in it, has when no cable drives it.
    public func setSceneInput(_ key: SceneUse.Key, of id: LayerID, to value: Value, interactive: Bool = false) {
        guard let input = document.layer(id)?.scene?.input(for: key) else { return }
        setScene(of: id, named: "Change \(input.name)", interactive: interactive) { $0.set(value, for: key) }
    }

    /// Adds a shape to a scene, or a model read from one of the document's assets.
    @discardableResult
    public func addSceneObject(_ shape: SceneObject.Shape, model: String? = nil, named name: String? = nil, to id: LayerID) -> String? {
        guard let scene = document.layer(id)?.scene else { return nil }
        let base = name ?? (shape == .model ? (model.map { ($0 as NSString).deletingPathExtension } ?? "Model") : shape.displayName)
        var unique = base
        var index = 2
        while scene.objects.contains(where: { $0.name == unique }) {
            unique = "\(base) \(index)"
            index += 1
        }
        let object = SceneObject(name: unique, shape: shape, model: model)
        setScene(of: id, named: "Add \(shape.displayName)") { $0.objects.append(object) }
        return object.id
    }

    public func removeSceneObject(_ object: String, from id: LayerID) {
        setScene(of: id, named: "Remove Object") { $0.objects.removeAll { $0.id == object } }
    }

    public func renameSceneObject(_ object: String, to name: String, in id: LayerID) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        setScene(of: id, named: "Rename Object") { scene in
            guard let index = scene.objects.firstIndex(where: { $0.id == object }) else { return }
            scene.objects[index].name = trimmed
        }
    }

    // MARK: Comments

    /// Adds a comment box. With patches selected it is drawn around them; otherwise it
    /// appears at `point`.
    @discardableResult
    public func addComment(at point: Point2, text: String = "Comment") -> UUID {
        let frames = document.graph.nodes.filter { selectedNodes.contains($0.id) }.map {
            PatchLayout(node: $0, ports: visiblePorts(for: $0)).frame
        }
        var comment = GraphComment(text: text, origin: point, size: Size2(width: 320, height: 200))
        comment.home = openView
        if let first = frames.first {
            let bounds = frames.dropFirst().reduce(first) { $0.union($1) }
            comment.origin = Point2(x: bounds.minX - 24, y: bounds.minY - 48)
            comment.size = Size2(width: bounds.width + 48, height: bounds.height + 72)
        }
        apply("Add Comment") { $0.graph.comments.append(comment) }
        return comment.id
    }

    public func renameComment(_ id: UUID, to text: String) {
        apply("Edit Comment") { document in
            if let index = document.graph.comments.firstIndex(where: { $0.id == id }) {
                document.graph.comments[index].text = text
            }
        }
    }

    public func deleteComment(_ id: UUID) {
        apply("Delete Comment") { $0.graph.comments.removeAll { $0.id == id } }
    }
}

extension Value {
    /// A live value as the Inspector shows it: the value, or for a loop how many and the
    /// first few. nil when nothing is known (the prototype is not running).
    public static func liveSummary(_ values: [Value]) -> String? {
        guard let first = values.first else { return nil }
        guard values.count > 1 else { return first.summary }
        let shown = values.prefix(3).map(\.summary).joined(separator: ", ")
        return "\(values.count) values: \(shown)\(values.count > 3 ? ", …" : "")"
    }
}
