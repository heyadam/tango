import Foundation
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

/// Stands in for the process that talks to Claude: records what the app sends and lets a
/// test play the other side.
@MainActor
final class FakeTransport: AssistantTransport {
    var onMessage: (([String: Any]) -> Void)?
    var onClose: ((String?) -> Void)?
    var sent: [[String: Any]] = []
    var startError: Error?
    var stopped = false

    func start(progress: @escaping (String) -> Void) async throws {
        if let startError { throw startError }
    }

    func send(_ message: [String: Any]) { sent.append(message) }
    func stop() { stopped = true }

    func sent(_ type: String) -> [[String: Any]] { sent.filter { $0["type"] as? String == type } }
}

@MainActor
@Suite struct AssistantSessionTests {
    private func make(_ store: DocumentStore = DocumentStore()) -> (AssistantSession, FakeTransport) {
        let transport = FakeTransport()
        return (AssistantSession(store: store) { transport }, transport)
    }

    @Test func theFirstMessageStartsTheConversationWithThePatchReference() async throws {
        let (session, transport) = make()
        await session.send("  Make a button  ")
        #expect(session.isWorking)
        #expect(session.entries.map(\.kind) == [.user])
        #expect(session.entries[0].text == "Make a button")
        let start = try #require(transport.sent("start").first)
        #expect((start["systemPrompt"] as? String)?.contains("`spring`") == true)
        #expect(start["model"] == nil)
        #expect(transport.sent("user").first?["text"] as? String == "Make a button")

        // A second message reuses the conversation.
        transport.onMessage?(["type": "done"])
        await session.send("Bigger")
        #expect(transport.sent("start").count == 1)
        #expect(transport.sent("user").count == 2)
    }

    @Test func modelsAreShownByNameAndVersion() async throws {
        #expect(AssistantSession.Model.allCases.map(\.title) == ["Default", "Fable 5.2", "Opus 5.5", "Sonnet 5.5", "Haiku 5.5"])
        #expect(AssistantSession.Model.name(of: "claude-sonnet-4-5-20250929") == "Sonnet 4.5")
        #expect(AssistantSession.Model.name(of: "claude-opus-5-5[1m]") == "Opus 5.5")
        #expect(AssistantSession.Model(named: "fable") == .fable)
        #expect(AssistantSession.Model(named: "gpt") == nil)

        let (session, transport) = make()
        session.model = .sonnet
        await session.send("Hi")
        #expect(transport.sent("start").first?["model"] as? String == "claude-sonnet-5-5")
        // Claude says which model is answering; that is what names the Default choice.
        transport.onMessage?(["type": "model", "model": "claude-opus-5-5"])
        #expect(session.answeringModel == "Opus 5.5")
    }

    @Test func textArrivesInPiecesAndBecomesOneAnswer() async {
        let (session, transport) = make()
        await session.send("Hi")
        transport.onMessage?(["type": "text", "delta": "Hello"])
        transport.onMessage?(["type": "text", "delta": " there."])
        transport.onMessage?(["type": "done"])
        #expect(session.entries.map(\.kind) == [.user, .assistant])
        #expect(session.entries[1].text == "Hello there.")
        #expect(!session.isWorking)
    }

    @Test func aToolCallEditsTheDocumentAndIsAnswered() async throws {
        let store = DocumentStore()
        let (session, transport) = make(store)
        await session.send("Make a card that grows when tapped")
        transport.onMessage?([
            "type": "tool_call", "id": "call-1", "name": "edit_document",
            "input": ["operations": AssistantToolboxTests.cardBatch],
        ])
        #expect(store.document.screen.children.map(\.name) == ["Card"])
        #expect(store.document.graph.patches.count == 4)
        let answer = try #require(transport.sent("tool_result").first)
        #expect(answer["id"] as? String == "call-1")
        #expect(answer["isError"] as? Bool == false)
        #expect((answer["text"] as? String)?.contains("\"applied\":9") == true)
        #expect(session.entries.last == nil ? false : session.entries.last!.kind == .action)
        #expect(session.entries.last?.text == "Added 1 view, 4 patches, and 4 cables")
    }

    @Test func aPictureIsSentBackAsBase64() async throws {
        let (session, transport) = make()
        await session.send("Look")
        transport.onMessage?(["type": "tool_call", "id": "call-7", "name": "view_prototype", "input": [:]])
        let answer = try #require(transport.sent("tool_result").first)
        let image = try #require((answer["images"] as? [String])?.first)
        #expect(Data(base64Encoded: image)?.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true)
    }

