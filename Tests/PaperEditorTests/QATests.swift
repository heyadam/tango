import AppKit
import Foundation
import Testing
import PaperEngine
import PaperHost
import PaperModel
@testable import PaperEditor

/// Defects found in the QA pass, each pinned by a test.
@MainActor
@Suite struct QATests {
    private func call(_ store: DocumentStore, _ name: String, _ input: [String: Any] = [:]) -> AssistantToolResult {
        AssistantToolbox(store: store).call(name, input: input)
    }

    @Test func numbersThatCannotBeDrawnOrSavedAreRefused() throws {
        #expect(AssistantToolbox.number("nan") == nil)
        #expect(AssistantToolbox.number("inf") == nil)
        #expect(AssistantToolbox.number(1e300) == nil)
        #expect(AssistantToolbox.number(-12.5) == -12.5)
        #expect(AssistantToolbox.number(true) == nil)
        #expect(AssistantToolbox.whole(2.6) == 3)

        let store = DocumentStore()
        let result = call(store, "edit_document", ["operations": [
            ["op": "add_view", "kind": "view", "name": "Box", "ref": "box"],
            ["op": "set_properties", "view": "box", "properties": ["position": ["x": "nan", "y": 0]]],
            ["op": "set_properties", "view": "box", "properties": ["size": "inf"]],
            ["op": "set_properties", "view": "box", "properties": ["opacity": "nan"]],
            ["op": "move_view", "view": "box", "index": 1e300],
            ["op": "add_patch", "kind": "loopBuilder", "input_count": "nan"],
        ] as [[String: Any]]])
        #expect(!result.isError)
        let box = try #require(store.document.screen.children.first)
        #expect(box.value(.position).pointValue == .zero)
        #expect(box.value(.size).sizeValue == Size2(width: 100, height: 100))
        #expect(box.value(.opacity).numberValue == 1)
        // Reading, saving and drawing all still work.
        #expect(call(store, "get_document").text.contains("Box"))
        #expect((try? store.package.document.encoded()) != nil)
        #expect(call(store, "view_prototype").image != nil)

        // A value that got in some other way is written as null, not a crash.
        #expect(AssistantToolbox.json(["v": AssistantToolbox.plain(.number(.nan))]) == "{\"v\":null}")
        #expect(AssistantToolbox.json(["v": AssistantToolbox.plain(.point(Point2(x: .infinity, y: 1)))]).contains("null"))
        #expect(PatchEditorView.parse("nan, 4", as: .point) == nil)
        #expect(PatchEditorView.parse("inf", as: .size) == nil)
    }

    /// Second round: the same refusal has to hold however the number is written, and
    /// refusing must not itself crash.
    @Test func badNumbersAreRefusedInEveryForm() throws {
        // What JSON parsing gives for -1e999.
        let infinity = NSNumber(value: -Double.infinity)
        let store = DocumentStore()
        let result = call(store, "edit_document", ["operations": [
            ["op": "add_view", "kind": "view", "name": "Box", "ref": "box"],
            ["op": "set_properties", "view": "box", "properties": ["rotation": infinity]],
            ["op": "set_properties", "view": "box", "properties": ["position": ["x": infinity, "y": 0]]],
            ["op": "set_properties", "view": "box", "properties": ["position": [infinity, 0]]],
            ["op": "set_properties", "view": "box", "properties": ["size": 1e300]],
            ["op": "set_properties", "view": "box", "properties": ["cornerRadius": "1e300"]],
            ["op": "set_properties", "view": "box", "properties": ["position": "1e400, 4"]],
            ["op": "set_properties", "view": "screen", "properties": ["size": 1e12]],
            ["op": "add_patch", "kind": "value", "type": "number", "inputs": ["value": infinity]],
        ] as [[String: Any]]])
        let answer = try #require(try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
        #expect((answer["errors"] as? [[String: Any]])?.count == 8)
        let box = try #require(store.document.screen.children.first)
        #expect(box.properties.isEmpty || box.properties.keys.allSatisfy { $0 == .position || $0 == .size || $0 == .fill } )
        #expect(box.value(.rotation).numberValue == 0)
        #expect(box.value(.position).pointValue == .zero)
        #expect(store.document.screen.value(.size).sizeValue == Size2(width: 390, height: 844))
        #expect((try? store.package.document.encoded()) != nil)
        #expect(call(store, "view_prototype").image != nil)
        #expect(AssistantToolbox.json(["v": Double.infinity]) == "{}")
        #expect(throws: AssistantToolbox.Problem.self) { try AssistantToolbox.value([1, infinity], as: .array) }
        #expect(try AssistantToolbox.value([1, "a"], as: .array) == .array([.number(1), .text("a")]))
        #expect(try AssistantToolbox.value(42, as: .number) == .number(42))
    }

