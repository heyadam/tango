import Foundation
import PaperHost
import PaperModel

/// The line to a model that is not Claude: OpenAI, Gemini, or a server on this Mac. One
/// loop serves them, in one of two dialects of OpenAI's API: Chat Completions, which Gemini
/// and local servers speak, and Responses, which OpenAI's own newer models need for tools.
/// It runs in the app, with no Node, and says what the Node program says for Claude (`Assistant/sidecar.mjs` lists
/// the messages), so a chat does not know which of the two it is talking to: the same four
/// tools, the same building while the model writes.
public final class ChatTransport: AssistantTransport {
    /// The two ways of saying the same conversation.
    public enum Dialect: Sendable {
        /// `chat/completions`: messages, with tool calls on the assistant's.
        case completions
        /// `responses`: a list of items, where a call and its answer are items of their own.
        case responses
    }

    public struct Config {
        /// Who answers, for the words of an error.
        public var name: String
        /// Where the API is: `chat/completions` and `models` are found under it.
        public var base: URL
        public var key: String?
        public var model: String
        /// Whether the model is shown pictures. One that reads only text is told there was one.
        public var sendsPictures = true
        /// Whether a thinking level is passed on.
        public var sendsEffort = true
        public var dialect = Dialect.completions

        public init(
            name: String, base: URL, key: String?, model: String, sendsPictures: Bool = true, sendsEffort: Bool = true,
            dialect: Dialect = .completions
        ) {
            self.dialect = dialect
            self.name = name
            self.base = base
            self.key = key
            self.model = model
            self.sendsPictures = sendsPictures
            self.sendsEffort = sendsEffort
        }
    }

    /// What a tool gave, carried across the wait for it. It only ever moves on the main actor.
    private struct Answer: @unchecked Sendable {
        var value: [String: Any]
    }

    typealias Lines = (URLRequest) async throws -> (Int, AsyncThrowingStream<String, Error>)

    public var onMessage: (([String: Any]) -> Void)?
    public var onClose: ((String?) -> Void)?

    /// How many times the model may be asked in one answer, as the Node program allows Claude.
    static let mostTurns = 80

    private(set) var config: Config
    /// Reads the saved key again before each request, so one replaced in Settings after
    /// it was refused is the one the next message goes out with.
    var currentKey: (() -> String?)?
    /// Why the line cannot open, such as a key that was never entered.
    private let problem: String?
    /// How the request is sent; tests answer it themselves.
    var lines: Lines = ChatTransport.stream

    private var system = ""
    private var effort: String?
    /// The conversation as the API takes it.
    private(set) var messages: [[String: Any]] = []
    private var answering: Task<Void, Never>?
    /// Tool calls the app has been asked to run, by the id it answers with.
    private var waiting: [String: CheckedContinuation<Answer, Never>] = [:]
    private var asked = 0
    private var requests = 0
    private var stopped = false

    public init(_ config: Config, problem: String? = nil) {
        self.config = config
        self.problem = problem
    }

    public func start(progress: @escaping (String) -> Void) async throws {
        if let problem { throw AssistantSetupError(message: problem) }
    }

