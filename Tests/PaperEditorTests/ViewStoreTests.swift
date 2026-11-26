import Foundation
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

/// Every view is one patch in the graph (spec 6.5), whatever made or removed the view.
@MainActor
@Suite struct ViewStoreTests {
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

    /// The layers that have exactly one view patch, which should be all of them.
    func agrees(_ store: DocumentStore) -> Bool {
        func agrees(_ root: Layer, _ graph: Graph) -> Bool {
            let views = graph.nodes.filter { $0.kind == PatchKind.view }.compactMap(\.layerID)
            return views.count == Set(views).count && Set(views) == Set(root.flattened.map(\.id))
        }
        let document = store.fullDocument
        return agrees(document.screen, document.graph)
            && document.components.allSatisfy { agrees($0.root, $0.graph) }
    }

    @Test func aNewDocumentHasItsScreenAsAPatch() {
        let store = DocumentStore()
        #expect(store.document.graph.nodes.map(\.kind) == [PatchKind.view])
        #expect(store.viewNode(for: store.document.screen.id) != nil)
    }

    @Test func addingAndDeletingAViewAddsAndDeletesItsPatchInTheSameUndoStep() {
        let (store, undo) = makeStore()
        var id: LayerID!
        step(undo) { id = store.addLayer(.view, frame: CGRect(x: 10, y: 20, width: 100, height: 50)) }
        let patch = store.viewNode(for: id)
        #expect(patch != nil)
        #expect(agrees(store))
        // The first view in the screen sits beside the screen's patch, on the grid; the
        // next one goes under it.
        let screen = store.viewNode(for: store.document.screen.id)!
        #expect(patch!.position.x > screen.position.x + PatchGrid.nodeWidth)
        #expect(patch!.position.y == screen.position.y)
        var second: LayerID!
        step(undo) { second = store.addLayer(.ellipse, frame: CGRect(x: 0, y: 0, width: 10, height: 10)) }
        #expect(store.viewNode(for: second)!.position.x == patch!.position.x)
        #expect(store.viewNode(for: second)!.position.y > patch!.position.y)
        undo.undo()
        #expect(PatchGrid.snap(patch!.position) == patch!.position)

        undo.undo()
        #expect(store.document.graph.nodes.count == 1)
        #expect(agrees(store))
        undo.redo()
        // The same patch comes back, not a new one.
        #expect(store.viewNode(for: id)?.id == patch?.id)
    }

    @Test func deletingAViewsPatchDeletesTheViewAndWhatIsInsideIt() {
        let (store, undo) = makeStore()
        var a: LayerID!
        var b: LayerID!
        step(undo) {
            a = store.addLayer(.view, frame: CGRect(x: 0, y: 0, width: 50, height: 50))
            b = store.addLayer(.ellipse, frame: CGRect(x: 60, y: 0, width: 50, height: 50))
            store.selectedLayers = [a, b]
            store.groupSelectedLayers()
        }
        let group = store.selectedLayers.first!
        #expect(agrees(store))
        step(undo) { store.addInteraction(for: a) }

        step(undo) {
            store.selectedNodes = [store.viewNode(for: group)!.id]
            store.deleteSelectedPatches()
        }
        #expect(store.document.screen.children.isEmpty)
        #expect(store.document.graph.nodes.count == 1)
        undo.undo()
        #expect(store.document.layer(b) != nil)
        #expect(agrees(store))

        // The screen's own patch cannot be deleted.
        store.selectedNodes = [store.viewNode(for: store.document.screen.id)!.id]
        step(undo) { store.deleteSelectedPatches() }
        #expect(store.viewNode(for: store.document.screen.id) != nil)
    }

