import AppKit
import Foundation
import Testing
import PaperEngine
import PaperModel
import PaperRender
@testable import PaperEditor

/// Documents built by chance, edit after edit, as a person or an agent might in a hurry,
/// with odd values thrown in. After every edit what must always hold is checked, and the
/// prototype is run and touched every few. A failure names its seed, so it can be run again.
///
/// To look harder: `TANGO_RANDOM_SEEDS=2000 swift test --filter RandomizedTests`.
/// To run one seed again: `TANGO_RANDOM_FIRST_SEED=415 TANGO_RANDOM_SEEDS=1`; add
/// `TANGO_RANDOM_TRACE=1` to print each seed as it starts (for a crash).
@MainActor
@Suite struct RandomizedTests {
    static var seeds: Range<UInt64> {
        let environment = ProcessInfo.processInfo.environment
        let count = environment["TANGO_RANDOM_SEEDS"].flatMap(UInt64.init) ?? 40
        let first = environment["TANGO_RANDOM_FIRST_SEED"].flatMap(UInt64.init) ?? 0
        return first..<(first + count)
    }

    @Test func editsKeepTheDocumentWhole() throws {
        for seed in Self.seeds {
            if ProcessInfo.processInfo.environment["TANGO_RANDOM_TRACE"] != nil { print("seed \(seed)"); fflush(stdout) }
            var chance = Chance(seed: seed)
            try Session(seed: seed).run(steps: 60, &chance)
        }
    }

    @Test func agentsSendingNonsenseChangeNothingThatBreaks() throws {
        var applied = 0, refused = 0
        for seed in Self.seeds {
            var chance = Chance(seed: seed &+ 10_000)
            let (made, failed) = try AgentSession(seed: seed).run(batches: 25, &chance)
            applied += made
            refused += failed
        }
        // Both sides are exercised: operations that work, and ones that are turned away.
        #expect(applied > 100 && refused > 100, "applied \(applied), refused \(refused)")
    }
}

// MARK: Chance

/// SplitMix64: small, fast, and the same everywhere for a seed.
struct Chance {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ range: Range<Int>) -> Int {
        guard range.count > 1 else { return range.lowerBound }
        return range.lowerBound + Int(next() % UInt64(range.count))
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func bool(_ odds: Double = 0.5) -> Bool { unit() < odds }

    mutating func pick<T>(_ items: [T]) -> T? {
        items.isEmpty ? nil : items[int(0..<items.count)]
    }

    /// Mostly ordinary numbers, sometimes the ones that break arithmetic.
    mutating func number() -> Double {
        if bool(0.7) { return (unit() * 800 - 200).rounded() }
        return pick([0, -0.0, 1, -1, 0.5, 1e-300, -1e-300, 1e15, -1e15, 1e300, -1e300,
                     Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude,
                     Double.leastNonzeroMagnitude, 9_007_199_254_740_992, 4_000_000])!
    }

    mutating func text() -> String {
        pick(["", "Hello", "a", "🙂👩‍👩‍👧‍👦", String(repeating: "long ", count: 400), "{\"a\": [1, 2]}", "[1,2,3]",
              "line\nline", "\u{0}", "https://example.com/x?y=1", "capture:1", "-1e309", "NaN", "   "])!
    }

    mutating func value(of type: PortType) -> Value {
        switch type {
        case .number: .number(number())
        case .bool: .bool(bool())
        case .pulse: .pulse(bool())
        case .text: .text(text())
        case .color: .color(ColorValue(red: unit(), green: unit(), blue: unit(), alpha: unit()))
        case .point: .point(Point2(x: number(), y: number()))
        case .size: .size(Size2(width: number(), height: number()))
        case .array: .array((0..<int(0..<6)).map { _ in .number(number()) })
        case .json: bool() ? .text(text()) : .object(["a": .number(number()), "b": .array([.text(text())])])
        }
    }
}

// MARK: Checks