    public func send(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "start":
            system = message["systemPrompt"] as? String ?? ""
            effort = message["effort"] as? String
            if !config.model.isEmpty { onMessage?(["type": "model", "model": config.model]) }
        case "effort":
            effort = message["effort"] as? String
        case "user":
            messages.append(ChatRequest.user(
                message["text"] as? String ?? "", pictures: message["images"] as? [[String: Any]] ?? [],
                shown: config.sendsPictures, dialect: config.dialect
            ))
            guard answering == nil else { return }
            answering = Task { [weak self] in await self?.answer() }
        case "tool_result":
            guard let id = message["id"] as? String else { return }
            waiting.removeValue(forKey: id)?.resume(returning: Answer(value: message))
        case "interrupt":
            answering?.cancel()
            letGo()
        default:
            break
        }
    }

    public func stop() {
        stopped = true
        answering?.cancel()
        letGo()
    }

    /// Answers every call the app was asked to run, so nothing waits on a stopped answer.
    private func letGo() {
        let all = waiting
        waiting = [:]
        for continuation in all.values {
            continuation.resume(returning: Answer(value: ["text": "Stopped by the user.", "isError": true]))
        }
    }

    private func emit(_ message: [String: Any]) {
        guard !stopped else { return }
        onMessage?(message)
    }

    // MARK: Answering

    /// One answer: asks the model, runs the tools it calls, and asks again with what they
    /// gave, until it has nothing more to call.
    private func answer() async {
        var failure: String?
        var reader = ChatStream(request: 0, dialect: config.dialect)
        /// Whether what `reader` read is in the conversation yet.
        var kept = true
        /// Whether an earlier request of this answer said anything, so the next words start apart.
        var spoke = false
        do {
            var turns = 0
            while true {
                turns += 1
                guard turns <= Self.mostTurns else {
                    failure = "The assistant stopped after \(Self.mostTurns) steps. Send a message to let it go on."
                    break
                }
                requests += 1
                if let currentKey { config.key = currentKey() }
                reader = ChatStream(request: requests, dialect: config.dialect)
                kept = false
                let request = ChatRequest.build(config, effort: effort, system: system, messages: messages)
                let (status, stream) = try await lines(request)
                guard status == 200 else {
                    var body = ""
                    for try await line in stream { body += line + "\n" }
                    failure = AIService.problem(status: status, body: Data(body.utf8), name: config.name)
                    break
                }
                for try await line in stream {
                    for event in reader.read(line) {
                        if spoke, event["type"] as? String == "text" {
                            spoke = false
                            emit(["type": "text", "delta": "\n\n"])
                        }
                        emit(event)
                    }
                }
                try Task.checkCancellation()
                if let problem = reader.failure {
                    failure = problem
                    break
                }
                messages += reader.items
                kept = true
                spoke = spoke || !reader.text.isEmpty
                let calls = reader.calls
                guard !calls.isEmpty else { break }
                var pictures: [(tool: String, data: String)] = []
                for call in calls {
                    let result: [String: Any]
                    if Task.isCancelled {
                        result = ["text": "Stopped by the user.", "isError": true]
                    } else if let input = call.input {
                        result = await ask(call, input: input)
                    } else {
                        // What was built from a call that cannot be read is taken back.
                        emit(["type": "tool_abandoned", "useId": call.useId])
                        result = ["text": "The arguments of this call were not valid JSON. Call it again.", "isError": true]
                    }
                    messages.append(ChatRequest.answer(to: call, result["text"] as? String ?? "", dialect: config.dialect))
                    for picture in result["images"] as? [String] ?? [] { pictures.append((call.name, picture)) }
                }
                // A tool's answer is text only, so what it drew follows as a message.
                if !pictures.isEmpty {
                    messages.append(ChatRequest.pictures(pictures, shown: config.sendsPictures, dialect: config.dialect))
                }
                try Task.checkCancellation()
            }
        } catch {
            if Task.isCancelled {
                // What was said before Stop stays in the conversation.
                if !kept, !reader.text.isEmpty { messages.append(ChatRequest.said(reader.text, dialect: config.dialect)) }
            } else {
                failure = Self.words(for: error, config: config)
            }
        }
        answering = nil
        if let failure { emit(["type": "error", "message": failure]) }
        emit(["type": "done"])
    }

    /// Has the app run a call, and waits for what it gives.
    private func ask(_ call: ChatStream.Call, input: [String: Any]) async -> [String: Any] {
        asked += 1
        let id = "call-\(asked)"
        let message: [String: Any] = ["type": "tool_call", "id": id, "name": call.name, "input": input, "useId": call.useId]
        let answer: Answer = await withCheckedContinuation { continuation in
            waiting[id] = continuation
            emit(message)
            // Nobody is listening any more: do not wait for an answer that cannot come.
            if stopped { waiting.removeValue(forKey: id)?.resume(returning: Answer(value: ["text": "Stopped.", "isError": true])) }
        }
        return answer.value
    }

    static func words(for error: Error, config: Config) -> String {
        if let url = error as? URLError, [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .timedOut, .notConnectedToInternet].contains(url.code) {
            let place = ExtensionManifest.isLoopback(config.base.host ?? "")
                ? "the server at \(config.base.absoluteString). Is it running?"
                : "\(config.base.host ?? config.name)."
            return "Could not reach \(place)"
        }
        return error.localizedDescription
    }

    // MARK: The network

    /// Sends a request and gives its answer line by line. A request to this Mac says so in a
    /// way the app's own agent port refuses, on every redirect too (`PrototypeNetwork.session`).
    static func stream(_ request: URLRequest) async throws -> (Int, AsyncThrowingStream<String, Error>) {
        let (bytes, response) = try await PrototypeNetwork.session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (status, stream)
    }

    /// The models a server has, as its `models` endpoint lists them.
    static func models(base: URL, key: String?) async throws -> [String] {
        let (data, response) = try await PrototypeNetwork.session.data(for: ChatRequest.models(base: base, key: key))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw AssistantSetupError(message: AIService.problem(status: status, body: data, name: "The server"))
        }
        return ChatRequest.modelIDs(in: data)
    }
}