    @Test func twoTapsInARowAreADoubleTap() throws {
        let box = Layer(name: "Box", kind: .view, properties: [
            .size: .size(Size2(width: 390, height: 400)), .fill: .color(Layer.viewFill),
        ])
        var screen = Layer(name: "Screen", kind: .screen)
        screen.children = [box]
        let touch = PatchNode.interaction(on: box.id, position: .zero)
        let flag = PatchNode(kind: "switch", position: .zero)
        let fill = PatchNode.view(of: box.id)
        let not = PatchNode(kind: "not", position: .zero)
        let document = PaperModel.Document(screen: screen, graph: Graph(nodes: [touch, flag, not, fill], connections: [
            Connection(from: PortRef(node: touch.id, port: "doubleTap"), to: PortRef(node: flag.id, port: "flip")),
            Connection(from: PortRef(node: flag.id, port: "on"), to: PortRef(node: not.id, port: "value")),
            Connection(from: PortRef(node: not.id, port: "result"), to: PortRef(node: fill.id, port: "opacity")),
        ]))
        let at = Point2(x: 100, y: 100)
        let pictures = ViewerSnapshot.bitmaps(of: document, steps: [.tap(at), .look, .tap(at), .look])
            .compactMap { $0.representation(using: .png, properties: [:]) }
        // One tap changes nothing; the second makes it a double tap and the box goes.
        #expect(pictures.count == 2)
        #expect(pictures[0] != pictures[1])
    }

