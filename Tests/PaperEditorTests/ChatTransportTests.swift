import Foundation
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

/// The assistant's line to a model that is not Claude: what it sends, how it reads a
/// streamed answer, and that a chat over it builds as one over Claude's does.
@MainActor
@Suite struct ChatTransportTests {
    /// Answers each request with the next scripted stream, and keeps what was asked.
    @MainActor final class Server {
        var answers: [(status: Int, lines: [String])]
        var requests: [URLRequest] = []
        /// When set, a stream stays open after its lines until the request is given up.
        var holdsOpen = false

        init(_ answers: [(status: Int, lines: [String])]) {
            self.answers = answers
        }

        var bodies: [[String: Any]] {
            requests.map { (try? JSONSerialization.jsonObject(with: $0.httpBody ?? Data())) as? [String: Any] ?? [:] }
        }

        func lines(_ request: URLRequest) async throws -> (Int, AsyncThrowingStream<String, Error>) {
            requests.append(request)
            let answer = answers.isEmpty ? (status: 200, lines: [ChatTransportTests.words("")]) : answers.removeFirst()
            let open = holdsOpen
            return (answer.status, AsyncThrowingStream { continuation in
                for line in answer.lines { continuation.yield(line) }
                if !open { continuation.finish() }
            })
        }
    }