    @Test func editingAValueOnAViewsPatchEditsTheView() {
        let store = DocumentStore()
        let id = store.addLayer(.view, frame: CGRect(x: 10, y: 20, width: 100, height: 50))
        let patch = store.viewNode(for: id)!
        store.setLiteral(.number(64), node: patch.id, port: "y")
        store.setLiteral(.number(0.5), node: patch.id, port: "opacity")
        #expect(store.document.layer(id)?.value(.position) == .point(Point2(x: 10, y: 64)))
        #expect(store.document.layer(id)?.value(.opacity) == .number(0.5))
        // The patch itself holds no values, and reports the view's.
        #expect(store.viewNode(for: id)?.inputs.isEmpty == true)
        let ports = store.visiblePorts(for: patch)
        #expect(ports.inputs.map(\.id) == ["x", "y", "width", "height", "fill"])
        #expect(store.literal(for: ports.inputs[1], of: patch) == .number(64))

        // Its name is the view's name.
        store.renamePatch(patch.id, to: "Hero")
        #expect(store.document.layer(id)?.name == "Hero")
        #expect(store.title(for: store.viewNode(for: id)!) == "Hero")
        #expect(store.viewNode(for: id)?.name == nil)
    }

    @Test func portsAreShownAndHiddenAndACabledOneAlwaysShows() {
        let (store, undo) = makeStore()
        var id: LayerID!
        step(undo) { id = store.addLayer(.view, frame: CGRect(x: 0, y: 0, width: 10, height: 10)) }
        let scale = ViewInput(.scale)
        #expect(!store.showsPort(scale, of: id))
        step(undo) { store.setPort(scale, of: id, shown: true) }
        #expect(store.showsPort(scale, of: id))
        #expect(store.visiblePorts(for: store.viewNode(for: id)!).inputs.map(\.id) == ["x", "y", "width", "height", "scale", "fill"])
        step(undo) { store.setPort(ViewInput(.fill), of: id, shown: false) }
        #expect(!store.showsPort(ViewInput(.fill), of: id))
        undo.undo()
        #expect(store.showsPort(ViewInput(.fill), of: id))

        step(undo) { store.setPort(scale, of: id, shown: false) }
        var source: NodeID!
        step(undo) {
            source = store.addPatch("spring")
            #expect(store.connect(from: PortRef(node: source, port: "value"), to: scale, of: id))
        }
        #expect(store.showsPort(scale, of: id))
        step(undo) { store.disconnect(input: PortRef(node: store.viewNode(for: id)!.id, port: "scale")) }
        #expect(!store.showsPort(scale, of: id))
    }

    @Test func copiesGroupsComponentsAndAgentBatchesAllKeepOnePatchPerView() {
        let (store, undo) = makeStore()
        var a: LayerID!
        var source: NodeID!
        step(undo) {
            a = store.addLayer(.view, frame: CGRect(x: 0, y: 0, width: 50, height: 50))
            source = store.addPatch("spring")
            store.connect(from: PortRef(node: source, port: "value"), toProperty: .opacity, of: a)
        }

        // Copying the view's patch copies the view, with its cable.
        store.selectedNodes = [store.viewNode(for: a)!.id]
        step(undo) { store.duplicateSelectedPatches() }
        #expect(store.document.screen.children.count == 2)
        let copy = store.document.screen.children[1].id
        #expect(store.document.graph.connection(into: PortRef(node: store.viewNode(for: copy)!.id, port: "opacity"))?.from.node == source)
        #expect(agrees(store))

        step(undo) {
            store.selectedLayers = [a, copy]
            store.groupSelectedLayers()
        }
        #expect(agrees(store))
        step(undo) { store.createComponentFromSelection() }
        #expect(agrees(store))
        let instance = store.document.screen.children[0]
        #expect(store.viewNode(for: instance.id)?.componentID == instance.component?.id)

        step(undo) {
            let result = AssistantToolbox(store: store).call("edit_document", input: ["operations": [
                ["op": "add_view", "kind": "view", "name": "Row", "ref": "row"],
                ["op": "add_view", "kind": "text", "name": "Title", "parent": "row"],
                ["op": "add_view", "kind": "ellipse", "name": "Dot", "parent": "row", "ref": "dot"],
                ["op": "delete_view", "view": "dot"],
            ]])
            #expect(!result.isError)
        }
        #expect(agrees(store))
        while undo.canUndo {
            undo.undo()
            #expect(agrees(store))
        }
    }

