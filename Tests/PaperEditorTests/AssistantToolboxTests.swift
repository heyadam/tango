import Foundation
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

@MainActor
@Suite struct AssistantToolboxTests {
    /// The batch the system prompt teaches: a card that grows when tapped.
    nonisolated(unsafe) static let cardBatch: [[String: Any]] = [
        ["op": "add_view", "kind": "view", "name": "Card", "ref": "card", "properties": [
            "position": ["x": 40, "y": 300], "size": ["width": 310, "height": 180],
            "fill": "#3D7BF7", "cornerRadius": 28,
        ]],
        ["op": "add_patch", "kind": "interaction", "view": "card", "ref": "touch"],
        ["op": "add_patch", "kind": "switch", "ref": "open", "name": "Open"],
        ["op": "add_patch", "kind": "spring", "ref": "spring"],
        ["op": "add_patch", "kind": "transition", "type": "size", "ref": "size", "inputs": [
            "start": ["width": 310, "height": 180], "end": ["width": 350, "height": 520],
        ]],
        ["op": "connect", "from": "touch", "output": "tap", "to": "open", "input": "flip"],
        ["op": "connect", "from": "open", "output": "on", "to": "spring", "input": "target"],
        ["op": "connect", "from": "spring", "output": "value", "to": "size", "input": "progress"],
        ["op": "connect", "from": "size", "output": "value", "to": "card", "input": "size"],
    ]

