import AppKit
import Foundation
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

/// Publishing ports from inside a view, as the editor and an agent do it.
@MainActor
@Suite struct PublishedPortStoreTests {
    @MainActor struct Scene {
        let store: DocumentStore
        let undo: UndoManager
        var card: LayerID!
        var dot: LayerID!
        var cardPatch: NodeID { store.viewNode(for: card)!.id }
        var dotPatch: NodeID { store.viewNode(for: dot)!.id }

        func step(_ body: () -> Void) {
            undo.beginUndoGrouping()
            body()
            undo.endUndoGrouping()
        }
    }

    /// A card with a dot in it, with the card open.
    func scene() -> Scene {
        let store = DocumentStore()
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        var scene = Scene(store: store, undo: undo)
        scene.step { scene.card = store.addView(.view, name: "Card") }
        store.open(scene.card)
        scene.step { scene.dot = store.addView(.view, name: "Dot") }
        return scene
    }

    private func edit(_ store: DocumentStore, _ operations: [[String: Any]]) -> [String] {
        let result = AssistantToolbox(store: store).call("edit_document", input: ["operations": operations])
        let answer = (try? JSONSerialization.jsonObject(with: Data(result.text.utf8))) as? [String: Any] ?? [:]
        return (answer["errors"] as? [[String: Any]] ?? []).compactMap { $0["error"] as? String }
    }

    @Test func publishingShowsThePortOnTheViewOutsideAndUndoes() throws {
        let s = scene()
        let inner = PortRef(node: s.dotPatch, port: "opacity")
        #expect(s.store.canPublish(inner, output: false))
        var id: String?
        s.step { id = s.store.publish(inner, output: false) }
        let port = try #require(id)
        let patch = try #require(s.store.viewNode(for: s.card))
        #expect(patch.published?.map(\.name) == ["Dot Opacity"])
        #expect(s.store.visiblePorts(for: patch).inputs.contains { $0.id == port })
        #expect(s.store.publication(of: inner, output: false)?.node == patch.id)
        // Once is enough, and the card's own ports go nowhere: it is in the screen.
        #expect(!s.store.canPublish(inner, output: false))
        #expect(!s.store.canPublish(PortRef(node: patch.id, port: "opacity"), output: false))

        s.step { s.store.renamePublished(port, on: patch.id, to: "Opacity") }
        // A name another port of the patch has would be ambiguous.
        #expect(s.store.viewNode(for: s.card)?.published?.first?.name == "Opacity 2")
        s.step { s.store.unpublish(port, on: patch.id) }
        #expect(s.store.viewNode(for: s.card)?.published == nil)
        s.undo.undo()
        s.undo.undo()
        #expect(s.store.viewNode(for: s.card)?.published?.map(\.name) == ["Dot Opacity"])
        s.undo.undo()
        #expect(s.store.viewNode(for: s.card)?.published == nil)
    }

    @Test func aValueSetOnThePublishedPortIsTheValueInside() throws {
        let s = scene()
        var id: String?
        s.step { id = s.store.publish(PortRef(node: s.dotPatch, port: "opacity"), output: false) }
        let port = try #require(id)
        s.step { s.store.setLiteral(.number(0.4), node: s.cardPatch, port: port) }
        #expect(s.store.document.layer(s.dot)?.value(.opacity).numberValue == 0.4)
        let patch = try #require(s.store.viewNode(for: s.card))
        let shown = try #require(s.store.visiblePorts(for: patch).inputs.first { $0.id == port })
        #expect(s.store.literal(for: shown, of: patch) == .number(0.4))
        #expect(patch.inputs.isEmpty)
    }

