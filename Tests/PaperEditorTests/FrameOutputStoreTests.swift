import Foundation
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

/// A view's frame outputs in the editor and for agents, and the Inspector's commands for a
/// patch that is not a view.
@MainActor
@Suite struct FrameOutputStoreTests {
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

    private func parsed(_ result: AssistantToolResult) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(result.text.utf8))) as? [String: Any] ?? [:]
    }

    // MARK: Frame outputs

    @Test func frameOutputsShowWhenChosenOrCabled() throws {
        let (store, undo) = makeStore()
        var card: LayerID!
        step(undo) { card = store.addView(.view, name: "Card") }
        let patch = try #require(store.viewNode(for: card))
        #expect(store.visiblePorts(for: patch).outputs.isEmpty)

        step(undo) { store.setOutputPort(.width, of: card, shown: true) }
        #expect(store.visiblePorts(for: store.viewNode(for: card)!).outputs.map(\.id) == ["frameWidth"])
        #expect(store.showsOutput(.width, of: card))
        // Choosing an output leaves the inputs the view shows as they were.
        #expect(store.visiblePorts(for: store.viewNode(for: card)!).inputs.map(\.id) == ["x", "y", "width", "height", "fill"])
        undo.undo()
        #expect(store.visiblePorts(for: store.viewNode(for: card)!).outputs.isEmpty)

        var add: NodeID!
        step(undo) { add = store.addPatch("add") }
        step(undo) { _ = store.connect(from: PortRef(node: patch.id, port: "frameY"), to: PortRef(node: add, port: "a")) }
        #expect(store.visiblePorts(for: store.viewNode(for: card)!).outputs.map(\.id) == ["frameY"])
        #expect(store.shownOutputs(on: store.viewNode(for: card)!) == [.y])
    }

    @Test func aScrollViewShowsItsScrollOutputsAndChosenFrameOnes() throws {
        let (store, undo) = makeStore()
        var list: LayerID!
        step(undo) { list = store.addView(.scrollView, name: "List") }
        step(undo) { store.setOutputPort(.height, of: list, shown: true) }
        let patch = try #require(store.viewNode(for: list))
        #expect(store.visiblePorts(for: patch).outputs.map(\.id) == ["offset", "velocity", "dragging", "frameHeight"])
    }

    @Test func anInstanceShowsItsComponentsOutputsButNotItsFrameUntilAsked() throws {
        let (store, undo) = makeStore()
        var button: LayerID?
        step(undo) { button = store.insertComponent(ComponentLibrary.iOS("Button")) }
        let id = try #require(button)
        let patch = try #require(store.viewNode(for: id))
        let all = store.registry.ports(for: patch).outputs
        #expect(all.prefix(4).map(\.id) == ViewOutput.allCases.map(\.id))
        let shown = store.visiblePorts(for: patch).outputs
        #expect(!shown.contains { ViewOutput.ids.contains($0.id) })
        #expect(shown.count == all.count - 4)

        // The instance's frame comes out of its patch when cabled, as any view's does.
        var add: NodeID!
        step(undo) { add = store.addPatch("add") }
        step(undo) { _ = store.connect(from: PortRef(node: patch.id, port: "frameWidth"), to: PortRef(node: add, port: "a")) }
        let runtime = Runtime(document: store.runtimeDocument, registry: store.runtimeRegistry)
        runtime.advance(seconds: 0.1)
        let width = store.document.layer(id)?.value(.size).sizeValue.width ?? 0
        #expect(width > 0)
        #expect(runtime.outputValue(PortRef(node: add, port: "result")) == .number(width))
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func anAgentConnectsFromAViewsFrameByIdOrName() throws {
        let store = DocumentStore()
        let toolbox = AssistantToolbox(store: store)
        let result = toolbox.call("edit_document", input: ["operations": [
            ["op": "add_view", "kind": "stack", "name": "Column", "ref": "column", "properties": ["width": 200, "height": 400, "spacing": 10]],
            ["op": "add_view", "kind": "view", "name": "Header", "parent": "column", "ref": "header", "properties": ["width": 200, "height": 60]],
            ["op": "add_view", "kind": "view", "name": "Body", "parent": "column", "ref": "body", "properties": ["width": 200, "height": 100]],
            ["op": "add_view", "kind": "view", "name": "Badge", "ref": "badge", "properties": ["width": 20, "height": 20]],
            ["op": "connect", "from": "body", "output": "frameY", "to": "badge", "input": "y"],
            ["op": "connect", "from": "Body", "output": "Width", "to": "badge", "input": "x"],
            ["op": "set_ports", "view": "header", "show": ["frameHeight"]],
        ] as [[String: Any]]])
        #expect(!result.isError)
        #expect(parsed(result)["errors"] == nil, "\(result.text)")

        let body = try #require(store.document.screen.flattened.first { $0.name == "Body" })
        let badge = try #require(store.document.screen.flattened.first { $0.name == "Badge" })
        let header = try #require(store.document.screen.flattened.first { $0.name == "Header" })
        let bodyPatch = try #require(store.viewNode(for: body.id))
        #expect(Set(store.visiblePorts(for: bodyPatch).outputs.map(\.id)) == ["frameY", "frameWidth"])
        #expect(store.shownOutputs(on: store.viewNode(for: header.id)!) == [.height])

        // get_document writes the cables with the output's id, as connect takes it.
        let cables = toolbox.describe()["cables"] as? [String] ?? []
        let short = AssistantToolbox.short(body.id)
        #expect(cables.contains { $0.hasPrefix("\(short).frameY -> ") })

        let runtime = Runtime(document: store.runtimeDocument, registry: store.runtimeRegistry)
        runtime.advance(seconds: 0.1)
        // Header 60 tall, then 10 of spacing.
        #expect(runtime.resolved.find(badge.id)?.position == Point2(x: 200, y: 70))
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func theReferenceTellsAgentsAboutFrameOutputs() {
        let reference = AssistantPrompt.reference(registry: .standard, components: ComponentLibrary.iOS)
        #expect(reference.contains("frameWidth"))
        #expect(reference.contains("frameX"))
    }

    // MARK: Inspecting a patch

    @Test func theInspectorFollowsOneSelectedPatchThatIsNotAView() throws {
        let (store, undo) = makeStore()
        var card: LayerID!
        var add: NodeID!
        var spring: NodeID!
        step(undo) { card = store.addView(.view, name: "Card") }
        step(undo) { add = store.addPatch("add") }
        step(undo) { spring = store.addPatch("spring") }
        store.selectedNodes = [add]
        #expect(store.selectedPatch?.id == add)
        store.selectedNodes = [add, spring]
        #expect(store.selectedPatch == nil)
        store.selectedNodes = [store.viewNode(for: card)!.id]
        #expect(store.selectedPatch == nil)
        #expect(store.selectedLayer?.id == card)
    }

    @Test func thePatchInspectorNamesWhereCablesComeFromAndGo() throws {
        let (store, undo) = makeStore()
        var card: LayerID!
        var add: NodeID!
        var spring: NodeID!
        step(undo) { card = store.addView(.view, name: "Card") }
        step(undo) { add = store.addPatch("add") }
        step(undo) { spring = store.addPatch("spring") }
        let view = store.viewNode(for: card)!.id
        step(undo) { _ = store.connect(from: PortRef(node: view, port: "frameWidth"), to: PortRef(node: add, port: "a")) }
        step(undo) { _ = store.connect(from: PortRef(node: add, port: "result"), to: PortRef(node: spring, port: "target")) }
        step(undo) { _ = store.connect(from: PortRef(node: add, port: "result"), to: PortRef(node: view, port: "x")) }

        let source = try #require(store.cableSource(into: PortRef(node: add, port: "a")))
        #expect(source.title == "Card")
        #expect(source.port == "Width")
        #expect(source.ref == PortRef(node: view, port: "frameWidth"))
        #expect(store.cableSource(into: PortRef(node: add, port: "b")) == nil)

        let targets = store.cableTargets(from: PortRef(node: add, port: "result"))
        #expect(targets.map(\.title) == [store.title(for: store.document.graph.node(spring)!), "Card"])
        #expect(targets.map(\.port) == ["Target", "X"])
    }

    @Test func aChosenFileNeverReplacesAnotherOfTheSameName() {
        let (store, _) = makeStore()
        #expect(store.addAsset(Data([1]), named: "clip.mov") == "clip.mov")
        #expect(store.addAsset(Data([1]), named: "clip.mov") == "clip.mov")
        #expect(store.addAsset(Data([2]), named: "clip.mov") == "clip 2.mov")
        #expect(store.assets["clip.mov"] == Data([1]))
        #expect(store.assets["clip 2.mov"] == Data([2]))
    }

    @Test func thePatchInspectorFollowsCablesThroughPublishedPorts() throws {
        let (store, undo) = makeStore()
        var card: LayerID!
        var inner: NodeID!
        var outside: NodeID!
        var input: String!
        var output: String!
        step(undo) { card = store.addView(.view, name: "Card") }
        store.open(card)
        step(undo) { inner = store.addPatch("add") }
        step(undo) { input = store.publish(PortRef(node: inner, port: "a"), output: false, name: "Amount") }
        step(undo) { output = store.publish(PortRef(node: inner, port: "result"), output: true, name: "Total") }
        store.closeView()
        step(undo) { outside = store.addPatch("multiply") }
        let view = store.viewNode(for: card)!.id
        step(undo) { _ = store.connect(from: PortRef(node: outside, port: "result"), to: PortRef(node: view, port: input)) }
        step(undo) { _ = store.connect(from: PortRef(node: view, port: output), to: PortRef(node: outside, port: "a")) }

        let source = try #require(store.cableSource(into: PortRef(node: inner, port: "a")))
        #expect(source.ref == PortRef(node: outside, port: "result"))
        let targets = store.cableTargets(from: PortRef(node: inner, port: "result"))
        #expect(targets.map(\.ref) == [PortRef(node: outside, port: "a")])
    }

    @Test func thePatchInspectorEditsInputsAndNamesAsUndoSteps() throws {
        let (store, undo) = makeStore()
        var add: NodeID!
        step(undo) { add = store.addPatch("add") }
        let node = try #require(store.document.graph.node(add))
        let b = try #require(store.visiblePorts(for: node).inputs.first { $0.id == "b" })
        #expect(store.literal(for: b, of: node) == .number(0))

        step(undo) { store.setLiteral(.number(12), node: add, port: "b") }
        #expect(store.literal(for: b, of: store.document.graph.node(add)!) == .number(12))
        step(undo) { store.renamePatch(add, to: "Offset") }
        #expect(store.title(for: store.document.graph.node(add)!) == "Offset")

        undo.undo()
        #expect(store.title(for: store.document.graph.node(add)!) != "Offset")
        undo.undo()
        #expect(store.literal(for: b, of: store.document.graph.node(add)!) == .number(0))
    }

    @Test func thePatchInspectorShowsLiveValuesWhileThePrototypeRuns() throws {
        let (store, undo) = makeStore()
        var add: NodeID!
        var loop: NodeID!
        step(undo) { add = store.addPatch("add") }
        step(undo) { store.setLiteral(.number(5), node: add, port: "a") }
        step(undo) { loop = store.addPatch("loop") }
        // Not running: nothing is known.
        #expect(store.liveValues(of: PortRef(node: add, port: "result")).isEmpty)
        #expect(Value.liveSummary([]) == nil)

        let runtime = Runtime(document: store.runtimeDocument, registry: store.runtimeRegistry)
        store.runtime = runtime
        runtime.advance(seconds: 0.05)
        let result = store.liveValues(of: PortRef(node: add, port: "result"))
        #expect(result == [.number(5)])
        #expect(Value.liveSummary(result) == "5")
        let indexes = store.liveValues(of: PortRef(node: loop, port: "index"))
        #expect(indexes.count == 3)
        #expect(Value.liveSummary(indexes) == "3 values: 0, 1, 2")
        #expect(Value.liveSummary((0..<5).map { .number(Double($0)) }) == "5 values: 0, 1, 2, …")
        #expect(store.liveInputValues(of: PortRef(node: add, port: "a")) == [.number(5)])
        store.runtime = nil
    }
}
