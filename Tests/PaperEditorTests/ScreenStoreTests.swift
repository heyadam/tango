import Foundation
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

/// Screens and flows as the editor makes them.
@MainActor
@Suite struct ScreenStoreTests {
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

    @Test func theFirstAddedScreenTakesInWhatTheRootHeld() {
        let (store, undo) = makeStore()
        var button: LayerID!
        var patch: NodeID!
        step(undo) { button = store.addLayer(.view, frame: CGRect(x: 10, y: 20, width: 100, height: 50)) }
        step(undo) { patch = store.addPatch("switch") }
        step(undo) { store.setProperty(.fill, of: store.document.screen.id, to: .color(ColorValue(white: 0.2))) }
        let before = store.document
        var second: LayerID!
        step(undo) { second = store.addScreen() }

        let screens = store.screens
        #expect(screens.count == 2)
        #expect(screens[0].name == "Screen 1")
        #expect(screens[0].children.map(\.id) == [button])
        #expect(screens[0].value(.fill) == .color(ColorValue(white: 0.2)))
        #expect(screens[1].id == second)
        #expect(store.selectedLayers == [second])
        // What was kept at the top of the graph went in with the views.
        #expect(store.document.graph.node(patch)?.home == screens[0].id)
        #expect(store.screen(holding: button)?.id == screens[0].id)
        #expect(store.isPlacedByParent(second))

        // One undo step, there and back.
        undo.undo()
        #expect(store.document == before)
        undo.redo()
        #expect(store.screens.count == 2)

        step(undo) { store.addScreen() }
        #expect(store.screens.map(\.name) == ["Screen 1", "Screen 2", "Screen 3"])
    }

    @Test func screensAreReordered() {
        let (store, undo) = makeStore()
        step(undo) { store.addScreen(name: "A") }
        step(undo) { store.addScreen(name: "B") }
        step(undo) { store.addScreen(name: "C") }
        let c = store.screens[2].id
        step(undo) { store.moveScreen(c, to: 0) }
        #expect(store.screens.map(\.name) == ["C", "A", "B"])
        undo.undo()
        #expect(store.screens.map(\.name) == ["A", "B", "C"])
    }

