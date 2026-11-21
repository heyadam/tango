import AppKit
import Foundation
import Testing
import PaperEngine
import PaperModel
import PaperRender
@testable import PaperEditor

/// What an agent's edits must get right even when the request is odd. Found in QA.
@MainActor
@Suite struct AgentEditTests {
    private func edit(_ store: DocumentStore, _ operations: [[String: Any]]) -> (applied: Int, errors: [String], created: [String: String]) {
        let result = AssistantToolbox(store: store).call("edit_document", input: ["operations": operations])
        let answer = (try? JSONSerialization.jsonObject(with: Data(result.text.utf8))) as? [String: Any] ?? [:]
        return (
            answer["applied"] as? Int ?? 0,
            (answer["errors"] as? [[String: Any]] ?? []).compactMap { $0["error"] as? String },
            answer["created"] as? [String: String] ?? [:]
        )
    }

    /// The batch the reference shows for screens is run as written, and then played.
    @Test func theReferenceExampleBuildsTwoScreensAndTheWayThereAndBack() throws {
        let store = DocumentStore()
        let operations = try #require(try JSONSerialization.jsonObject(with: Data(AssistantPrompt.flowExample.utf8)) as? [[String: Any]])
        #expect(edit(store, operations).errors == [])
        #expect(store.screens.map(\.name) == ["Home", "Detail"])
        #expect(store.screens[0].children.map(\.name) == ["Open"])
        let flows = store.flows
        #expect(flows.count == 2)
        #expect(flows.contains { $0.target == store.screens[1].id && $0.style == .push })
        #expect(flows.contains { $0.target == nil && $0.source == store.screens[1].children[0].id })

        // What an agent reads back names the screens and the flows.
        let described = AssistantToolbox(store: store).describe()
        #expect((described["flows"] as? [[String: Any]])?.count == 2)
        let views = try #require((described["views"] as? [String: Any])?["children"] as? [[String: Any]])
        #expect(views.allSatisfy { $0["screen"] as? Bool == true })

        let runtime = Runtime(document: store.document, registry: store.runtimeRegistry)
        func tap(_ x: Double, _ y: Double) {
            runtime.send(.touchBegan(id: 0, Point2(x: x, y: y)))
            runtime.tick(dt: 1.0 / 60)
            runtime.send(.touchEnded(id: 0, Point2(x: x, y: y)))
            for _ in 0..<300 where runtime.needsAnotherFrame { runtime.tick(dt: 1.0 / 60) }
        }
        runtime.tick(dt: 1.0 / 60)
        tap(200, 428)
        #expect(runtime.navigation.current == store.screens[1].id)
        tap(60, 86)
        #expect(runtime.navigation.current == store.screens[0].id)

        // What cannot be a flow says why.
        #expect(!edit(store, [["op": "add_flow", "from": "Open", "to": "Back"]]).errors.isEmpty)
        #expect(!edit(store, [["op": "add_flow", "from": "Open"]]).errors.isEmpty)
        #expect(!edit(store, [["op": "add_flow", "from": "Open", "to": "Detail", "style": "Spin"]]).errors.isEmpty)
        #expect(!edit(store, [["op": "add_patch", "kind": "navigate", "view": "Open"]]).errors.isEmpty)
        #expect(edit(store, [["op": "add_patch", "kind": "navigate", "view": "Detail", "inputs": ["style": "Fade"]]]).errors.isEmpty)
    }

    @Test func aShortNameIsNotTakenForTheStartOfAnId() throws {
        let store = DocumentStore()
        // Layers whose ids start with every hex digit, so any one-letter name could collide.
        var screen = store.document.screen
        for digit in "0123456789abcdef" {
            let id = UUID(uuidString: "\(digit)1111111-1111-1111-1111-111111111111")!
            screen.children.append(Layer(id: id, name: "Card \(digit)", kind: .view))
        }
        screen.children.append(Layer(name: "A", kind: .view))
        store.apply("Setup") { $0.screen = screen }

        let result = edit(store, [["op": "set_properties", "view": "A", "properties": ["opacity": 0.25]]])
        #expect(result.errors.isEmpty)
        let named = try #require(store.document.screen.children.first { $0.name == "A" })
        #expect(named.value(.opacity).numberValue == 0.25)
        #expect(store.document.screen.children.filter { $0.value(.opacity).numberValue != 1 }.count == 1)
        // A full short id still works; a fragment of one does not.
        #expect(edit(store, [["op": "rename_view", "view": "a1111111", "name": "Renamed"]]).errors.isEmpty)
        #expect(!edit(store, [["op": "rename_view", "view": "b111", "name": "Nope"]]).errors.isEmpty)
    }