    private func parsed(_ result: AssistantToolResult) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(result.text.utf8))) as? [String: Any] ?? [:]
    }

    @Test func aBatchBuildsAWorkingInteraction() throws {
        let store = DocumentStore()
        let result = AssistantToolbox(store: store).call("edit_document", input: ["operations": Self.cardBatch])
        #expect(!result.isError)
        #expect(parsed(result)["errors"] == nil)
        #expect(result.summary == "Added 1 view, 4 patches, and 4 cables")

        let card = try #require(store.document.screen.children.first)
        #expect(card.name == "Card")
        #expect(card.value(.fill).colorValue.hex == "#3D7BF7")

        let runtime = Runtime(document: store.document)
        runtime.tick(dt: 0)
        #expect(runtime.resolved.children[0].size.height == 180)
        runtime.send(.touchDown(Point2(x: 100, y: 350)))
        runtime.send(.touchUp(Point2(x: 100, y: 350)))
        runtime.advance(seconds: 3)
        #expect(abs(runtime.resolved.children[0].size.height - 520) < 1)
    }

    @Test func newPatchesAreLaidOutLeftToRightWithoutOverlap() {
        let store = DocumentStore()
        _ = AssistantToolbox(store: store).call("edit_document", input: ["operations": Self.cardBatch])
        let nodes = store.document.graph.nodes
        func x(_ kind: String) -> Double { nodes.first { $0.kind == kind }?.position.x ?? -1 }
        #expect(x("interaction") < x("switch"))
        #expect(x("switch") < x("spring"))
        #expect(x("spring") < x("transition"))
        // The card's own patch is at the end, where the cable into it arrives.
        let card = store.document.screen.children[0].id
        #expect(x("transition") < (store.viewNode(for: card)?.position.x ?? -1))
        #expect(Set(nodes.map(\.position)).count == nodes.count)
    }

    @Test func aBatchIsOneUndoStep() {
        let store = DocumentStore()
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        let empty = store.document
        undo.beginUndoGrouping()
        _ = AssistantToolbox(store: store).call("edit_document", input: ["operations": Self.cardBatch])
        undo.endUndoGrouping()
        #expect(store.document != empty)
        undo.undo()
        #expect(store.document == empty)
        #expect(!undo.canUndo)
    }

    @Test func aFailedStepIsReportedAndTheRestStillRun() throws {
        let store = DocumentStore()
        let result = AssistantToolbox(store: store).call("edit_document", input: ["operations": [
            ["op": "add_view", "kind": "ellipse", "ref": "dot"],
            ["op": "add_patch", "kind": "no-such-patch"],
            ["op": "add_patch", "kind": "time", "ref": "time"],
            ["op": "connect", "from": "time", "output": "nope", "to": "dot", "input": "opacity"],
            ["op": "set_properties", "view": "dot", "properties": ["fill": "not a color"]],
            ["op": "set_properties", "view": "dot", "properties": ["opacity": 0.5]],
        ]])
        #expect(!result.isError)
        let errors = try #require(parsed(result)["errors"] as? [[String: Any]])
        #expect(errors.map { $0["index"] as? Int } == [1, 3, 4])
        // The model is told what it could have used.
        #expect((errors[1]["error"] as? String)?.contains("Its outputs:") == true)
        #expect(store.document.screen.children.first?.value(.opacity).numberValue == 0.5)
        #expect(store.document.graph.patches.map(\.kind) == ["time"])
    }

    @Test func thingsAreFoundByShortIDNameAndPortName() throws {
        let store = DocumentStore(package: DocumentPackage(document: SampleDocuments.card().document))
        let toolbox = AssistantToolbox(store: store)
        let description = toolbox.describe()
        let patches = try #require(description["patches"] as? [[String: Any]])
        let spring = try #require(patches.first { $0["kind"] as? String == "spring" }?["id"] as? String)
        #expect(spring.count == 8)

        let result = toolbox.call("edit_document", input: ["operations": [
            ["op": "set_inputs", "patch": spring, "inputs": ["Response": 0.9]],
            ["op": "set_properties", "view": "Card", "properties": ["Corner Radius": 40]],
            ["op": "connect", "from": "\(spring).value", "to": "Close", "input": "scale"],
        ]])
        #expect(parsed(result)["errors"] == nil)
        let node = try #require(store.document.graph.nodes.first { $0.kind == "spring" })
        #expect(node.inputs["response"] == .number(0.9))
        let card = try #require(store.document.screen.flattened.first { $0.name == "Card" })
        #expect(card.value(.cornerRadius) == .number(40))
        let close = try #require(store.document.screen.flattened.first { $0.name == "Close" })
        let patch = try #require(store.viewNode(for: close.id))
        #expect(store.document.graph.connection(into: PortRef(node: patch.id, port: "scale"))?.from.node == node.id)
    }

    @Test func componentsAreInsertedConfiguredAndWired() throws {
        let store = DocumentStore()
        let result = AssistantToolbox(store: store).call("edit_document", input: ["operations": [
            ["op": "insert_component", "component": "toggle", "ref": "toggle", "inputs": ["On": true]],
            ["op": "add_view", "kind": "ellipse", "ref": "lamp"],
            // The instance is a view, and a view is a patch: its outputs are wired from it.
            ["op": "connect", "from": "toggle", "output": "On", "to": "lamp", "input": "opacity"],
        ]])
        #expect(parsed(result)["errors"] == nil)
        let toggle = try #require(store.document.screen.children.first { $0.kind == .component })
        let use = try #require(toggle.component)
        let definition = try #require(store.fullDocument.component(use.id))
        let port = try #require(definition.input(named: "On"))
        #expect(use.inputs[port] == .bool(true))
        #expect(store.document.graph.connections.count == 1)
    }

    @Test func valuesAreReadLoosely() throws {
        #expect(try AssistantToolbox.value(["x": 1, "y": 2], as: .point) == .point(Point2(x: 1, y: 2)))
        #expect(try AssistantToolbox.value([3, 4], as: .size) == .size(Size2(width: 3, height: 4)))
        #expect(try AssistantToolbox.value("#FF0000", as: .color) == .color(ColorValue(hex: "#FF0000")!))
        #expect(try AssistantToolbox.value(12, as: .point) == .point(Point2(x: 12, y: 12)))
        #expect(try AssistantToolbox.value(true, as: .bool) == .bool(true))
        #expect(try AssistantToolbox.value("vertical", as: .text, options: ["None", "Vertical"]) == .text("Vertical"))
        #expect(try AssistantToolbox.value(["a", "b"], as: .array) == .array([.text("a"), .text("b")]))
        #expect(throws: AssistantToolbox.Problem.self) { try AssistantToolbox.value("red-ish", as: .color) }
        #expect(throws: AssistantToolbox.Problem.self) { try AssistantToolbox.value("Diagonal", as: .text, options: ["None"]) }
    }

    @Test func viewingReturnsAPictureOfTheRunningPrototype() throws {
        let store = DocumentStore(package: DocumentPackage(document: SampleDocuments.card().document))
        let result = AssistantToolbox(store: store).call("view_prototype", input: ["tap": ["x": 195, "y": 400], "seconds": 1])
        let png = try #require(result.image)
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(result.text.contains("390 × 844"))
        // Looking must not take the document's runtime away from the real Viewer.
        #expect(store.runtime == nil)
    }

    @Test func thePromptListsEveryPatchAndComponent() {
        let prompt = AssistantPrompt.system(registry: .standard, components: [])
        for definition in PatchRegistry.standard.library where definition.kind != PatchKind.layerProperty {
            #expect(prompt.contains("`\(definition.kind)`"), "missing \(definition.kind)")
        }
        for component in ComponentLibrary.iOS { #expect(prompt.contains("- \(component.name) (")) }
        #expect(prompt.contains("cornerRadius: number"))
    }
}