    @Test func aFlowIsATapANavigateAndACable() {
        let (store, undo) = makeStore()
        var button: LayerID!
        step(undo) { button = store.addLayer(.view, frame: CGRect(x: 100, y: 100, width: 200, height: 60)) }
        step(undo) { store.addScreen(name: "Detail") }
        let detail = store.screens[1].id
        let before = store.document
        var flow: NodeID!
        step(undo) { flow = store.addFlow(from: button, to: detail, style: .modal) }

        let node = store.document.graph.node(flow)
        #expect(node?.kind == PatchKind.navigate && node?.layerID == detail)
        #expect(store.flows == [DocumentStore.Flow(id: flow, source: button, target: detail, style: .modal)])
        #expect(store.selectedNodes == [flow])
        // The Navigate patch is at the top, beside the screens; the Tap is with its view.
        #expect(store.document.levelGraph(of: nil).nodes.contains { $0.id == flow })
        let taps = store.document.graph.nodes.filter { $0.kind == PatchKind.tap && $0.layerID == button }
        #expect(taps.count == 1)

        // A second flow from the same view uses the Tap it has.
        step(undo) { store.addScreen(name: "Other") }
        step(undo) { store.addFlow(from: button, to: store.screens[2].id) }
        #expect(store.document.graph.nodes.filter { $0.kind == PatchKind.tap }.count == 1)
        #expect(store.flows.count == 2)
        undo.undo()
        undo.undo()
        undo.undo()
        #expect(store.document == before)

        // Not to the screen the view is on, and not to something that is no screen.
        step(undo) { #expect(store.addFlow(from: button, to: store.screens[0].id) == nil) }
        step(undo) { #expect(store.addFlow(from: button, to: button) == nil) }
    }

    @Test func theFlowPlaysInTheRuntime() {
        let (store, undo) = makeStore()
        var open: LayerID!
        step(undo) { open = store.addLayer(.view, frame: CGRect(x: 100, y: 100, width: 200, height: 60)) }
        step(undo) { store.addScreen(name: "Detail") }
        let detail = store.screens[1].id
        var close: LayerID!
        step(undo) {
            store.open(detail)
            close = store.addView(.view)
        }
        step(undo) { store.addFlow(from: open, to: detail) }
        var back: NodeID!
        step(undo) { back = store.addFlow(from: close, to: nil) }
        #expect(store.document.graph.node(back)?.home == detail)

        let runtime = Runtime(document: store.document, registry: store.runtimeRegistry)
        let frame = 1.0 / 60.0
        func tap(_ point: Point2) {
            runtime.send(.touchBegan(id: 0, point))
            runtime.tick(dt: frame)
            runtime.send(.touchEnded(id: 0, point))
            for _ in 0..<300 where runtime.needsAnotherFrame { runtime.tick(dt: frame) }
        }
        runtime.tick(dt: frame)
        tap(Point2(x: 150, y: 120))
        #expect(runtime.navigation.current == detail)
        let frameOfClose = runtime.resolved.find(close)!.frame
        tap(Point2(x: frameOfClose.midX, y: frameOfClose.midY))
        #expect(runtime.navigation.current == store.screens[0].id)
    }

    @Test func aViewThatLeavesTheRootIsNoLongerAScreen() {
        let (store, undo) = makeStore()
        step(undo) { store.addScreen(name: "A") }
        step(undo) { store.addScreen(name: "B") }
        let b = store.screens[1].id
        step(undo) { store.setScreen(b, false) }
        #expect(store.screens.map(\.name) == ["A"])
        #expect(!store.isPlacedByParent(b))
        step(undo) { store.setScreen(b, true) }
        #expect(store.screens.count == 2)
    }

    // MARK: QA

    @Test func deletingAScreenTakesItsFlowsAndLeavesTheRest() {
        let (store, undo) = makeStore()
        var button: LayerID!
        step(undo) { button = store.addLayer(.view, frame: CGRect(x: 100, y: 100, width: 200, height: 60)) }
        step(undo) { store.addScreen(name: "Detail") }
        let detail = store.screens[1].id
        step(undo) { store.addFlow(from: button, to: detail) }
        let before = store.document
        step(undo) {
            store.selectedLayers = [detail]
            store.deleteSelectedLayers()
        }
        #expect(store.screens.count == 1)
        #expect(store.flows.isEmpty)
        #expect(!store.document.graph.nodes.contains { $0.kind == PatchKind.navigate })
        // The Tap is the view's, and stays, with no cable to nowhere.
        #expect(store.document.graph.nodes.contains { $0.kind == PatchKind.tap && $0.layerID == button })
        #expect(store.document.graph.connections.allSatisfy { store.document.graph.node($0.to.node) != nil })
        undo.undo()
        #expect(store.document == before)
    }

    @Test func aDuplicatedScreenIsAScreenWithItsViewsAndAScreenMovedIntoAViewIsNot() {
        let (store, undo) = makeStore()
        step(undo) { store.addLayer(.view, frame: CGRect(x: 10, y: 10, width: 50, height: 50)) }
        step(undo) { store.addScreen(name: "Second") }
        let first = store.screens[0].id
        step(undo) {
            store.selectedLayers = [first]
            store.duplicateSelectedLayers()
        }
        // A copy lands beside the original: a third screen, with a copy of what was on it.
        #expect(store.screens.count == 3)
        #expect(store.screens[2].children.count == 1)
        #expect(store.screens[2].children[0].id != store.screens[0].children[0].id)
        // Moved inside another screen it is an ordinary view there.
        let copy = store.screens[2]
        let second = store.screens[1].id
        step(undo) {
            store.apply("Move") { document in
                guard let moved = document.screen.remove(copy.id) else { return }
                document.screen.insert(moved, into: second)
            }
        }
        #expect(store.screens.count == 2)
        #expect(store.document.layer(copy.id)?.page == nil)
        #expect(store.screens[1].children.map(\.id) == [copy.id])
    }

    @Test func screensWithComponentInstancesStillShowOneAtATimeAndAllOnTheCanvas() throws {
        let (store, undo) = makeStore()
        let button = ComponentLibrary.iOS("Button")
        step(undo) { store.addScreen(name: "A") }
        step(undo) { store.addScreen(name: "B") }
        // At the top, with a screen selected, new things go into that screen and not over all.
        var instance: LayerID?
        step(undo) {
            store.selectedLayers = [store.screens[0].id]
            instance = store.insertComponent(button)
        }
        #expect(store.screens[0].children.map(\.id) == [try #require(instance)])
        step(undo) {
            store.selectedLayers = []
            store.addView(.view)
        }
        #expect(store.screens[0].children.count == 2)
        #expect(store.document.screen.children.count == 2)
        let runtime = Runtime(document: store.document, registry: store.runtimeRegistry)
        runtime.tick(dt: 1.0 / 60)
        #expect(runtime.navigation.pages == store.screens.map(\.id))
        #expect(runtime.resolved.children.map(\.name) == ["A"])
        // At rest on the Canvas both are there, each filling its frame.
        let resolved = CanvasView.resolve(store.document, registry: store.runtimeRegistry)
        #expect(resolved.children.map(\.name) == ["A", "B"])
        let trees = CanvasView.trees(of: resolved, on: Board(store.document))
        #expect(trees[1].children.map(\.name) == ["B"])
    }

    @Test func insideAComponentThereAreNoScreensOrFlows() throws {
        let (store, undo) = makeStore()
        step(undo) { store.addLayer(.view, frame: CGRect(x: 10, y: 10, width: 50, height: 50)) }
        step(undo) { store.addScreen() }
        var component: ComponentID?
        step(undo) {
            store.open(store.screens[0].id)
            store.selectedLayers = [store.screens[0].children[0].id]
            component = store.createComponentFromSelection()
        }
        store.enterComponent(try #require(component))
        #expect(store.screens.isEmpty && store.flows.isEmpty)
        step(undo) { #expect(store.addScreen() == nil) }
        #expect(Board(store.document).frames.count == 1)
        store.exitComponent()
        #expect(store.screens.count == 2)
    }

    @Test func theChangesReportForAnAgentCoversScreensAndFlows() {
        let (store, undo) = makeStore()
        var button: LayerID!
        step(undo) { button = store.addLayer(.view, frame: CGRect(x: 100, y: 100, width: 200, height: 60)) }
        step(undo) { store.markBaseline() }
        step(undo) { store.addScreen(name: "Detail") }
        step(undo) { store.addFlow(from: button, to: store.screens[1].id, style: .modal) }
        let report = AssistantToolbox(store: store).call("get_changes", input: [:]).text
        #expect(report.contains("Detail"))
        #expect(report.lowercased().contains("navigate"))
    }

    // MARK: Designer workflows

    @Test func aViewMovesToAnotherScreenOrOverEveryScreen() {
        let (store, undo) = makeStore()
        var bar: LayerID!
        step(undo) { bar = store.addLayer(.view, frame: CGRect(x: 0, y: 760, width: 390, height: 84)) }
        step(undo) { store.addScreen(name: "Detail") }
        let first = store.screens[0].id, detail = store.screens[1].id
        #expect(store.screenMoves(for: bar).everyScreen)
        #expect(store.screenMoves(for: bar).screens.map(\.id) == [detail])
        // Over every screen: a tab bar.
        step(undo) { store.move(bar, toScreen: nil) }
        #expect(store.document.screen.children.last?.id == bar)
        #expect(store.screen(holding: bar) == nil)
        #expect(store.document.layer(bar)?.value(.position).pointValue == Point2(x: 0, y: 760))
        #expect(!store.screenMoves(for: bar).everyScreen)
        #expect(store.screenMoves(for: bar).screens.count == 2)
        // It shows on every screen while the prototype runs.
        let runtime = Runtime(document: store.document, registry: store.runtimeRegistry)
        runtime.tick(dt: 1.0 / 60)
        #expect(runtime.resolved.children.map(\.id) == [first, bar])
        // Back onto one screen.
        step(undo) { store.move(bar, toScreen: detail) }
        #expect(store.screen(holding: bar)?.id == detail)
        undo.undo()
        #expect(store.screen(holding: bar) == nil)
        // A screen does not move this way.
        #expect(store.screenMoves(for: first).screens.isEmpty)
    }

    @Test func thePrototypeCanStartOnAnyScreen() {
        let (store, undo) = makeStore()
        step(undo) { store.addLayer(.view, frame: CGRect(x: 10, y: 10, width: 50, height: 50)) }
        step(undo) { store.addScreen(name: "Third") }
        let third = store.screens[1].id
        let runtime = Runtime(document: store.document, registry: store.runtimeRegistry)
        runtime.startPage = third
        runtime.restart()
        runtime.tick(dt: 1.0 / 60)
        #expect(runtime.navigation.current == third)
        #expect(!runtime.navigation.canGoBack)
        #expect(runtime.resolved.children.map(\.id) == [third])
        // A screen that is gone leaves it on the first.
        runtime.startPage = LayerID()
        runtime.restart()
        runtime.tick(dt: 1.0 / 60)
        #expect(runtime.navigation.current == store.screens[0].id)
        // The store remembers it for the Viewer, and opens the Viewer.
        store.showsViewer = false
        let before = store.restartToken
        store.preview(from: third)
        #expect(store.previewScreen == third && store.showsViewer && store.restartToken == before + 1)
        store.preview(from: nil)
        #expect(store.previewScreen == nil)
    }

    @Test func theOldNameOfTheInstantStyleStillWorks() {
        #expect(Navigation.Style.named("Switch") == .replace)
        #expect(Navigation.Style.named("instant") == .replace)
        #expect(Navigation.Style.named("modal") == .modal)
        #expect(Navigation.Style.named("Spin") == nil)
    }
}