// MARK: - Requests

/// What is sent: plain functions, so tests read them without a network.
enum ChatRequest {
    /// The assistant's four tools, from the schemas outside agents are given
    /// (`AgentServer.tools`), without the argument that picks a document.
    static let tools: [(name: String, description: String, parameters: Any)] = {
        let names = ["get_document", "edit_document", "view_prototype", "interact_prototype"]
        return AgentServer.tools.compactMap { tool in
            guard let name = tool["name"] as? String, names.contains(name),
                  var schema = tool["inputSchema"] as? [String: Any] else { return nil }
            var properties = schema["properties"] as? [String: Any] ?? [:]
            properties["document"] = nil
            schema["properties"] = properties
            // The assistant has no get_reference: what it holds is in its instructions.
            let description = (tool["description"] as? String ?? "").replacingOccurrences(of: "get_reference", with: "your instructions")
            return (name, description, plain(schema))
        }
    }()

    static func tools(for dialect: ChatTransport.Dialect) -> [[String: Any]] {
        tools.map { tool in
            switch dialect {
            case .completions:
                ["type": "function", "function": ["name": tool.name, "description": tool.description, "parameters": tool.parameters]]
            case .responses:
                // Not strict: an operation is an object of any shape, which strict schemas cannot say.
                ["type": "function", "name": tool.name, "description": tool.description, "parameters": tool.parameters, "strict": false]
            }
        }
    }

    /// A schema every provider takes: Gemini refuses a list of choices on anything but text.
    static func plain(_ schema: Any) -> Any {
        if let list = schema as? [Any] { return list.map(plain) }
        guard var object = schema as? [String: Any] else { return schema }
        if object["enum"] != nil, object["type"] as? String != "string" { object["enum"] = nil }
        return object.mapValues(plain)
    }

