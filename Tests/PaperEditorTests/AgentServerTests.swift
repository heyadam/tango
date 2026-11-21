import Foundation
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

@MainActor
@Suite struct AgentServerTests {
    private func ask(_ server: AgentServer, _ method: String, _ params: [String: Any] = [:], id: Any? = 1) throws -> [String: Any] {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if let id { message["id"] = id }
        let answer = try #require(server.handle(try JSONSerialization.data(withJSONObject: message)))
        return try #require(try JSONSerialization.jsonObject(with: answer) as? [String: Any])
    }

    /// The text and images a tool call came back with.
    private func call(_ server: AgentServer, _ name: String, _ arguments: [String: Any] = [:]) throws -> (text: String, images: Int, isError: Bool) {
        let answer = try ask(server, "tools/call", ["name": name, "arguments": arguments])
        let result = try #require(answer["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        return (
            content.first { $0["type"] as? String == "text" }?["text"] as? String ?? "",
            content.count { $0["type"] as? String == "image" },
            result["isError"] as? Bool ?? false
        )
    }

    private func server(_ stores: (String, DocumentStore)...) -> AgentServer {
        let documents = OpenDocuments()
        for (name, store) in stores { documents.open(store, name: name) }
        return AgentServer(documents: documents)
    }

    @Test func aClientCanShakeHandsAndListTheTools() throws {
        let server = server()
        let hello = try ask(server, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:]], id: "a")
        #expect(hello["id"] as? String == "a")
        let result = try #require(hello["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
        #expect((result["instructions"] as? String)?.contains("get_reference") == true)

        // A version we do not know is answered with one we do.
        let future = try ask(server, "initialize", ["protocolVersion": "2099-01-01"])
        #expect((future["result"] as? [String: Any])?["protocolVersion"] as? String == AgentServer.protocolVersions[0])

        let list = try ask(server, "tools/list")
        let tools = try #require((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == [
            "get_reference", "list_documents", "get_document", "edit_document",
            "view_prototype", "interact_prototype", "undo", "redo",
            "mark_baseline", "get_changes", "compare_prototype",
        ])
        for tool in tools { #expect((tool["inputSchema"] as? [String: Any])?["type"] as? String == "object") }
    }

    @Test func notificationsAreNotAnsweredAndUnknownMethodsAreRefused() throws {
        let server = server()
        let note = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"])
        #expect(server.handle(note) == nil)
        let unknown = try ask(server, "resources/list")
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
        let garbage = try #require(server.handle(Data("not json".utf8)))
        #expect(String(decoding: garbage, as: UTF8.self).contains("-32700"))
        let noTool = try ask(server, "tools/call", ["name": "format_disk"])
        #expect((noTool["error"] as? [String: Any])?["code"] as? Int == -32602)
        #expect(try ask(server, "ping")["result"] != nil)
    }

    @Test func anEditLandsInTheOpenDocumentAsOneUndoStep() throws {
        let store = DocumentStore()
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        let server = server(("Untitled", store))
        let empty = store.document

        undo.beginUndoGrouping()
        let edit = try call(server, "edit_document", ["operations": AssistantToolboxTests.cardBatch])
        undo.endUndoGrouping()
        #expect(!edit.isError)
        #expect(store.document.screen.children.first?.name == "Card")
        #expect(undo.undoActionName == "Agent Edit")

        let read = try call(server, "get_document")
        #expect(read.text.contains("Card"))

        let undone = try call(server, "undo")
        #expect(undone.text == "Undid Agent Edit.")
        #expect(store.document == empty)
        let redone = try call(server, "redo")
        #expect(!redone.isError)
        #expect(store.document.screen.children.count == 1)
        #expect(try call(server, "redo").isError)
    }

    @Test func aCallNamesItsDocumentOrGetsTheFrontOne() throws {
        let first = DocumentStore()
        let second = DocumentStore()
        let documents = OpenDocuments()
        documents.open(first, name: "Checkout")
        documents.open(second, name: "Onboarding")
        documents.bringToFront(first)
        let server = AgentServer(documents: documents)
        let layer: [[String: Any]] = [["op": "add_view", "kind": "view", "name": "Box"]]

        _ = try call(server, "edit_document", ["operations": layer])
        #expect(first.document.screen.children.count == 1)
        #expect(second.document.screen.children.isEmpty)

        _ = try call(server, "edit_document", ["operations": layer, "document": "onboarding"])
        #expect(second.document.screen.children.count == 1)
        _ = try call(server, "edit_document", ["operations": layer, "document": "doc2"])
        #expect(second.document.screen.children.count == 2)

        let list = try call(server, "list_documents").text
        #expect(list.contains("Checkout") && list.contains("Onboarding") && list.contains("doc1"))

        let missing = try call(server, "get_document", ["document": "Nope"])
        #expect(missing.isError && missing.text.contains("Checkout"))

        documents.close(first)
        documents.close(second)
        let none = try call(server, "get_document")
        #expect(none.isError && none.text.contains("No document is open"))
    }

    @Test func aWindowThatWentAwayIsForgotten() throws {
        let documents = OpenDocuments()
        do {
            let store = DocumentStore()
            documents.open(store, name: "Gone")
            #expect(documents.all.count == 1)
        }
        #expect(documents.all.isEmpty)
    }

    @Test func theReferenceTeachesTheOperationsAndPatches() throws {
        let reference = try call(server(), "get_reference").text
        #expect(reference.contains("# edit_document operations"))
        #expect(reference.contains("`spring`"))
        #expect(!reference.contains("You are the assistant"))
        // The built-in assistant still gets the same reference after its introduction. An
        // outside agent gets two things more: to build in steps it can be seen taking, since
        // its calls arrive whole, and how to sketch a screen from the code it can read.
        // The first comes before the reference, where an agent that reads only the start of a
        // long answer still sees it.
        #expect(reference.hasPrefix(AgentServer.pacingGuide + "\n\n"))
        #expect(reference.hasSuffix("\n\n" + AgentServer.sketchGuide))
        let shared = String(reference
            .dropFirst((AgentServer.pacingGuide + "\n\n").count)
            .dropLast(("\n\n" + AgentServer.sketchGuide).count))
        #expect(AssistantPrompt.system(registry: .standard, components: []).hasSuffix(shared))
    }

    @Test func touchesInARowGiveAPictureAtEachLook() throws {
        let store = DocumentStore(package: DocumentPackage(document: SampleDocuments.scrollingList().document))
        let server = server(("List", store))
        let result = try call(server, "interact_prototype", ["steps": [
            ["do": "look"],
            ["do": "drag", "from": ["x": 195, "y": 600], "to": ["x": 195, "y": 300], "seconds": 0.3],
            ["do": "wait", "seconds": 1],
        ]])
        #expect(!result.isError)
        #expect(result.images == 2)
        #expect(result.text.contains("dragged from 195, 600 to 195, 300"))
        #expect(store.runtime == nil)

        let bad = try call(server, "interact_prototype", ["steps": [["do": "pinch"]]])
        #expect(bad.isError)
    }

    @Test func anAgentUsesTwoFingers() throws {
        let example = SampleDocuments.pinchZoom()
        let store = DocumentStore(package: DocumentPackage(document: example.document))
        let server = server(("Pinch", store))
        // Two fingers of its own, looked at while both are down, and a pinch that also travels.
        let result = try call(server, "interact_prototype", ["steps": [
            ["do": "down", "at": ["x": 150, "y": 400]],
            ["do": "down", "finger": 2, "at": ["x": 250, "y": 400]],
            ["do": "move", "finger": 2, "to": ["x": 330, "y": 400], "seconds": 0.3],
            ["do": "look"],
            ["do": "up", "finger": 2], ["do": "up"], ["do": "wait", "seconds": 1],
            ["do": "pinch", "at": ["x": 195, "y": 400], "scale": 1.6, "rotation": 30, "pan": ["x": 30, "y": 40]],
        ]])
        #expect(!result.isError)
        #expect(result.images == 2)
        #expect(result.text.contains("second finger down at 250, 400"))
        #expect(result.text.contains("moved the second finger to 330, 400"))
        #expect(result.text.contains("spread to 1.6 times as far apart, turned 30°, carried 30, 40"))

        // What the first picture shows: the photo pinched larger with both fingers down.
        let held = ViewerSnapshot.bitmaps(of: example.document, steps: [
            .look, .down(Point2(x: 150, y: 400)), .down(Point2(x: 250, y: 400), finger: 2),
            .move(to: Point2(x: 330, y: 400), seconds: 0.3, finger: 2), .look,
        ]).compactMap { $0.representation(using: .png, properties: [:]) }
        #expect(held.count == 2 && held[0] != held[1])

        for steps in [
            [["do": "down", "finger": 3, "at": ["x": 1, "y": 1]]],
            [["do": "down", "at": ["x": 1, "y": 1]], ["do": "move", "finger": 2, "to": ["x": 9, "y": 9]]],
            [["do": "pinch", "at": ["x": 1, "y": 1], "pan": "left"]],
        ] as [[[String: Any]]] {
            #expect(try call(server, "interact_prototype", ["steps": steps]).isError)
        }
        // The tool says what a step may hold.
        let tools = try #require(try ask(server, "tools/list")["result"] as? [String: Any])
        #expect(String(describing: tools).contains("finger"))
    }

    @Test func aDragMovesWhatItTouches() throws {
        let document = SampleDocuments.scrollingList().document
        let pictures = ViewerSnapshot.bitmaps(of: document, steps: [
            .look,
            .drag(from: Point2(x: 195, y: 600), to: Point2(x: 195, y: 300), seconds: 0.3),
            .wait(1), .look,
            .wait(100), .look,
        ])
        #expect(pictures.count == 3)
        let data = pictures.compactMap { $0.representation(using: .png, properties: [:]) }
        #expect(data[0] != data[1])
        // The one-tap picture is the same code path.
        #expect(ViewerSnapshot.bitmap(of: document)?.representation(using: .png, properties: [:]) == data[0])
    }

    /// An outside agent builds screens, a tab bar over all of them, and every kind of flow,
    /// reads them back, and looks at a screen in the middle of the flow.
    @Test func anAgentBuildsScreensAndFlowsOverMCP() throws {
        let store = DocumentStore()
        let server = server(("Flows", store))
        let reference = try call(server, "get_reference").text
        for word in ["add_flow", "kind `screen`", "Morph", "parent: \"device\"", "`screen`: the run starts there"] {
            #expect(reference.contains(word), "\(word)")
        }
        let tools = try ask(server, "tools/list")
        let list = try #require((tools["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        for name in ["view_prototype", "interact_prototype"] {
            let schema = try #require(list.first { $0["name"] as? String == name }?["inputSchema"] as? [String: Any])
            #expect((schema["properties"] as? [String: Any])?["screen"] != nil, "\(name)")
        }

        let batch: [[String: Any]] = [
            ["op": "add_view", "kind": "screen", "name": "Feed", "ref": "feed"],
            ["op": "add_view", "kind": "view", "name": "Card", "ref": "card", "parent": "feed",
             "properties": ["x": 16, "y": 120, "width": 358, "height": 200, "fill": "#5E5CE6"]],
            ["op": "add_view", "kind": "screen", "name": "Detail", "ref": "detail"],
            ["op": "add_view", "kind": "view", "name": "Card", "parent": "detail",
             "properties": ["x": 0, "y": 0, "width": 390, "height": 400, "fill": "#5E5CE6"]],
            ["op": "add_view", "kind": "view", "name": "Close", "ref": "close", "parent": "detail",
             "properties": ["x": 16, "y": 500, "width": 100, "height": 44]],
            ["op": "add_view", "kind": "view", "name": "Tab Bar", "parent": "device",
             "properties": ["x": 0, "y": 760, "width": 390, "height": 84, "fill": "#FFFFFF"]],
            ["op": "add_view", "kind": "view", "name": "Loose"],
            ["op": "add_flow", "from": "card", "to": "detail", "style": "Morph"],
            ["op": "add_flow", "from": "close", "back": true],
        ]
        let edit = try call(server, "edit_document", ["operations": batch])
        #expect(!edit.isError, "\(edit.text)")
        #expect(!edit.text.contains("\"error\""), "\(edit.text)")
        #expect(store.screens.map(\.name) == ["Feed", "Detail"])
        // A view with no parent goes on a screen; the tab bar floats over both.
        #expect(store.screen(holding: try #require(store.document.screen.flattened.first { $0.name == "Loose" }).id) != nil)
        #expect(store.document.screen.children.map(\.name) == ["Feed", "Detail", "Tab Bar"])
        #expect(store.flows.map(\.style) == [.morph, .push])

        let document = try call(server, "get_document").text
        let read = try #require(try JSONSerialization.jsonObject(with: Data(document.utf8)) as? [String: Any])
        #expect((read["flows"] as? [[String: Any]])?.first?["style"] as? String == "Morph")
        let tree = try #require((read["views"] as? [String: Any])?["children"] as? [[String: Any]])
        #expect(tree.filter { $0["screen"] as? Bool == true }.count == 2)

        // A look that starts on the detail, and a run from there that goes back.
        let look = try call(server, "view_prototype", ["screen": "Detail"])
        #expect(!look.isError && look.images == 1 && look.text.contains("on the screen Detail"))
        let run = try call(server, "interact_prototype", ["screen": "Detail", "steps": [["do": "tap", "at": ["x": 60, "y": 520]], ["do": "wait", "seconds": 1]]])
        #expect(!run.isError && run.images == 1)
        #expect(try call(server, "view_prototype", ["screen": "Card"]).isError)
    }
}