    @Test func theSelectionTravelsWithTheMessage() async throws {
        let store = DocumentStore(package: DocumentPackage(document: SampleDocuments.card().document))
        let card = try #require(store.document.screen.flattened.first { $0.name == "Card" })
        store.selectedLayers = [card.id]
        let (session, transport) = make(store)
        await session.send("Make this green")
        let text = try #require(transport.sent("user").first?["text"] as? String)
        #expect(text.hasPrefix("[Selected views: Card (\(AssistantToolbox.short(card.id)))]"))
        #expect(text.hasSuffix("Make this green"))
        // The transcript shows what the person typed, not the note for the model.
        #expect(session.entries[0].text == "Make this green")
    }

    @Test func aSignedOutErrorOffersSigningIn() async {
        let (session, transport) = make()
        await session.send("Hi")
        transport.onMessage?(["type": "error", "message": "Failed to authenticate: run `claude auth login`"])
        transport.onMessage?(["type": "done"])
        #expect(session.entries.last?.kind == .signIn)
        #expect(!session.isWorking)
    }

    @Test func aFailedStartIsReportedAndCanBeRetried() async {
        let transport = FakeTransport()
        transport.startError = AssistantSetupError(message: "The assistant needs Node.js.")
        let session = AssistantSession(store: DocumentStore()) { transport }
        await session.send("Hi")
        #expect(session.entries.map(\.kind) == [.user, .problem])
        #expect(!session.isWorking)
        transport.startError = nil
        await session.send("Hi again")
        #expect(session.isWorking)
        #expect(transport.sent("user").count == 1)
    }

    @Test func stoppingInterruptsAndANewChatClearsTheTranscript() async {
        let (session, transport) = make()
        await session.send("Hi")
        session.stop()
        #expect(transport.sent("interrupt").count == 1)
        transport.onMessage?(["type": "done"])
        #expect(!session.isWorking)
        session.newChat()
        #expect(session.entries.isEmpty)
        #expect(transport.stopped)
    }

    @Test func aProcessThatDiesMidAnswerIsReported() async {
        let (session, transport) = make()
        await session.send("Hi")
        transport.onClose?("node: bad things")
        #expect(session.entries.last?.kind == .problem)
        #expect(session.entries.last?.text == "node: bad things")
        #expect(!session.isWorking)
    }
}

/// While the model writes a tool call the status line says what it is planning.
@MainActor
@Suite struct AssistantProgressTests {
    @Test func theStatusFollowsACallWhileItIsWritten() async throws {
        let store = DocumentStore()
        let transport = FakeTransport()
        let session = AssistantSession(store: store) { transport }
        await session.send("Make a weather app")
        let before = store.fullDocument

        transport.onMessage?(["type": "thinking"])
        #expect(session.status == "Thinking…")
        transport.onMessage?(["type": "tool_start", "name": "edit_document"])
        #expect(session.status == "Planning changes…")
        transport.onMessage?(["type": "tool_item", "name": "edit_document",
                              "item": ["op": "add_view", "kind": "text", "name": "Temperature"]])
        #expect(session.status == "1 change planned · Adding text “Temperature”…")
        transport.onMessage?(["type": "tool_item", "name": "edit_document",
                              "item": ["op": "connect", "from": "Tap", "output": "tap", "to": "Navigate", "input": "go"]])
        #expect(session.status == "2 changes planned · Connecting Tap → Navigate…")
        // Planning changes nothing and adds no entry; only the call itself does.
        #expect(store.fullDocument == before)
        #expect(session.entries.map(\.kind) == [.user])

        // The next call counts from one again.
        transport.onMessage?(["type": "tool_start", "name": "interact_prototype"])
        transport.onMessage?(["type": "tool_item", "name": "interact_prototype", "item": ["do": "tap", "at": ["x": 1, "y": 2]]])
        #expect(session.status == "1 step planned · Tapping…")
        transport.onMessage?(["type": "done"])
        #expect(session.status == "")
    }

    @Test func operationsReadAsAPersonWouldSayThem() {
        let say = { (op: [String: Any]) in AssistantProgress.operation(op) }
        #expect(say(["op": "add_view", "kind": "image", "name": "Icon"]) == "Adding an image “Icon”")
        #expect(say(["op": "add_view", "kind": "screen", "name": "Forecast"]) == "Adding a screen “Forecast”")
        #expect(say(["op": "add_view", "kind": "textField"]) == "Adding a text field")
        #expect(say(["op": "add_patch", "kind": "networkRequest"]) == "Adding a network request patch")
        #expect(say(["op": "add_flow", "from": "Row", "to": "Detail"]) == "Adding a flow to “Detail”")
        #expect(say(["op": "set_properties", "view": "Card"]) == "Styling “Card”")
        #expect(say(["op": "something_new"]) == "Editing")
        #expect(say(["op": "add_view", "name": String(repeating: "x", count: 50)]).count < 50)
    }
}