    static func build(
        _ config: ChatTransport.Config, effort: String?, system: String, messages: [[String: Any]], withTools: Bool = true
    ) -> URLRequest {
        var body: [String: Any] = ["model": config.model, "stream": true]
        let level = config.sendsEffort ? reasoning(effort) : nil
        let path: String
        switch config.dialect {
        case .completions:
            path = "chat/completions"
            body["messages"] = (system.isEmpty ? [] : [["role": "system", "content": system]]) + messages
            if let level { body["reasoning_effort"] = level }
        case .responses:
            path = "responses"
            body["input"] = messages
            if !system.isEmpty { body["instructions"] = system }
            if let level { body["reasoning"] = ["effort": level] }
            // Nothing is kept on the server, so what the model thought comes back sealed and
            // is sent again with the conversation, which a call's answer needs.
            body["store"] = false
            body["include"] = ["reasoning.encrypted_content"]
        }
        if withTools { body["tools"] = tools(for: config.dialect) }
        var request = URLRequest(url: config.base.appendingPathComponent(path), timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let key = config.key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return PrototypeNetwork.guarded(request)
    }

    static func models(base: URL, key: String?) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent("models"), timeoutInterval: 15)
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return PrototypeNetwork.guarded(request)
    }

    static func modelIDs(in data: Data) -> [String] {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let list = object?["data"] as? [[String: Any]] ?? object?["models"] as? [[String: Any]] ?? []
        return list.compactMap { $0["id"] as? String ?? $0["name"] as? String }.sorted()
    }

    /// The assistant's thinking levels as these APIs name them: they stop at high.
    static func reasoning(_ effort: String?) -> String? {
        switch effort {
        case "low", "medium", "high": effort
        case "xhigh", "max": "high"
        default: nil
        }
    }

    /// A message of the person's. Pictures follow the text, each after the line that says
    /// what it is, as they do for Claude.
    static func user(_ text: String, pictures: [[String: Any]], shown: Bool, dialect: ChatTransport.Dialect = .completions) -> [String: Any] {
        guard !pictures.isEmpty else { return ["role": "user", "content": text] }
        guard shown else {
            let count = pictures.count == 1 ? "A picture was" : "\(pictures.count) pictures were"
            return ["role": "user", "content": text + "\n\n[\(count) attached, but this model is not shown pictures.]"]
        }
        var content = [words(text, dialect)]
        for picture in pictures {
            if let label = picture["label"] as? String, !label.isEmpty { content.append(words(label, dialect)) }
            let type = picture["mediaType"] as? String ?? "image/jpeg"
            content.append(image(picture["data"] as? String ?? "", type: type, dialect))
        }
        return ["role": "user", "content": content]
    }

    /// What tools drew, which a tool's own answer cannot carry.
    static func pictures(_ pictures: [(tool: String, data: String)], shown: Bool, dialect: ChatTransport.Dialect = .completions) -> [String: Any] {
        guard shown else {
            return ["role": "user", "content": "[The prototype was drawn, but this model is not shown pictures. Go by get_document.]"]
        }
        var content: [[String: Any]] = []
        for picture in pictures {
            content.append(words("A picture from \(picture.tool):", dialect))
            content.append(image(picture.data, type: "image/png", dialect))
        }
        return ["role": "user", "content": content]
    }

    /// What a tool gave, as the answer to the call that asked.
    static func answer(to call: ChatStream.Call, _ text: String, dialect: ChatTransport.Dialect) -> [String: Any] {
        switch dialect {
        case .completions: ["role": "tool", "tool_call_id": call.id, "content": text]
        case .responses: ["type": "function_call_output", "call_id": call.id, "output": text]
        }
    }

    /// Words of the model's that were cut short, kept in the conversation.
    static func said(_ text: String, dialect: ChatTransport.Dialect) -> [String: Any] {
        switch dialect {
        case .completions: ["role": "assistant", "content": text]
        case .responses: ["role": "assistant", "content": [["type": "output_text", "text": text]]]
        }
    }

    private static func words(_ text: String, _ dialect: ChatTransport.Dialect) -> [String: Any] {
        ["type": dialect == .responses ? "input_text" : "text", "text": text]
    }

    private static func image(_ base64: String, type: String, _ dialect: ChatTransport.Dialect) -> [String: Any] {
        let url = "data:\(type);base64,\(base64)"
        switch dialect {
        case .completions: return ["type": "image_url", "image_url": ["url": url]]
        case .responses: return ["type": "input_image", "image_url": url]
        }
    }
}

// MARK: - Reading the answer

/// Reads one streamed answer, a line at a time, and says what to tell the chat as it goes.
struct ChatStream {
    /// A tool call the model wrote.
    struct Call {
        /// The provider's id for it, which the tool's answer must name.
        var id: String
        /// Ours, which never repeats in a chat (some servers call every call `call_0`).
        var useId: String
        var name = ""
        var arguments = ""
        /// What else came with the call, sent back as it was: Gemini keeps a signature there.
        var extra: [String: Any] = [:]
        var scanner = ItemScanner()
        var announced = false

