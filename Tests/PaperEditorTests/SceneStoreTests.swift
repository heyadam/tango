import AppKit
import Foundation
import PaperEngine
import PaperModel
import PaperRender
import Testing
@testable import PaperEditor

/// Editing scene views: the store's commands, the ports a scene's patch shows, and what an
/// agent may send.
@MainActor
@Suite struct SceneStoreTests {
    private func edit(_ store: DocumentStore, _ operations: [[String: Any]]) -> (errors: [String], created: [String: String]) {
        let result = AssistantToolbox(store: store).call("edit_document", input: ["operations": operations])
        let answer = (try? JSONSerialization.jsonObject(with: Data(result.text.utf8))) as? [String: Any] ?? [:]
        return ((answer["errors"] as? [[String: Any]] ?? []).compactMap { $0["error"] as? String }, answer["created"] as? [String: String] ?? [:])
    }

    /// What get_document says of the view called `name`, wherever in its answer that is.
    private func described(_ store: DocumentStore, _ name: String) throws -> [String: Any] {
        let text = AssistantToolbox(store: store).call("get_document", input: [:]).text
        let document = try JSONSerialization.jsonObject(with: Data(text.utf8))
        func find(_ any: Any) -> [String: Any]? {
            if let view = any as? [String: Any] {
                if view["name"] as? String == name, view["scene"] != nil { return view }
                for value in view.values { if let found = find(value) { return found } }
            }
            for item in any as? [Any] ?? [] { if let found = find(item) { return found } }
            return nil
        }
        return try #require(find(document), "\(text.prefix(600))")
    }