    static func chunk(_ delta: [String: Any], finish: String? = nil) -> String {
        let object: [String: Any] = ["choices": [["index": 0, "delta": delta, "finish_reason": finish as Any? ?? NSNull()]]]
        return "data: " + String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    static func words(_ text: String) -> String { chunk(["content": text]) }

    /// A tool call as a server streams it: its name first, then its arguments in pieces.
    static func call(_ name: String, _ input: [String: Any], id: String = "call_a", index: Int = 0, piece: Int = 23) -> [String] {
        let json = String(data: try! JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]), encoding: .utf8)!
        var lines = [chunk(["tool_calls": [["index": index, "id": id, "type": "function", "function": ["name": name, "arguments": ""]]]])]
        var rest = Substring(json)
        while !rest.isEmpty {
            lines.append(chunk(["tool_calls": [["index": index, "function": ["arguments": String(rest.prefix(piece))]]]]))
            rest = rest.dropFirst(piece)
        }
        return lines + [chunk([:], finish: "tool_calls"), "data: [DONE]"]
    }

    private func config(_ base: String = "https://api.openai.com/v1", pictures: Bool = true, effort: Bool = true) -> ChatTransport.Config {
        ChatTransport.Config(name: "OpenAI", base: URL(string: base)!, key: "sk-test", model: "gpt-test", sendsPictures: pictures, sendsEffort: effort)
    }

    private func session(_ server: Server, config: ChatTransport.Config? = nil, problem: String? = nil) -> (DocumentStore, AssistantSession) {
        let store = DocumentStore()
        let config = config ?? self.config()
        let session = AssistantSession(store: store, model: .init(.openAI, "gpt-test")) {
            let transport = ChatTransport(config, problem: problem)
            transport.lines = server.lines
            return transport
        }
        return (store, session)
    }

    private func finished(_ session: AssistantSession) async {
        for _ in 0..<2000 where session.isWorking { try? await Task.sleep(for: .milliseconds(2)) }
    }

    // MARK: What is sent

    @Test func aRequestCarriesThePromptTheToolsAndTheKey() throws {
        let request = ChatRequest.build(
            config(), effort: "max", system: "You build prototypes.", messages: [["role": "user", "content": "Hi"]]
        )
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "Origin") == nil)
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["model"] as? String == "gpt-test")
        #expect(body["stream"] as? Bool == true)
        // These APIs stop at high.
        #expect(body["reasoning_effort"] as? String == "high")
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
        let tools = try #require(body["tools"] as? [[String: Any]])
        let functions = tools.compactMap { $0["function"] as? [String: Any] }
        #expect(functions.compactMap { $0["name"] as? String } == ["get_document", "edit_document", "view_prototype", "interact_prototype"])
        // The assistant works on its own document: there is none to choose.
        for function in functions {
            let properties = (function["parameters"] as? [String: Any])?["properties"] as? [String: Any]
            #expect(properties?["document"] == nil)
        }
        // Gemini refuses a list of choices on a number.
        let text = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(!text.contains("\"enum\":[1,2]"))
        #expect(text.contains("\"enum\":[\"delete\",\"return\"]") || text.contains("\"enum\":[\"return\",\"delete\"]"))
    }

    @Test func aLocalServerGetsNoThinkingLevelAndCannotBeTheAppsOwnPort() throws {
        var local = config("http://localhost:8000/v1", effort: false)
        local.key = nil
        let request = ChatRequest.build(local, effort: "high", system: "", messages: [], withTools: false)
        #expect(request.url?.absoluteString == "http://localhost:8000/v1/chat/completions")
        // What the app's agent port refuses, so an address typed in Settings cannot drive it.
        #expect(request.value(forHTTPHeaderField: "Origin") == "null")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["reasoning_effort"] == nil)
        #expect(body["tools"] == nil)
        #expect(ChatRequest.models(base: local.base, key: nil).value(forHTTPHeaderField: "Origin") == "null")
        #expect(ChatRequest.reasoning("low") == "low" && ChatRequest.reasoning(nil) == nil && ChatRequest.reasoning("xhigh") == "high")
    }

    @Test func picturesGoAsPicturesOrAsANote() throws {
        let picture: [[String: Any]] = [["label": "Sketch.png", "data": "QUJD", "mediaType": "image/jpeg"]]
        let shown = ChatRequest.user("Build this", pictures: picture, shown: true)
        let content = try #require(shown["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["text", "text", "image_url"])
        #expect((content[2]["image_url"] as? [String: Any])?["url"] as? String == "data:image/jpeg;base64,QUJD")
        let told = ChatRequest.user("Build this", pictures: picture, shown: false)
        #expect((told["content"] as? String)?.contains("not shown pictures") == true)
        #expect(ChatRequest.user("Hi", pictures: [], shown: true)["content"] as? String == "Hi")
    }

    @Test func aServersModelsAreRead() {
        let openAI = Data(#"{"object":"list","data":[{"id":"qwen3-coder"},{"id":"gemma-3"}]}"#.utf8)
        #expect(ChatRequest.modelIDs(in: openAI) == ["gemma-3", "qwen3-coder"])
        #expect(ChatRequest.modelIDs(in: Data("nothing".utf8)) == [])
    }

    // MARK: Reading an answer

    @Test func aCallIsReadWhileItIsWritten() throws {
        var stream = ChatStream(request: 3)
        var events: [[String: Any]] = []
        events += stream.read(Self.chunk(["reasoning_content": "Let me think"]))
        events += stream.read(Self.chunk(["reasoning_content": " some more"]))
        events += stream.read(Self.words("Adding "))
        events += stream.read(Self.words("a card."))
        let operations: [[String: Any]] = [
            ["op": "add_view", "kind": "view", "name": "A {brace} \"quoted\" [name]"],
            ["op": "set_properties", "view": "A", "properties": ["width": 120]],
        ]
        for line in Self.call("edit_document", ["operations": operations], piece: 7) { events += stream.read(line) }
        #expect(events.map { $0["type"] as? String } == ["thinking", "text", "text", "tool_start", "tool_item", "tool_item"])
        // Each operation is known as soon as it is closed, braces in its text and all.
        let items = events.compactMap { $0["item"] as? [String: Any] }
        #expect(items.first?["name"] as? String == "A {brace} \"quoted\" [name]")
        #expect(items.last?["op"] as? String == "set_properties")
        #expect(events[3]["useId"] as? String == "use-3-0")
        let call = try #require(stream.calls.first)
        #expect(call.id == "call_a" && call.name == "edit_document")
        #expect((call.input?["operations"] as? [[String: Any]])?.count == 2)
        #expect(stream.message["content"] as? String == "Adding a card.")
        #expect((stream.message["tool_calls"] as? [[String: Any]])?.first?["id"] as? String == "call_a")
    }

    @Test func callsSentWholeAndWhatCameWithThemAreKept() throws {
        // Gemini sends a call in one piece, with no place in the list, and a signature it
        // wants back; some local servers give every call the same id or none.
        var stream = ChatStream(request: 1)
        let signature: [String: Any] = ["google": ["thought_signature": "abc"]]
        var events = stream.read(Self.chunk(["tool_calls": [[
            "id": "", "type": "function", "extra_content": signature,
            "function": ["name": "get_document", "arguments": "{}"],
        ]]]))
        events += stream.read(Self.chunk(["tool_calls": [[
            "id": "second", "type": "function", "function": ["name": "view_prototype", "arguments": "{\"seconds\":1}"],
        ]]]))
        #expect(events.map { $0["name"] as? String } == ["get_document", "view_prototype"])
        #expect(stream.calls.map(\.name) == ["get_document", "view_prototype"])
        #expect(stream.calls[0].id == "call_1_0")
        let kept = try #require(stream.message["tool_calls"] as? [[String: Any]])
        #expect(NSDictionary(dictionary: kept[0]["extra_content"] as? [String: Any] ?? [:]).isEqual(to: signature))
        #expect(stream.message["content"] is NSNull)

        // With neither a place nor an id, a piece that names a function is a new call.
        var bare = ChatStream(request: 2)
        for name in ["get_document", "view_prototype"] {
            _ = bare.read(Self.chunk(["tool_calls": [["function": ["name": name, "arguments": "{"]]]]))
            _ = bare.read(Self.chunk(["tool_calls": [["function": ["arguments": "}"]]]]))
        }
        #expect(bare.calls.map(\.name) == ["get_document", "view_prototype"])
        #expect(bare.calls.map(\.arguments) == ["{}", "{}"])

        var failed = ChatStream(request: 1)
        _ = failed.read(#"data: {"error":{"message":"The model is overloaded."}}"#)
        #expect(failed.failure == "The model is overloaded.")
        #expect(failed.read(": keep-alive").isEmpty && failed.read("data: [DONE]").isEmpty)
    }

    // MARK: A whole chat

    @Test func aChatBuildsWhileTheModelWritesAndHearsWhatItBuilt() async throws {
        let server = Server([
            (200, [Self.words("I'll build it.")] + Self.call("edit_document", ["operations": AssistantToolboxTests.cardBatch])),
            (200, [Self.words("The card grows when tapped."), "data: [DONE]"]),
        ])
        let (store, session) = session(server)
        session.effort = .medium
        await session.send("Make a card that grows when tapped")
        await finished(session)

        #expect(store.document.screen.children.map(\.name) == ["Card"])
        #expect(store.document.graph.patches.count == 4)
        #expect(session.entries.map(\.kind) == [.user, .assistant, .action, .assistant, .changes])
        #expect(session.entries[2].text == "Added 1 view, 4 patches, and 4 cables")
        #expect(session.entries[3].text == "The card grows when tapped.")

        // The second request tells the model what its call did, in the API's own terms.
        #expect(server.requests.count == 2)
        #expect(server.bodies[0]["reasoning_effort"] as? String == "medium")
        let messages = try #require(server.bodies[1]["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "tool"])
        #expect((messages[0]["content"] as? String)?.contains("edit_document") == true)
        #expect(messages[3]["tool_call_id"] as? String == "call_a")
        #expect((messages[3]["content"] as? String)?.contains("\"applied\":9") == true)
    }

    @Test func whatAToolDrewFollowsItsAnswer() async throws {
        for shown in [true, false] {
            let server = Server([
                (200, Self.call("view_prototype", ["seconds": 0.1])),
                (200, [Self.words("It is empty.")]),
            ])
            let (_, session) = session(server, config: config(pictures: shown))
            await session.send("What does it look like?")
            await finished(session)
            let messages = try #require(server.bodies.last?["messages"] as? [[String: Any]])
            #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "tool", "user"])
            if shown {
                let content = try #require(messages[4]["content"] as? [[String: Any]])
                #expect(content.map { $0["type"] as? String } == ["text", "image_url"])
                let url = (content[1]["image_url"] as? [String: Any])?["url"] as? String ?? ""
                #expect(url.hasPrefix("data:image/png;base64,"))
            } else {
                #expect((messages[4]["content"] as? String)?.contains("not shown pictures") == true)
            }
        }
    }

    @Test func aCallThatCannotBeReadIsToldSoAndNothingOfItStays() async throws {
        var lines = Self.call("edit_document", ["operations": AssistantToolboxTests.cardBatch])
        // Cut off before it closes: the operations that streamed were built, the call never arrives.
        lines.removeSubrange((lines.count - 4)...)
        let server = Server([(200, lines), (200, [Self.words("Sorry.")])])
        let (store, session) = session(server)
        let empty = store.fullDocument
        await session.send("Make a card")
        await finished(session)
        #expect(store.fullDocument == empty)
        let messages = try #require(server.bodies.last?["messages"] as? [[String: Any]])
        #expect((messages.last?["content"] as? String)?.contains("not valid JSON") == true)
        // What is sent back for the broken call is still something the API accepts.
        let kept = (messages[2]["tool_calls"] as? [[String: Any]])?.first?["function"] as? [String: Any]
        #expect(kept?["arguments"] as? String == "{}")
    }

    @Test func aRefusedKeyAndAMissingOneAreSaidPlainly() async {
        let refused = Server([(401, [#"{"error":{"message":"Incorrect API key provided"}}"#])])
        let (_, first) = session(refused)
        await first.send("Hello")
        await finished(first)
        #expect(first.entries.last?.kind == .problem)
        #expect(first.entries.last?.text == "OpenAI refused the API key. Check it in Settings (Command-comma).")

        let (_, second) = session(Server([]), problem: "Add an OpenAI API key in Settings (Command-comma), then send your message again.")
        await second.send("Hello")
        #expect(!second.isWorking)
        #expect(second.entries.last?.kind == .problem)
        #expect(second.entries.last?.text.hasPrefix("Add an OpenAI API key") == true)
    }

    @Test func stopEndsTheAnswerAndTheNextMessageGoesOn() async throws {
        let server = Server([(200, [Self.words("Let me")])])
        server.holdsOpen = true
        let (_, session) = session(server)
        await session.send("Make something big")
        for _ in 0..<500 where session.entries.last?.kind != .assistant { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(session.isWorking)
        session.stop()
        await finished(session)
        #expect(!session.isWorking)
        #expect(session.entries.last?.text == "Let me")

        server.holdsOpen = false
        server.answers = [(200, [Self.words("Going on.")])]
        await session.send("Go on")
        await finished(session)
        // What was said before Stop is still part of the conversation.
        let messages = try #require(server.bodies.last?["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "user"])
        #expect(messages[2]["content"] as? String == "Let me")

    }

    /// Runs a transport with no chat on it, answering its calls by hand.
    private func bare(_ server: Server) -> (ChatTransport, () -> [[String: Any]]) {
        let transport = ChatTransport(config())
        transport.lines = server.lines
        var heard: [[String: Any]] = []
        transport.onMessage = { heard.append($0) }
        transport.send(["type": "start", "systemPrompt": "p"])
        return (transport, { heard })
    }

    private func wait(for type: String, in heard: () -> [[String: Any]]) async {
        for _ in 0..<1000 where !heard().contains(where: { $0["type"] as? String == type }) {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test func stoppedWhileAToolIsAwaitedTheConversationStaysWhole() async throws {
        let server = Server([(200, [Self.words("Looking.")] + Self.call("get_document", [:]))])
        let (transport, heard) = bare(server)
        transport.send(["type": "user", "text": "Look"])
        await wait(for: "tool_call", in: heard)
        transport.send(["type": "interrupt"])
        await wait(for: "done", in: heard)
        // The call has its answer, or the next request would be refused; what was said is there once.
        #expect(transport.messages.map { $0["role"] as? String } == ["user", "assistant", "tool"])
        #expect(transport.messages[2]["content"] as? String == "Stopped by the user.")
        #expect(server.requests.count == 1)
        #expect(heard().filter { $0["type"] as? String == "error" }.isEmpty)
    }

    @Test func wordsAfterAToolStartApart() async throws {
        let server = Server([(200, [Self.words("One.")] + Self.call("get_document", [:])), (200, [Self.words("Two."), Self.words(" Three.")])])
        let (transport, heard) = bare(server)
        transport.send(["type": "user", "text": "Count"])
        await wait(for: "tool_call", in: heard)
        let id = try #require(heard().last { $0["type"] as? String == "tool_call" }?["id"] as? String)
        transport.send(["type": "tool_result", "id": id, "text": "{}", "isError": false])
        await wait(for: "done", in: heard)
        #expect(heard().compactMap { $0["delta"] as? String } == ["One.", "\n\n", "Two.", " Three."])
        #expect(heard().first?["model"] as? String == "gpt-test")
    }

    @Test func aModelThatNeverStopsCallingIsStopped() async {
        let endless = (0..<(ChatTransport.mostTurns + 5)).map { _ in (status: 200, lines: Self.call("get_document", [:])) }
        let server = Server(endless)
        let (_, session) = session(server)
        await session.send("Loop")
        await finished(session)
        #expect(server.requests.count == ChatTransport.mostTurns)
        #expect(session.entries.last?.text.contains("stopped after \(ChatTransport.mostTurns) steps") == true)
    }

    @Test func theToolsDoNotNameWhatIsNotThere() {
        // The assistant has no get_reference to be sent to.
        #expect(ChatRequest.tools.count == 4)
        #expect(!ChatRequest.tools.contains { $0.description.contains("get_reference") })
    }

    // MARK: OpenAI's Responses

    static func event(_ object: [String: Any]) -> String {
        "data: " + String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    /// A function call as Responses streams it, after the sealed thinking that goes with it.
    static func responseCall(_ name: String, _ input: [String: Any], id: String = "call_r", piece: Int = 19) -> [String] {
        let json = String(data: try! JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]), encoding: .utf8)!
        let thought: [String: Any] = ["type": "reasoning", "id": "rs_1", "encrypted_content": "sealed", "summary": []]
        var lines = [
            "event: response.output_item.added",
            event(["type": "response.output_item.added", "output_index": 0, "item": ["type": "reasoning", "id": "rs_1"]]),
            event(["type": "response.output_item.done", "output_index": 0, "item": thought]),
            event(["type": "response.output_item.added", "output_index": 1, "item": ["type": "function_call", "id": "fc_1", "call_id": id, "name": name, "arguments": ""]]),
        ]
        var rest = Substring(json)
        while !rest.isEmpty {
            lines.append(event(["type": "response.function_call_arguments.delta", "output_index": 1, "delta": String(rest.prefix(piece))]))
            rest = rest.dropFirst(piece)
        }
        return lines + [
            event(["type": "response.output_item.done", "output_index": 1, "item": ["type": "function_call", "id": "fc_1", "call_id": id, "name": name, "arguments": json]]),
            event(["type": "response.completed", "response": ["status": "completed"]]),
        ]
    }

    static func responseWords(_ text: String) -> [String] {
        let message: [String: Any] = ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]]
        return [
            event(["type": "response.output_text.delta", "output_index": 0, "delta": text]),
            event(["type": "response.output_item.done", "output_index": 0, "item": message]),
        ]
    }

    @Test func openAIIsAskedThroughResponses() throws {
        var config = config()
        config.dialect = .responses
        let user = ChatRequest.user("Build this", pictures: [["label": "Sketch", "data": "QUJD"]], shown: true, dialect: .responses)
        let request = ChatRequest.build(config, effort: "low", system: "You build prototypes.", messages: [user])
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["instructions"] as? String == "You build prototypes." && body["messages"] == nil)
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "low")
        // Nothing is kept on OpenAI's side; the sealed thinking travels with the conversation.
        #expect(body["store"] as? Bool == false && body["include"] as? [String] == ["reasoning.encrypted_content"])
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["get_document", "edit_document", "view_prototype", "interact_prototype"])
        #expect(tools.allSatisfy { $0["strict"] as? Bool == false && $0["function"] == nil })
        let content = try #require((body["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["input_text", "input_text", "input_image"])
        #expect(content[2]["image_url"] as? String == "data:image/jpeg;base64,QUJD")
    }

    @Test func aChatOverResponsesBuildsLiveAndSendsBackWhatCame() async throws {
        let server = Server([
            (200, Self.responseCall("edit_document", ["operations": AssistantToolboxTests.cardBatch])),
            (200, Self.responseCall("view_prototype", ["seconds": 0.1], id: "call_look")),
            (200, Self.responseWords("The card grows when tapped.")),
        ])
        var config = config()
        config.dialect = .responses
        let (store, session) = session(server, config: config)
        await session.send("Make a card that grows when tapped")
        await finished(session)

        #expect(store.document.screen.children.map(\.name) == ["Card"])
        #expect(store.document.graph.patches.count == 4)
        #expect(session.entries.map(\.kind) == [.user, .action, .action, .assistant, .changes])
        #expect(session.entries[1].text == "Added 1 view, 4 patches, and 4 cables")

        let input = try #require(server.bodies.last?["input"] as? [[String: Any]])
        // The person's message, then each round as it came: the thinking, the call, its
        // answer; and what the second call drew, as a message.
        #expect(input.map { $0["type"] as? String ?? $0["role"] as? String } == [
            "user", "reasoning", "function_call", "function_call_output",
            "reasoning", "function_call", "function_call_output", "user",
        ])
        #expect(input[1]["encrypted_content"] as? String == "sealed")
        #expect(input[3]["call_id"] as? String == "call_r")
        #expect((input[3]["output"] as? String)?.contains("\"applied\":9") == true)
        let drawn = try #require(input[7]["content"] as? [[String: Any]])
        #expect(drawn.map { $0["type"] as? String } == ["input_text", "input_image"])
    }

    @Test func aResponsesAnswerThatFailsOrArrivesWholeIsRead() {
        var failed = ChatStream(request: 1, dialect: .responses)
        _ = failed.read(Self.event(["type": "response.failed", "response": ["error": ["message": "The model is overloaded."]]]))
        #expect(failed.failure == "The model is overloaded.")

        // A call that was never streamed in pieces is still announced, built from and kept.
        var whole = ChatStream(request: 4, dialect: .responses)
        let item: [String: Any] = [
            "type": "function_call", "call_id": "call_w", "name": "edit_document",
            "arguments": #"{"operations":[{"op":"add_view","kind":"view","name":"A"}]}"#,
        ]
        let events = whole.read(Self.event(["type": "response.output_item.done", "output_index": 0, "item": item]))
        #expect(events.map { $0["type"] as? String } == ["tool_start", "tool_item"])
        #expect(whole.calls.first?.id == "call_w" && whole.calls.first?.useId == "use-4-0")
        #expect(whole.items.count == 1)

        // One cut short goes back as an empty call, which the API accepts.
        var cut = ChatStream(request: 5, dialect: .responses)
        _ = cut.read(Self.event(["type": "response.output_item.done", "output_index": 0, "item": item.merging(["arguments": #"{"operations":[{"op""#]) { $1 }]))
        #expect(cut.calls.first?.input == nil)
        #expect(cut.items.first?["arguments"] as? String == "{}")
    }

    // MARK: Who answers

    @Test func modelsAreNamedByProvider() {
        typealias Model = AssistantSession.Model
        #expect(Model(named: "openai:gpt-6.2-astra") == Model(.openAI, "gpt-6.2-astra"))
        #expect(Model(named: "gemini:gemini-4-argon")?.provider == .gemini)
        #expect(Model(named: "local:mlx-community/Qwen3-Coder")?.rawValue == "mlx-community/Qwen3-Coder")
        #expect(Model(named: "claude:opus") == .opus && Model(named: "openai:") == nil && Model(named: "nobody:x") == nil)
        #expect(Model(.openAI, "gpt-6.2-astra").title == "gpt-6.2-astra")
        #expect(Model.name(of: "gpt-6.2-astra") == "gpt-6.2-astra")
        // What the defaults keep reads back, Claude's Default included.
        for model in [Model.standard, .opus, Model(.local, "a:b"), Model(.gemini, "gemini-4-argon")] {
            #expect(Model(stored: model.id) == model)
        }
        #expect(Model(stored: "openAI:") == nil && Model(stored: "junk") == nil)
        #expect(!Model.openAI.isEmpty && Model.openAI.allSatisfy { !$0.rawValue.hasPrefix("claude") })
    }

    @Test func theTransportFollowsTheProviderAndItsSettings() throws {
        let defaults = try #require(UserDefaults(suiteName: "ChatTransportTests.settings"))
        defaults.removePersistentDomain(forName: "ChatTransportTests.settings")
        let keys = AIKeys(vault: MemoryVault(), defaults: defaults)
        #expect(AssistantProvider.transport(for: .opus, keys: keys, defaults: defaults) is ProcessTransport)
        // Without a key the line says how to get one going, and with one it is ready.
        let gemini = AssistantSession.Model(.gemini, "gemini-4-argon")
        #expect(AssistantProvider.transport(for: gemini, keys: keys, defaults: defaults) is ChatTransport)
        try keys.set("g-key-1234", account: AIKeys.gemini)
        let ready = try #require(AssistantProvider.transport(for: gemini, keys: keys, defaults: defaults) as? ChatTransport)
        #expect(ready.config.key == "g-key-1234")
        #expect(ready.config.base.absoluteString == "https://generativelanguage.googleapis.com/v1beta/openai")
        #expect(keys.hints[AIKeys.gemini] == "1234" && !keys.hasKey(for: .openAI))

        // A local server needs no key, is where Settings says, and sees pictures only when told.
        defaults.set("http://localhost:11434/v1/", forKey: AssistantSettings.localURLKey)
        let local = try #require(AssistantProvider.transport(for: .init(.local, "qwen"), keys: keys, defaults: defaults) as? ChatTransport)
        #expect(local.config.base.absoluteString == "http://localhost:11434/v1")
        #expect(local.config.key == nil && !local.config.sendsPictures && !local.config.sendsEffort)
        #expect(AssistantSettings.url(from: "localhost:8000") == nil && AssistantSettings.url(from: "ftp://x/v1") == nil)
        // The server's address alone is enough: its API is under /v1.
        #expect(AssistantSettings.url(from: "http://localhost:1234")?.absoluteString == "http://localhost:1234/v1")
        #expect(AssistantSettings.url(from: "http://localhost:1234/api/v2/")?.absoluteString == "http://localhost:1234/api/v2")
        defaults.set("b-model\na-model", forKey: AssistantSettings.localModelsKey)
        #expect(AssistantSession.Model.models(for: .local, defaults: defaults).map(\.rawValue) == ["b-model", "a-model"])
        // OpenAI is spoken to through Responses, the others through Chat Completions.
        try keys.set("sk-1", account: AssistantProvider.openAI.keyAccount)
        let openAI = try #require(AssistantProvider.transport(for: .init(.openAI, "gpt"), keys: keys, defaults: defaults) as? ChatTransport)
        #expect(openAI.config.dialect == .responses && ready.config.dialect == .completions && local.config.dialect == .completions)

        #expect(AssistantSettings.model(defaults) == .opus)
        AssistantSettings.remember(gemini, in: defaults)
        #expect(AssistantSettings.model(defaults) == gemini)
        defaults.removePersistentDomain(forName: "ChatTransportTests.settings")
    }

    @Test func claudeTakesItsKeyOnlyWhenThePersonChoseIt() {
        let start: [String: Any] = ["type": "start", "systemPrompt": "p"]
        #expect(ProcessTransport.outgoing(start, apiKey: nil)["apiKey"] == nil)
        #expect(ProcessTransport.outgoing(start, apiKey: "sk-ant")["apiKey"] as? String == "sk-ant")
        // Only the first message carries it.
        #expect(ProcessTransport.outgoing(["type": "user", "text": "Hi"], apiKey: "sk-ant")["apiKey"] == nil)
    }

    @Test func aChatWithClaudeOnAKeyThatIsNotThereSaysSo() async {
        let store = DocumentStore()
        let session = AssistantSession(store: store) { ProcessTransport(apiKey: nil, needsKey: true) }
        await session.send("Hello")
        #expect(session.entries.last?.kind == .problem)
        #expect(session.entries.last?.text.hasPrefix("Add a Claude API key in Settings") == true)
    }
}