    @Test func deletingWhatIsInsideTakesItsPortAndCableInTheSameStep() throws {
        let s = scene()
        var id: String?
        s.step { id = s.store.publish(PortRef(node: s.dotPatch, port: "opacity"), output: false) }
        let port = try #require(id)
        s.store.open(nil)
        var source: NodeID!
        s.step { source = s.store.addPatch("add") }
        s.step { #expect(s.store.connect(from: PortRef(node: source, port: "result"), to: PortRef(node: s.cardPatch, port: port))) }
        let before = s.store.document
        s.step {
            s.store.selectedLayers = [s.dot]
            s.store.deleteSelectedLayers()
        }
        #expect(s.store.viewNode(for: s.card)?.published == nil)
        #expect(s.store.document.graph.connections.isEmpty)
        s.undo.undo()
        #expect(s.store.document == before)
    }

    @Test func ungroupingKeepsTheCablesOnWhatWasPublished() throws {
        let s = scene()
        var id: String?
        s.step { id = s.store.publish(PortRef(node: s.dotPatch, port: "opacity"), output: false) }
        let port = try #require(id)
        s.store.open(nil)
        var source: NodeID!
        s.step { source = s.store.addPatch("add") }
        s.step { _ = s.store.connect(from: PortRef(node: source, port: "result"), to: PortRef(node: s.cardPatch, port: port)) }
        let dotPatch = s.dotPatch
        s.step { s.store.ungroup(s.card) }
        #expect(s.store.document.graph.connection(into: PortRef(node: dotPatch, port: "opacity"))?.from.node == source)
    }

    @Test func aDuplicatedViewPublishesItsOwnCopies() throws {
        let s = scene()
        s.step { _ = s.store.publish(PortRef(node: s.dotPatch, port: "opacity"), output: false) }
        s.store.open(nil)
        s.step {
            s.store.selectedLayers = [s.card]
            s.store.duplicateSelectedLayers()
        }
        let copy = try #require(s.store.document.screen.children.last)
        #expect(copy.id != s.card)
        let published = try #require(s.store.viewNode(for: copy.id)?.published)
        #expect(published.count == 1)
        #expect(published[0].inner.node == s.store.viewNode(for: copy.children[0].id)?.id)
        #expect(s.store.viewNode(for: s.card)?.published?.first?.inner.node == s.dotPatch)
    }

    @Test func anAgentPublishesAPortAndCablesToItByName() throws {
        let store = DocumentStore()
        let errors = edit(store, [
            ["op": "add_view", "kind": "view", "name": "Card", "ref": "card"],
            ["op": "add_view", "kind": "text", "name": "Title", "parent": "card", "ref": "title"],
            ["op": "add_patch", "kind": "interaction", "view": "title", "ref": "touch"],
            ["op": "publish_port", "view": "title", "input": "text", "name": "Title"],
            ["op": "publish_port", "patch": "touch", "output": "tap", "name": "Tapped"],
            ["op": "add_patch", "kind": "counter", "ref": "count"],
            ["op": "connect", "from": "card", "output": "Tapped", "to": "count", "input": "increase"],
        ])
        #expect(errors.isEmpty, "\(errors)")
        let card = try #require(store.document.screen.children.first)
        let patch = try #require(store.viewNode(for: card.id))
        #expect(patch.published?.map(\.name) == ["Title", "Tapped"])
        #expect(store.document.graph.connections.contains { $0.from.node == patch.id })

        let described = AssistantToolbox.json(AssistantToolbox(store: store).describe())
        #expect(described.contains("\"published\""))
        #expect(described.contains(".Tapped ->"))

        // A view directly in the screen has no view to publish on.
        #expect(edit(store, [["op": "publish_port", "view": "Card", "input": "opacity"]]).count == 1)
        #expect(edit(store, [["op": "rename_port", "view": "Card", "port": "Tapped", "name": "Pressed"]]).isEmpty)
        #expect(edit(store, [["op": "unpublish_port", "view": "Card", "port": "Title"]]).isEmpty)
        #expect(store.viewNode(for: card.id)?.published?.map(\.name) == ["Pressed"])
        // The cable stays on the renamed port; the tap still reaches the counter.
        #expect(store.document.graph.connections.count == 1)
    }

    @Test func aTapInsideAViewCountsOutsideThroughAPublishedPort() throws {
        let store = DocumentStore()
        let errors = edit(store, [
            ["op": "add_view", "kind": "view", "name": "Card", "ref": "card", "properties": ["x": 0, "y": 0, "width": 200, "height": 200]],
            ["op": "add_view", "kind": "view", "name": "Button", "parent": "card", "ref": "button", "properties": ["x": 0, "y": 0, "width": 100, "height": 100]],
            ["op": "add_patch", "kind": "interaction", "view": "button", "ref": "touch"],
            ["op": "publish_port", "patch": "touch", "output": "tap", "name": "Tapped"],
            ["op": "add_patch", "kind": "switch", "ref": "on"],
            ["op": "connect", "from": "card", "output": "Tapped", "to": "on", "input": "flip"],
        ])
        #expect(errors.isEmpty, "\(errors)")
        let toggle = try #require(store.document.graph.patches.first { $0.kind == "switch" })
        let runtime = Runtime(document: store.fullDocument)
        runtime.tick(dt: 1 / 60)
        runtime.send(.touchDown(Point2(x: 50, y: 50)))
        runtime.send(.touchUp(Point2(x: 50, y: 50)))
        runtime.advance(seconds: 0.2)
        #expect(runtime.outputValue(PortRef(node: toggle.id, port: "on")) == .bool(true))
    }

    // MARK: Found in QA

    /// A page holding a card holding a dot with an Interaction, built the way an agent does.
    private func nested() -> DocumentStore {
        let store = DocumentStore()
        #expect(edit(store, [
            ["op": "add_view", "kind": "view", "name": "Page", "ref": "page", "properties": ["x": 0, "y": 0, "width": 390, "height": 400]],
            ["op": "add_view", "kind": "view", "name": "Card", "ref": "card", "parent": "page", "properties": ["x": 10, "y": 10, "width": 300, "height": 200]],
            ["op": "add_view", "kind": "ellipse", "name": "Dot", "ref": "dot", "parent": "card", "properties": ["x": 10, "y": 10, "width": 40, "height": 40]],
            ["op": "add_patch", "kind": "interaction", "view": "dot"],
            ["op": "publish_port", "view": "dot", "input": "opacity", "name": "Dim"],
            ["op": "publish_port", "patch": "Interaction", "output": "tap", "name": "Tapped"],
        ]) == [])
        return store
    }

    private func view(_ name: String, in store: DocumentStore) -> Layer {
        store.document.screen.flattened.first { $0.name == name }!
    }

    private func published(_ name: String, in store: DocumentStore) -> [String] {
        (store.viewNode(for: view(name, in: store).id)?.published ?? []).map(\.name)
    }

    private func dotOpacity(_ store: DocumentStore) -> Double {
        let runtime = Runtime(document: store.runtimeDocument, registry: store.registry)
        runtime.advance(seconds: 2)
        return runtime.resolved.find(view("Dot", in: store).id)?.opacity ?? -1
    }

    @Test func anAgentIsToldWhenAPortNameIsTaken() {
        let store = nested()
        // "opacity" would be taken for the card's own input when cabling by name.
        let errors = edit(store, [
            ["op": "publish_port", "view": "Dot", "input": "fill", "name": "opacity"],
            ["op": "publish_port", "view": "Dot", "input": "fill", "name": "Dim"],
            ["op": "rename_port", "view": "Card", "port": "Dim", "name": "x"],
        ])
        #expect(errors.count == 3)
        #expect(errors.allSatisfy { $0.contains("already has a port") })
        #expect(published("Card", in: store) == ["Dim", "Tapped"])
    }

    @Test func groupingCarriesWhatWasPublishedThroughTheGroup() {
        let store = nested()
        #expect(edit(store, [
            ["op": "add_patch", "kind": "spring", "ref": "half", "inputs": ["target": 0.5]],
            ["op": "connect", "from": "half", "output": "value", "to": "Card", "input": "Dim"],
            ["op": "group_views", "views": ["Dot"], "name": "Wrap"],
        ]) == [])
        #expect(published("Card", in: store) == ["Dim", "Tapped"])
        #expect(published("Wrap", in: store) == ["Dim", "Tapped"])
        #expect(abs(dotOpacity(store) - 0.5) < 0.01)
        store.ungroup(view("Wrap", in: store).id)
        #expect(published("Card", in: store) == ["Dim", "Tapped"])
        #expect(abs(dotOpacity(store) - 0.5) < 0.01)
    }

    @Test func ungroupingTheMiddleOfAChainKeepsThePortFurtherOut() {
        let store = nested()
        #expect(edit(store, [
            ["op": "publish_port", "view": "Card", "input": "Dim", "name": "Dim"],
            ["op": "add_patch", "kind": "spring", "ref": "half", "inputs": ["target": 0.5]],
            ["op": "connect", "from": "half", "output": "value", "to": "Page", "input": "Dim"],
        ]) == [])
        store.ungroup(view("Card", in: store).id)
        #expect(published("Page", in: store) == ["Dim"])
        #expect(abs(dotOpacity(store) - 0.5) < 0.01)
    }

    @Test func aCopyKeepsAPortPublishedThroughTwoLevels() {
        let store = nested()
        #expect(edit(store, [["op": "publish_port", "view": "Card", "input": "Dim", "name": "Dim"]]) == [])
        store.selectedLayers = [view("Page", in: store).id]
        store.duplicateSelectedLayers()
        let pages = store.document.screen.children.filter { $0.name.hasPrefix("Page") }
        #expect(pages.count == 2)
        for page in pages {
            #expect(store.viewNode(for: page.id)?.published?.map(\.name) == ["Dim"])
            #expect(store.viewNode(for: page.children[0].id)?.published?.count == 2)
        }
    }

    @Test func aPublishedInputShowsOnThePatchInside() {
        let store = nested()
        let dot = store.viewNode(for: view("Dot", in: store).id)!
        #expect(store.visiblePorts(for: dot).inputs.contains { $0.id == "opacity" })
        #expect(edit(store, [["op": "unpublish_port", "view": "Card", "port": "Dim"]]) == [])
        #expect(!store.visiblePorts(for: dot).inputs.contains { $0.id == "opacity" })
    }

    @Test func whatAnAgentAddsOutOfSightIsNotSelected() {
        let store = nested()
        #expect(store.openView == nil)
        #expect(edit(store, [
            ["op": "add_view", "kind": "view", "name": "Deep", "parent": "Card"],
            ["op": "add_patch", "kind": "spring", "inside": "Card"],
        ]) == [])
        // Delete would otherwise remove a view the person cannot see.
        #expect(store.selectedNodes.isEmpty)
        store.deleteSelectedPatches()
        #expect(store.document.screen.flattened.contains { $0.name == "Deep" })
    }

    @Test func portsArePublishedInsideAComponentAndFromAnInstance() throws {
        let store = nested()
        #expect(edit(store, [
            ["op": "insert_component", "component": "Toggle", "name": "Lamp", "ref": "lamp", "parent": "Card", "properties": ["x": 100, "y": 100]],
            ["op": "publish_port", "view": "lamp", "output": "On", "name": "Lit"],
            ["op": "connect", "from": "Card", "output": "Lit", "to": "Page", "input": "clips"],
        ]) == [])
        #expect(published("Card", in: store) == ["Dim", "Tapped", "Lit"])

        store.selectedLayers = [view("Page", in: store).id]
        let component = try #require(store.createComponentFromSelection(named: "Sheet"))
        store.enterComponent(component)
        #expect(edit(store, [
            ["op": "add_patch", "kind": "spring", "ref": "half", "inputs": ["target": 0.5]],
            ["op": "connect", "from": "half", "output": "value", "to": "Card", "input": "Dim"],
            ["op": "open_view", "view": "Card"],
        ]) == [])
        #expect(store.openContainer.name == "Card")
        store.exitComponent()
        #expect(store.openView == nil)
        let runtime = Runtime(document: store.runtimeDocument, registry: store.registry)
        runtime.advance(seconds: 2)
        func find(_ layer: ResolvedLayer) -> ResolvedLayer? { layer.name == "Dot" ? layer : layer.children.lazy.compactMap(find).first }
        #expect(abs((find(runtime.resolved)?.opacity ?? -1) - 0.5) < 0.01)
    }

    @Test func undoingAViewOneIsInsideStepsOut() {
        let s = scene()
        #expect(s.store.openView == s.card)
        s.undo.undo()
        s.undo.undo()
        #expect(s.store.openView == nil)
        #expect(s.store.document.screen.children.isEmpty)
        var added: LayerID!
        s.step { added = s.store.addView(.view, name: "New") }
        #expect(s.store.document.screen.parent(of: added)?.id == s.store.document.screen.id)
    }

    /// The right-click menu on a port, used the way a person does.
    @Test func theMenuOnAPortPublishesGoesToAndUnpublishes() throws {
        let store = nested()
        store.open(view("Card", in: store).id)
        let editor = PatchEditorView(store: store)
        editor.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        func menu(_ ref: PortRef, output: Bool) throws -> NSMenu {
            editor.update(graph: store.levelGraph, selection: [], reveal: nil)
            let point = try #require(editor.portPoint(ref, output: output))
            return try #require(editor.contextMenu(at: point))
        }
        func choose(_ title: String, in menu: NSMenu) throws {
            let item = try #require(menu.items.first { $0.title == title })
            _ = item.target?.perform(item.action)
        }
        let dot = try #require(store.viewNode(for: view("Dot", in: store).id))
        let card = try #require(store.viewNode(for: view("Card", in: store).id))

        // Inside: a port that is not published offers to be, one that is offers to stop.
        let fill = try menu(PortRef(node: dot.id, port: "fill"), output: false)
        #expect(fill.items.map(\.title) == ["Publish to Card"])
        try choose("Publish to Card", in: fill)
        #expect(published("Card", in: store) == ["Dim", "Tapped", "Dot Fill"])
        let opacity = try menu(PortRef(node: dot.id, port: "opacity"), output: false)
        #expect(opacity.items.map(\.title) == ["Rename Port…", "Unpublish “Dim”"])

        // Outside, on the card's patch: the way in, and the same two.
        store.closeView()
        let tapped = try #require(card.published?.first { $0.name == "Tapped" })
        let outside = try menu(PortRef(node: card.id, port: tapped.id), output: true)
        #expect(outside.items.map(\.title) == ["Go to Interaction", "Rename Port…", "Unpublish “Tapped”"])
        try choose("Unpublish “Tapped”", in: outside)
        #expect(published("Card", in: store) == ["Dim", "Dot Fill"])
        try choose("Go to Interaction", in: outside)
        #expect(store.openView == view("Card", in: store).id)
    }

    @Test func whatAnAgentAddsInsideAViewDoesNotLandOnTopOfWhatIsThere() {
        let store = nested()
        _ = edit(store, [
            ["op": "add_view", "kind": "text", "name": "Title", "parent": "Card"],
            ["op": "add_patch", "kind": "spring", "inside": "Card"],
            ["op": "add_patch", "kind": "switch"],
        ])
        var levels: [LayerID?] = [nil]
        levels += store.document.screen.flattened.filter { $0.kind.canHaveChildren }.map { Optional($0.id) }
        for level in levels {
            let frames = store.document.levelGraph(of: level).nodes.map { node in
                CGRect(origin: CGPoint(x: node.position.x, y: node.position.y), size: PatchLayout(node: node, ports: store.visiblePorts(for: node)).size)
            }
            for (index, frame) in frames.enumerated() {
                for other in frames[(index + 1)...] { #expect(!frame.intersects(other)) }
            }
        }
    }
}