    @Test func aShortPatchNameIsNotTakenForTheStartOfAnId() throws {
        let store = DocumentStore()
        var graph = store.document.graph
        for digit in "0123456789abcdef" {
            graph.add(PatchNode(id: UUID(uuidString: "\(digit)1111111-1111-1111-1111-111111111111")!, kind: "add", name: "Sum \(digit)"))
        }
        let named = graph.add(PatchNode(kind: "add", name: "A"))
        store.apply("Setup") { $0.graph = graph }
        #expect(edit(store, [["op": "rename_patch", "patch": "A", "name": "Renamed"]]).errors.isEmpty)
        #expect(store.document.graph.node(named)?.name == "Renamed")
        #expect(store.document.graph.nodes.filter { $0.name?.hasPrefix("Sum") == true }.count == 16)
    }

    @Test func headersCanBeGivenAsAnObject() throws {
        let store = DocumentStore()
        let result = edit(store, [["op": "add_patch", "kind": "networkRequest", "ref": "fetch",
                                   "inputs": ["headers": ["Accept": "application/json"], "url": "https://example.com"]]])
        #expect(result.errors.isEmpty)
        let node = try #require(store.document.graph.nodes.first { $0.kind == "networkRequest" })
        #expect(node.inputs["headers"] == .text(#"{"Accept":"application/json"}"#))
    }

    @Test func layersInDifferentPlacesAreNotHalfGrouped() {
        let store = DocumentStore()
        _ = edit(store, [
            ["op": "add_view", "kind": "view", "name": "G1", "ref": "g"],
            ["op": "add_view", "kind": "view", "name": "Inner", "parent": "g"],
            ["op": "add_view", "kind": "view", "name": "Outer"],
        ])
        let before = store.document
        let result = edit(store, [["op": "group_views", "views": ["Inner", "Outer"], "name": "Both"]])
        #expect(result.errors.first?.contains("same view") == true)
        #expect(store.document == before)
        // The interface's own Group refuses the same selection.
        store.selectedLayers = Set(store.document.screen.flattened.filter { ["Inner", "Outer"].contains($0.name) }.map(\.id))
        store.groupSelectedLayers()
        #expect(store.document == before)
        #expect(edit(store, [["op": "group_views", "views": ["G1", "Outer"], "name": "Both"]]).errors.isEmpty)
    }

    @Test func aStepThatFailsLeavesNothingBehind() {
        let store = DocumentStore()
        let before = store.document
        let result = edit(store, [
            ["op": "insert_component", "component": "Toggle", "parent": "Nope"],
            ["op": "add_patch", "kind": "spring", "inputs": ["nonsense": 3]],
            ["op": "add_patch", "kind": "spring", "type": "color"],
            ["op": "add_patch", "kind": "value", "script": "hello"],
            ["op": "add_patch", "kind": "javascript", "ref": "js", "script": "inputs = {a: 0}; outputs = {r: 0}; function evaluate(i, o) { o.r = i.a +  }"],
        ])
        #expect(result.applied == 0)
        #expect(result.errors.count == 5)
        #expect(result.errors.last?.contains("SyntaxError") == true)
        #expect(store.document.graph.patches.isEmpty)
        #expect(store.document.screen == before.screen)

        // A script that loops for ever is refused the same way, and promptly.
        let started = Date()
        let forever = edit(store, [["op": "add_patch", "kind": "javascript", "script": "while (true) {}"]])
        #expect(forever.errors.first?.contains("too long") == true)
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(store.document.graph.patches.isEmpty)

        // A bad replacement script keeps the working one, and its cables.
        let good = "inputs = {a: 0}; outputs = {r: 0}; function evaluate(i, o) { o.r = i.a * 2; }"
        _ = edit(store, [
            ["op": "add_view", "kind": "view", "name": "Box"],
            ["op": "add_patch", "kind": "javascript", "ref": "js", "script": good],
            ["op": "connect", "from": "js", "output": "r", "to": "Box", "input": "opacity"],
        ])
        let cables = store.document.graph.connections.count
        #expect(cables == 1)
        #expect(!edit(store, [["op": "set_script", "patch": "JavaScript", "script": "function evaluate( {"]]).errors.isEmpty)
        #expect(store.document.graph.nodes.first { $0.kind == PatchKind.javascript }?.script == good)
        #expect(store.document.graph.connections.count == cables)
    }