    @Test func aSceneIsEditedThroughTheStoreAndEveryStepUndoes() throws {
        let store = DocumentStore()
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        func step(_ body: () -> Void) {
            undo.beginUndoGrouping()
            body()
            undo.endUndoGrouping()
        }
        var id = LayerID()
        step { id = store.addView(.scene) }
        #expect(store.document.layer(id)?.type == .scene)
        let box = try #require(store.document.layer(id)?.scene?.objects.first)
        var ball: String?
        step { ball = store.addSceneObject(.sphere, to: id) }
        step { store.addSceneObject(.sphere, to: id) }
        #expect(store.document.layer(id)?.scene?.objects.map(\.name) == ["Box", "Sphere", "Sphere 2"])
        let sphere = try #require(ball)

        // The patch shows the camera's two angles to begin with, and the rest once chosen or cabled.
        func shown() throws -> [String] {
            store.visiblePorts(for: try #require(store.viewNode(for: id))).inputs.map(\.id).filter { $0.hasPrefix("scene.") }
        }
        #expect(try shown() == SceneUse.presetPorts)
        let turn = SceneUse.portID(object: sphere, "rotationY")
        step { store.setScenePort(turn, of: id, shown: true) }
        #expect(try shown().contains(turn))
        step { store.setScenePort(turn, of: id, shown: false) }
        #expect(try !shown().contains(turn))
        var source = NodeID()
        step { source = store.addPatch("value") }
        let patch = try #require(store.viewNode(for: id))
        step { #expect(store.connect(from: PortRef(node: source, port: "value"), to: PortRef(node: patch.id, port: turn))) }
        #expect(try shown().contains(turn))

        // A value set on the patch is the scene's, and reads back from it.
        let ports = store.registry.ports(for: patch)
        step { store.setLiteral(.number(2), node: patch.id, port: SceneUse.portID(object: sphere, "scale")) }
        step { store.setLiteral(.text("Sunset"), node: patch.id, port: SceneUse.portID("environment")) }
        #expect(store.document.layer(id)?.scene?.object(sphere)?.number("scale") == 2)
        #expect(store.literal(for: try #require(ports.input(SceneUse.portID("environment"))), of: patch) == .text("Sunset"))
        #expect(store.literal(for: try #require(ports.input(SceneUse.portID(object: box.id, "color"))), of: patch) == box.value("color"))

        // Renaming keeps the cable; removing the object takes it away, and undo brings both back.
        step { store.renameSceneObject(sphere, to: "Planet", in: id) }
        #expect(store.registry.ports(for: try #require(store.viewNode(for: id))).input(turn)?.name == "Planet Rotation Y")
        #expect(store.document.graph.connections.count == 1)
        step { store.removeSceneObject(sphere, from: id) }
        #expect(store.document.graph.connections.isEmpty)
        undo.undo()
        #expect(store.document.graph.connections.count == 1)
        #expect(store.document.layer(id)?.scene?.object(sphere)?.name == "Planet")
    }

    @Test func aViewBecomesASceneAndBackWithWhatIsInIt() throws {
        let store = DocumentStore()
        let box = store.addView(.stack)
        store.open(box)
        let inner = store.addView(.text)
        store.closeView()
        store.convert(box, to: .scene)
        let scene = try #require(store.document.layer(box))
        #expect(scene.type == .scene && scene.children.map(\.id) == [inner])
        // It still arranges what is in it.
        #expect(scene.arrangement == .stack)
        store.convert(box, to: .shader)
        #expect(store.document.layer(box)?.scene == nil && store.document.layer(box)?.type == .shader)
        store.convert(box, to: .scene)
        store.convert(box, to: .stack)
        #expect(store.document.layer(box)?.scene == nil && store.document.layer(box)?.type == .stack)
        #expect(store.document.layer(box)?.children.map(\.id) == [inner])
        #expect(store.viewNode(for: box)?.scene == nil)
    }

    @Test func aDuplicatedSceneKeepsItsObjectsAndACopyIsItsOwn() throws {
        let store = DocumentStore()
        let id = store.addView(.scene)
        store.setSceneInput(SceneUse.Key(input: "cameraYaw"), of: id, to: .number(40))
        store.selectedLayers = [id]
        store.duplicateSelectedLayers()
        let scenes = store.document.screen.flattened.filter { $0.type == .scene }
        #expect(scenes.count == 2)
        #expect(scenes.allSatisfy { $0.scene?.number("cameraYaw") == 40 && $0.scene?.objects.count == 1 })
        let copy = try #require(scenes.first { $0.id != id })
        store.setSceneInput(SceneUse.Key(input: "cameraYaw"), of: copy.id, to: .number(-10))
        #expect(store.document.layer(id)?.scene?.number("cameraYaw") == 40)
    }

    @Test func anAgentBuildsAndChangesAScene() throws {
        let store = DocumentStore()
        let made = edit(store, [
            ["op": "add_view", "kind": "scene", "name": "Stage", "ref": "stage", "objects": [
                ["name": "Ball", "shape": "sphere", "color": "#FF0000", "metalness": 1, "Rotation Y": 20],
                ["name": "Ground", "shape": "Plane", "y": -0.5, "scale": 4],
            ], "inputs": ["Camera Pitch": 25, "environment": "Night"]],
            ["op": "add_patch", "kind": "value", "ref": "turn", "inputs": ["value": 30]],
            ["op": "connect", "from": "turn", "output": "value", "to": "stage", "input": "Ball Rotation Y"],
            ["op": "connect", "from": "turn", "output": "value", "to": "stage", "input": "cameraYaw"],
        ])
        #expect(made.errors == [], "\(made.errors)")
        let stage = try #require(store.document.screen.flattened.first { $0.name == "Stage" })
        let scene = try #require(stage.scene)
        // Given its objects, it has only those: not the box a new scene starts with.
        #expect(scene.objects.map(\.name) == ["Ball", "Ground"])
        #expect(scene.objects.map(\.shape) == [.sphere, .plane])
        #expect(scene.object(named: "Ball")?.value("color") == .color(ColorValue(hex: "#FF0000")!))
        #expect(scene.object(named: "Ball")?.number("rotationY") == 20)
        #expect(scene.number("cameraPitch") == 25 && scene.value("environment") == .text("Night"))
        #expect(store.document.graph.connections.count == 2)

        let changed = edit(store, [["op": "set_scene", "view": "Stage", "inputs": ["rayTracing": false], "remove": ["Ground"], "objects": [
            ["name": "Ball", "roughness": 0.1], ["name": "Ring", "shape": "torus"],
        ]]])
        #expect(changed.errors == [], "\(changed.errors)")
        let after = try #require(store.document.layer(stage.id)?.scene)
        #expect(after.objects.map(\.name) == ["Ball", "Ring"])
        #expect(after.object(named: "Ball")?.id == scene.object(named: "Ball")?.id)
        #expect(after.object(named: "Ball")?.number("roughness") == 0.1 && after.object(named: "Ball")?.number("metalness") == 1)
        #expect(after.value("rayTracing") == .bool(false))
        // The cable into the ball survived the change.
        #expect(store.document.graph.connections.count == 2)

        let read = try described(store, "Stage")
        let told = try #require(read["scene"] as? [String: Any])
        #expect((told["objects"] as? [[String: Any]])?.map { $0["name"] as? String } == ["Ball", "Ring"])
        #expect((told["inputs"] as? [String: Any])?["environment"] as? String == "Night")
        #expect((read["in"] as? [String])?.contains("Ball Rotation Y: number") == true)
    }

    @Test func anAgentHearsWhatASceneCannotTake() throws {
        let store = DocumentStore()
        #expect(edit(store, [["op": "add_view", "kind": "scene", "name": "Stage"]]).errors == [])
        func problem(_ operation: [String: Any]) -> String {
            var operation = operation
            operation["op"] = "set_scene"
            operation["view"] = "Stage"
            return edit(store, [operation]).errors.first ?? ""
        }
        let before = store.document
        #expect(problem(["objects": [["name": "New", "shape": "teapot"]]]).contains("Unknown shape"))
        #expect(problem(["objects": [["name": "New"]]]).contains("needs a shape"))
        #expect(problem(["objects": [["name": "New", "model": "chair.usdz"]]]).contains("no model file"))
        #expect(problem(["objects": [["name": "Box", "wobble": 3]]]).contains("no input"))
        #expect(problem(["objects": [["name": "Box", "x": 1e300]]]).contains("too large"))
        #expect(problem(["inputs": ["environment": "Underwater"]]) != "")
        #expect(problem(["remove": ["Nobody"]]).contains("no object"))
        #expect(problem([:]).contains("Missing"))
        // A failed change leaves nothing behind.
        #expect(store.document == before)
        #expect(edit(store, [["op": "add_view", "kind": "text", "objects": [["name": "A", "shape": "box"]]]]).errors.first?.contains("Only a scene") == true)
        #expect(edit(store, [["op": "set_scene", "view": "Screen", "inputs": ["exposure": 2]]]).errors.first?.contains("not a scene view") == true)
        // A model the document has is taken.
        store.assets["chair.usdz"] = Data([1, 2, 3])
        #expect(problem(["objects": [["name": "Chair", "model": "chair.usdz"]]]) == "")
        #expect(store.document.screen.flattened.first { $0.name == "Stage" }?.scene?.object(named: "Chair")?.shape == .model)
        let read = try described(store, "Stage")
        let chair = ((read["scene"] as? [String: Any])?["objects"] as? [[String: Any]])?.first { $0["name"] as? String == "Chair" }
        #expect(chair?["shape_error"] != nil)
    }
}