        /// The arguments as an object; nil when they are not one.
        var input: [String: Any]? {
            let text = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return [:] }
            return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        }
    }

    /// Which request of the chat this is, for ids of its own.
    let request: Int
    let dialect: ChatTransport.Dialect
    /// What a Responses answer was made of, to send back as it came.
    private var outputs: [[String: Any]] = []
    private(set) var text = ""
    private var order: [Int] = []
    private var byIndex: [Int: Call] = [:]
    private(set) var failure: String?
    private var thinking = false

    init(request: Int, dialect: ChatTransport.Dialect = .completions) {
        self.request = request
        self.dialect = dialect
    }

    /// The answer as the conversation keeps it, in the dialect it came in.
    var items: [[String: Any]] {
        guard dialect == .responses else { return [message] }
        return outputs.map { item in
            // A call that cannot be read is kept as an empty one, or the next request is refused.
            guard item["type"] as? String == "function_call", let index = order.first(where: { byIndex[$0]?.id == item["call_id"] as? String }),
                  byIndex[index]?.input == nil else { return item }
            return item.merging(["arguments": "{}"]) { $1 }
        }
    }

    var calls: [Call] { order.compactMap { byIndex[$0] } }

    /// The answer as the conversation keeps it.
    var message: [String: Any] {
        var message: [String: Any] = ["role": "assistant", "content": text.isEmpty ? NSNull() : text as Any]
        if !order.isEmpty {
            message["tool_calls"] = calls.map { call -> [String: Any] in
                var item = call.extra
                item["id"] = call.id
                item["type"] = "function"
                // A call that cannot be read is kept as an empty one, or the next request is refused.
                item["function"] = ["name": call.name, "arguments": call.input == nil ? "{}" : (call.arguments.isEmpty ? "{}" : call.arguments)]
                return item
            }
        }
        return message
    }

    /// Takes one line of the stream and gives the messages for the chat that it completes.
    mutating func read(_ line: String) -> [[String: Any]] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let chunk = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else {
            return []
        }
        if let error = chunk["error"] {
            failure = (error as? [String: Any])?["message"] as? String ?? (error as? String) ?? "The model reported an error."
            return []
        }
        if dialect == .responses { return readResponse(chunk) }
        guard let choice = (chunk["choices"] as? [[String: Any]])?.first else { return [] }
        let delta = choice["delta"] as? [String: Any] ?? choice["message"] as? [String: Any] ?? [:]
        var out: [[String: Any]] = []

        let thought = delta["reasoning_content"] as? String ?? delta["reasoning"] as? String ?? ""
        if !thought.isEmpty, !thinking {
            thinking = true
            out.append(["type": "thinking"])
        }
        if let words = delta["content"] as? String, !words.isEmpty {
            thinking = false
            text += words
            out.append(["type": "text", "delta": words])
        }
        for piece in delta["tool_calls"] as? [[String: Any]] ?? [] {
            let function = piece["function"] as? [String: Any] ?? [:]
            let id = piece["id"] as? String ?? ""
            // Servers that leave the index out send each call whole, one after another.
            // Without an id either, a piece that names a function begins a call and one that
            // does not goes on with the last.
            let continues = id.isEmpty && (function["name"] as? String ?? "").isEmpty
            let index = piece["index"] as? Int
                ?? order.first { !id.isEmpty && byIndex[$0]?.id == id }
                ?? (continues ? order.last : nil)
                ?? (order.max() ?? -1) + 1
            var call = byIndex[index] ?? Call(id: "", useId: "use-\(request)-\(index)")
            if byIndex[index] == nil { order.append(index) }
            if !id.isEmpty { call.id = id }
            if call.id.isEmpty { call.id = "call_\(request)_\(index)" }
            if let name = function["name"] as? String, !name.isEmpty { call.name = name }
            for (key, value) in piece where !["index", "id", "type", "function"].contains(key) { call.extra[key] = value }
            if !call.announced, !call.name.isEmpty {
                call.announced = true
                thinking = false
                out.append(["type": "tool_start", "name": call.name, "useId": call.useId])
            }
            if let more = function["arguments"] as? String, !more.isEmpty {
                call.arguments += more
                for item in call.scanner.read(more) {
                    out.append(["type": "tool_item", "name": call.name, "useId": call.useId, "item": item])
                }
            }
            byIndex[index] = call
        }
        return out
    }
}

