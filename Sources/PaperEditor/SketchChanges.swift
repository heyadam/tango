import AppKit
import Foundation
import PaperEngine
import PaperModel

/// What a person changed in a sketch since its starting point, in the terms a coding agent
/// needs to carry it into code: which view, which property, from what to what, and for
/// motion the numbers SwiftUI and Reanimated take. Views and patches are matched by id, so
/// a rename or a move is reported as that and not as something deleted and something new.
struct SketchChanges {
    let store: DocumentStore
    let toolbox: AssistantToolbox

    init(store: DocumentStore) {
        self.store = store
        toolbox = AssistantToolbox(store: store)
    }

    /// One side of the comparison: a tree of views and the graph that goes with it.
    private struct Side {
        let root: Layer
        let graph: Graph
        let layers: [LayerID: Layer]
        let parents: [LayerID: LayerID]
        let nodes: [NodeID: PatchNode]

        init(root: Layer, graph: Graph) {
            self.root = root
            self.graph = graph
            var layers: [LayerID: Layer] = [:]
            var parents: [LayerID: LayerID] = [:]
            func walk(_ layer: Layer) {
                layers[layer.id] = layer
                for child in layer.children {
                    parents[child.id] = layer.id
                    walk(child)
                }
            }
            walk(root)
            self.layers = layers
            self.parents = parents
            nodes = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// The report, or nil when the document has no starting point.
    func report() -> [String: Any]? {
        let now = store.fullDocument
        guard let sketch = now.sketch else { return nil }
        let then = sketch.baseline
        var out: [String: Any] = [:]
        if let source = sketch.source { out["sketch_of"] = source }

        let registry = store.registry
        var changed = compare(Side(root: then.screen, graph: then.graph), Side(root: now.screen, graph: now.graph), registry)
        // A component drawn in several places is changed once, inside it.
        var components: [[String: Any]] = []
        for component in now.components {
            guard let before = then.components.first(where: { $0.id == component.id }) else { continue }
            var inside = compare(
                Side(root: before.root, graph: before.graph), Side(root: component.root, graph: component.graph), registry
            )
            guard !inside.isEmpty else { continue }
            inside["component"] = component.name
            components.append(inside)
        }
        if !components.isEmpty { changed["inside_components"] = components }
        if changed.isEmpty {
            out["changes"] = "Nothing has changed since the starting point."
        } else {
            out.merge(changed) { _, new in new }
        }
        return out
    }

    /// How many things the report lists, for the one line the chat and the menu show.
    static func count(in report: [String: Any]) -> Int {
        var total = 0
        for (key, value) in report where key != "motion" {
            if let dictionary = value as? [String: Any] {
                total += dictionary.values.reduce(0) { $0 + (($1 as? [Any])?.count ?? 0) }
            } else if let list = value as? [[String: Any]] {
                total += list.reduce(0) { $0 + count(in: $1) }
            }
        }
        return total
    }

    /// The report as text a person can paste into any coding agent.
    static func text(for store: DocumentStore) -> String? {
        guard let report = SketchChanges(store: store).report() else { return nil }
        return """
        These are the changes a designer made in tango to a sketch of this code. Each view and \
        patch has a `source` saying where it lives in the code; `motion` gives animations as SwiftUI \
        and Reanimated write them. Make these changes in the code, in the code's own way, and say \
        what you could not carry over.

        \(AssistantToolbox.json(report))
        """
    }

    static func copy(from store: DocumentStore) {
        guard let text = text(for: store) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Comparing

    private func compare(_ old: Side, _ new: Side, _ registry: PatchRegistry) -> [String: Any] {
        var out: [String: Any] = [:]
        let views = self.views(old, new)
        if !views.isEmpty { out["views"] = views }
        let patches = self.patches(old, new, registry)
        if !patches.isEmpty { out["patches"] = patches }
        let before = Set(old.graph.connections.map { cable($0, in: old, registry) })
        let after = Set(new.graph.connections.map { cable($0, in: new, registry) })
        var cables: [String: Any] = [:]
        if !after.subtracting(before).isEmpty { cables["added"] = after.subtracting(before).sorted() }
        if !before.subtracting(after).isEmpty { cables["removed"] = before.subtracting(after).sorted() }
        if !cables.isEmpty { out["cables"] = cables }
        let motion = self.motion(old, new, registry)
        if !motion.isEmpty { out["motion"] = motion }
        return out
    }

    private func views(_ old: Side, _ new: Side) -> [String: Any] {
        var added: [[String: Any]] = []
        var removed: [[String: Any]] = []
        var changed: [[String: Any]] = []

        // Only the outermost of what was added or removed: the rest comes with it.
        for layer in new.root.flattened where old.layers[layer.id] == nil {
            guard let parent = new.parents[layer.id], old.layers[parent] != nil, let container = new.layers[parent] else { continue }
            var entry = toolbox.describe(layer, in: PaperModel.Document(screen: new.root, graph: new.graph))
            entry["parent"] = container.name
            let index = container.children.firstIndex { $0.id == layer.id } ?? 0
            entry["after"] = index > 0 ? container.children[index - 1].name : "nothing: it is first"
            added.append(entry)
        }
        for layer in old.root.flattened where new.layers[layer.id] == nil {
            guard let parent = old.parents[layer.id], new.layers[parent] != nil else { continue }
            var entry: [String: Any] = ["view": layer.name, "kind": layer.type.rawValue]
            if let source = layer.source { entry["source"] = source }
            if let container = old.layers[parent] { entry["was_in"] = container.name }
            removed.append(entry)
        }

        for layer in new.root.flattened {
            guard let before = old.layers[layer.id] else { continue }
            var entry: [String: Any] = [:]
            if before.name != layer.name { entry["renamed"] = ["from": before.name, "to": layer.name] }
            if before.type != layer.type, layer.kind != .screen {
                entry["kind"] = ["from": before.type.rawValue, "to": layer.type.rawValue]
            }
            let properties = self.properties(before, layer)
            if !properties.isEmpty { entry["properties"] = properties }
            if before.component?.inputs != layer.component?.inputs, let use = layer.component,
               let definition = store.fullDocument.component(use.id) ?? store.libraryComponents.first(where: { $0.id == use.id }) {
                var inputs: [String: Any] = [:]
                for port in definition.inputs where before.component?.inputs[port.id] != use.inputs[port.id] {
                    inputs[port.name] = [
                        "from": AssistantToolbox.plain(before.component?.inputs[port.id] ?? port.defaultValue),
                        "to": AssistantToolbox.plain(use.inputs[port.id] ?? port.defaultValue),
                    ]
                }
                if !inputs.isEmpty { entry["inputs"] = inputs }
            }
            if before.custom != layer.custom, let custom = layer.custom {
                if before.custom?.kind != custom.kind { entry["extension_view"] = custom.kind }
                if before.custom?.inputs != custom.inputs { entry["extension_inputs"] = custom.inputs.mapValues(AssistantToolbox.plain) }
            }
            if before.scene != layer.scene, let scene = layer.scene {
                let was = before.scene
                var inputs: [String: Any] = [:]
                for input in SceneUse.inputs where was?.value(input.id) != scene.value(input.id) {
                    inputs[input.id] = AssistantToolbox.plain(scene.value(input.id))
                }
                if !inputs.isEmpty { entry["scene_inputs"] = inputs }
                // Each object that is new or differs, with everything set on it; and the names of those that went.
                let changed = scene.objects.filter { $0 != was?.object($0.id) }.map { object -> [String: Any] in
                    var described: [String: Any] = ["name": object.name, "shape": object.shape.rawValue]
                    if let model = object.model { described["model"] = model }
                    if was?.object(object.id) == nil { described["added"] = true }
                    for (key, value) in object.values { described[key] = AssistantToolbox.plain(value) }
                    return described
                }
                if !changed.isEmpty { entry["scene_objects"] = changed }
                let gone = (was?.objects ?? []).filter { scene.object($0.id) == nil }.map(\.name)
                if !gone.isEmpty { entry["scene_removed"] = gone }
            }
            if before.shader != layer.shader, let shader = layer.shader {
                if before.shader?.source != shader.source { entry["shader"] = shader.source }
                if before.shader?.inputs != shader.inputs { entry["shader_inputs"] = shader.inputs.mapValues(AssistantToolbox.plain) }
            }
            if let was = old.parents[layer.id], let parent = new.parents[layer.id], was != parent {
                entry["moved"] = ["from": old.layers[was]?.name ?? "?", "to": new.layers[parent]?.name ?? "?"]
            }
            // The order of the views that were here before and still are.
            let kept = layer.children.filter { old.parents[$0.id] == layer.id }.map(\.id)
            let earlier = before.children.filter { new.parents[$0.id] == layer.id }.map(\.id)
            if kept != earlier { entry["children_now_in_order"] = kept.compactMap { new.layers[$0]?.name } }

            guard !entry.isEmpty else { continue }
            entry["view"] = layer.name
            entry["id"] = AssistantToolbox.short(layer.id)
            if let source = layer.source { entry["source"] = source }
            changed.append(entry)
        }

        var out: [String: Any] = [:]
        if !changed.isEmpty { out["changed"] = changed }
        if !added.isEmpty { out["added"] = added }
        if !removed.isEmpty { out["removed"] = removed }
        return out
    }

    /// Every stored value that differs, with position and size as the four numbers they are everywhere else.
    private func properties(_ before: Layer, _ after: Layer) -> [String: Any] {
        var out: [String: Any] = [:]
        func note(_ key: String, _ from: Any, _ to: Any) { out[key] = ["from": from, "to": to] }
        for property in Set(before.properties.keys).union(after.properties.keys) {
            let (from, to) = (before.value(property), after.value(property))
            guard from != to else { continue }
            switch property {
            case .position:
                if from.pointValue.x != to.pointValue.x { note("x", from.pointValue.x, to.pointValue.x) }
                if from.pointValue.y != to.pointValue.y { note("y", from.pointValue.y, to.pointValue.y) }
            case .size:
                if from.sizeValue.width != to.sizeValue.width { note("width", from.sizeValue.width, to.sizeValue.width) }
                if from.sizeValue.height != to.sizeValue.height { note("height", from.sizeValue.height, to.sizeValue.height) }
            case .contentOffset, .scrolls: break
            case .layout where after.kind != .screen: break
            default: note(property.rawValue, AssistantToolbox.plain(from), AssistantToolbox.plain(to))
            }
        }
        return out
    }

    private func patches(_ old: Side, _ new: Side, _ registry: PatchRegistry) -> [String: Any] {
        var added: [[String: Any]] = []
        var removed: [[String: Any]] = []
        var changed: [[String: Any]] = []

        func basics(_ node: PatchNode, in side: Side) -> [String: Any] {
            var entry: [String: Any] = ["patch": title(node, in: side, registry), "kind": node.kind]
            if let layer = node.layerID, let view = side.layers[layer] { entry["on_view"] = view.name }
            if let source = node.source { entry["source"] = source }
            return entry
        }

        for node in new.graph.patches {
            guard let before = old.nodes[node.id] else {
                var entry = basics(node, in: new)
                if !node.inputs.isEmpty { entry["inputs"] = node.inputs.mapValues(AssistantToolbox.plain) }
                if let script = node.script { entry["script"] = script }
                added.append(entry)
                continue
            }
            var entry: [String: Any] = [:]
            let (was, name) = (title(before, in: old, registry), title(node, in: new, registry))
            if was != name { entry["renamed"] = ["from": was, "to": name] }
            let ports = registry.ports(for: node).inputs
            var inputs: [String: Any] = [:]
            for port in ports {
                let from = before.inputs[port.id] ?? port.defaultValue
                let to = node.inputs[port.id] ?? port.defaultValue
                if from != to { inputs[port.id] = ["from": AssistantToolbox.plain(from), "to": AssistantToolbox.plain(to)] }
            }
            if !inputs.isEmpty { entry["inputs"] = inputs }
            if before.valueType != node.valueType, let type = node.valueType { entry["type"] = type.rawValue }
            if before.script != node.script, let script = node.script { entry["script"] = script }
            guard !entry.isEmpty else { continue }
            entry.merge(basics(node, in: new)) { own, _ in own }
            changed.append(entry)
        }
        for node in old.graph.patches where new.nodes[node.id] == nil { removed.append(basics(node, in: old)) }

        var out: [String: Any] = [:]
        if !changed.isEmpty { out["changed"] = changed }
        if !added.isEmpty { out["added"] = added }
        if !removed.isEmpty { out["removed"] = removed }
        return out
    }

    // MARK: Names

    private func title(_ node: PatchNode, in side: Side, _ registry: PatchRegistry) -> String {
        if node.kind == PatchKind.view { return node.layerID.flatMap { side.layers[$0] }?.name ?? "a view that is gone" }
        return node.name ?? registry.defaultTitle(for: node)
    }

    /// A port as a person would say it: the patch or view, then the port by its published name or its id.
    private func end(_ ref: PortRef, in side: Side, _ registry: PatchRegistry) -> String {
        guard let node = side.nodes[ref.node] else { return "?.\(ref.port)" }
        let published = node.published?.first { $0.id == ref.port }
        return "\(title(node, in: side, registry)).\(published?.name ?? ref.port)"
    }

    private func cable(_ connection: Connection, in side: Side, _ registry: PatchRegistry) -> String {
        "\(end(connection.from, in: side, registry)) -> \(end(connection.to, in: side, registry))"
    }

    // MARK: Motion

    /// A spring's numbers in SwiftUI's terms and in Reanimated's. The patch's Response is the
    /// period of the undamped spring and Damping its damping ratio (`Spring.step`), which are
    /// SwiftUI's `response` and `dampingFraction`; with a mass of 1 that is a stiffness of
    /// (2π / response)² and a damping of 4π · ratio / response.
    static func springCode(response: Double, damping: Double) -> [String: String] {
        let r = max(response, 0.01)
        let stiffness = pow(2 * Double.pi / r, 2)
        let friction = 4 * Double.pi * damping / r
        return [
            "swiftui": ".spring(response: \(Value.format(response)), dampingFraction: \(Value.format(damping)))",
            "reanimated": "withSpring(value, { mass: 1, stiffness: \(format(stiffness)), damping: \(format(friction)) })",
        ]
    }

    /// An easing's numbers. The patch's curves are cubic, so SwiftUI gets the matching
    /// timing curve and not its own, slightly different, ease.
    static func easingCode(duration: Double, curve: EasingCurve) -> [String: String] {
        let seconds = Value.format(duration)
        let milliseconds = Value.format((duration * 1000).rounded())
        let (swiftui, reanimated): (String, String) = switch curve {
        case .linear: (".linear(duration: \(seconds))", "Easing.linear")
        case .easeIn: (".timingCurve(0.55, 0.055, 0.675, 0.19, duration: \(seconds))", "Easing.in(Easing.cubic)")
        case .easeOut: (".timingCurve(0.215, 0.61, 0.355, 1, duration: \(seconds))", "Easing.out(Easing.cubic)")
        case .easeInOut: (".timingCurve(0.645, 0.045, 0.355, 1, duration: \(seconds))", "Easing.inOut(Easing.cubic)")
        }
        return ["swiftui": swiftui, "reanimated": "withTiming(value, { duration: \(milliseconds), easing: \(reanimated) })"]
    }

    private static func format(_ number: Double) -> String { Value.format((number * 10).rounded() / 10) }

    /// Every animation whose feel changed: its own numbers, or the values it moves between.
    private func motion(_ old: Side, _ new: Side, _ registry: PatchRegistry) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for node in new.graph.patches where node.kind == "spring" || node.kind == "easing" {
            let before = old.nodes[node.id]
            let drives = self.drives(node, in: new, registry)
            let drove = before.map { self.drives($0, in: old, registry) }
            guard before == nil || before?.inputs != node.inputs || drove != drives else { continue }

            func number(_ port: String, _ fallback: Double, of node: PatchNode) -> Double { node.inputs[port]?.numberValue ?? fallback }
            func numbers(of node: PatchNode) -> [String: String] {
                if node.kind == "spring" {
                    return Self.springCode(response: number("response", 0.4, of: node), damping: number("damping", 0.8, of: node))
                }
                let curve = EasingCurve(rawValue: node.inputs["curve"]?.textValue ?? "") ?? .easeInOut
                return Self.easingCode(duration: number("duration", 0.3, of: node), curve: curve)
            }

            var entry: [String: Any] = ["animation": title(node, in: new, registry), "kind": node.kind]
            entry["status"] = before == nil ? "new" : "changed"
            if let source = node.source { entry["source"] = source }
            entry["code"] = numbers(of: node)
            if let before, before.inputs != node.inputs { entry["code_before"] = numbers(of: before) }
            if !drives.isEmpty { entry["drives"] = drives }
            if let drove, drove != drives, !drove.isEmpty { entry["drove_before"] = drove }
            if let start = started(node, in: new, registry) { entry["started_by"] = start }
            out.append(entry)
        }
        return out
    }

    /// What an animation moves: each view property it reaches, straight or through a
    /// Transition, with the two values it goes between.
    private func drives(_ node: PatchNode, in side: Side, _ registry: PatchRegistry) -> [String] {
        var out: [String] = []
        for connection in side.graph.connections where connection.from.node == node.id && connection.from.port == "value" {
            guard let target = side.nodes[connection.to.node] else { continue }
            if target.kind == "transition", connection.to.port == "progress" {
                func value(_ port: String, _ fallback: Double) -> String {
                    switch target.inputs[port] ?? .number(fallback) {
                    case let .number(number): return Value.format(number)
                    case let .point(point): return "(\(Value.format(point.x)), \(Value.format(point.y)))"
                    case let .size(size): return "\(Value.format(size.width)) × \(Value.format(size.height))"
                    case let other: return "\(AssistantToolbox.plain(other))"
                    }
                }
                let range = "\(value("start", 0)) → \(value("end", 1))"
                let ends = side.graph.connections.filter { $0.from.node == target.id }
                out += ends.map { "\(end($0.to, in: side, registry)) \(range)" }
                if ends.isEmpty { out.append("\(title(target, in: side, registry)) \(range)") }
            } else {
                out.append("\(end(connection.to, in: side, registry)) 0 → 1")
            }
        }
        return out.sorted()
    }

    /// What sets an animation off: what feeds its target, and what feeds that.
    private func started(_ node: PatchNode, in side: Side, _ registry: PatchRegistry) -> String? {
        guard let cable = side.graph.connections.first(where: { $0.to.node == node.id && $0.to.port == "target" }),
              let source = side.nodes[cable.from.node] else { return nil }
        var text = end(cable.from, in: side, registry)
        let causes = side.graph.connections.filter { $0.to.node == source.id }.compactMap { feed -> String? in
            guard let origin = side.nodes[feed.from.node] else { return nil }
            let view = origin.kind == PatchKind.view ? nil : origin.layerID.flatMap { side.layers[$0] }?.name
            return "\(feed.to.port) from \(end(feed.from, in: side, registry))" + (view.map { " on \($0)" } ?? "")
        }
        if !causes.isEmpty { text += " (" + causes.sorted().joined(separator: "; ") + ")" }
        return text
    }
}

// MARK: The tools

extension AssistantToolbox {
    func markBaseline(_ input: [String: Any]) -> AssistantToolResult {
        store.markBaseline(source: (input["source"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        return AssistantToolResult(
            text: "The document as it is now is the starting point. get_changes reports what differs from it.",
            summary: "Marked the starting point"
        )
    }

    func changes(_ input: [String: Any]) -> AssistantToolResult {
        guard let report = SketchChanges(store: store).report(), let sketch = store.fullDocument.sketch else {
            return AssistantToolResult(
                text: "This document has no starting point. Call mark_baseline when the sketch matches the code; get_changes then reports what the person changes after that.",
                isError: true, summary: "No starting point to compare with"
            )
        }
        var images: [Data] = []
        var text = Self.json(report)
        if input["pictures"] as? Bool == true {
            let before = ViewerSnapshot.png(of: sketch.baseline.document, assets: store.assets, registry: store.runtimeRegistry)
            let after = ViewerSnapshot.png(of: store.fullDocument, assets: store.assets, registry: store.runtimeRegistry)
            images = [before, after].compactMap { $0 }
            if images.count == 2 { text += "\n\nImage 1 is the starting point, image 2 the sketch now. One pixel is one point." }
        }
        let count = SketchChanges.count(in: report)
        return AssistantToolResult(
            text: text, images: images,
            summary: count == 0 ? "Nothing has changed since the starting point" : "Read \(count) \(count == 1 ? "change" : "changes") since the starting point"
        )
    }

    /// The prototype beside a picture of the real thing, so differences can be seen in one look.
    func compare(_ input: [String: Any]) -> AssistantToolResult {
        func bad(_ message: String) -> AssistantToolResult {
            AssistantToolResult(text: message, isError: true, summary: "Could not compare the prototype")
        }
        guard let path = input["path"] as? String, !path.isEmpty else { return bad("Give \"path\": a PNG or JPEG file on this Mac to compare with.") }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard AssistantMediaLoader.canLoad(url), let image = NSImage(contentsOf: url),
              let reference = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return bad("No picture could be read at \(path).")
        }
        let tap = (input["tap"] as? [String: Any]).flatMap { at -> Point2? in
            guard let x = Self.number(at["x"]), let y = Self.number(at["y"]) else { return nil }
            return Point2(x: x, y: y)
        }
        let seconds = Self.number(input["seconds"]) ?? 0
        guard let prototype = ViewerSnapshot.bitmap(of: store.runtimeDocument, assets: store.assets, registry: store.runtimeRegistry, tap: tap, seconds: seconds),
              let shown = prototype.cgImage else { return bad("Could not draw the prototype.") }

        // The picture is scaled to the prototype's width, so a 3x screenshot lines up with it.
        let (width, height) = (prototype.pixelsWide, prototype.pixelsHigh)
        let scaledHeight = Int((Double(reference.height) * Double(width) / Double(max(reference.width, 1))).rounded())
        let gap = 16
        guard let both = Self.canvas(width: width * 2 + gap, height: max(height, scaledHeight)),
              let left = Self.canvas(width: width, height: height) else { return bad("Could not draw the comparison.") }
        let tall = max(height, scaledHeight)
        both.setFillColor(gray: 0.35, alpha: 1)
        both.fill(CGRect(x: 0, y: 0, width: width * 2 + gap, height: tall))
        // Core Graphics counts from the bottom; both pictures hang from the top.
        both.draw(reference, in: CGRect(x: 0, y: tall - scaledHeight, width: width, height: scaledHeight))
        both.draw(shown, in: CGRect(x: width + gap, y: tall - height, width: width, height: height))
        left.setFillColor(gray: 1, alpha: 1)
        left.fill(CGRect(x: 0, y: 0, width: width, height: height))
        left.draw(reference, in: CGRect(x: 0, y: height - scaledHeight, width: width, height: scaledHeight))
        guard let composed = both.makeImage(), let scaled = left.makeImage(),
              let png = NSBitmapImageRep(cgImage: composed).representation(using: .png, properties: [:]) else {
            return bad("Could not draw the comparison.")
        }

        let differing = Self.differing(scaled, shown)
        let size = store.runtimeDocument.screen.value(.size).sizeValue
        var text = "Left: the picture, scaled to the prototype's width. Right: the prototype, \(Value.format(size.width)) × \(Value.format(size.height)) points"
        if let tap { text += ", tapped at \(Value.format(tap.x)), \(Value.format(tap.y))" }
        if seconds > 0 { text += ", \(Value.format(seconds)) s later" }
        text += ". \(Value.format((differing * 1000).rounded() / 10))% of the pixels differ noticeably."
        if abs(scaledHeight - height) > 2 {
            text += " The picture's proportions differ from the screen's (\(reference.width) × \(reference.height) pixels), so compare from the top."
        }
        return AssistantToolResult(text: text, image: png, summary: "Compared the prototype with a picture")
    }

    private static func canvas(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0, width <= 8192, height <= 8192 else { return nil }
        return CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    /// The share of pixels whose color is clearly not the same in two pictures of one size.
    static func differing(_ first: CGImage, _ second: CGImage) -> Double {
        let (width, height) = (min(first.width, second.width), min(first.height, second.height))
        guard let a = canvas(width: width, height: height), let b = canvas(width: width, height: height) else { return 1 }
        a.draw(first, in: CGRect(x: 0, y: height - first.height, width: first.width, height: first.height))
        b.draw(second, in: CGRect(x: 0, y: height - second.height, width: second.width, height: second.height))
        guard let one = a.data, let two = b.data else { return 1 }
        let count = width * height * 4
        let (p, q) = (one.bindMemory(to: UInt8.self, capacity: count), two.bindMemory(to: UInt8.self, capacity: count))
        var different = 0
        for pixel in 0..<(width * height) {
            let at = pixel * 4
            let off = max(abs(Int(p[at]) - Int(q[at])), abs(Int(p[at + 1]) - Int(q[at + 1])), abs(Int(p[at + 2]) - Int(q[at + 2])))
            if off > 24 { different += 1 }
        }
        return Double(different) / Double(max(width * height, 1))
    }
}
