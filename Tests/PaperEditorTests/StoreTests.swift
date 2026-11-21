import Foundation
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

@MainActor
@Suite struct StoreTests {
    func makeStore() -> (DocumentStore, UndoManager) {
        let store = DocumentStore()
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        return (store, undo)
    }

    func step(_ undo: UndoManager, _ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    @Test func editsAreUndoable() {
        let (store, undo) = makeStore()
        var id: LayerID!
        step(undo) { id = store.addLayer(.view, frame: CGRect(x: 10, y: 20, width: 100, height: 50)) }
        #expect(store.document.layer(id)?.value(.position) == .point(Point2(x: 10, y: 20)))
        #expect(store.selectedLayers == [id])
        undo.undo()
        #expect(store.document.screen.children.isEmpty)
        #expect(store.selectedLayers.isEmpty)
        undo.redo()
        #expect(store.document.layer(id) != nil)
    }

    @Test func aDragIsOneUndoStep() {
        let (store, undo) = makeStore()
        var id: LayerID!
        step(undo) { id = store.addLayer(.view, frame: CGRect(x: 0, y: 0, width: 10, height: 10)) }
        step(undo) {
            for x in 1...20 {
                store.setProperty(.position, of: id, to: .point(Point2(x: Double(x), y: 0)), interactive: true)
            }
            store.endInteractive("Move")
        }
        #expect(store.document.layer(id)?.value(.position) == .point(Point2(x: 20, y: 0)))
        undo.undo()
        #expect(store.document.layer(id)?.value(.position) == .point(.zero))
    }

    @Test func buildingTheCardInteractionThroughStoreCommands() {
        // The same steps a person takes in the interface for spec example A.
        let store = DocumentStore()
        let card = store.addLayer(.view, frame: CGRect(x: 40, y: 320, width: 310, height: 200))
        let touch = store.addInteraction(for: card)
        let toggle = store.addPatch("switch")
        let spring = store.addPatch("spring")
        let size = store.addPatch("transition")
        #expect(store.connect(from: PortRef(node: touch, port: "tap"), to: PortRef(node: toggle, port: "flip")))
        #expect(store.connect(from: PortRef(node: toggle, port: "on"), to: PortRef(node: spring, port: "target")))
        #expect(store.connect(from: PortRef(node: spring, port: "value"), to: PortRef(node: size, port: "progress")))
        store.setValueType(.size, node: size)
        store.setLiteral(.size(Size2(width: 310, height: 200)), node: size, port: "start")
        store.setLiteral(.size(Size2(width: 358, height: 560)), node: size, port: "end")
        #expect(store.connect(from: PortRef(node: size, port: "value"), toProperty: .size, of: card))
        #expect(store.connect(from: PortRef(node: spring, port: "value"), toProperty: .cornerRadius, of: card))

        let runtime = Runtime(document: store.document)
        runtime.tick(dt: 1.0 / 60)
        runtime.send(.touchDown(Point2(x: 100, y: 400)))
        runtime.send(.touchUp(Point2(x: 100, y: 400)))
        runtime.advance(seconds: 3)
        #expect(runtime.resolved.find(card)?.size == Size2(width: 358, height: 560))
        #expect(runtime.resolved.find(card)?.value(.cornerRadius) == .number(1))
    }

    @Test func incompatibleCablesAreRefused() {
        let store = DocumentStore()
        let color = store.addPatch("makeColor")
        let sum = store.addPatch("add")
        #expect(!store.connect(from: PortRef(node: color, port: "color"), to: PortRef(node: sum, port: "a")))
        #expect(store.document.graph.connections.isEmpty)
    }

    @Test func aGenericPatchAdoptsTheTypeOfItsFirstCable() {
        let store = DocumentStore()
        let point = store.addPatch("makePoint")
        let pick = store.addPatch("if")
        #expect(store.connect(from: PortRef(node: point, port: "point"), to: PortRef(node: pick, port: "then")))
        #expect(store.registry.valueType(for: store.document.graph.node(pick)!) == .point)
    }

    @Test func reroutingACableIsOneStep() {
        let (store, undo) = makeStore()
        var a: NodeID!, sum: NodeID!
        step(undo) {
            a = store.addPatch("add")
            sum = store.addPatch("add")
            store.connect(from: PortRef(node: a, port: "result"), to: PortRef(node: sum, port: "a"))
        }
        step(undo) {
            store.connect(from: PortRef(node: a, port: "result"), to: PortRef(node: sum, port: "b"), replacing: PortRef(node: sum, port: "a"))
        }
        #expect(store.document.graph.connections.map(\.to.port) == ["b"])
        undo.undo()
        #expect(store.document.graph.connections.map(\.to.port) == ["a"])
    }

    @Test func groupingKeepsLayersWhereTheyAppear() {
        let store = DocumentStore()
        let a = store.addLayer(.view, frame: CGRect(x: 50, y: 60, width: 20, height: 20))
        let b = store.addLayer(.ellipse, frame: CGRect(x: 100, y: 100, width: 40, height: 40))
        store.selectedLayers = [a, b]
        store.groupSelectedLayers()
        let group = store.selectedLayer!
        #expect(group.kind == .view)
        #expect(ResolvedLayer(group).frame == CGRect(x: 50, y: 60, width: 90, height: 80))
        let tree = ResolvedLayer(store.document.screen)
        #expect(tree.hitTest(Point2(x: 55, y: 65), options: .editing).first == a)
        store.ungroup(group.id)
        #expect(store.document.layer(a)?.value(.position) == .point(Point2(x: 50, y: 60)))
        #expect(store.document.screen.children.map(\.id) == [a, b])
    }

    @Test func deletingALayerRemovesItsPatches() {
        let store = DocumentStore()
        let layer = store.addLayer(.view, frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        store.addInteraction(for: layer)
        store.revealPropertyPatch(.opacity, of: layer)
        // Its own patch and the Interaction.
        #expect(store.document.graph.nodes.filter { $0.layerID == layer }.count == 2)
        #expect(store.showsPort(ViewInput(.opacity), of: layer))
        store.selectedLayers = [layer]
        store.deleteSelectedLayers()
        #expect(store.document.graph.nodes.map(\.layerID) == [store.document.screen.id])
    }

    @Test func upstreamTraceFindsEverythingThatDrivesAProperty() {
        let example = SampleDocuments.card()
        let store = DocumentStore(package: DocumentPackage(document: example.document))
        let dimPatch = store.document.graph.viewNode(layer: example.dim)!
        let trace = store.upstream(of: dimPatch.id)
        let kinds = Set(trace.nodes.compactMap { store.document.graph.node($0)?.kind })
        #expect(kinds == ["view", "transition", "spring", "switch", "interaction"])
        #expect(trace.connections.count == 4)
    }

    @Test func valueParsing() {
        #expect(PatchEditorView.parse("12.5", as: .number) == .number(12.5))
        #expect(PatchEditorView.parse("10, 20", as: .point) == .point(Point2(x: 10, y: 20)))
        #expect(PatchEditorView.parse("310 × 200", as: .size) == .size(Size2(width: 310, height: 200)))
        #expect(PatchEditorView.parse("#FF0000", as: .color) == .color(ColorValue(red: 1, green: 0, blue: 0)))
        #expect(PatchEditorView.parse("abc", as: .number) == nil)
    }

    @Test func loopBuilderInputsCanBeAddedAndRemovedAndAdoptTheCableType() {
        let store = DocumentStore()
        let builder = store.addPatch("loopBuilder")
        func inputs() -> [String] { store.registry.ports(for: store.document.graph.node(builder)!).inputs.map(\.id) }
        #expect(inputs() == ["value0", "value1", "value2"])
        store.changeInputCount(of: builder, by: 1)
        #expect(inputs().count == 4)

        // A text cable into a repeated input makes the whole patch work on text.
        let source = store.addPatch("value")
        store.setValueType(.text, node: source)
        #expect(store.connect(from: PortRef(node: source, port: "value"), to: PortRef(node: builder, port: "value3")))
        #expect(store.registry.valueType(for: store.document.graph.node(builder)!) == .text)

        // Removing the input takes its cable with it.
        store.changeInputCount(of: builder, by: -1)
        #expect(inputs().count == 3)
        #expect(store.document.graph.connections.isEmpty)
    }

    // MARK: Components

    @Test func aBarSpansTheScreenAtItsEdgeWhateverTheDevice() {
        let (store, undo) = makeStore()
        let board = store.document.screen.value(.size).sizeValue
        var top: LayerID?, bottom: LayerID?
        step(undo) { top = store.insertComponent(ComponentLibrary.iOS("Navigation Bar")) }
        step(undo) { bottom = store.insertComponent(ComponentLibrary.iOS("Tab Bar")) }
        #expect(store.document.layer(top!)?.value(.size) == .size(Size2(width: board.width, height: 44)))
        #expect(store.document.layer(top!)?.value(.position) == .point(.zero))
        #expect(store.document.layer(bottom!)?.value(.size) == .size(Size2(width: board.width, height: 83)))
        #expect(store.document.layer(bottom!)?.value(.position) == .point(Point2(x: 0, y: board.height - 83)))
        // A place that was asked for is kept.
        step(undo) { top = store.insertComponent(ComponentLibrary.iOS("Navigation Bar"), at: Point2(x: 10, y: 90)) }
        #expect(store.document.layer(top!)?.value(.position) == .point(Point2(x: 10, y: 90)))
    }

    @Test func barsStackAtTheirEdgeInTheOrderTheyAreAdded() {
        let (store, undo) = makeStore()
        let board = store.document.screen.value(.size).sizeValue
        func y(_ name: String) -> Double {
            var id: LayerID?
            step(undo) { id = store.insertComponent(ComponentLibrary.iOS(name)) }
            return store.document.layer(id!)!.value(.position).pointValue.y
        }
        #expect(y("Status Bar") == 0)
        #expect(y("Navigation Bar") == 62)
        #expect(y("Home Indicator") == board.height - 34)
        // The home indicator lies over the bottom edge and takes no room from the tab bar.
        #expect(y("Tab Bar") == board.height - 83)
        #expect(y("Toolbar") == board.height - 83 - 76)
    }

    @Test func insertingALibraryComponentCopiesItIntoTheDocumentOnce() {
        let (store, undo) = makeStore()
        var first: LayerID?
        step(undo) { first = store.insertComponent(ComponentLibrary.iOS("Toggle")) }
        step(undo) { store.insertComponent(ComponentLibrary.iOS("Toggle")) }
        #expect(store.fullDocument.components.map(\.name) == ["Toggle"])
        #expect(store.document.screen.children.count == 2)
        #expect(store.document.layer(first!)?.value(.size) == .size(Size2(width: 63, height: 28)))
        #expect(store.useCount(of: ComponentLibrary.iOS("Toggle").id) == 2)

        // Its patch is the instance's view patch: where it is, then the published ports.
        // Editing an input there sets it on the layer.
        let patch = store.revealComponentPatch(for: first!)!
        let ports = store.visiblePorts(for: store.document.graph.node(patch)!)
        #expect(ports.inputs.map(\.name) == ["X", "Y", "On", "Tint", "Dark"])
        #expect(ports.outputs.map(\.name) == ["On", "Changed"])
        step(undo) { store.setLiteral(.bool(true), node: patch, port: ports.inputs[2].id) }
        #expect(store.document.layer(first!)?.component?.inputs[ports.inputs[2].id] == .bool(true))
        step(undo) { store.setLiteral(.number(7), node: patch, port: "x") }
        #expect(store.document.layer(first!)?.value(.position).pointValue.x == 7)

        for _ in 0..<4 { undo.undo() }
        #expect(store.fullDocument.components.isEmpty)
    }

    @Test func editingInsideAComponentChangesTheDefinitionAndUndoes() {
        let (store, undo) = makeStore()
        let button = ComponentLibrary.iOS("Button")
        step(undo) { store.insertComponent(button) }
        let screen = store.document.screen.id

        store.enterComponent(button.id)
        #expect(store.scope == button.id)
        #expect(store.document.screen.kind == .screen)
        #expect(store.document.screen.id == button.root.id)
        #expect(store.document.graph.nodes.count == button.graph.nodes.count)
        // The Viewer runs the component alone while it is edited.
        #expect(store.runtimeDocument.screen.children.map(\.kind) == [.component])
        // A component cannot be put inside itself.
        #expect(!store.canInsert(button))
        #expect(store.canInsert(ComponentLibrary.iOS("Toggle")))

        let label = store.document.screen.flattened.first { $0.name == "Label" }!.id
        step(undo) { store.setProperty(.fontSize, of: label, to: .number(22)) }
        var addedID: NodeID?
        step(undo) { addedID = store.addPatch("add") }
        let added = addedID!
        #expect(store.document.graph.node(added) != nil)

        store.exitComponent()
        #expect(store.scope == nil)
        #expect(store.document.screen.id == screen)
        let edited = store.fullDocument.component(button.id)!
        #expect(edited.root.kind == .view)
        #expect(edited.root.find(label)?.value(.fontSize) == .number(22))
        #expect(edited.graph.node(added) != nil)
        #expect(store.document.graph.node(added) == nil)
    }

    @Test func creatingAComponentKeepsThePrototypeWorking() {
        // A box that fades when tapped. Its color comes from a patch that stays outside and
        // its taps are counted outside, so both cross the component's boundary.
        let box = Layer(name: "Box", kind: .view, properties: [
            .position: .point(Point2(x: 50, y: 60)), .size: .size(Size2(width: 120, height: 80)),
        ])
        var b = SampleDocuments.Builder(screen: Layer(kind: .screen, children: [box]))
        let touch = b.interaction(on: box.id, at: Point2(x: 300, y: 100))
        let faded = b.add("switch", at: Point2(x: 520, y: 100))
        let fade = b.add("transition", at: Point2(x: 740, y: 100), type: .number, inputs: ["start": .number(1), "end": .number(0.4)])
        let opacity = b.property(.opacity, of: box.id, at: Point2(x: 960, y: 100))
        let color = b.add("value", at: Point2(x: 40, y: 400), type: .color, inputs: ["value": .color(ColorValue(hex: "#FF3B30")!)])
        let colorSwitch = b.add("value", at: Point2(x: 40, y: 600), type: .color)
        let fill = b.property(.fill, of: box.id, at: Point2(x: 960, y: 400))
        let taps = b.add("counter", at: Point2(x: 960, y: 700))
        let shownElsewhere = b.add("value", at: Point2(x: 1200, y: 700), type: .number)
        b.connect(touch, "tap", to: faded, "flip")
        b.connect(faded, "on", to: fade, "progress")
        b.connect(fade, "value", to: opacity, "value")
        b.connect(color, "value", to: fill, "value")
        b.connect(color, "value", to: colorSwitch, "value")
        b.connect(touch, "tap", to: taps, "increase")
        b.connect(taps, "value", to: shownElsewhere, "value")

        func run(_ document: PaperModel.Document) -> (opacity: Double, fill: String, taps: Value?) {
            let runtime = Runtime(document: document)
            runtime.advance(seconds: 0.1)
            runtime.send(.touchDown(Point2(x: 100, y: 100)))
            runtime.tick(dt: 1 / 60)
            runtime.send(.touchUp(Point2(x: 100, y: 100)))
            runtime.advance(seconds: 0.5)
            var found: ResolvedLayer?
            func walk(_ layer: ResolvedLayer) {
                if layer.name == "Box", layer.kind == .view { found = layer }
                layer.children.forEach(walk)
            }
            walk(runtime.resolved)
            return (found!.opacity, found!.value(.fill).colorValue.hex, runtime.outputValue(PortRef(node: taps, port: "value")))
        }
        let before = run(b.document)
        #expect(before.opacity == 0.4)
        #expect(before.fill == "#FF3B30")
        #expect(before.taps == .number(1))

        let (store, undo) = (DocumentStore(package: DocumentPackage(document: b.document)), UndoManager())
        undo.groupsByEvent = false
        store.undoManager = undo
        store.selectedLayers = [box.id]
        var created: ComponentID?
        step(undo) { created = store.createComponentFromSelection() }
        let component = store.fullDocument.component(created!)!

        // The touch, the switch and the fade went inside; the color and the counter stayed out.
        #expect(Set(component.graph.nodes.map(\.id)).isSuperset(of: [touch, faded, fade, b.input(opacity).node, b.input(fill).node]))
        #expect(store.document.graph.node(color) != nil && store.document.graph.node(taps) != nil)
        #expect(store.document.graph.node(touch) == nil)
        #expect(component.inputs.map(\.name) == ["Fill"])
        #expect(component.inputs.map(\.type) == [.color])
        #expect(component.outputs.map(\.name) == ["Tap"])
        #expect(component.outputs.map(\.type) == [.pulse])
        #expect(store.document.screen.children.map(\.kind) == [.component])
        #expect(store.document.screen.children[0].value(.position) == .point(Point2(x: 50, y: 60)))

        let after = run(store.fullDocument)
        #expect(after.opacity == before.opacity)
        #expect(after.fill == before.fill)
        #expect(after.taps == before.taps)

        undo.undo()
        #expect(store.fullDocument == b.document)
    }

    // MARK: Copying and reordering

    @Test func duplicatingALayerBringsItsPatchesAndTheirCables() throws {
        let example = SampleDocuments.card()
        let store = DocumentStore(package: DocumentPackage(document: example.document))
        let before = store.document
        store.selectedLayers = [example.card]
        let fragment = store.fragmentOfSelectedLayers()
        let inside = Set(before.layer(example.card)!.flattened.map(\.id))
        let bound = before.graph.nodes.filter { node in node.layerID.map { inside.contains($0) } == true }
        #expect(fragment.layers.map(\.id) == [example.card])
        #expect(fragment.nodes.count == bound.count)

        // Through the pasteboard's encoding and back, then in.
        let copied = try JSONDecoder().decode(DocumentFragment.self, from: JSONEncoder().encode(fragment))
        #expect(store.insert(copied))
        let after = store.document
        #expect(after.screen.children.count == before.screen.children.count + 1)
        let clone = try #require(after.screen.children.first { new in !before.screen.children.contains { $0.id == new.id } })
        #expect(store.selectedLayers.contains(clone.id))
        #expect(clone.value(.size) == before.layer(example.card)!.value(.size))
        // The copy has its own patches, driven by the same sources as the original's.
        let copies = Set(clone.flattened.map(\.id))
        let cloned = after.graph.nodes.filter { node in node.layerID.map { copies.contains($0) } == true }
        #expect(cloned.count == bound.count)
        let incoming = { (graph: Graph, nodes: [PatchNode]) in
            graph.connections.filter { connection in nodes.contains { $0.id == connection.to.node } }.count
        }
        #expect(incoming(after.graph, cloned) == incoming(before.graph, bound))
        #expect(after.graph.nodes.filter { node in node.layerID.map { inside.contains($0) } == true }.count == bound.count)
    }

    @Test func duplicatingPatchesKeepsTheCablesBetweenThem() {
        let store = DocumentStore()
        let a = store.addPatch("add")
        let b = store.addPatch("multiply")
        let bound = store.addInteraction(for: store.addLayer(.view, frame: CGRect(x: 0, y: 0, width: 10, height: 10)))
        store.connect(from: PortRef(node: a, port: "result"), to: PortRef(node: b, port: "a"))
        store.selectedNodes = [a, b, bound]
        store.duplicateSelectedPatches()
        #expect(store.document.graph.patches.count == 5)
        #expect(store.selectedNodes.count == 2)
        #expect(store.selectedNodes.isDisjoint(with: [a, b, bound]))
        #expect(store.document.graph.connections.count == 2)
    }

    @Test func layersCanBeMovedAmongTheirSiblings() {
        let store = DocumentStore()
        let ids = (0..<4).map { store.addLayer(.view, frame: CGRect(x: 0, y: Double($0) * 10, width: 10, height: 10)) }
        let screen = store.document.screen.id
        func order() -> [Int] { store.document.screen.children.map { ids.firstIndex(of: $0.id)! } }
        store.moveLayer(ids[0], in: screen, to: 4)
        #expect(order() == [1, 2, 3, 0])
        store.moveLayer(ids[0], in: screen, to: 1)
        #expect(order() == [1, 0, 2, 3])
        store.moveLayer(ids[2], in: screen, to: 2)
        #expect(order() == [1, 0, 2, 3])
    }

    @Test func editingAScriptChangesThePatchAndDropsCablesThatNoLongerFit() {
        let store = DocumentStore()
        let script = store.addPatch(PatchKind.javascript)
        let source = store.addPatch("value")
        let sink = store.addPatch("value")
        #expect(store.document.graph.node(script)?.script == Script.template)
        #expect(store.connect(from: PortRef(node: source, port: "value"), to: PortRef(node: script, port: "a")))
        #expect(store.connect(from: PortRef(node: script, port: "result"), to: PortRef(node: sink, port: "value")))

        store.setScript("inputs = { a: 0 }; outputs = { label: \"\" }; function evaluate(i, o) { o.label = \"n\" + i.a; }", node: script)
        let ports = store.registry.ports(for: store.document.graph.node(script)!)
        #expect(ports.inputs.map(\.id) == ["a"])
        #expect(ports.outputs.map(\.type) == [.text])
        // The cable into `a` survives; the one from the vanished `result` does not.
        #expect(store.document.graph.connections.map(\.to) == [PortRef(node: script, port: "a")])
    }
}