extension ChatStream {
    /// One event of a Responses stream.
    private mutating func readResponse(_ event: [String: Any]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        let index = event["output_index"] as? Int ?? (order.max() ?? -1) + 1
        let item = event["item"] as? [String: Any] ?? [:]

        /// The call an item is, known from now on; says so the first time.
        func call(for item: [String: Any], at index: Int, into out: inout [[String: Any]]) -> Call {
            if let known = byIndex[index] { return known }
            order.append(index)
            var call = Call(id: item["call_id"] as? String ?? item["id"] as? String ?? "call_\(request)_\(index)", useId: "use-\(request)-\(index)")
            call.name = item["name"] as? String ?? ""
            call.announced = true
            thinking = false
            out.append(["type": "tool_start", "name": call.name, "useId": call.useId])
            return call
        }
        /// Takes arguments that arrived whole, when none had streamed.
        func fill(_ call: inout Call, with arguments: String?, into out: inout [[String: Any]]) {
            guard call.arguments.isEmpty, let arguments, !arguments.isEmpty else { return }
            call.arguments = arguments
            for item in call.scanner.read(arguments) {
                out.append(["type": "tool_item", "name": call.name, "useId": call.useId, "item": item])
            }
        }

        switch event["type"] as? String {
        case "response.output_text.delta":
            guard let words = event["delta"] as? String, !words.isEmpty else { break }
            thinking = false
            text += words
            out.append(["type": "text", "delta": words])
        case "response.output_item.added":
            if item["type"] as? String == "function_call" {
                byIndex[index] = call(for: item, at: index, into: &out)
            } else if item["type"] as? String == "reasoning", !thinking {
                thinking = true
                out.append(["type": "thinking"])
            }
        case "response.function_call_arguments.delta":
            guard var known = byIndex[index], let more = event["delta"] as? String, !more.isEmpty else { break }
            known.arguments += more
            for item in known.scanner.read(more) {
                out.append(["type": "tool_item", "name": known.name, "useId": known.useId, "item": item])
            }
            byIndex[index] = known
        case "response.output_item.done":
            outputs.append(item)
            guard item["type"] as? String == "function_call" else { break }
            var known = call(for: item, at: index, into: &out)
            fill(&known, with: item["arguments"] as? String, into: &out)
            byIndex[index] = known
        case "response.failed":
            let response = event["response"] as? [String: Any]
            failure = (response?["error"] as? [String: Any])?["message"] as? String ?? "The model could not answer."
        case "error":
            failure = event["message"] as? String ?? "The model reported an error."
        default:
            break
        }
        return out
    }
}

/// Finds each operation of a batch (or step of a run) in a call's JSON while it is still
/// being written: the objects of the list that is the call's one argument, as in
/// `{"operations":[{…},{…}]}`. The same as the Node program's for Claude.
struct ItemScanner {
    private var bytes: [UInt8] = []
    private var depth = 0
    private var inString = false
    private var escaped = false
    private var start: Int?

    mutating func read(_ piece: String) -> [[String: Any]] {
        var items: [[String: Any]] = []
        for byte in piece.utf8 {
            bytes.append(byte)
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
                if depth == 3, byte == UInt8(ascii: "{") { start = bytes.count - 1 }
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if depth == 3, byte == UInt8(ascii: "}"), let from = start {
                    if let item = (try? JSONSerialization.jsonObject(with: Data(bytes[from...]))) as? [String: Any] { items.append(item) }
                    start = nil
                }
                depth -= 1
            default:
                break
            }
        }
        return items
    }
}
