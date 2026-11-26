import AppKit
import Foundation
import PaperEngine
import PaperModel
import PaperRender

/// What a tool hands back to the assistant, and what the chat shows about it.
public struct AssistantToolResult {
    /// The answer the model reads.
    public var text: String
    /// PNGs the model looks at, in order.
    public var images: [Data]
    public var image: Data? { images.first }
    public var isError = false
    /// One line for the chat, such as "Added 3 layers and 5 patches".
    public var summary: String

    public init(text: String, image: Data? = nil, images: [Data] = [], isError: Bool = false, summary: String) {
        self.text = text
        self.images = image.map { [$0] } ?? images
        self.isError = isError
        self.summary = summary
    }
}

/// The assistant's hands: reading the open document and editing it through the same
/// commands the interface uses. No process or network here, so tests can drive it directly.
public struct AssistantToolbox {
    public let store: DocumentStore
    /// The undo menu's name for one batch of edits.
    public let editName: String

    public init(store: DocumentStore, editName: String = "Assistant Edit") {
        self.store = store
        self.editName = editName
    }

    public static let toolNames = [
        "get_document", "edit_document", "view_prototype", "interact_prototype", "undo", "redo",
        "mark_baseline", "get_changes", "compare_prototype",
    ]

    public func call(_ name: String, input: [String: Any]) -> AssistantToolResult {
        // A drag or a color being picked is not an undo step yet. Close it first, so the
        // person's change and this one stay separate and in order.
        if ["edit_document", "undo", "redo", "mark_baseline", "get_changes"].contains(name) { store.finishInteractive() }
        switch name {
        case "get_document":
            return AssistantToolResult(text: Self.json(describe()), summary: "Read the document")
        case "edit_document":
            return edit(input["operations"] as? [[String: Any]] ?? [])
        case "view_prototype":
            return view(input)
        case "interact_prototype":
            return interact(input)
        case "undo", "redo":
            return step(back: name == "undo")
        case "mark_baseline":
            return markBaseline(input)
        case "get_changes":
            return changes(input)
        case "compare_prototype":
            return compare(input)
        default:
            return AssistantToolResult(text: "Unknown tool \(name)", isError: true, summary: "Unknown tool")
        }
    }

    // MARK: Describing

    static let shortIDLength = 8
    static func short(_ id: UUID) -> String { String(id.uuidString.lowercased().prefix(shortIDLength)) }