    @Test func anObjectWithXAndYStaysAnObjectWhereJSONIsWanted() throws {
        #expect(try AssistantToolbox.value(["x": 10, "y": 20, "label": "pin"], as: .json)
            == .object(["x": .number(10), "y": .number(20), "label": .text("pin")]))
        #expect(try AssistantToolbox.value(["x": 10, "y": 20], as: .point) == .point(Point2(x: 10, y: 20)))
        #expect(try AssistantToolbox.value(["width": 3, "height": 4], as: .size) == .size(Size2(width: 3, height: 4)))
    }

    @Test func aDeletedViewCannotBeUsedAndTheOldPatchKindsSayWhatToDoInstead() {
        let store = DocumentStore()
        let result = edit(store, [
            ["op": "add_view", "kind": "view", "name": "Box", "ref": "r"],
            ["op": "add_view", "kind": "view", "name": "Other", "ref": "o"],
            ["op": "delete_view", "view": "r"],
            ["op": "add_patch", "kind": "interaction", "view": "r"],
            ["op": "rename_view", "view": "r", "name": "Ghost"],
            ["op": "add_patch", "kind": "layer.property", "view": "o"],
            ["op": "add_patch", "kind": "scroll", "view": "o"],
            ["op": "set_inputs", "patch": "o", "inputs": ["opacity": 0.2]],
        ])
        #expect(result.errors.count == 5)
        #expect(result.errors[0].contains("was deleted"))
        #expect(result.errors[2].contains("already a patch"))
        #expect(result.errors[3].contains("scrollView"))
        #expect(result.errors[4].contains("set_properties"))
        #expect(store.document.graph.patches.isEmpty)
    }

    @Test func patchesGoOnTheGridAndALoopOfCablesDoesNotScatterThem() {
        let store = DocumentStore()
        var operations: [[String: Any]] = [
            ["op": "add_patch", "kind": "value", "type": "number", "position": ["x": 101, "y": 57]],
            ["op": "add_patch", "kind": "add", "ref": "sum"],
            ["op": "add_patch", "kind": "delay", "ref": "wait"],
            ["op": "connect", "from": "sum", "output": "result", "to": "wait", "input": "value"],
            ["op": "connect", "from": "wait", "output": "value", "to": "sum", "input": "a"],
        ]
        for index in 0..<8 { operations.append(["op": "add_patch", "kind": "not", "ref": "n\(index)"]) }
        let result = edit(store, operations)
        #expect(result.errors.isEmpty)
        for node in store.document.graph.nodes { #expect(node.position == PatchGrid.snap(node.position)) }
        let columns = Set(store.document.graph.nodes.filter { $0.kind != "value" }.map(\.position.x))
        // The counter loop takes two columns, not eleven.
        #expect(columns.count == 2)
    }

    @Test func aBroadcastStaysOutsideANewComponentSoItsListenersStillHear() throws {
        let button = Layer(name: "Button", kind: .view)
        let light = Layer(name: "Light", kind: .view, properties: [
            .position: .point(Point2(x: 0, y: 300)), .opacity: .number(0),
        ])
        var screen = Layer(name: "Screen", kind: .screen)
        screen.children = [button, light]
        var b = SampleDocuments.Builder(screen: screen)
        let touch = b.interaction(on: button.id, at: .zero)
        let send = b.add("broadcast", at: Point2(x: 240, y: 0), type: .bool, inputs: ["name": .text("on")])
        let receive = b.add("receive", at: Point2(x: 0, y: 240), type: .bool, inputs: ["name": .text("on")])
        let opacity = b.property(.opacity, of: light.id, at: Point2(x: 240, y: 240))
        b.connect(touch, "down", to: send, "value")
        b.connect(receive, "value", to: opacity, "value")
        let store = DocumentStore(package: DocumentPackage(document: b.document))

        func lightWhilePressed() -> Double {
            let runtime = Runtime(document: store.runtimeDocument, registry: store.registry)
            runtime.tick(dt: 1.0 / 60.0)
            runtime.send(.touchDown(Point2(x: 50, y: 50)))
            runtime.advance(seconds: 0.1)
            return runtime.resolved.find(light.id)?.opacity ?? -1
        }
        #expect(lightWhilePressed() == 1)
        store.selectedLayers = [button.id]
        #expect(store.createComponentFromSelection() != nil)
        #expect(store.document.graph.nodes.contains { $0.kind == "broadcast" })
        #expect(lightWhilePressed() == 1)
    }

    @Test func aLayerWithGeometryThatIsNotANumberIsStillDrawn() {
        let box = Layer(name: "Box", kind: .view, properties: [
            .position: .point(Point2(x: .nan, y: .infinity)), .size: .size(Size2(width: .nan, height: 40)),
            .scale: .number(.nan), .rotation: .number(.infinity), .opacity: .number(.nan),
        ])
        var screen = Layer(name: "Screen", kind: .screen)
        screen.children = [box]
        let renderer = LayerRenderer()
        renderer.render(ResolvedLayer(screen))
        #expect(renderer.layer(for: box.id) != nil)
    }

    // MARK: Views as patches

    @Test func anAgentBuildsAScrollingListInViewWordsAndWiresItsOffset() throws {
        let store = DocumentStore()
        let result = edit(store, [
            ["op": "add_view", "kind": "scrollView", "name": "List", "ref": "list", "properties": [
                "x": 0, "y": 100, "width": 390, "height": 744, "spacing": 8, "paddingHorizontal": 16, "paddingVertical": 12,
            ]],
            ["op": "add_view", "kind": "view", "name": "Row A", "parent": "list", "properties": ["height": 300, "widthMode": "Grow", "fill": "#FFFFFF"]],
            ["op": "add_view", "kind": "view", "name": "Row B", "parent": "list", "properties": ["height": 300, "widthMode": "Grow"]],
            ["op": "add_view", "kind": "view", "name": "Row C", "parent": "list", "properties": ["height": 300, "widthMode": "Grow"]],
            ["op": "add_view", "kind": "text", "name": "Title", "ref": "title", "properties": ["x": 16, "y": 50, "text": "Inbox"]],
            ["op": "add_patch", "kind": "progress", "ref": "fade", "inputs": ["start": -60, "end": 0]],
            ["op": "connect", "from": "list", "output": "offset", "to": "fade", "input": "value"],
            ["op": "connect", "from": "fade", "output": "progress", "to": "title", "input": "opacity"],
        ])
        #expect(result.errors.isEmpty)
        let list = try #require(store.document.screen.children.first)
        #expect(list.type == .scrollView)
        #expect(list.value(.position) == .point(Point2(x: 0, y: 100)))
        #expect(list.value(.size) == .size(Size2(width: 390, height: 744)))
        #expect(list.children.map(\.name) == ["Row A", "Row B", "Row C"])
        // A new view is gray unless told otherwise.
        #expect(list.children[1].value(.fill) == .color(Layer.viewFill))

        // It scrolls, and the title fades with it.
        let runtime = Runtime(document: store.document)
        runtime.tick(dt: 1 / 60)
        let title = try #require(store.document.screen.children.last)
        #expect(runtime.resolved.find(title.id)?.opacity == 1)
        runtime.send(.touchDown(Point2(x: 195, y: 500)))
        runtime.tick(dt: 1 / 60)
        runtime.send(.touchMoved(Point2(x: 195, y: 460)))
        runtime.tick(dt: 1 / 60)
        // The first row started at the padding, 12, and went up with the finger.
        let firstRow = try #require(runtime.resolved.find(list.children[0].id))
        #expect(abs(firstRow.position.y + 18) < 1e-9)
        #expect(runtime.resolved.find(title.id)?.opacity == 0.5)

        // What it reads back: one tree of views, kinds as built, x and y as numbers, and
        // cables that name a view by the view's own id.
        let described = AssistantToolbox(store: store).describe()
        let views = try #require(described["views"] as? [String: Any])
        #expect(views["kind"] as? String == "screen")
        let first = try #require((views["children"] as? [[String: Any]])?.first)
        #expect(first["kind"] as? String == "scrollView")
        #expect((first["properties"] as? [String: Any])?["y"] as? Double == 100)
        #expect((first["properties"] as? [String: Any])?["layout"] == nil)
        #expect((first["out"] as? [String])?.first == "offset: number")
        let patches = try #require(described["patches"] as? [[String: Any]])
        #expect(patches.map { $0["kind"] as? String } == ["progress"])
        let cables = try #require(described["cables"] as? [String])
        #expect(cables.contains("\(AssistantToolbox.short(list.id)).offset -> \(patches[0]["id"] as! String).value"))
        #expect(cables.contains("\(patches[0]["id"] as! String).progress -> \(AssistantToolbox.short(title.id)).opacity"))
    }

    @Test func aViewChangesKindItsPortsAreChosenAndWrongInputsAreRefused() throws {
        let store = DocumentStore()
        _ = edit(store, [
            ["op": "add_view", "kind": "view", "name": "Box", "ref": "box"],
            ["op": "add_view", "kind": "text", "name": "Label", "parent": "box"],
            ["op": "add_patch", "kind": "spring", "ref": "spring"],
        ])
        let box = try #require(store.document.screen.children.first)

        let changed = edit(store, [
            ["op": "change_view", "view": "Box", "kind": "stack"],
            ["op": "set_properties", "view": "Box", "properties": ["axis": "Horizontal", "distribution": "Space Between"]],
            ["op": "set_ports", "view": "Box", "show": ["scale"], "hide": ["fill"]],
            ["op": "connect", "from": "Spring Animation", "output": "value", "to": "Box", "input": "Scale"],
        ])
        #expect(changed.errors.isEmpty)
        #expect(store.document.layer(box.id)?.type == .stack)
        #expect(store.document.layer(box.id)?.value(.axis) == .text("Horizontal"))
        #expect(store.document.layer(box.id)?.children.count == 1)
        let patch = try #require(store.viewNode(for: box.id))
        #expect(patch.shownPorts?.contains("scale") == true)
        #expect(patch.shownPorts?.contains("fill") == false)
        #expect(store.document.graph.connection(into: PortRef(node: patch.id, port: "scale")) != nil)

        // Text cannot become a stack, a stack has no columns to cable, and a plain view
        // has no outputs to take a cable from.
        let refused = edit(store, [
            ["op": "change_view", "view": "Label", "kind": "stack"],
            ["op": "connect", "from": "Spring Animation", "output": "value", "to": "Box", "input": "columns"],
            ["op": "connect", "from": "Box", "output": "offset", "to": "Spring Animation", "input": "target"],
            ["op": "set_properties", "view": "Label", "properties": ["spacing": 4]],
            ["op": "add_view", "kind": "rectangle"],
        ])
        #expect(refused.errors.count == 5)
        #expect(refused.errors[4].contains("scrollView"))
        // The reference an agent reads names what the tools take.
        let reference = AssistantPrompt.reference(registry: store.registry, components: [])
        for word in ["add_view", "change_view", "scrollView", "paddingHorizontal", "distribution", "\"to\":\"card\",\"input\":\"height\""] {
            #expect(reference.contains(word), "\(word)")
        }
        for word in ["add_layer", "layer.property", "artboard", "`scroll`"] {
            #expect(!reference.contains(word), "\(word)")
        }
    }

    /// The batches the reference shows an agent are run as written, so they cannot go stale.
    @Test func theReferenceExamplesBuildAViewWithAPublishedPort() throws {
        func operations(_ text: String) throws -> [[String: Any]] {
            try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        }
        let store = DocumentStore()
        #expect(edit(store, try operations(AssistantPrompt.tapExample)).errors == [])
        #expect(edit(store, try operations(AssistantPrompt.publishExample)).errors == [])
        #expect(edit(store, try operations(AssistantPrompt.shaderExample)).errors == [])
        let glow = try #require(store.document.screen.children.first { $0.name == "Glow" })
        #expect(glow.type == .shader && glow.shader?.inputs["tint"] == .color(ColorValue(hex: "#3D7BF7")!))
        #expect(store.document.graph.connection(into: PortRef(node: try #require(store.viewNode(for: glow.id)).id, port: "shader.amount")) != nil)

        let card = try #require(store.document.screen.children.first { $0.name == "Card" })
        let patch = try #require(store.viewNode(for: card.id))
        let pressed = try #require(patch.published?.first)
        #expect(pressed.name == "Pressed" && pressed.isOutput)
        let open = try #require(store.document.graph.patches.first { $0.kind == "switch" })
        #expect(store.document.graph.connection(into: PortRef(node: open.id, port: "flip"))?.from == PortRef(node: patch.id, port: pressed.id))
        // The touch on the button is kept inside the card, and the batch left the person there.
        #expect(store.openView == card.id)
        #expect(store.levelGraph.nodes.contains { $0.kind == PatchKind.interaction && $0.layerID == card.children.first?.id })

        // What the agent reads back says where the person is and what the card publishes.
        let read = AssistantToolbox(store: store).call("get_document", input: [:])
        let answer = try #require(try JSONSerialization.jsonObject(with: Data(read.text.utf8)) as? [String: Any])
        #expect(answer["open_view"] as? String == AssistantToolbox.short(card.id))
        #expect(read.text.contains("Pressed"))

        // The button opens the card.
        let runtime = Runtime(document: store.runtimeDocument, registry: store.registry)
        runtime.advance(seconds: 0.1)
        runtime.send(.touchDown(Point2(x: 120, y: 342)))
        runtime.advance(seconds: 0.05)
        runtime.send(.touchUp(Point2(x: 120, y: 342)))
        runtime.advance(seconds: 2)
        #expect((runtime.resolved.find(card.id)?.size.height ?? 0) > 500)

        // A published port holds no value: the error says where to set it.
        #expect(edit(store, [["op": "open_view", "view": "screen"]]).errors == [])
        #expect(store.openView == nil)
        #expect(edit(store, [["op": "open_view", "view": "Open"]]).errors.count == 1)
        _ = edit(store, [["op": "publish_port", "view": "Button", "input": "opacity", "name": "Dim"]])
        let refused = edit(store, [["op": "set_properties", "view": "Card", "properties": ["Dim": 0.5]]])
        #expect(refused.errors.first?.contains("Button") == true)

        // Published again one level out, it is still known by names, never by an id.
        _ = edit(store, [
            ["op": "group_views", "views": ["Card"], "name": "Page"],
            ["op": "publish_port", "view": "Card", "input": "Dim", "name": "Dim"],
        ])
        let further = edit(store, [["op": "set_properties", "view": "Page", "properties": ["Dim": 0.5]]])
        #expect(further.errors.first?.contains("\"opacity\" of Button") == true)
        let again = AssistantToolbox(store: store).call("get_document", input: [:]).text
        let dim = try #require(store.viewNode(for: card.id)?.published?.last)
        #expect(!again.contains(pressed.id) && !again.contains(dim.id))
    }

    @Test func theReferenceCoversViewsInsideViews() {
        let reference = AssistantPrompt.reference(registry: .standard, components: [])
        let operations = [
            "add_view", "set_properties", "rename_view", "delete_view", "move_view", "change_view", "group_views",
            "insert_component", "set_component_inputs", "set_ports", "publish_port", "unpublish_port", "rename_port",
            "open_view", "add_patch", "set_inputs", "set_type", "rename_patch", "delete_patch", "set_script",
            "connect", "disconnect", "add_comment", "restart_prototype",
        ]
        for word in operations + ["# Views inside views", "# Reading get_document", "`inside`", "`published`", "open_view", "\"output\":\"Pressed\""] {
            #expect(reference.contains(word), "\(word)")
        }
        #expect(AgentServer.instructions.contains("publish_port"))
    }
}