    @Test func undoDuringADragUndoesSomethingReal() {
        let store = DocumentStore()
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        undo.beginUndoGrouping()
        let box = store.addLayer(.view, frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        undo.endUndoGrouping()

        // The person is mid-drag when the agent's undo arrives. The drag is closed as a
        // step first (an undo manager in a test needs its group closed by hand).
        undo.beginUndoGrouping()
        store.interactive { $0.screen.update(box) { $0.set(.position, .point(Point2(x: 80, y: 0))) } }
        store.finishInteractive()
        undo.endUndoGrouping()
        let result = call(store, "undo")
        // The drag was closed as a step, and that is the step that was undone.
        #expect(!result.isError)
        #expect(store.document.layer(box)?.value(.position).pointValue == .zero)
        #expect(store.document.screen.children.count == 1)
    }

    @Test func anImpossiblyLargeScreenGivesNoPictureInsteadOfACrash() {
        let store = DocumentStore()
        _ = call(store, "edit_document", ["operations": [
            ["op": "set_properties", "view": "screen", "properties": ["size": ["width": 900_000, "height": 900_000]]],
        ] as [[String: Any]]])
        #expect(call(store, "view_prototype").isError)
    }

    @Test func aPictureRightAfterATouchShowsTheTouch() throws {
        let document = SampleDocuments.signIn().document
        // No wait between the tap, the typing and the picture.
        let pictures = ViewerSnapshot.bitmaps(of: document, steps: [.look, .tap(Point2(x: 100, y: 372)), .type("Ada"), .look])
            .compactMap { $0.representation(using: .png, properties: [:]) }
        #expect(pictures.count == 2)
        #expect(pictures[0] != pictures[1])

        // A swipe has fired by the time the picture is taken.
        let menu = SampleDocuments.swipeMenu()
        let store = DocumentStore(package: DocumentPackage(document: menu.document))
        let swiped = call(store, "interact_prototype", ["steps": [
            ["do": "look"],
            ["do": "drag", "from": ["x": 300, "y": 180], "to": ["x": 120, "y": 180], "seconds": 0.1],
            ["do": "look"],
            ["do": "wait", "seconds": 1],
        ] as [[String: Any]]])
        #expect(swiped.images.count == 3)
        #expect(swiped.images[1] != swiped.images[2])
    }

    @Test func picturesSendNothingOverTheNetwork() {
        // The live-data example asks for its list at start. In a picture it just stays loading.
        let live = SampleDocuments.liveList().document
        // A Viewer made for pictures never hands a request on, even the one on its first frame.
        let quiet = ViewerView(store: DocumentStore(package: DocumentPackage(document: live)), sendsRequests: false)
        for _ in 0..<30 { quiet.advance(by: 1.0 / 60.0) }
        let request = quiet.runtime.document.graph.nodes.first { $0.kind == "networkRequest" }!
        #expect(quiet.runtime.outputValue(PortRef(node: request.id, port: "loading"))?.boolValue == true)
        #expect(quiet.runtime.outputValue(PortRef(node: request.id, port: "hasError"))?.boolValue == false)
        #expect(ViewerSnapshot.bitmap(of: live, seconds: 0.5) != nil)
        let store = DocumentStore(package: DocumentPackage(document: live))
        #expect(call(store, "interact_prototype", ["steps": [["do": "look"]]]).text.contains("Network requests and AI calls are not sent"))
    }

    @Test func anAgentEditDuringADragStaysItsOwnUndoStep() {
        let store = DocumentStore()
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        undo.beginUndoGrouping()
        let box = store.addLayer(.view, frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        undo.endUndoGrouping()

        // The person is half way through dragging the box.
        store.interactive { $0.screen.update(box) { $0.set(.position, .point(Point2(x: 80, y: 0))) } }
        undo.beginUndoGrouping()
        _ = call(store, "edit_document", ["operations": [["op": "add_view", "kind": "ellipse", "name": "Dot"]]])
        undo.endUndoGrouping()
        #expect(store.document.screen.children.count == 2)

        // Undo takes the agent's edit away and leaves the drag.
        undo.undo()
        #expect(store.document.screen.children.count == 1)
        #expect(store.document.layer(box)?.value(.position).pointValue == Point2(x: 80, y: 0))
        undo.undo()
        #expect(store.document.layer(box)?.value(.position).pointValue == .zero)
    }

    @Test func aDocumentKeepsItsIdWhenItsWindowComesBack() {
        let documents = OpenDocuments()
        let first = DocumentStore()
        let second = DocumentStore()
        documents.open(first, name: "A")
        documents.open(second, name: "B")
        documents.close(first)
        #expect(documents.all.map(\.entry.id) == ["doc2"])
        documents.open(first, name: "A2")
        #expect(documents.all.map(\.entry.id).sorted() == ["doc1", "doc2"])
        #expect(documents.all.first { $0.entry.id == "doc1" }?.entry.name == "A2")
    }

    private func key(_ characters: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: 0
        )!
    }

    @Test func onlyPrintableKeysTypeAndNoneLeakToKeyboardPatches() throws {
        // A field, and a Keyboard patch listening for "a".
        let field = Layer(name: "Field", kind: .textField, properties: [.size: .size(Size2(width: 390, height: 60))])
        var screen = Layer(name: "Screen", kind: .screen)
        screen.children = [field]
        let keyboard = PatchNode(kind: "keyboard", position: .zero, inputs: ["key": .text("a")])
        let input = PatchNode(kind: "textInput", position: .zero, layerID: field.id)
        let document = PaperModel.Document(screen: screen, graph: Graph(nodes: [keyboard, input]))
        let view = ViewerView(store: DocumentStore(package: DocumentPackage(document: document)))
        view.fillsWindow = true
        view.frame = NSRect(x: 0, y: 0, width: 390, height: 844)
        view.layoutSubtreeIfNeeded()
        func run() { for _ in 0..<4 { view.advance(by: 1.0 / 60.0) } }
        func text() -> String { view.runtime.outputValue(PortRef(node: input.id, port: "text"))!.textValue }
        func held() -> Bool { view.runtime.outputValue(PortRef(node: keyboard.id, port: "down"))!.boolValue }
        run()

        // Not editing: the key goes to the Keyboard patch.
        view.keyDown(with: key("a"))
        run()
        #expect(held() && text() == "")
        view.keyUp(with: key("a"))
        view.runtime.send(.touchDown(Point2(x: 50, y: 30)))
        run()
        view.runtime.send(.touchUp(Point2(x: 50, y: 30)))
        run()
        #expect(view.runtime.isEditingText)

        view.keyDown(with: key("a"))
        view.keyDown(with: key("\u{01}", .control))
        view.keyDown(with: key("b\u{07}"))
        run()
        #expect(text() == "ab")
        #expect(!held())
        view.keyDown(with: key("\u{7F}"))
        run()
        #expect(text() == "a")
    }

    /// Found by `RandomizedTests`: a pulse stored as firing fired every frame until the
    /// document was saved and opened again, and then never (pulses are written as off).
    @Test func aPulseInputIsNeverStoredAsFiring() throws {
        let store = DocumentStore()
        let id = store.addPatch("impulse")
        store.setLiteral(.pulse(true), node: id, port: "trigger")
        let node = try #require(store.document.graph.node(id))
        #expect(node.inputs["trigger"] != .pulse(true))
        let read = try JSONDecoder().decode(PaperModel.Document.self, from: JSONEncoder().encode(store.fullDocument))
        #expect(read == store.fullDocument)
    }
}

@Suite struct NetworkRequestSendingTests {
    @Test func aDocumentsRequestCannotDriveTheAppOrPoseAsABrowser() throws {
        let request = NetworkRequest.forPatch(
            url: "http://localhost:47821/mcp", method: "POST", body: #"{"jsonrpc":"2.0"}"#,
            headers: "Origin: https://example.com\nCookie: a=b\nHost: evil\nX-Token: 1", query: ""
        )
        let outgoing = PrototypeNetwork.urlRequest(for: request, url: try #require(URL(string: request.url)))
        // The agent port refuses any request with an Origin; this one has `null`.
        #expect(outgoing.value(forHTTPHeaderField: "Origin") == "null")
        #expect(outgoing.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(outgoing.value(forHTTPHeaderField: "Host") == nil)
        #expect(outgoing.value(forHTTPHeaderField: "X-Token") == "1")
        #expect(outgoing.httpMethod == "POST")
        #expect(outgoing.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func methodsHeadersAndBodiesGoOutAsAsked() throws {
        let put = NetworkRequest.forPatch(
            url: "https://api.example.com/items/3", method: "PUT", body: "name=Ada",
            headers: "Content-Type: application/x-www-form-urlencoded", query: ""
        )
        let outgoing = PrototypeNetwork.urlRequest(for: put, url: try #require(URL(string: put.url)))
        #expect(outgoing.httpMethod == "PUT")
        #expect(outgoing.httpBody == Data("name=Ada".utf8))
        #expect(outgoing.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(outgoing.value(forHTTPHeaderField: "Origin") == nil)

        let get = NetworkRequest.forPatch(url: "https://api.example.com", method: "GET", body: "x", headers: "", query: "")
        #expect(PrototypeNetwork.urlRequest(for: get, url: try #require(URL(string: get.url))).httpBody == nil)
    }

    @Test func aRedirectToThisMacIsMarkedAsWell() throws {
        // A server anywhere can answer 307 and send the POST, body and all, on to the agent port.
        let hop = URLRequest(url: try #require(URL(string: "http://127.0.0.1:47821/mcp")))
        #expect(PrototypeNetwork.guarded(hop).value(forHTTPHeaderField: "Origin") == "null")
        let elsewhere = URLRequest(url: try #require(URL(string: "https://cdn.example.com/a.png")))
        #expect(PrototypeNetwork.guarded(elsewhere).value(forHTTPHeaderField: "Origin") == nil)
    }

    @Test func aHeaderValueCannotStartAnotherHeader() throws {
        let request = NetworkRequest.forPatch(
            url: "https://api.example.com", method: "GET", body: "",
            headers: #"{"X-A": "1\r\nX-Injected: 2", "X-B": "ok"}"#, query: ""
        )
        let outgoing = PrototypeNetwork.urlRequest(for: request, url: try #require(URL(string: request.url)))
        #expect(outgoing.value(forHTTPHeaderField: "X-A") == nil)
        #expect(outgoing.value(forHTTPHeaderField: "X-B") == "ok")
    }
}