    static func json(_ object: Any) -> String {
        // Writing something JSON cannot hold (an infinity, say) is not an error that can be
        // caught: it ends the app. So ask first.
        guard JSONSerialization.isValidJSONObject(object) else { return "{}" }
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func plain(_ value: Value) -> Any {
        switch value {
        // JSON has no way to write these, and writing them is not an error that can be caught.
        case let .number(n) where !n.isFinite: return NSNull()
        // As a decimal, 0.7 is written "0.7"; as a double it comes out 0.69999999999999996.
        case let .number(n): return n == n.rounded() && abs(n) < 1e15 ? Int(n) : NSDecimalNumber(string: "\(n)")
        case let .bool(b): return b
        case let .pulse(p): return p
        case let .text(t): return t
        case let .color(c): return c.hex
        case let .point(p): return ["x": plain(.number(p.x)), "y": plain(.number(p.y))]
        case let .size(s): return ["width": plain(.number(s.width)), "height": plain(.number(s.height))]
        case let .array(items): return items.map(plain)
        case let .object(fields): return fields.mapValues(plain)
        }
    }

    /// The document being edited (or the inside of the component being edited) as compact JSON.
    public func describe() -> [String: Any] {
        let document = store.document
        let registry = store.registry
        var out: [String: Any] = [:]
        if let scope = store.scope, let component = store.fullDocument.component(scope) {
            out["editing"] = "inside component \"\(component.name)\""
        } else {
            out["editing"] = "document"
        }
        // A view is a patch, so in cables it is named by its own id, like any patch.
        let viewOf = Dictionary(
            document.graph.nodes.filter { $0.kind == PatchKind.view }.compactMap { node in node.layerID.map { (node.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        // A published port is known by its name.
        func end(_ ref: PortRef) -> String {
            let published = document.graph.node(ref.node)?.published?.first { $0.id == ref.port }
            return "\(Self.short(viewOf[ref.node] ?? ref.node)).\(published?.name ?? ref.port)"
        }
        // The level of the graph the person is looking at, when it is not the screen's.
        if let open = store.openView { out["open_view"] = Self.short(open) }
        if let sketch = store.fullDocument.sketch { out["sketch_of"] = sketch.source ?? "code" }
        out["views"] = describe(document.screen, in: document)
        out["patches"] = document.graph.patches.map { node -> [String: Any] in
            var patch: [String: Any] = [
                "id": Self.short(node.id), "kind": node.kind, "title": store.title(for: node),
            ]
            if let layer = node.layerID { patch["view"] = Self.short(layer) }
            if let home = node.home { patch["inside"] = Self.short(home) }
            if registry.definition(node.kind)?.isGeneric == true { patch["type"] = registry.valueType(for: node).rawValue }
            if !node.inputs.isEmpty { patch["inputs"] = node.inputs.mapValues(Self.plain) }
            if let count = registry.variableInputCount(for: node) { patch["input_count"] = count.count }
            if node.kind == PatchKind.javascript {
                let ports = registry.ports(for: node)
                patch["in"] = ports.inputs.map { "\($0.id) (\($0.name)): \($0.type.rawValue)" }
                patch["out"] = ports.outputs.map { "\($0.id) (\($0.name)): \($0.type.rawValue)" }
            }
            if let script = node.script { patch["script"] = script }
            if let source = node.source { patch["source"] = source }
            // A patch whose extension is missing or switched off is there and does nothing.
            if let missing = store.missingExtension(for: node) { patch["needs_extension"] = missing }
            return patch
        }
        // The ways between screens: each is a Navigate (or Navigate Back) patch.
        let flows = store.flows
        if !flows.isEmpty {
            out["flows"] = flows.map { flow -> [String: Any] in
                var entry: [String: Any] = ["patch": Self.short(flow.id)]
                if let source = flow.source { entry["from"] = Self.short(source) }
                if let target = flow.target {
                    entry["to"] = Self.short(target)
                    entry["style"] = flow.style.rawValue
                } else {
                    entry["back"] = true
                }
                return entry
            }
        }
        out["cables"] = document.graph.connections.map { "\(end($0.from)) -> \(end($0.to))" }
        if !document.graph.comments.isEmpty { out["comments"] = document.graph.comments.map(\.text) }
        out["selected_views"] = store.selectedLayers.map(Self.short).sorted()
        out["selected_patches"] = document.graph.patches.filter { store.selectedNodes.contains($0.id) }.map { Self.short($0.id) }.sorted()
        return out
    }

    func describe(_ layer: Layer, in document: PaperModel.Document) -> [String: Any] {
        var out: [String: Any] = ["id": Self.short(layer.id), "name": layer.name, "kind": layer.type.rawValue]
        // One of the prototype's screens: it fills the device, and one shows at a time.
        if layer.isPage { out["screen"] = true }
        if let source = layer.source { out["source"] = source }
        // Position and size are four numbers; what makes a view a stack or a scroll view is
        // already in its kind.
        var properties: [String: Any] = [:]
        for (property, value) in layer.properties {
            switch property {
            case .position:
                properties["x"] = value.pointValue.x
                properties["y"] = value.pointValue.y
            case .size:
                properties["width"] = value.sizeValue.width
                properties["height"] = value.sizeValue.height
            case .layout where layer.kind != .screen: break
            case .scrolls, .contentOffset: break
            default: properties[property.rawValue] = Self.plain(value)
            }
        }
        if !properties.isEmpty { out["properties"] = properties }
        if let ports = document.graph.viewNode(layer: layer.id)?.shownPorts { out["ports"] = ports }
        if layer.arrangement == .scrollView { out["out"] = PatchRegistry.scrollOutputs.map { "\($0.id): \($0.type.rawValue)" } }
        if let use = layer.component, let definition = store.fullDocument.component(use.id) {
            out["component"] = definition.name
            var inputs: [String: Any] = [:]
            for port in definition.inputs { inputs[port.name] = Self.plain(use.inputs[port.id] ?? port.defaultValue) }
            out["inputs"] = inputs
            if !definition.outputs.isEmpty { out["out"] = definition.outputs.map { "\($0.name): \($0.type.rawValue)" } }
        }
        if let custom = layer.custom {
            // What to ask `add_view` for to make another, and its inputs by the names `connect` takes.
            out["kind"] = custom.kind
            if let view = store.registry.view(custom.kind) {
                out["extension_view"] = view.name
                out["in"] = view.inputs.map { "\($0.id): \($0.type.rawValue)" }
                if !view.inputs.isEmpty {
                    out["inputs"] = Dictionary(uniqueKeysWithValues: view.inputs.map {
                        ($0.id, Self.plain(custom.inputs[$0.id]?.coerced(to: $0.type) ?? $0.defaultValue))
                    })
                }
            }
            if let patch = document.graph.viewNode(layer: layer.id), let missing = store.missingExtension(for: patch) {
                out["needs_extension"] = missing
            }
        }
        if let scene = layer.scene {
            // The scene's own inputs, and every object with what is set on it. In `connect`
            // an input goes by its name: "Camera Yaw", "<object> Rotation Y".
            out["scene"] = [
                "inputs": Dictionary(uniqueKeysWithValues: SceneUse.inputs.map { ($0.id, Self.plain(scene.value($0.id))) }),
                "objects": scene.objects.map { object -> [String: Any] in
                    var described: [String: Any] = ["name": object.name, "shape": object.shape.rawValue]
                    if let model = object.model { described["model"] = model }
                    for input in SceneObject.inputs { described[input.id] = Self.plain(object.value(input.id)) }
                    if object.shape == .model, let problem = SceneSections.problem(with: object, store: store) { described["shape_error"] = problem }
                    return described
                },
            ] as [String: Any]
            out["in"] = SceneUse.inputs.map { "\($0.name): \($0.type.rawValue)" }
                + scene.objects.flatMap { object in SceneObject.inputs.map { "\(object.name) \($0.name): \($0.type.rawValue)" } }
        }
        if let shader = layer.shader {
            out["shader"] = shader.source
            let uniforms = ShaderSource.uniforms(of: shader)
            // The code itself is an input too; with a cable into it, the code that arrives is drawn.
            if let arriving = shader.arriving { out["shader_arriving"] = arriving }
            out["in"] = ["code: text"] + uniforms.map { "\($0.name): \($0.kind.portType.rawValue)" }
            if !uniforms.isEmpty {
                out["inputs"] = Dictionary(uniqueKeysWithValues: uniforms.map {
                    ($0.name, Self.plain(ShaderSource.value(of: $0, stored: shader.inputs)))
                })
            }
            if let problem = ShaderCompiler.error(in: shader.source) { out["shader_error"] = problem }
        }
        if let published = document.graph.viewNode(layer: layer.id)?.published, !published.isEmpty {
            out["published"] = published.map { port -> [String: Any] in
                let inner = document.graph.node(port.inner.node)
                return [
                    "name": port.name, "type": port.type.rawValue, "direction": port.isOutput ? "output" : "input",
                    "of": Self.short(inner?.kind == PatchKind.view ? inner?.layerID ?? port.inner.node : port.inner.node),
                    // A port published again from further in is known by its name there.
                    "port": document.graph.published(port.inner, output: port.isOutput)?.name ?? port.inner.port,
                ]
            }
        }
        if !layer.children.isEmpty { out["children"] = layer.children.map { describe($0, in: document) } }
        return out
    }

    // MARK: Looking

    private func view(_ input: [String: Any]) -> AssistantToolResult {
        var tap: Point2?
        if let at = input["tap"] as? [String: Any], let x = Self.number(at["x"]), let y = Self.number(at["y"]) {
            tap = Point2(x: x, y: y)
        }
        let seconds = Self.number(input["seconds"]) ?? 0
        let start: LayerID?
        do { start = try startScreen(input) } catch {
            return AssistantToolResult(text: "\(error)", isError: true, summary: "Could not look at the prototype")
        }
        let document = store.runtimeDocument
        guard let png = ViewerSnapshot.png(of: document, assets: store.assets, registry: store.runtimeRegistry, tap: tap, seconds: seconds, startScreen: start) else {
            return AssistantToolResult(text: "Could not draw the prototype.", isError: true, summary: "Could not look at the prototype")
        }
        if let tap { store.replayInViewer([.tap(tap), .wait(seconds), .look], from: start) }
        let size = document.screen.value(.size).sizeValue
        var text = "The prototype, \(Value.format(size.width)) × \(Value.format(size.height)) points, started fresh"
            + (start.flatMap { store.document.layer($0)?.name }.map { " on the screen \($0)" } ?? "")
        if let tap { text += ", tapped at \(Value.format(tap.x)), \(Value.format(tap.y))" }
        if seconds > 0 { text += ", \(Value.format(seconds)) s later" }
        return AssistantToolResult(
            text: text + ". One pixel is one point.", image: png,
            summary: tap == nil ? "Looked at the prototype" : "Tapped the prototype and looked"
        )
    }

    private static func point(_ any: Any?) -> Point2? {
        guard let at = any as? [String: Any], let x = number(at["x"]), let y = number(at["y"]) else { return nil }
        return Point2(x: x, y: y)
    }

    /// Several touches in a row on a fresh prototype, with a picture wherever one is asked for.
    private func interact(_ input: [String: Any]) -> AssistantToolResult {
        func bad(_ message: String) -> AssistantToolResult {
            AssistantToolResult(text: message, isError: true, summary: "Could not use the prototype")
        }
        guard let list = input["steps"] as? [[String: Any]], !list.isEmpty else { return bad("No steps given.") }
        var steps: [ViewerSnapshot.Step] = []
        var told: [String] = []
        /// Which fingers the steps so far have left down.
        var down: Set<Int> = []
        for (index, step) in list.enumerated() {
            // `down`, `move` and `up` are for finger 1 unless they name the second.
            var finger = 1
            if let named = step["finger"] {
                guard let number = Self.number(named), number == 1 || number == 2 else {
                    return bad("Step \(index): finger must be 1 or 2.")
                }
                finger = number.whole
            }
            let which = finger == 1 ? "finger" : "second finger"
            switch step["do"] as? String {
            case "tap":
                guard let at = Self.point(step["at"] ?? step) else { return bad("Step \(index): tap needs x and y.") }
                steps.append(.tap(at))
                told.append("tapped at \(Value.format(at.x)), \(Value.format(at.y))")
            case "drag":
                guard let from = Self.point(step["from"]), let to = Self.point(step["to"]) else {
                    return bad("Step \(index): drag needs from and to, each {x, y}.")
                }
                let seconds = Self.number(step["seconds"]) ?? 0.3
                steps.append(.drag(from: from, to: to, seconds: seconds))
                told.append("dragged from \(Value.format(from.x)), \(Value.format(from.y)) to \(Value.format(to.x)), \(Value.format(to.y))")
            case "down":
                guard let at = Self.point(step["at"] ?? step) else { return bad("Step \(index): down needs at {x, y}.") }
                steps.append(.down(at, finger: finger))
                down.insert(finger)
                told.append("\(which) down at \(Value.format(at.x)), \(Value.format(at.y))")
            case "move":
                guard let to = Self.point(step["to"]) else { return bad("Step \(index): move needs to {x, y}.") }
                guard down.contains(finger) else {
                    return bad("Step \(index): move needs a finger that is down. Use {do:\"down\", at} first.")
                }
                let seconds = Self.number(step["seconds"]) ?? 0.3
                steps.append(.move(to: to, seconds: seconds, finger: finger))
                told.append("moved the \(which) to \(Value.format(to.x)), \(Value.format(to.y))")
            case "up":
                steps.append(.up(finger: finger))
                down.remove(finger)
                told.append("\(which) lifted")
            case "wait":
                let seconds = Self.number(step["seconds"]) ?? 1
                steps.append(.wait(seconds))
                told.append("waited \(Value.format(seconds)) s")
            case "type":
                let text = step["text"] as? String ?? ""
                steps.append(.type(text))
                told.append("typed \"\(text)\"")
            case "press":
                switch step["key"] as? String {
                case "return": steps.append(.submit)
                case "delete": steps.append(.deleteBackward)
                default: return bad("Step \(index): press needs key \"return\" or \"delete\".")
                }
                told.append("pressed \(step["key"] as? String ?? "")")
            case "pinch":
                guard let at = Self.point(step["at"]) else { return bad("Step \(index): pinch needs at {x, y}.") }
                let scale = Self.number(step["scale"]) ?? 1
                let rotation = Self.number(step["rotation"]) ?? 0
                let pan = step["pan"].map { Self.point($0) } ?? Point2.zero
                guard let pan else { return bad("Step \(index): pan needs x and y.") }
                steps.append(.pinch(
                    at: at, scale: scale, rotation: rotation, seconds: Self.number(step["seconds"]) ?? 0.4, pan: pan
                ))
                down = []
                told.append("two fingers at \(Value.format(at.x)), \(Value.format(at.y)) spread to \(Value.format(scale)) times as far apart, turned \(Value.format(rotation))°"
                    + (pan == .zero ? "" : ", carried \(Value.format(pan.x)), \(Value.format(pan.y))"))
            case "hover":
                let at = Self.point(step["at"])
                steps.append(.hover(at))
                told.append(at.map { "hovered at \(Value.format($0.x)), \(Value.format($0.y))" } ?? "stopped hovering")
            case "look":
                steps.append(.look)
                told.append("picture \(steps.count(where: { $0 == .look }))")
            default:
                return bad("Step \(index): `do` must be tap, drag, down, move, up, wait, type, press, pinch, hover or look.")
            }
        }
        if steps.last != .look {
            steps.append(.look)
            told.append("picture \(steps.count(where: { $0 == .look }))")
        }
        let start: LayerID?
        do { start = try startScreen(input) } catch { return bad("\(error)") }
        let document = store.runtimeDocument
        let pictures = ViewerSnapshot.bitmaps(of: document, assets: store.assets, registry: store.runtimeRegistry, steps: steps, startScreen: start)
            .compactMap { $0.representation(using: .png, properties: [:]) }
        guard !pictures.isEmpty else { return bad("Could not draw the prototype.") }
        store.replayInViewer(steps, from: start)
        let size = document.screen.value(.size).sizeValue
        let onScreen = start.flatMap { store.document.layer($0)?.name }.map { " on the screen \($0)" } ?? ""
        return AssistantToolResult(
            text: "The prototype, \(Value.format(size.width)) × \(Value.format(size.height)) points, started fresh\(onScreen): "
                + told.joined(separator: "; ") + ". One pixel is one point. At most 30 s are run. Network requests and AI calls are not sent, so a Network Request or AI patch (Generate Text, Generate Image, Speak, Transcribe) stays loading; they run only in the person's Viewer, with their own API keys.",
            images: pictures, summary: "Used the prototype and looked"
        )
    }

    // MARK: Undoing

    private func step(back: Bool) -> AssistantToolResult {
        guard let manager = store.undoManager, back ? manager.canUndo : manager.canRedo else {
            let text = back ? "Nothing to undo." : "Nothing to redo."
            return AssistantToolResult(text: text, isError: true, summary: text)
        }
        let name = back ? manager.undoActionName : manager.redoActionName
        if back { manager.undo() } else { manager.redo() }
        let text = (back ? "Undid" : "Redid") + (name.isEmpty ? " the last change" : " \(name)")
        return AssistantToolResult(text: text + ".", summary: text)
    }

    // MARK: Editing

    struct Problem: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// What a batch has made so far, so later operations can name earlier ones.
    fileprivate final class Batch {
        var layers: [String: LayerID] = [:]
        var nodes: [String: NodeID] = [:]
        var created: [String: String] = [:]
        var placed: Set<NodeID> = []
        /// Patches whose level was given with `inside`.
        var homed: Set<NodeID> = []
        var comments: [(text: String, nodes: Set<NodeID>)] = []
        var newLayers: Set<LayerID> = []
    }

    /// A batch being applied one operation at a time, as the model writes it, so the person
    /// watches the prototype being built. `edit` is the same thing done all at once.
    /// Everything between `beginEdit` and `finishEdit` is one undo step; the caller keeps a
    /// store transaction open across it (`store.beginTransaction`).
    public final class LiveEdit {
        fileprivate let batch = Batch()
        fileprivate var errors: [[String: Any]] = []
        fileprivate let before: Document
        fileprivate let existingNodes: Set<NodeID>
        /// The document (as the store edits it) before the first operation.
        public var startingPoint: Document { before }
        /// The operations applied so far, in order, as they were given.
        public fileprivate(set) var operations: [[String: Any]] = []

        fileprivate init(before: Document) {
            self.before = before
            existingNodes = Set(before.graph.nodes.map(\.id))
        }
    }

    public func beginEdit() -> LiveEdit {
        store.finishInteractive()
        return LiveEdit(before: store.document)
    }

    /// Applies the next operation of a batch.
    public func apply(_ operation: [String: Any], to live: LiveEdit) {
        let index = live.operations.count
        live.operations.append(operation)
        // An operation that fails part way leaves nothing behind, so "failed" means
        // the document is as it was and the same step can simply be tried again.
        let before = store.document
        do {
            try perform(operation, live.batch)
            // Code cabled into a shader view declares inputs of its own. The next
            // operation may cable to them, so they are found now, not when the Viewer runs.
            store.settleArrivingShaderCode()
        } catch let problem as Problem {
            if store.document != before { store.apply("Revert") { $0 = before } }
            live.errors.append(["index": index, "op": operation["op"] as? String ?? "?", "error": problem.message])
        } catch {
            if store.document != before { store.apply("Revert") { $0 = before } }
            live.errors.append(["index": index, "error": "\(error)"])
        }
    }

    /// The name a person knows a view or patch by, for a ref or id the model wrote; nil when
    /// it names nothing that is there.
    public func name(for key: String, in live: LiveEdit? = nil) -> String? {
        let layers = store.document.screen.flattened
        let nodes = store.document.graph.nodes
        func layer(_ id: LayerID?) -> String? { id.flatMap { id in layers.first { $0.id == id }?.name } }
        func node(_ id: NodeID?) -> String? {
            id.flatMap { id in nodes.first { $0.id == id }.map { store.title(for: $0) } }
        }
        if let name = layer(live?.batch.layers[key]) ?? node(live?.batch.nodes[key])
            ?? layer(store.agentRefs.layers[key]) ?? node(store.agentRefs.nodes[key]) { return name }
        guard key.count >= Self.shortIDLength else { return nil }
        let prefix = key.lowercased()
        if let match = layers.first(where: { $0.id.uuidString.lowercased().hasPrefix(prefix) }) { return match.name }
        return nodes.first { $0.id.uuidString.lowercased().hasPrefix(prefix) }.map { store.title(for: $0) }
    }

    private func edit(_ operations: [[String: Any]]) -> AssistantToolResult {
        guard !operations.isEmpty else {
            return AssistantToolResult(text: "No operations given.", isError: true, summary: "Nothing to change")
        }
        var result: AssistantToolResult!
        store.transaction(editName) {
            let live = beginEdit()
            for operation in operations { apply(operation, to: live) }
            result = finishEdit(live)
        }
        return result
    }

    /// Lays out what a batch added and says what it did, as the answer to the model.
    public func finishEdit(_ live: LiveEdit) -> AssistantToolResult {
        let batch = live.batch, before = live.before, existingNodes = live.existingNodes
        let errors = live.errors, operations = live.operations
        // Refs outlive the batch, so the next one can name what this one made.
        store.agentRefs.layers.merge(batch.layers) { $1 }
        store.agentRefs.nodes.merge(batch.nodes) { $1 }
        guard !operations.isEmpty else {
            return AssistantToolResult(text: "No operations given.", isError: true, summary: "Nothing to change")
        }
        do {
            // A new view's patch already has a place under the patch of the view before
            // it. One that a cable reaches is laid out with the rest, so the cable is short.
            let graph = store.document.graph
            let cabled = Set(graph.connections.flatMap { [$0.from.node, $0.to.node] })
            let added = Set(graph.nodes.filter { $0.kind != PatchKind.view || cabled.contains($0.id) }.map(\.id))
                .subtracting(existingNodes)
            // A new patch is kept in the level of the views it works on, unless it was told where.
            let unhomed = Set(graph.patches.filter { $0.layerID == nil }.map(\.id)).subtracting(existingNodes).subtracting(batch.homed)
            if !unhomed.isEmpty { store.apply("Place Patches") { $0.settleHomes(only: unhomed) } }
            arrange(added.subtracting(batch.placed))
            for comment in batch.comments {
                store.selectedNodes = comment.nodes
                store.addComment(at: store.freePatchPosition(), text: comment.text)
            }
        }

        let after = store.document
        let addedNodes = after.graph.nodes.filter { !existingNodes.contains($0.id) && $0.kind != PatchKind.view }.map(\.id)
        let oldLayers = Set(before.screen.flattened.map(\.id))
        let addedLayers = after.screen.flattened.filter { !oldLayers.contains($0.id) }.map(\.id)
        let newViews = Set(addedLayers).intersection(batch.newLayers).compactMap { store.viewNode(for: $0)?.id }
        // Only what the person can see is selected: Delete must never reach into a level
        // of the graph that is not on screen.
        store.selectedNodes = Set(addedNodes).union(newViews).intersection(store.levelGraph.nodes.map(\.id))
        if !addedNodes.isEmpty { store.requestFitPatches() }

        let cables = after.graph.connections.count - before.graph.connections.count
        var parts: [String] = []
        func count(_ n: Int, _ one: String, _ many: String) { if n > 0 { parts.append("\(n) \(n == 1 ? one : many)") } }
        count(addedLayers.count, "view", "views")
        count(addedNodes.count, "patch", "patches")
        count(max(cables, 0), "cable", "cables")
        var summary = parts.isEmpty
            ? (after == before ? "Changed nothing" : "Edited the document")
            : "Added " + ListFormatter.localizedString(byJoining: parts)
        if !errors.isEmpty { summary += " (\(errors.count) of \(operations.count) steps failed)" }

        var answer: [String: Any] = ["applied": operations.count - errors.count, "created": batch.created]
        if !errors.isEmpty { answer["errors"] = errors }
        return AssistantToolResult(
            text: Self.json(answer), isError: errors.count == operations.count, summary: summary
        )
    }

    // MARK: Finding things

    /// A number an agent wrote. Infinity and "not a number" are refused: a layer cannot be
    /// drawn or saved with them. Sizes beyond `limit` are refused for the same reason.
    static func number(_ any: Any?) -> Double? {
        var read: Double?
        if let number = any as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { read = number.doubleValue }
        if let text = any as? String { read = Double(text) }
        guard let read, read.isFinite, abs(read) <= limit else { return nil }
        return read
    }

    /// The largest number an agent may put in a document. Far beyond any real design.
    static let limit = 1e6

    /// A whole number an agent wrote, such as a position in a list.
    static func whole(_ any: Any?) -> Int? {
        number(any).map { Int($0.rounded()) }
    }

    private func text(_ operation: [String: Any], _ key: String) throws -> String {
        guard let value = operation[key] as? String, !value.isEmpty else { throw Problem("Missing \"\(key)\".") }
        return value
    }

    /// Where a view goes when an operation names no parent: in the root, or with screens
    /// the screen the person has selected (or holds what is selected), else the first.
    /// Something meant to show over every screen names "device" as its parent.
    private var defaultParent: LayerID {
        let screens = store.screens
        guard let first = screens.first else { return store.document.screen.id }
        return store.selectedLayers.lazy.compactMap { self.store.screen(holding: $0)?.id }.first ?? first.id
    }

    /// The screen a look at the prototype starts on, from `screen` in its input.
    private func startScreen(_ input: [String: Any]) throws -> LayerID? {
        guard let named = input["screen"] else { return nil }
        let id = try layerID(named, Batch())
        guard store.isScreen(id) else { throw Problem("\"screen\" must be one of the prototype's screens.") }
        return id
    }

    private func layerID(_ any: Any?, _ batch: Batch) throws -> LayerID {
        guard let key = any as? String, !key.isEmpty else { throw Problem("Missing view.") }
        // The root: with screens, the device, whose views show over every screen.
        if key == "screen" || key == "device" { return store.document.screen.id }
        let all = store.document.screen.flattened
        // A ref can outlive its layer when the same batch deletes it.
        if let id = batch.layers[key] {
            guard all.contains(where: { $0.id == id }) else { throw Problem("The view \"\(key)\" was deleted.") }
            return id
        }
        // A ref from an earlier batch, while what it named is still there.
        if let id = store.agentRefs.layers[key], all.contains(where: { $0.id == id }) { return id }
        // A name first: a layer called "Add" or "A" is not the start of some other layer's id.
        let byName = all.filter { $0.name == key }
        if byName.count == 1 { return byName[0].id }
        if key.count >= Self.shortIDLength {
            let byID = all.filter { $0.id.uuidString.lowercased().hasPrefix(key.lowercased()) }
            if byID.count == 1 { return byID[0].id }
        }
        if byName.count > 1 { throw Problem("More than one view is called \"\(key)\". Use an id from get_document.") }
        throw Problem("No view \"\(key)\". Use an id from get_document, a ref, or \"screen\".")
    }

    private func nodeID(_ any: Any?, _ batch: Batch) throws -> NodeID {
        guard let key = any as? String, !key.isEmpty else { throw Problem("Missing patch.") }
        if let id = batch.nodes[key] { return id }
        let all = store.document.graph.nodes
        if let id = store.agentRefs.nodes[key], all.contains(where: { $0.id == id }) { return id }
        // A name first: a patch called "Add" or "A" is not the start of some other patch's id.
        let byTitle = all.filter { store.title(for: $0) == key }
        if byTitle.count == 1 { return byTitle[0].id }
        if key.count >= Self.shortIDLength {
            let byID = all.filter { $0.id.uuidString.lowercased().hasPrefix(key.lowercased()) }
            if byID.count == 1 { return byID[0].id }
        }
        // A view is a patch too, and is named the way views are.
        if let layer = try? layerID(key, batch), let view = store.viewNode(for: layer) { return view.id }
        throw Problem("No patch or view \"\(key)\". Use an id from get_document or a ref.")
    }

    /// The inputs a cable may go into. For a view: the properties its kind has, x, y, width
    /// and height, and a component instance's own inputs.
    private func inputs(of node: PatchNode) -> [PaperEngine.Port] {
        let all = store.registry.ports(for: node).inputs
        guard node.kind == PatchKind.view, let layer = node.layerID.flatMap({ store.document.layer($0) }) else { return all }
        let held = LayerProperty.properties(for: layer.kind)
        var allowed = Set(layer.inputs.map(\.id))
        if held.contains(.position) { allowed.insert("position") }
        if held.contains(.size) { allowed.insert("size") }
        return all.filter { allowed.contains($0.id) || ViewInput(id: $0.id) == nil }
    }

    /// The outputs a cable can leave a patch from: what it shows, and for a view also its
    /// frame outputs (x, y, width, height), which a cable then shows. They come last, so a
    /// component's own output called Width is found by that name before the frame's.
    private func outputs(of node: PatchNode) -> [PaperEngine.Port] {
        let shown = store.visiblePorts(for: node).outputs
        guard node.kind == PatchKind.view else { return shown }
        return shown.filter { !ViewOutput.ids.contains($0.id) } + PatchRegistry.frameOutputs
    }

    private func node(_ id: NodeID) throws -> PatchNode {
        guard let node = store.document.graph.node(id) else { throw Problem("That patch no longer exists.") }
        return node
    }

    private func port(_ key: String, in ports: [PaperEngine.Port], of node: PatchNode, _ what: String) throws -> PaperEngine.Port {
        let wanted = key.lowercased()
        if let match = ports.first(where: { $0.id.lowercased() == wanted }) ?? ports.first(where: { $0.name.lowercased() == wanted })
            // A scene's input may be written without its spaces: "cameraYaw".
            ?? ports.first(where: { SceneUse.key(port: $0.id) != nil && $0.name.lowercased().filter { !$0.isWhitespace } == wanted.filter { !$0.isWhitespace } })
            // A shader's input goes by the name its source gives it.
            ?? ports.first(where: { ShaderUse.inputName(port: $0.id)?.lowercased() == wanted })
            // As does an input of a view an extension draws.
            ?? ports.first(where: { CustomViewUse.inputName(port: $0.id)?.lowercased() == wanted }) {
            return match
        }
        let known = ports.map { "\($0.id): \($0.type.rawValue)" }.joined(separator: ", ")
        throw Problem("\(store.title(for: node)) has no \(what) \"\(key)\". Its \(what)s: \(known.isEmpty ? "none" : known).")
    }

    /// An input of a view by id or name: one of x, y, width and height, or a property. Any
    /// property the view's stored kind can hold is accepted, so setting `layout` on a view
    /// is allowed; the message lists what the view shows now.
    private func input(_ key: String, for layer: Layer) throws -> ViewInput {
        let properties = LayerProperty.properties(for: layer.kind)
        var allowed = properties.map(ViewInput.init)
        if properties.contains(.position) { allowed += [ViewInput(.x), ViewInput(.y)] }
        if properties.contains(.size) { allowed += [ViewInput(.width), ViewInput(.height)] }
        let wanted = key.lowercased()
        guard let match = allowed.first(where: { $0.id.lowercased() == wanted })
            ?? allowed.first(where: { $0.name.lowercased() == wanted })
        else {
            // A published port is set where it comes from.
            if let port = store.viewNode(for: layer.id)?.published?.first(where: { !$0.isOutput && $0.name.lowercased() == wanted }),
               case let real = store.document.graph.resolved(port.inner, output: false),
               let inner = store.document.graph.node(real.node) {
                throw Problem("\"\(port.name)\" is published from inside \(layer.name) and holds no value: it stands for \"\(real.port)\" of \(store.title(for: inner)). Set it there, or connect a cable to it on \(layer.name).")
            }
            throw Problem("A \(layer.type.rawValue) has no property \"\(key)\". It has: \(layer.inputs.map(\.id).joined(separator: ", ")).")
        }
        return match
    }

    /// Whether every number in a value is one a document can hold: finite and within `limit`.
    static func isUsable(_ value: Value) -> Bool {
        func fine(_ number: Double) -> Bool { number.isFinite && abs(number) <= limit }
        switch value {
        case let .number(n): return fine(n)
        case let .point(p): return fine(p.x) && fine(p.y)
        case let .size(s): return fine(s.width) && fine(s.height)
        case let .array(items): return items.allSatisfy(isUsable)
        case let .object(fields): return fields.values.allSatisfy(isUsable)
        default: return true
        }
    }

    /// Reads a loosely written JSON value as `type`. However it was written, a number that
    /// is not finite or is beyond `limit` is refused.
    static func value(_ any: Any?, as type: PortType, options: [String] = []) throws -> Value {
        let value = try parsed(any, as: type, options: options)
        guard isUsable(value) else {
            throw Problem("That number is too large or not a number. Use values between -\(Value.format(limit)) and \(Value.format(limit)).")
        }
        return value
    }

    private static func parsed(_ any: Any?, as type: PortType, options: [String]) throws -> Value {
        func fail() -> Problem {
            let shown = JSONSerialization.isValidJSONObject(["value": any ?? NSNull()]) ? json(["value": any ?? NSNull()]) : "that value"
            return Problem("Cannot use \(shown) as \(type.rawValue).")
        }
        guard let any, !(any is NSNull) else { throw fail() }
        if type != .json, type != .array, let dictionary = any as? [String: Any] {
            if let x = number(dictionary["x"]), let y = number(dictionary["y"]) {
                guard let value = Value.point(Point2(x: x, y: y)).coerced(to: type) else { throw fail() }
                return value
            }
            if let width = number(dictionary["width"]), let height = number(dictionary["height"]) {
                guard let value = Value.size(Size2(width: width, height: height)).coerced(to: type) else { throw fail() }
                return value
            }
        }
        if type == .point || type == .size, let list = any as? [Any], list.count == 2,
           let a = number(list[0]), let b = number(list[1]) {
            return type == .point ? .point(Point2(x: a, y: b)) : .size(Size2(width: a, height: b))
        }
        if type == .array || type == .json {
            // A lone string or number is fine as a fragment; a collection must be writable.
            let writable = any is String || (any as? NSNumber).map { $0.doubleValue.isFinite } ?? JSONSerialization.isValidJSONObject(any)
            guard writable, let data = try? JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed]),
                  let value = Value.parseJSON(data)?.coerced(to: type)
            else { throw fail() }
            return value
        }
        // An object or a list for a text input is taken as its JSON text (Network Request's
        // Headers and Query read either).
        if type == .text, options.isEmpty, any is [String: Any] || any is [Any], JSONSerialization.isValidJSONObject(any),
           let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys, .withoutEscapingSlashes]) {
            return .text(String(decoding: data, as: UTF8.self))
        }
        if let text = any as? String {
            if !options.isEmpty {
                guard let match = options.first(where: { $0.lowercased() == text.lowercased() }) else {
                    throw Problem("\"\(text)\" is not one of: \(options.joined(separator: ", ")).")
                }
                return .text(match)
            }
            guard let value = PatchEditorView.parse(text, as: type) else { throw fail() }
            return value
        }
        if let flag = any as? NSNumber {
            let raw: Value = CFGetTypeID(flag) == CFBooleanGetTypeID() ? .bool(flag.boolValue) : .number(flag.doubleValue)
            if type == .pulse { return .pulse(raw.boolValue) }
            if let value = raw.coerced(to: type) { return value }
        }
        throw fail()
    }

    /// Splits "patch.port" when the port was not given on its own.
    private func endpoint(_ operation: [String: Any], _ patchKey: String, _ portKey: String) throws -> (String, String) {
        let patch = try text(operation, patchKey)
        if let port = operation[portKey] as? String, !port.isEmpty { return (patch, port) }
        guard let dot = patch.lastIndex(of: ".") else { throw Problem("Missing \"\(portKey)\".") }
        return (String(patch[..<dot]), String(patch[patch.index(after: dot)...]))
    }

    // MARK: Operations

    private func perform(_ operation: [String: Any], _ batch: Batch) throws {
        let name = try text(operation, "op")
        let ref = operation["ref"] as? String
        func made(layer id: LayerID) {
            batch.newLayers.insert(id)
            if let ref {
                batch.layers[ref] = id
                batch.created[ref] = Self.short(id)
            }
        }
        func made(node id: NodeID) {
            if let ref {
                batch.nodes[ref] = id
                batch.created[ref] = Self.short(id)
            }
        }

        switch name {
        case "add_flow":
            let source = try layerID(operation["from"], batch)
            let style: Navigation.Style
            if let named = operation["style"] as? String {
                guard let known = Navigation.Style.named(named) else {
                    throw Problem("Unknown style \"\(named)\". Styles: \(Navigation.Style.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                style = known
            } else {
                style = .push
            }
            let goesBack = operation["back"] as? Bool == true
            guard goesBack != (operation["to"] != nil) else { throw Problem("Give \"to\" (a screen) or \"back\": true.") }
            let target = goesBack ? nil : try layerID(operation["to"], batch)
            if let target, !store.isScreen(target) {
                throw Problem("\"to\" must be a screen. Add screens with add_view kind screen.")
            }
            if goesBack, store.screen(holding: source) == nil { throw Problem("Only a view on a screen can go back.") }
            guard let node = store.addFlow(from: source, to: target, style: style) else {
                throw Problem("A flow starts at a view on one screen and shows another screen.")
            }
            made(node: node)

        case "add_view":
            let kindName = try text(operation, "kind")
            // A screen of the prototype: a view that fills the device, beside the others.
            if kindName == "screen" {
                if operation["parent"] != nil { throw Problem("A screen is always directly in the root; leave out \"parent\".") }
                guard let id = store.addScreen(name: operation["name"] as? String) else {
                    throw Problem("Screens cannot be added inside a component.")
                }
                if operation["properties"] != nil {
                    var layer = store.document.layer(id)!
                    try set(operation["properties"], on: &layer)
                    let properties = layer.properties
                    store.apply("Add Screen") { $0.screen.update(id) { $0.properties = properties } }
                }
                if let source = operation["source"] as? String { store.apply("Add Screen") { $0.screen.update(id) { $0.source = source } } }
                made(layer: id)
                break
            }
            // A view an extension adds is asked for by its own kind.
            if let view = store.registry.view(kindName) {
                guard view.isAvailable else {
                    throw Problem("\"\(kindName)\" cannot be added: the extension \(view.origin.name) is not installed or is switched off on this Mac.")
                }
                let parent = try operation["parent"].map { try layerID($0, batch) } ?? defaultParent
                guard store.document.layer(parent)?.kind.canHaveChildren == true else {
                    throw Problem("Only the screen, a view, a stack or a grid can contain views.")
                }
                var layer = view.layer(named: (operation["name"] as? String) ?? store.uniqueLayerName(view.name))
                try set(operation["properties"], on: &layer)
                layer.source = operation["source"] as? String
                store.apply("Add \(view.name)") { $0.screen.insert(layer, into: parent) }
                made(layer: layer.id)
                if view.shader != nil {
                    try setShaderInputs(operation["inputs"], of: layer.id)
                } else {
                    try setCustomInputs(operation["inputs"], of: layer.id, view)
                }
                break
            }
            guard let type = ViewType(rawValue: kindName), type != .screen, type != .component, type != .custom else {
                let kinds = ViewType.allCases.filter { $0 != .screen && $0 != .component && $0 != .custom }.map(\.rawValue)
                throw Problem("Unknown kind \"\(kindName)\". Kinds: \(kinds.joined(separator: ", ")). Use insert_component for components.")
            }
            let parent = try operation["parent"].map { try layerID($0, batch) } ?? defaultParent
            guard store.document.layer(parent)?.kind.canHaveChildren == true else {
                throw Problem("Only the screen, a view, a stack or a grid can contain views.")
            }
            var layer = Layer.new(type, name: (operation["name"] as? String) ?? store.uniqueLayerName(type.displayName))
            try set(operation["properties"], on: &layer)
            layer.source = operation["source"] as? String
            if operation["shader"] != nil || (operation["inputs"] != nil && type != .scene), type != .shader {
                throw Problem("Only a shader view has shader code and inputs. Use kind \"shader\".")
            }
            if operation["objects"] != nil, type != .scene {
                throw Problem("Only a scene view has objects. Use kind \"scene\".")
            }
            // A scene that is given its objects starts with only those.
            if type == .scene, operation["objects"] != nil { layer.scene = SceneUse() }
            store.apply("Add \(type.displayName)") { $0.screen.insert(layer, into: parent) }
            made(layer: layer.id)
            if type == .scene {
                try setScene(operation, of: layer.id)
                break
            }
            if let source = operation["shader"] as? String { try setShader(source, of: layer.id) }
            try setShaderInputs(operation["inputs"], of: layer.id)

        case "set_scene":
            let id = try layerID(operation["view"], batch)
            guard store.document.layer(id)?.scene != nil else {
                throw Problem("That view is not a scene view. Make it one first: change_view with kind \"scene\".")
            }
            guard operation["objects"] != nil || operation["inputs"] != nil || operation["remove"] != nil else {
                throw Problem("Missing \"objects\", \"inputs\" or \"remove\".")
            }
            try setScene(operation, of: id)

        case "set_shader":
            let id = try layerID(operation["view"], batch)
            guard store.document.layer(id)?.shader != nil else {
                throw Problem("That view is not a shader view. Make it one first: change_view with kind \"shader\".")
            }
            guard operation["shader"] != nil || operation["inputs"] != nil else { throw Problem("Missing \"shader\" or \"inputs\".") }
            if operation["shader"] != nil { try setShader(try text(operation, "shader"), of: id) }
            try setShaderInputs(operation["inputs"], of: id)

        case "set_properties":
            let id = try layerID(operation["view"], batch)
            guard var layer = store.document.layer(id) else { throw Problem("That view no longer exists.") }
            try set(operation["properties"], on: &layer)
            let properties = layer.properties
            store.apply("Change Properties") { $0.screen.update(id) { $0.properties = properties } }
            if let name = operation["name"] as? String { store.renameLayer(id, to: name) }

        case "rename_view":
            store.renameLayer(try layerID(operation["view"], batch), to: try text(operation, "name"))

        case "delete_view":
            let id = try layerID(operation["view"], batch)
            guard id != store.document.screen.id else { throw Problem("The screen cannot be deleted.") }
            store.apply("Delete View") { $0.removeLayer(id) }

        case "move_view":
            let id = try layerID(operation["view"], batch)
            let current = store.document.screen.parent(of: id)?.id
            let parent = try operation["parent"].map { try layerID($0, batch) } ?? current ?? store.document.screen.id
            guard let moving = store.document.layer(id), id != store.document.screen.id else {
                throw Problem("That view cannot be moved.")
            }
            guard !moving.contains(parent), store.document.layer(parent)?.kind.canHaveChildren == true else {
                throw Problem("A view can only move into the screen, or into a view, stack or grid that is not inside it.")
            }
            let index = Self.whole(operation["index"])
            store.apply("Move View") { document in
                guard let layer = document.screen.remove(id) else { return }
                document.screen.insert(layer, into: parent, at: index)
            }

        case "group_views":
            let ids = try (operation["views"] as? [Any] ?? []).map { try layerID($0, batch) }
            guard !ids.isEmpty else { throw Problem("Missing \"views\".") }
            let parents = Set(ids.map { store.document.screen.parent(of: $0)?.id })
            guard parents.count == 1, parents.first != .some(nil) else {
                throw Problem("Those views cannot be grouped: they must all be directly inside the same view.")
            }
            store.selectedLayers = Set(ids)
            store.groupSelectedLayers()
            guard let group = store.selectedLayers.first, store.document.layer(group)?.kind == .view else {
                throw Problem("Those views could not be grouped. They must share a parent.")
            }
            if let name = operation["name"] as? String { store.renameLayer(group, to: name) }
            if operation["properties"] != nil, var layer = store.document.layer(group) {
                try set(operation["properties"], on: &layer)
                let properties = layer.properties
                store.apply("Change Properties") { $0.screen.update(group) { $0.properties = properties } }
            }
            made(layer: group)

        case "insert_component":
            let wanted = try text(operation, "component")
            let known = store.fullDocument.components + store.libraryComponents
            guard let definition = known.first(where: { $0.name.lowercased() == wanted.lowercased() }) else {
                let names = Set(known.map(\.name)).sorted().joined(separator: ", ")
                throw Problem("No component \"\(wanted)\". Components: \(names).")
            }
            guard let id = store.insertComponent(definition) else { throw Problem("That component cannot go inside itself.") }
            // Into the screen it belongs on, unless a parent says otherwise below.
            if operation["parent"] == nil, store.document.screen.parent(of: id)?.id != defaultParent {
                let target = defaultParent
                store.apply("Insert Component") { document in
                    guard let layer = document.screen.remove(id) else { return }
                    document.screen.insert(layer, into: target)
                }
            }
            if let name = operation["name"] as? String { store.renameLayer(id, to: name) }
            if let source = operation["source"] as? String { store.apply("Note Source") { $0.screen.update(id) { $0.source = source } } }
            if operation["properties"] != nil, var layer = store.document.layer(id) {
                try set(operation["properties"], on: &layer)
                let properties = layer.properties
                store.apply("Change Properties") { $0.screen.update(id) { $0.properties = properties } }
            }
            if let parent = operation["parent"] {
                let parentID = try layerID(parent, batch)
                guard store.document.layer(parentID)?.kind.canHaveChildren == true else {
                    throw Problem("Only the screen, a view, a stack or a grid can contain views.")
                }
                store.apply("Move View") { document in
                    guard let layer = document.screen.remove(id) else { return }
                    document.screen.insert(layer, into: parentID)
                }
            }
            try setComponentInputs(operation["inputs"], of: id)
            made(layer: id)

        case "insert_template":
            let wanted = try text(operation, "template")
            guard let template = ComponentLibrary.template(wanted) else {
                throw Problem("No template \"\(wanted)\". Templates: \(ComponentLibrary.templates.map(\.name).joined(separator: ", ")).")
            }
            guard let id = store.insertTemplate(template) else { throw Problem("That template could not be added here.") }
            // Into the screen it belongs on, or the parent that was named.
            let target = try operation["parent"].map { try layerID($0, batch) } ?? defaultParent
            if store.document.screen.parent(of: id)?.id != target {
                guard store.document.layer(target)?.kind.canHaveChildren == true else {
                    throw Problem("Only the screen, a view, a stack or a grid can contain views.")
                }
                store.apply("Move View") { document in
                    guard let layer = document.screen.remove(id) else { return }
                    document.screen.insert(layer, into: target)
                }
            }
            if let name = operation["name"] as? String { store.renameLayer(id, to: name) }
            if operation["properties"] != nil, var layer = store.document.layer(id) {
                try set(operation["properties"], on: &layer)
                let properties = layer.properties
                store.apply("Change Properties") { $0.screen.update(id) { $0.properties = properties } }
            }
            made(layer: id)

        case "set_component_inputs":
            try setComponentInputs(operation["inputs"], of: try layerID(operation["view"], batch))

        case "add_patch":
            let kind = try text(operation, "kind")
            let id: NodeID
            if kind == PatchKind.view || kind == PatchKind.layerProperty || kind == PatchKind.component {
                throw Problem("A view is already a patch. Add one with add_view, and connect to it with {to: <view>, input: <property>}.")
            } else if kind == "scroll" {
                throw Problem("Scrolling belongs to a scroll view: add_view with kind scrollView, and use its offset output.")
            } else if DocumentStore.touchPatchKinds.contains(kind) {
                guard operation["view"] != nil else { throw Problem("A \(kind) patch needs a \"view\" to attach to.") }
                let layer = try layerID(operation["view"], batch)
                if let needed = DocumentStore.viewKind(for: kind), store.document.layer(layer)?.kind != needed {
                    throw Problem("A \(kind) patch attaches to a view of kind \(needed.rawValue).")
                }
                if kind == PatchKind.navigate, store.document.layer(layer)?.isPage != true {
                    throw Problem("A navigate patch attaches to the screen it shows. Add screens with add_view kind screen, or use add_flow.")
                }
                id = store.addTouchPatch(kind, for: layer)
            } else {
                guard let definition = store.registry.definition(kind) else {
                    throw Problem("Unknown patch kind \"\(kind)\". Use a kind from the patch list.")
                }
                guard definition.isAvailable else {
                    let name = definition.origin?.name ?? "its extension"
                    throw Problem("\"\(kind)\" cannot be added: the extension \(name) is not installed or is switched off on this Mac.")
                }
                id = store.addPatch(kind)
            }
            made(node: id)
            if let inside = operation["inside"] {
                let home = try layerID(inside, batch)
                guard store.document.layer(home)?.kind.canHaveChildren == true, try node(id).layerID == nil else {
                    throw Problem("A patch can be kept inside the screen, a view, a stack or a grid; one attached to a view goes where its view is.")
                }
                store.apply("Place Patch") { $0.graph.update(id) { $0.home = home == $0.home ? $0.home : home } }
                batch.homed.insert(id)
            }
            if let position = operation["position"] as? [String: Any],
               let x = Self.number(position["x"]), let y = Self.number(position["y"]) {
                store.apply("Move Patch") { $0.graph.update(id) { $0.position = PatchGrid.snap(Point2(x: x, y: y)) } }
                batch.placed.insert(id)
            }
            if let name = operation["name"] as? String { store.renamePatch(id, to: name) }
            if let type = operation["type"] as? String { try setType(type, of: id) }
            if let count = Self.whole(operation["input_count"]), let current = store.registry.variableInputCount(for: try node(id)) {
                store.changeInputCount(of: id, by: count - current.count)
            }
            if let script = operation["script"] as? String {
                guard kind == PatchKind.javascript else { throw Problem("Only a javascript patch has a script.") }
                try setScript(script, of: id)
            }
            try setInputs(operation["inputs"], of: id)
            if let source = operation["source"] as? String {
                store.apply("Note Source") { $0.graph.update(id) { $0.source = source } }
            }

        case "set_source":
            let source = (operation["source"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if operation["view"] != nil {
                let id = try layerID(operation["view"], batch)
                store.apply("Note Source") { $0.screen.update(id) { $0.source = source } }
            } else {
                let id = try nodeID(operation["patch"], batch)
                store.apply("Note Source") { $0.graph.update(id) { $0.source = source } }
            }

        case "set_inputs":
            let id = try nodeID(operation["patch"], batch)
            if let type = operation["type"] as? String { try setType(type, of: id) }
            let patch = try node(id)
            if patch.kind == PatchKind.view {
                // A view an extension draws has inputs of its own besides its properties.
                if let layer = patch.layerID, let view = store.document.layer(layer).flatMap({ store.customView(of: $0) }) {
                    try setCustomInputs(operation["inputs"], of: layer, view)
                    break
                }
                // A view that publishes inputs from inside it (a template's root) takes those by name.
                let published = (patch.published ?? []).filter { !$0.isOutput }
                guard !published.isEmpty, let inputs = operation["inputs"] as? [String: Any] else {
                    throw Problem("A view's inputs are its properties. To set one, use set_properties on the view.")
                }
                for (key, raw) in inputs.sorted(by: { $0.key < $1.key }) {
                    guard let port = published.first(where: { $0.name.lowercased() == key.lowercased() || $0.id == key }) else {
                        throw Problem("\(store.title(for: patch)) publishes no input \"\(key)\". It publishes: \(published.map(\.name).joined(separator: ", ")). Its own properties are set with set_properties.")
                    }
                    store.setLiteral(try Self.value(raw, as: port.type, options: port.options), node: id, port: port.id)
                }
                break
            }
            try setInputs(operation["inputs"], of: id)

        case "set_type":
            try setType(try text(operation, "type"), of: try nodeID(operation["patch"], batch))

        case "set_script":
            let id = try nodeID(operation["patch"], batch)
            guard try node(id).kind == PatchKind.javascript else { throw Problem("Only a javascript patch has a script.") }
            try setScript(try text(operation, "script"), of: id)

        case "rename_patch":
            store.renamePatch(try nodeID(operation["patch"], batch), to: try text(operation, "name"))

        case "delete_patch":
            let id = try nodeID(operation["patch"], batch)
            store.selectedNodes = [id]
            store.deleteSelectedPatches()

        case "connect":
            let (fromKey, outputKey) = try endpoint(operation, "from", "output")
            let fromID = try nodeID(fromKey, batch)
            let source = try node(fromID)
            let output = try port(outputKey, in: outputs(of: source), of: source, "output")
            let from = PortRef(node: fromID, port: output.id)
            let (toKey, inputKey) = try endpoint(operation, "to", "input")
            let toID = try nodeID(toKey, batch)
            let destination = try node(toID)
            let input = try port(inputKey, in: inputs(of: destination), of: destination, "input")
            guard store.connect(from: from, to: PortRef(node: toID, port: input.id)) else {
                throw Problem("A \(output.type.rawValue) output cannot go into the \(input.type.rawValue) input \"\(input.id)\" of \(store.title(for: destination)). Set the patch's type first, or convert the value.")
            }

        case "disconnect":
            let (toKey, inputKey) = try endpoint(operation, "to", "input")
            let toID = try nodeID(toKey, batch)
            let destination = try node(toID)
            let input = try port(inputKey, in: inputs(of: destination), of: destination, "input")
            store.disconnect(input: PortRef(node: toID, port: input.id))

        case "publish_port":
            let key = operation["view"] ?? operation["patch"]
            let id = try nodeID(key, batch)
            let inner = try node(id)
            let isOutput = operation["output"] != nil
            let found: PaperEngine.Port
            if isOutput {
                found = try port(try text(operation, "output"), in: outputs(of: inner), of: inner, "output")
            } else {
                found = try port(try text(operation, "input"), in: inputs(of: inner), of: inner, "input")
            }
            let inside = PortRef(node: id, port: found.id)
            guard let target = store.publishTarget(for: inside) else {
                throw Problem("\(store.title(for: inner)) is directly in the screen, so there is no view to publish its ports on. Cable to it directly.")
            }
            if let existing = store.publication(of: inside, output: isOutput) {
                throw Problem("That port is already published on \(store.title(for: target)) as \"\(existing.port.name)\".")
            }
            if let wanted = operation["name"] as? String, store.uniquePortName(wanted, on: target) != wanted {
                throw Problem("\(store.title(for: target)) already has a port called \"\(wanted)\". Give this one another name.")
            }
            guard store.publish(inside, output: isOutput, name: operation["name"] as? String) != nil else {
                throw Problem("That port cannot be published.")
            }

        case "unpublish_port", "rename_port":
            let layer = try layerID(operation["view"], batch)
            guard let patch = store.viewNode(for: layer) else { throw Problem("That view no longer exists.") }
            let wanted = try text(operation, "port").lowercased()
            guard let published = patch.published?.first(where: { $0.name.lowercased() == wanted || $0.id.lowercased() == wanted }) else {
                let known = (patch.published ?? []).map(\.name).joined(separator: ", ")
                throw Problem("\(store.title(for: patch)) has no published port \"\(wanted)\". It has: \(known.isEmpty ? "none" : known).")
            }
            if name == "rename_port" {
                let wanted = try text(operation, "name")
                guard store.uniquePortName(wanted, on: patch, except: published.id) == wanted else {
                    throw Problem("\(store.title(for: patch)) already has a port called \"\(wanted)\". Give this one another name.")
                }
                store.renamePublished(published.id, on: patch.id, to: wanted)
            } else {
                store.unpublish(published.id, on: patch.id)
            }

        case "open_view":
            let id = try layerID(operation["view"], batch)
            guard store.document.layer(id)?.kind.canHaveChildren == true else {
                throw Problem("Only the screen, a view, a stack or a grid has an inside to show.")
            }
            store.open(id)

        case "change_view":
            let id = try layerID(operation["view"], batch)
            let kindName = try text(operation, "kind")
            guard let type = ViewType(rawValue: kindName), DocumentStore.convertibleTypes.contains(type) else {
                throw Problem("A view can change to: \(DocumentStore.convertibleTypes.map(\.rawValue).joined(separator: ", ")).")
            }
            guard store.document.layer(id)?.kind == .view, id != store.document.screen.id else {
                throw Problem("Only a view, stack, grid or scrollView can change kind.")
            }
            store.convert(id, to: type)

        case "set_ports":
            let id = try layerID(operation["view"], batch)
            guard let layer = store.document.layer(id) else { throw Problem("That view no longer exists.") }
            for (key, shown) in [("show", true), ("hide", false)] {
                for name in operation[key] as? [String] ?? [] {
                    // A frame output goes by its id (frameX, frameWidth…); a bare x is the input.
                    if let output = ViewOutput(rawValue: name) ?? ViewOutput.allCases.first(where: { $0.id.lowercased() == name.lowercased() }) {
                        store.setOutputPort(output, of: id, shown: shown)
                    } else {
                        store.setPort(try self.input(name, for: layer), of: id, shown: shown)
                    }
                }
            }

        case "add_comment":
            let nodes = try (operation["patches"] as? [Any] ?? []).map { try nodeID($0, batch) }
            batch.comments.append((try text(operation, "text"), Set(nodes)))

        case "restart_prototype":
            store.restartPrototype()

        default:
            throw Problem("Unknown operation \"\(name)\".")
        }
    }

    private func set(_ any: Any?, on layer: inout Layer) throws {
        guard let properties = any as? [String: Any] else { return }
        for (key, raw) in properties.sorted(by: { $0.key < $1.key }) {
            let input = try input(key, for: layer)
            input.set(try Self.value(raw, as: input.type, options: input.options), on: &layer)
        }
    }

    /// Sets a JavaScript patch's script, and says so when the script does not work: a
    /// script with a mistake has no ports, so everything after it would fail confusingly.
    private func setScript(_ script: String, of id: NodeID) throws {
        store.setScript(script, node: id)
        if let problem = Script.interface(of: script).error {
            throw Problem("The script does not run: \(problem)")
        }
    }

    /// Changes a scene from an operation's `inputs` (the scene's own, by id or name),
    /// `objects` (each found by name and changed, or added) and `remove` (names).
    private func setScene(_ operation: [String: Any], of id: LayerID) throws {
        guard var scene = store.document.layer(id)?.scene else { return }
        func find(_ key: String, in inputs: [SceneInput], of what: String) throws -> SceneInput {
            let wanted = key.lowercased().filter { !$0.isWhitespace }
            if let input = inputs.first(where: { $0.id.lowercased() == wanted || $0.name.lowercased().filter { !$0.isWhitespace } == wanted }) { return input }
            throw Problem("\(what) has no input \"\(key)\". Its inputs: \(inputs.map { "\($0.id): \($0.type.rawValue)" }.joined(separator: ", ")).")
        }
        for (key, raw) in (operation["inputs"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
            let input = try find(key, in: SceneUse.inputs, of: "A scene")
            scene.set(try Self.value(raw, as: input.type, options: input.options), for: SceneUse.Key(input: input.id))
        }
        if let removed = operation["remove"] {
            guard let names = removed as? [String] else { throw Problem("\"remove\" is a list of object names.") }
            for name in names {
                guard let object = scene.object(named: name) else { throw Problem("The scene has no object \"\(name)\".") }
                scene.objects.removeAll { $0.id == object.id }
            }
        }
        if let listed = operation["objects"] {
            guard let objects = listed as? [[String: Any]] else { throw Problem("\"objects\" is a list of objects, each with a name and a shape.") }
            guard scene.objects.count + objects.count <= 200 else { throw Problem("A scene holds at most 200 objects.") }
            for described in objects {
                let name = (described["name"] as? String)?.trimmingCharacters(in: .whitespaces)
                var object: SceneObject
                if let name, let known = scene.object(named: name) {
                    object = known
                } else {
                    guard described["shape"] != nil || described["model"] != nil else {
                        throw Problem("A new object needs a shape: \(SceneObject.Shape.builtIn.map(\.rawValue).joined(separator: ", ")), or a model.")
                    }
                    object = SceneObject(name: name?.isEmpty == false ? name : nil, shape: .box)
                    if scene.objects.contains(where: { $0.name == object.name }) {
                        var index = 2
                        let base = object.name
                        while scene.objects.contains(where: { $0.name == "\(base) \(index)" }) { index += 1 }
                        object.name = "\(base) \(index)"
                    }
                }
                if let shape = described["shape"] as? String {
                    guard let known = SceneObject.Shape(named: shape) else {
                        throw Problem("Unknown shape \"\(shape)\". Shapes: \(SceneObject.Shape.builtIn.map(\.rawValue).joined(separator: ", ")); a file is given as \"model\".")
                    }
                    object.shape = known
                    if known != .model { object.model = nil }
                }
                if let model = described["model"] as? String {
                    let files = store.assets.keys.filter { LayerRenderer.modelExtensions.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
                    guard files.contains(model) else {
                        throw Problem("There is no model file \"\(model)\" in the document. \(files.isEmpty ? "It has none: the person adds one in the Inspector (Add to Scene > Model from File). Use shapes meanwhile." : "Its model files: \(files.joined(separator: ", ")).")")
                    }
                    object.shape = .model
                    object.model = model
                }
                guard object.shape != .model || object.model != nil else { throw Problem("A model needs \"model\": the name of a file in the document.") }
                for (key, raw) in described.sorted(by: { $0.key < $1.key }) where !["name", "shape", "model"].contains(key) {
                    let input = try find(key, in: SceneObject.inputs, of: "An object")
                    object.values[input.id] = try Self.value(raw, as: input.type, options: input.options)
                }
                if let index = scene.objects.firstIndex(where: { $0.id == object.id }) {
                    scene.objects[index] = object
                } else {
                    scene.objects.append(object)
                }
            }
        }
        let changed = scene
        store.setScene(of: id) { $0 = changed }
    }

    /// Sets a shader view's code, and says so when Metal will not compile it.
    private func setShader(_ source: String, of id: LayerID) throws {
        store.setShader(source, of: id)
        if let problem = ShaderCompiler.error(in: source) {
            throw Problem("The shader does not compile: \(problem)")
        }
    }

    /// Sets inputs of a view an extension draws, each named by its id or its name.
    private func setCustomInputs(_ any: Any?, of id: LayerID, _ view: CustomViewDefinition) throws {
        guard let inputs = any as? [String: Any] else { return }
        for (key, raw) in inputs.sorted(by: { $0.key < $1.key }) {
            let wanted = key.lowercased()
            guard let port = view.inputs.first(where: { $0.id.lowercased() == wanted || $0.name.lowercased() == wanted }) else {
                let known = view.inputs.map { "\($0.id): \($0.type.rawValue)" }.joined(separator: ", ")
                throw Problem("\(view.name) has no input \"\(key)\". Its inputs: \(known.isEmpty ? "none" : known).")
            }
            store.setCustomInput(port.id, of: id, to: try Self.value(raw, as: port.type, options: port.options))
        }
    }

    private func setShaderInputs(_ any: Any?, of id: LayerID) throws {
        guard let inputs = any as? [String: Any] else { return }
        for (key, raw) in inputs.sorted(by: { $0.key < $1.key }) {
            let uniforms = store.document.layer(id)?.shader.map(ShaderSource.uniforms(of:)) ?? []
            let wanted = key.lowercased()
            guard let uniform = uniforms.first(where: { $0.name.lowercased() == wanted || $0.port.name.lowercased() == wanted }) else {
                let known = uniforms.map { "\($0.name): \($0.kind.portType.rawValue)" }.joined(separator: ", ")
                throw Problem("The shader has no input \"\(key)\". Its inputs: \(known.isEmpty ? "none" : known).")
            }
            store.setShaderInput(uniform.name, of: id, to: try Self.value(raw, as: uniform.kind.portType, options: []))
        }
    }

    private func setInputs(_ any: Any?, of id: NodeID) throws {
        guard let inputs = any as? [String: Any] else { return }
        for (key, raw) in inputs.sorted(by: { $0.key < $1.key }) {
            let patch = try node(id)
            let input = try port(key, in: store.registry.ports(for: patch).inputs, of: patch, "input")
            store.setLiteral(try Self.value(raw, as: input.type, options: input.options), node: id, port: input.id)
        }
    }

    private func setComponentInputs(_ any: Any?, of layer: LayerID) throws {
        guard let inputs = any as? [String: Any] else { return }
        guard let use = store.document.layer(layer)?.component, let definition = store.fullDocument.component(use.id) else {
            throw Problem("That view is not a component instance.")
        }
        for (key, raw) in inputs.sorted(by: { $0.key < $1.key }) {
            let wanted = key.lowercased()
            guard let input = definition.inputs.first(where: { $0.name.lowercased() == wanted || $0.id.lowercased() == wanted }) else {
                throw Problem("\(definition.name) has no input \"\(key)\". Its inputs: \(definition.inputs.map(\.name).joined(separator: ", ")).")
            }
            store.setComponentInput(input.id, of: layer, to: try Self.value(raw, as: input.type, options: input.options))
        }
    }

    private func setType(_ name: String, of id: NodeID) throws {
        let patch = try node(id)
        guard let definition = store.registry.definition(patch.kind), definition.isGeneric else {
            throw Problem("\(store.title(for: patch)) works on one type only.")
        }
        guard let type = PortType(rawValue: name), definition.genericTypes.contains(type) else {
            throw Problem("\(store.title(for: patch)) can be: \(definition.genericTypes.map(\.rawValue).joined(separator: ", ")).")
        }
        store.setValueType(type, node: id)
    }

    // MARK: Arranging

    /// Lays new patches out left to right in the order values flow, below what was there.
    /// Lays out new patches level by level: each level of the graph is its own space, so
    /// what was added to one goes below what that level already had.
    private func arrange(_ added: Set<NodeID>) {
        guard !added.isEmpty else { return }
        let document = store.document
        let containers: [LayerID?] = [nil] + document.screen.flattened
            .filter { $0.id != document.screen.id && $0.kind.canHaveChildren }.map { Optional($0.id) }
        for container in containers {
            let level = document.levelGraph(of: container).nodes
            let mine = added.intersection(level.map(\.id))
            guard !mine.isEmpty else { continue }
            let before = level.filter { !mine.contains($0.id) }
            var origin = Point2(x: 60, y: 60)
            if !before.isEmpty {
                let bottom = before.map { $0.position.y + PatchLayout(node: $0, ports: store.visiblePorts(for: $0)).size.height }.max() ?? 60
                origin = PatchGrid.snap(Point2(x: before.map(\.position.x).min() ?? 60, y: bottom + 24))
            }
            arrange(mine, from: origin)
        }
    }

    private func arrange(_ added: Set<NodeID>, from origin: Point2) {
        guard !added.isEmpty else { return }
        let graph = store.document.graph
        // A cable that closes a loop (a counter feeding itself) says nothing about left and
        // right, and following it would push everything off to the far right.
        var back: Set<Connection> = []
        var done: Set<NodeID> = []
        var onPath: Set<NodeID> = []
        func walk(_ id: NodeID) {
            guard !done.contains(id) else { return }
            onPath.insert(id)
            for cable in graph.connections where cable.from.node == id && added.contains(cable.to.node) {
                if onPath.contains(cable.to.node) { back.insert(cable) } else { walk(cable.to.node) }
            }
            onPath.remove(id)
            done.insert(id)
        }
        for node in graph.nodes where added.contains(node.id) { walk(node.id) }

        var depth: [NodeID: Int] = [:]
        for _ in 0..<added.count {
            var changed = false
            for cable in graph.connections
            where added.contains(cable.from.node) && added.contains(cable.to.node) && !back.contains(cable) {
                let wanted = min((depth[cable.from.node] ?? 0) + 1, added.count)
                if wanted > (depth[cable.to.node] ?? 0) {
                    depth[cable.to.node] = wanted
                    changed = true
                }
            }
            if !changed { break }
        }
        var positions: [NodeID: Point2] = [:]
        var columns: [Int: Double] = [:]
        // Document order keeps related patches together within a column.
        for node in graph.nodes where added.contains(node.id) {
            let column = depth[node.id] ?? 0
            let top = columns[column] ?? origin.y
            positions[node.id] = Point2(x: origin.x + Double(column) * 264, y: top)
            columns[column] = top + PatchLayout(node: node, ports: store.visiblePorts(for: node)).size.height + 24
        }
        store.apply("Arrange Patches") { document in
            for (id, position) in positions { document.graph.update(id) { $0.position = position } }
        }
    }
}