    @Test func aComponentsRootHasItsOwnPatchInside() {
        let store = DocumentStore()
        let button = ComponentLibrary.iOS("Button")
        store.insertComponent(button)
        store.enterComponent(button.id)
        let root = store.viewNode(for: store.document.screen.id)
        #expect(root != nil)
        #expect(store.subtitle(for: root!) == "Component")
        store.exitComponent()
        #expect(store.subtitle(for: store.viewNode(for: store.document.screen.id)!) == "Screen")
    }

    // MARK: The graph as the workspace

    @Test func selectingAViewSelectsItsPatchAndTheOtherWayRound() {
        let store = DocumentStore()
        let a = store.addView(.view)
        let b = store.addView(.text)
        let spring = store.addPatch("spring")

        // From the outline or the canvas: the view's patch is selected, and scrolled to.
        store.selectedLayers = [a]
        #expect(store.selectedNodes == [store.viewNode(for: a)!.id])
        #expect(store.revealNode == store.viewNode(for: a)!.id)
        #expect(store.selectedLayer?.id == a)

        // From the graph: the views behind the selected patches are selected.
        store.selectedNodes = [store.viewNode(for: b)!.id, spring]
        #expect(store.selectedLayers == [b])
        // Naming the same views again keeps the other patches selected.
        store.selectedLayers = [b]
        #expect(store.selectedNodes.contains(spring))

        // A patch attached to a view leaves the view selected, for the next one.
        let touch = store.addInteraction(for: b)
        #expect(store.selectedNodes.contains(touch))
        #expect(store.selectedLayers == [b])

        store.selectedNodes = []
        #expect(store.selectedLayers.isEmpty)
    }

    @Test func aNewViewGoesInsideTheOpenViewAndItsPatchWhereAsked() {
        let store = DocumentStore()
        let stack = store.addView(.stack)
        #expect(store.document.layer(stack)?.type == .stack)
        // Selecting a view is not enough: one steps into it to put views in it.
        #expect(store.containerForNewViews.id == store.document.screen.id)
        store.open(stack)
        #expect(store.containerForNewViews.id == stack)

        let text = store.addView(.text, patchAt: Point2(x: 607, y: 301))
        #expect(store.document.screen.parent(of: text)?.id == stack)
        #expect(store.viewNode(for: text)?.position == Point2(x: 612, y: 300))
        #expect(agrees(store))
        let image = store.addView(.image)
        #expect(store.document.screen.parent(of: image)?.id == stack)
        // Its x and y are the stack's to decide.
        #expect(store.isPlacedByParent(image))
        #expect(!store.isPlacedByParent(stack))

        store.closeView()
        let scroll = store.addView(.scrollView)
        #expect(store.document.screen.parent(of: scroll)?.id == store.document.screen.id)
        #expect(store.document.layer(scroll)?.value(.size) == .size(Size2(width: 390, height: 844)))
        #expect(store.visiblePorts(for: store.viewNode(for: scroll)!).outputs.map(\.id) == ["offset", "velocity", "dragging"])
        #expect(store.visiblePorts(for: store.viewNode(for: stack)!).outputs.isEmpty)
    }

    @Test func aViewChangesTypeAndKeepsItsPatchCablesAndChildren() {
        let (store, undo) = makeStore()
        var box: LayerID!
        var spring: NodeID!
        step(undo) {
            box = store.addView(.view)
            store.open(box)
            _ = store.addView(.text)
            store.closeView()
            spring = store.addPatch("spring")
            store.connect(from: PortRef(node: spring, port: "value"), to: ViewInput(.opacity), of: box)
        }
        let patch = store.viewNode(for: box)!.id
        step(undo) { store.convert(box, to: .stack) }
        #expect(store.document.layer(box)?.type == .stack)
        #expect(store.subtitle(for: store.viewNode(for: box)!) == "Stack")
        #expect(store.visiblePorts(for: store.viewNode(for: box)!).inputs.map(\.id).contains("spacing"))
        step(undo) { store.convert(box, to: .scrollView) }
        #expect(store.document.layer(box)?.type == .scrollView)
        #expect(store.document.layer(box)?.value(.clips) == .bool(true))
        step(undo) { store.convert(box, to: .grid) }
        #expect(store.document.layer(box)?.type == .grid)
        #expect(store.document.layer(box)?.value(.scrolls) == .bool(false))

        #expect(store.viewNode(for: box)?.id == patch)
        #expect(store.document.graph.connection(into: PortRef(node: patch, port: "opacity"))?.from.node == spring)
        #expect(store.document.layer(box)?.children.count == 1)
        undo.undo()
        #expect(store.document.layer(box)?.type == .scrollView)

        // Only a view changes type; text stays text.
        let text = store.document.layer(box)!.children[0].id
        step(undo) { store.convert(text, to: .stack) }
        #expect(store.document.layer(text)?.type == .text)
    }