/// Where two documents first differ, in words short enough to read in a failure.
@MainActor
func difference(_ a: PaperModel.Document, _ b: PaperModel.Document) -> String {
    var out: [String] = []
    let la = Dictionary(flattened(a.screen).map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
    let lb = Dictionary(flattened(b.screen).map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
    for id in Set(la.keys).symmetricDifference(lb.keys) { out.append("view \(la[id]?.name ?? lb[id]?.name ?? "?") only in one") }
    for (id, x) in la { guard let y = lb[id] else { continue }
        for key in Set(x.properties.keys).union(y.properties.keys) where x.properties[key] != y.properties[key] {
            out.append("\(x.name).\(key): \(String(describing: x.properties[key])) vs \(String(describing: y.properties[key]))")
        }
        if x.children.map(\.id) != y.children.map(\.id) { out.append("\(x.name) children differ") }
        if x.kind != y.kind || x.name != y.name { out.append("\(x.name) kind/name differ") }
        if x.component != y.component || x.shader != y.shader || x.custom != y.custom || x.scene != y.scene { out.append("\(x.name) settings differ") }
    }
    let na = Dictionary(a.graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
    let nb = Dictionary(b.graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
    for id in Set(na.keys).symmetricDifference(nb.keys) { out.append("patch \(na[id]?.kind ?? nb[id]?.kind ?? "?") only in one") }
    for (id, x) in na { guard let y = nb[id], x != y else { continue }; out.append("patch \(x.kind): \(x) vs \(y)") }
    if Set(a.graph.connections) != Set(b.graph.connections) { out.append("cables differ: \(Set(a.graph.connections).symmetricDifference(b.graph.connections))") }
    if a.graph.connections != b.graph.connections, Set(a.graph.connections) == Set(b.graph.connections) { out.append("cable order differs") }
    if a.graph.nodes.map(\.id) != b.graph.nodes.map(\.id), Set(na.keys) == Set(nb.keys) { out.append("patch order differs") }
    if a.components != b.components { out.append("components differ") }
    if a.graph.comments != b.graph.comments { out.append("comments differ") }
    return out.prefix(6).joined(separator: "; ")
}

@MainActor
func flattened(_ layer: Layer) -> [Layer] {
    [layer] + layer.children.flatMap(flattened)
}

/// What must hold of a document after any edit.
@MainActor
func checkWhole(_ store: DocumentStore, _ context: @autoclosure () -> String) throws {
    let document = store.fullDocument
    // Settling again changes nothing.
    var again = document
    again.normalize()
    store.registry.settlePublished(in: &again)
    #expect(again == document, "normalize is not idempotent: \(context()) — \(difference(document, again))")
    // One view patch per view, and every cable joins two patches that are there.
    let layers = flattened(document.screen)
    let viewPatches = document.graph.nodes.filter { $0.kind == PatchKind.view }
    #expect(viewPatches.count == layers.count, "view patches \(viewPatches.count) for \(layers.count) views: \(context())")
    let nodes = Set(document.graph.nodes.map(\.id))
    for connection in document.graph.connections {
        #expect(nodes.contains(connection.from.node) && nodes.contains(connection.to.node), "a cable to nowhere: \(context())")
    }
    // Every stored number can be saved, and saving and reading gives the same document.
    for layer in layers {
        for (property, value) in layer.properties where !value.isFinite {
            Issue.record("\(layer.name).\(property) is \(value): \(context())")
        }
    }
    let data = try JSONEncoder().encode(document)
    let read = try JSONDecoder().decode(PaperModel.Document.self, from: data)
    #expect(read == document, "saving and reading changed the document: \(context()) — \(difference(document, read))")
}

/// Runs the document for a moment, touching it, and checks what comes out.
@MainActor
func checkRuns(_ store: DocumentStore, _ chance: inout Chance, _ context: @autoclosure () -> String) {
    let document = store.fullDocument
    let runtime = Runtime(document: document, registry: store.runtimeRegistry)
    let size = document.screen.value(.size).sizeValue
    func somewhere(_ chance: inout Chance) -> Point2 {
        Point2(x: chance.unit() * max(size.width, 1), y: chance.unit() * max(size.height, 1))
    }
    var down = false
    for _ in 0..<40 {
        switch chance.int(0..<10) {
        case 0 where !down: runtime.send(.touchDown(somewhere(&chance))); down = true
        case 1 where down: runtime.send(.touchMoved(somewhere(&chance)))
        case 2 where down: runtime.send(.touchUp(somewhere(&chance))); down = false
        case 3: runtime.send(.text(chance.text()))
        case 4: runtime.send(.hover(chance.bool() ? somewhere(&chance) : nil))
        case 5: runtime.send(.pinchBegan(somewhere(&chance))); runtime.send(.pinchChanged(scale: chance.unit() * 3, rotation: chance.number()))
        case 6: runtime.send(.pinchEnded)
        // More fingers, in no order a hand would keep: lifted before they land, landed
        // twice, taken away.
        case 7:
            let id = chance.int(0..<3)
            switch chance.int(0..<5) {
            case 0, 1: runtime.send(.touchBegan(id: id, somewhere(&chance)))
            case 2: runtime.send(.touchChanged(id: id, somewhere(&chance)))
            case 3: runtime.send(.touchEnded(id: id, somewhere(&chance)))
            default: runtime.send(.touchCancelled(id: id))
            }
        case 8:
            for id in 0..<3 { runtime.send(.touchChanged(id: id, somewhere(&chance))) }
        default: break
        }
        runtime.tick(dt: chance.bool(0.1) ? 0.5 : 1.0 / 60.0)
    }
    for node in document.graph.nodes {
        for port in store.runtimeRegistry.ports(for: node).outputs {
            for value in runtime.outputValues(PortRef(node: node.id, port: port.id)) where !value.isFinite {
                Issue.record("\(node.kind).\(port.id) gave \(value): \(context())")
            }
        }
    }
    func walk(_ layer: ResolvedLayer) {
        for property in [LayerProperty.position, .size, .opacity, .scale, .rotation] {
            let value = layer.value(property)
            if !value.isFinite { Issue.record("\(layer.name).\(property) resolved to \(value): \(context())") }
        }
        layer.children.forEach(walk)
    }
    walk(runtime.resolved)
    // And it can be drawn, as the Viewer would.
    LayerRenderer().render(runtime.resolved)
}

// MARK: Editing by chance

@MainActor
struct Session {
    let seed: UInt64
    let store = DocumentStore()
    let undo = UndoManager()

    init(seed: UInt64) {
        self.seed = seed
        undo.groupsByEvent = false
        store.undoManager = undo
    }

    func step(_ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    var containers: [Layer] { flattened(store.document.screen).filter { $0.kind.canHaveChildren } }
    var views: [Layer] { flattened(store.document.screen).filter { $0.kind != .screen } }

    func run(steps: Int, _ chance: inout Chance) throws {
        let start = store.fullDocument
        var log: [String] = []
        var edits = 0
        for index in 0..<steps {
            let before = store.fullDocument
            let action = act(&chance)
            log.append(action)
            if ProcessInfo.processInfo.environment["TANGO_RANDOM_TRACE"] != nil { print("  \(index): \(action)"); fflush(stdout) }
            // Undo and redo of the edit just made return exactly to each side of it.
            let after = store.fullDocument
            if after != before, !action.hasPrefix("undo"), !action.hasPrefix("redo"), undo.canUndo {
                undo.undo()
                #expect(store.fullDocument == before, "undo of \(action) did not restore it: seed \(seed), step \(index) — \(difference(before, store.fullDocument))")
                undo.redo()
                #expect(store.fullDocument == after, "redo of \(action) did not repeat it: seed \(seed), step \(index) — \(difference(after, store.fullDocument))")
            }
            if action.hasPrefix("undo") { edits = max(0, edits - 1) } else if !action.hasPrefix("redo"), !action.hasPrefix("-") { edits += 1 }
            let context = "seed \(seed), step \(index): \(log.suffix(4).joined(separator: " / "))"
            try checkWhole(store, context)
            if index % 8 == 7 {
                if ProcessInfo.processInfo.environment["TANGO_RANDOM_TRACE"] != nil { print("  running"); fflush(stdout) }
                checkRuns(store, &chance, context)
            }
        }
        checkRuns(store, &chance, "seed \(seed), at the end")
        // Undoing everything gives back the empty document; redoing gives back the last
        // (with whatever the session itself undid redone first).
        while undo.canRedo { undo.redo() }
        let end = store.fullDocument
        while undo.canUndo { undo.undo() }
        #expect(store.fullDocument == start, "undoing everything did not return to the start: seed \(seed) — \(difference(start, store.fullDocument))")
        while undo.canRedo { undo.redo() }
        #expect(store.fullDocument == end, "redoing everything did not return to the end: seed \(seed) — \(difference(end, store.fullDocument))")
    }

    /// One edit, by chance. Returns what it was, for the failure message.
    func act(_ chance: inout Chance) -> String {
        let types = ViewType.allCases.filter { ![.screen, .component, .custom].contains($0) }
        switch chance.int(0..<19) {
        case 17:
            // Screens: a new one, one moved, one made a plain view again.
            let screens = store.screens
            switch chance.int(0..<4) {
            case 0, 1:
                step { store.addScreen() }
                return "add screen"
            case 2:
                guard let screen = chance.pick(screens) else { return "-" }
                let place = chance.int(0..<(screens.count + 1))
                step { store.moveScreen(screen.id, to: place) }
                return "move screen \(screen.name) to \(place)"
            default:
                guard let view = chance.pick(store.document.screen.children) else { return "-" }
                let makes = chance.bool()
                step { store.setScreen(view.id, makes) }
                return "set screen \(view.name) \(makes)"
            }
        case 18:
            // A flow from any view to any screen (or back); the store refuses what makes no sense.
            guard let from = chance.pick(store.document.screen.flattened) else { return "-" }
            let target = chance.bool(0.25) ? nil : chance.pick(store.screens)?.id
            let style = chance.pick(Navigation.Style.allCases)!
            var made: NodeID?
            step { made = store.addFlow(from: from.id, to: target, style: style) }
            return "flow from \(from.name) \(made == nil ? "(refused)" : style.rawValue)"
        case 0, 1, 2:
            guard let parent = chance.pick(containers), let type = chance.pick(types) else { return "-" }
            let layer = Layer.new(type, name: store.uniqueLayerName(type.displayName))
            step { store.apply("Add") { $0.screen.insert(layer, into: parent.id) } }
            return "add \(type) in \(parent.name)"
        case 3:
            guard let view = chance.pick(views) else { return "-" }
            step { store.apply("Delete") { $0.removeLayer(view.id) } }
            return "delete \(view.name)"
        case 4:
            guard let view = chance.pick(views), let parent = chance.pick(containers.filter { !view.contains($0.id) }) else { return "-" }
            step {
                store.apply("Move") { document in
                    guard let layer = document.screen.remove(view.id) else { return }
                    document.screen.insert(layer, into: parent.id, at: 0)
                }
            }
            return "move \(view.name) into \(parent.name)"
        case 5:
            guard let parent = chance.pick(containers), !parent.children.isEmpty else { return "-" }
            let some = parent.children.filter { _ in chance.bool() }
            guard !some.isEmpty else { return "-" }
            step { store.selectedLayers = Set(some.map(\.id)); store.groupSelectedLayers() }
            return "group \(some.count) in \(parent.name)"
        case 6:
            guard let group = chance.pick(views.filter { $0.kind == .view && !$0.children.isEmpty }) else { return "-" }
            step { store.ungroup(group.id) }
            return "ungroup \(group.name)"
        case 7:
            guard let view = chance.pick(views), let type = chance.pick(types) else { return "-" }
            step { store.convert(view.id, to: type) }
            return "change \(view.name) to \(type)"
        case 8, 9:
            guard let view = chance.pick(views), let property = chance.pick(LayerProperty.properties(for: view.type)) else { return "-" }
            let current = view.value(property)
            let value = chance.value(of: current.type)
            step { store.setProperty(property, of: view.id, to: value) }
            return "set \(view.name).\(property) to \(value)"
        case 10, 11:
            let kinds = store.registry.library.map(\.kind).filter { $0 != PatchKind.view && $0 != PatchKind.component }
            guard let kind = chance.pick(kinds) else { return "-" }
            if DocumentStore.touchPatchKinds.contains(kind) {
                let fits = views.filter { view in DocumentStore.viewKind(for: kind).map { view.kind == $0 } ?? true }
                guard let view = chance.pick(fits) else { return "-" }
                step { _ = store.addTouchPatch(kind, for: view.id) }
                return "attach \(kind) to \(view.name)"
            }
            step { _ = store.addPatch(kind) }
            return "add patch \(kind)"
        case 12, 13:
            let nodes = store.document.graph.nodes
            guard let from = chance.pick(nodes), let to = chance.pick(nodes),
                  let output = chance.pick(store.registry.ports(for: from).outputs),
                  let input = chance.pick(store.registry.ports(for: to).inputs) else { return "-" }
            var joined = false
            step { joined = store.connect(from: PortRef(node: from.id, port: output.id), to: PortRef(node: to.id, port: input.id)) }
            return "connect \(from.kind).\(output.id) to \(to.kind).\(input.id) \(joined ? "" : "(refused)")"
        case 14:
            guard let node = chance.pick(store.document.graph.nodes),
                  let input = chance.pick(store.registry.ports(for: node).inputs) else { return "-" }
            let value = chance.value(of: input.type)
            step { store.setLiteral(value, node: node.id, port: input.id) }
            return "literal \(node.kind).\(input.id) = \(value)"
        case 15:
            guard let node = chance.pick(store.document.graph.nodes) else { return "-" }
            step {
                store.selectedNodes = [node.id]
                if chance.bool(0.3) { store.duplicateSelectedPatches() } else { store.deleteSelectedPatches() }
            }
            return "delete or duplicate \(node.kind)"
        default:
            if chance.bool(0.6), undo.canUndo { undo.undo(); return "undo" }
            if undo.canRedo { undo.redo(); return "redo" }
            guard let node = chance.pick(store.document.graph.nodes), store.publishTarget(for: PortRef(node: node.id, port: "")) != nil else { return "-" }
            let ports = store.registry.ports(for: node)
            let output = chance.bool()
            guard let port = chance.pick(output ? ports.outputs : ports.inputs) else { return "-" }
            step { _ = store.publish(PortRef(node: node.id, port: port.id), output: output) }
            return "publish \(node.kind).\(port.id)"
        }
    }
}

// MARK: Agents by chance

/// Batches made of real operation names with fields filled by chance: names of views and
/// patches that exist, ones that do not, numbers far out of range, wrong types.
@MainActor
struct AgentSession {
    let seed: UInt64
    let store = DocumentStore()
    let undo = UndoManager()

    init(seed: UInt64) {
        self.seed = seed
        undo.groupsByEvent = false
        store.undoManager = undo
    }

    static let operations = [
        "add_view", "set_properties", "rename_view", "delete_view", "move_view", "group_views", "add_patch",
        "set_inputs", "set_type", "rename_patch", "delete_patch", "connect", "disconnect", "publish_port",
        "unpublish_port", "rename_port", "open_view", "change_view", "set_ports", "add_comment", "insert_component", "add_flow",
    ]

    /// How many operations were applied and how many refused.
    func run(batches: Int, _ chance: inout Chance) throws -> (applied: Int, refused: Int) {
        var applied = 0, refused = 0
        let toolbox = AssistantToolbox(store: store)
        for index in 0..<batches {
            let operations = (0..<chance.int(1..<6)).map { _ in operation(&chance) }
            let before = store.fullDocument
            undo.beginUndoGrouping()
            let result = toolbox.call("edit_document", input: ["operations": operations])
            undo.endUndoGrouping()
            let answer = (try? JSONSerialization.jsonObject(with: Data(result.text.utf8))) as? [String: Any] ?? [:]
            applied += answer["applied"] as? Int ?? 0
            refused += (answer["errors"] as? [Any])?.count ?? 0
            let context = "agent seed \(seed), batch \(index): \(operations.map { $0["op"] as? String ?? "?" })"
            try checkWhole(store, context)
            if index % 6 == 5 { checkRuns(store, &chance, context) }
            // One batch is one undo step.
            if store.fullDocument != before, chance.bool(0.2) {
                undo.undo()
                #expect(store.fullDocument == before, "undoing a batch did not restore it: \(context)")
            }
            // Reading the document back always works.
            #expect(!toolbox.call("get_document", input: [:]).text.isEmpty)
        }
        return (applied, refused)
    }

    func reference(_ chance: inout Chance) -> Any {
        let layers = flattened(store.document.screen)
        let nodes = store.document.graph.nodes
        switch chance.int(0..<6) {
        case 0, 1: return chance.pick(layers)?.name ?? "Screen"
        case 2: return chance.pick(nodes).map { store.title(for: $0) } ?? "nothing"
        case 3: return chance.pick(layers).map { String($0.id.uuidString.prefix(8)).lowercased() } ?? "0"
        case 4: return chance.pick(["", "Screen", "A", "x", "deadbeef", "Nope"])!
        default: return chance.pick([42, -1, 1e300, ["a"], ["view": "A"]] as [Any])!
        }
    }

    func operation(_ chance: inout Chance) -> [String: Any] {
        let op = chance.pick(Self.operations)!
        var operation: [String: Any] = ["op": op]
        let kinds = ViewType.allCases.map(\.rawValue) + ["nonsense", "screen"]
        let patchKinds = store.registry.library.map(\.kind) + ["view", "scroll", "nope/nope"]
        let properties = LayerProperty.allCases.map(\.rawValue) + ["x", "y", "width", "height", "nope"]
        func value(_ chance: inout Chance) -> Any {
            switch chance.int(0..<6) {
            case 0: return chance.number()
            case 1: return chance.text()
            case 2: return chance.bool()
            case 3: return [chance.number(), chance.number()]
            case 4: return ["x": chance.number(), "y": chance.number()]
            default: return ["red": chance.unit(), "green": 2, "blue": -1]
            }
        }
        for key in ["view", "patch", "parent", "from", "to", "inside"] where chance.bool(0.5) {
            operation[key] = reference(&chance)
        }
        if chance.bool(0.6) { operation["kind"] = chance.bool(0.5) ? chance.pick(kinds)! : chance.pick(patchKinds)! }
        if chance.bool(0.5) { operation["name"] = chance.text() }
        if op == "add_flow" {
            if chance.bool(0.5) { operation["style"] = chance.pick(["Push", "modal", "Fade", "Switch", "Spin"])! }
            if chance.bool(0.3) { operation["back"] = chance.bool() }
        }
        if chance.bool(0.5) {
            operation["properties"] = Dictionary((0..<chance.int(1..<4)).map { _ in (chance.pick(properties)!, value(&chance)) }, uniquingKeysWith: { a, _ in a })
        }
        if chance.bool(0.4) {
            let ports = store.document.graph.nodes.flatMap { store.registry.ports(for: $0).inputs.map(\.id) }
            operation["inputs"] = Dictionary((0..<chance.int(1..<4)).map { _ in (chance.pick(ports) ?? "value", value(&chance)) }, uniquingKeysWith: { a, _ in a })
        }
        if chance.bool(0.5) { operation["output"] = chance.pick(["value", "tap", "frameX", "offset", "nope", "Value"])! }
        if chance.bool(0.5) { operation["input"] = chance.pick(["value", "opacity", "x", "position", "text", "nope", "Scale"])! }
        if chance.bool(0.3) { operation["views"] = (0..<chance.int(0..<4)).map { _ in reference(&chance) } }
        if chance.bool(0.2) { operation["index"] = chance.number() }
        if chance.bool(0.2) { operation["position"] = ["x": chance.number(), "y": chance.number()] }
        if chance.bool(0.2) { operation["type"] = chance.pick(PortType.allCases.map(\.rawValue) + ["nope"])! }
        if chance.bool(0.2) { operation["ports"] = [chance.pick(properties)!] }
        if chance.bool(0.2) { operation["component"] = chance.pick(["Button", "Switch", "nope"])! }
        return operation
    }
}