    @Test func theLibraryOffersViewsAndNoLongerTheScrollPatch() {
        #expect(LibraryItem.views.map(\.name) == [
            "View", "Stack", "Grid", "Scroll View", "Ellipse", "Text", "Image", "Symbol", "Text Field", "Camera", "Video", "Shader", "Scene",
        ])
        #expect(!PatchRegistry.standard.library.contains { $0.kind == "scroll" })
        // A document that has one still runs it.
        #expect(PatchRegistry.standard.definition("scroll") != nil)
    }

    // MARK: Stepping into a view

    /// Screen > Card > [Title, Row > Dot], with a spring that only works on Card's children.
    func nested() -> (DocumentStore, card: LayerID, title: LayerID, row: LayerID, dot: LayerID) {
        let store = DocumentStore()
        let card = store.addView(.view, name: "Card")
        store.open(card)
        let title = store.addView(.text, name: "Title")
        let row = store.addView(.stack, name: "Row")
        store.open(row)
        let dot = store.addView(.ellipse, name: "Dot")
        store.open(nil)
        return (store, card, title, row, dot)
    }

    @Test func aLevelShowsAViewItsChildrenAndWhatIsKeptThere() {
        let (store, card, title, row, dot) = nested()
        func shown() -> Set<String> { Set(store.levelGraph.nodes.map { store.title(for: $0) }) }
        // At the top: the screen and the one view directly in it.
        #expect(shown() == ["Screen", "Card"])
        #expect(store.openPath.map(\.name) == ["Screen"])

        store.open(card)
        // Only what is nested in the card: the card's own patch is one level out.
        #expect(shown() == ["Title", "Row"])
        #expect(store.openPath.map(\.name) == ["Screen", "Card"])
        // A patch added here is kept here, and so is an Interaction on a view that is here.
        let spring = store.addPatch("spring")
        let touch = store.addInteraction(for: title)
        #expect(store.document.graph.node(spring)?.home == card)
        #expect(shown() == ["Title", "Row", "Spring Animation", "Interaction"])

        store.open(row)
        #expect(shown() == ["Dot"])
        #expect(store.viewNode(for: dot) != nil)
        store.closeView()
        #expect(store.openView == card)
        store.closeView()
        #expect(store.openView == nil)
        #expect(!store.levelGraph.nodes.contains { $0.id == spring || $0.id == touch })
        // Text holds nothing, so it has no level to open.
        store.open(title)
        #expect(store.openView == nil)
    }

    @Test func selectingAViewOpensTheLevelItsPatchIsIn() {
        let (store, card, _, row, dot) = nested()
        store.selectedLayers = [dot]
        #expect(store.openView == row)
        #expect(store.selectedNodes == [store.viewNode(for: dot)!.id])
        // Selecting the open view itself goes out to where its patch is.
        store.selectedLayers = [row]
        #expect(store.openView == card)
        store.selectedLayers = [card]
        #expect(store.openView == nil)

        // A patch elsewhere is shown by going to it.
        store.open(card)
        let spring = store.addPatch("spring")
        store.open(nil)
        store.show(spring)
        #expect(store.openView == card)
        #expect(store.selectedNodes == [spring])
    }

    @Test func aCableCanLeaveALevelAndDeletingAViewTakesWhatWasKeptInIt() {
        let (store, undo) = makeStore()
        var card: LayerID!
        var title: LayerID!
        var inner: NodeID!
        var outer: NodeID!
        step(undo) {
            card = store.addView(.view, name: "Card")
            outer = store.addPatch("spring")
            store.open(card)
            title = store.addView(.text, name: "Title")
            inner = store.addPatch("transition")
            store.connect(from: PortRef(node: outer, port: "value"), to: PortRef(node: inner, port: "progress"))
            store.connect(from: PortRef(node: inner, port: "value"), to: ViewInput(.opacity), of: title)
        }
        // Inside the card the cable from the spring is known, though the spring is not here.
        let level = store.levelGraph
        #expect(level.node(outer) == nil)
        #expect(level.connection(into: PortRef(node: inner, port: "progress"))?.from.node == outer)
        // It still runs: levels are for the person, not the prototype.
        var edited = store.document
        edited.graph.update(outer) { $0.inputs["target"] = .number(1) }
        let runtime = Runtime(document: edited)
        runtime.advance(seconds: 2)
        #expect(abs((runtime.resolved.find(title)?.opacity ?? 0) - 1) < 0.01)

        step(undo) {
            store.selectedLayers = [card]
            store.deleteSelectedLayers()
        }
        #expect(store.openView == nil)
        #expect(store.document.graph.node(inner) == nil)
        #expect(store.document.graph.node(outer) != nil)
        undo.undo()
        #expect(store.document.graph.node(inner)?.home == card)

        // Ungrouping moves what was kept inside out with the views.
        step(undo) { store.ungroup(card) }
        #expect(store.document.graph.node(inner) != nil)
        #expect(store.document.graph.node(inner)?.home == nil)
    }

    @Test func patchesSettleInTheLevelOfTheViewsTheyWorkOn() throws {
        // An agent's patches, and an older document's, are put where their views are.
        let store = DocumentStore()
        let result = AssistantToolbox(store: store).call("edit_document", input: ["operations": [
            ["op": "add_view", "kind": "view", "name": "Card", "ref": "card"],
            ["op": "add_view", "kind": "text", "name": "Title", "parent": "card", "ref": "title"],
            ["op": "add_view", "kind": "ellipse", "name": "Badge", "parent": "card", "ref": "badge"],
            ["op": "add_patch", "kind": "interaction", "view": "title", "ref": "touch"],
            ["op": "add_patch", "kind": "switch", "ref": "on"],
            ["op": "add_patch", "kind": "spring", "ref": "spring"],
            ["op": "connect", "from": "touch", "output": "tap", "to": "on", "input": "flip"],
            ["op": "connect", "from": "on", "output": "on", "to": "spring", "input": "target"],
            ["op": "connect", "from": "spring", "output": "value", "to": "badge", "input": "scale"],
            ["op": "add_patch", "kind": "time", "ref": "clock", "inside": "card"],
            ["op": "add_patch", "kind": "counter", "ref": "loose"],
        ]])
        #expect(!result.isError)
        let card = try #require(store.document.screen.children.first).id
        func home(_ kind: String) -> LayerID? { store.document.graph.nodes.first { $0.kind == kind }?.home }
        // Title and Badge are both in Card, so what joins them is too.
        #expect(home("switch") == card)
        #expect(home("spring") == card)
        #expect(home("time") == card)
        // A patch that reaches no view stays on the screen.
        #expect(home("counter") == nil)

        // Saved as a version 3 document, where the graph was one level, it settles the same way.
        var old = store.document
        for index in old.graph.nodes.indices { old.graph.nodes[index].home = nil }
        var json = try #require(JSONSerialization.jsonObject(with: old.encoded()) as? [String: Any])
        json["version"] = 3
        let reopened = try PaperModel.Document.decode(from: JSONSerialization.data(withJSONObject: json))
        #expect(reopened.version == PaperModel.Document.currentVersion)
        #expect(reopened.graph.nodes.first { $0.kind == "spring" }?.home == card)
        #expect(reopened.graph.nodes.first { $0.kind == "time" }?.home == nil)
    }
}
