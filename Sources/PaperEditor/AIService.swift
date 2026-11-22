import AVFoundation
import AppKit
import Foundation
import Observation
import PaperEngine
import PaperModel

// The calls AI patches ask for, made with the person's own API keys.
//
// The runtime says what it wants (`AIRequest`); `AIService` builds the request for the
// provider, sends it, and reports back with `Runtime.update(ai:_:)`. Building and reading
// are plain functions (`AIService.urlRequest`, `AIStream`), tested without a network.

/// The API keys of the AI patches and of the assistant: in this Mac's keychain, one per
/// account (a provider's name). Whether a key is saved, and its last characters, are kept
/// in the defaults, so Settings can say so without opening the keychain.
@Observable
final class AIKeys {
    static let shared = AIKeys(vault: KeychainVault(service: KeychainVault.aiService, label: "tango AI key"))

    /// Every account a key can be saved for: the AI patches' providers, which the assistant
    /// shares, and the ones only the assistant uses.
    static let accounts = AIProvider.allCases.map(\.rawValue) + [gemini, local]
    static let gemini = "gemini"
    /// The key of a local server, for the few that want one.
    static let local = "local"

    private let vault: any KeyVault
    private let defaults: UserDefaults
    /// The last four characters of each saved key, by account.
    private(set) var hints: [String: String] = [:]
    /// Values read this launch. The keychain is asked once per account.
    @ObservationIgnored private var cache: [String: String] = [:]

    init(vault: any KeyVault = MemoryVault(), defaults: UserDefaults = .standard) {
        self.vault = vault
        self.defaults = defaults
        for account in Self.accounts {
            if let hint = defaults.string(forKey: Self.hintKey(account)) { hints[account] = hint }
        }
    }

    private static func hintKey(_ account: String) -> String { "aiKeyHint." + account }

    func hasKey(account: String) -> Bool { hints[account] != nil }

    func key(account: String) -> String? {
        if let cached = cache[account] { return cached }
        guard hasKey(account: account), let value = vault.value(for: account), !value.isEmpty else { return nil }
        cache[account] = value
        return value
    }

    func set(_ value: String, account: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try remove(account: account) }
        try vault.set(trimmed, for: account)
        cache[account] = trimmed
        let hint = String(trimmed.suffix(4))
        hints[account] = hint
        defaults.set(hint, forKey: Self.hintKey(account))
    }

    /// Forgets the key. If the keychain refuses, the key is still there, and so is its hint.
    func remove(account: String) throws {
        try vault.remove(account)
        cache[account] = nil
        hints[account] = nil
        defaults.removeObject(forKey: Self.hintKey(account))
    }

    func hasKey(for provider: AIProvider) -> Bool { hasKey(account: provider.rawValue) }
    func key(for provider: AIProvider) -> String? { key(account: provider.rawValue) }
    func set(_ value: String, for provider: AIProvider) throws { try set(value, account: provider.rawValue) }
    func remove(_ provider: AIProvider) throws { try remove(account: provider.rawValue) }

    /// Where a person gets a key.
    static func consoleURL(for provider: AIProvider) -> URL {
        switch provider {
        case .anthropic: URL(string: "https://platform.claude.com/settings/keys")!
        case .openAI: URL(string: "https://platform.openai.com/api-keys")!
        }
    }

    /// Settings' switch: whether a prototype must be allowed before it uses a key.
    static let asksFirstKey = "aiAsksBeforeUsingKeys"
}

/// Makes the calls of one running prototype. The Viewer owns one.
final class AIService {
    let keys: AIKeys
    /// Hands an update to the runtime, then draws a frame.
    var deliver: (UUID, AIUpdate) -> Void = { _, _ in }
    /// A picture the prototype can show, by name: what Image inputs name.
    var picture: (String) -> CGImage? = { _ in nil }
    /// Keeps a picture that was made, under the name the patch's Image output gives.
    var keep: (String, CGImage) -> Void = { _, _ in }
    /// Asks the person whether this prototype may use their key. Nil allows it.
    var ask: ((AIProvider, @escaping (Bool) -> Void) -> Void)?
    /// Sends a request and returns the whole answer; replaced in tests.
    var send: (URLRequest) async throws -> (Data, Int) = AIService.load
    /// Sends a request and gives the answer's lines as they come; replaced in tests.
    var lines: (URLRequest) async throws -> (Int, AsyncThrowingStream<String, Error>) = AIService.stream

    private var allowed: Set<AIProvider> = []
    private var refused: Set<AIProvider> = []
    /// Requests waiting on the person (the key question, the microphone prompt) before
    /// anything is sent or recorded. A cancel or a stop takes one out, and it never starts.
    private var waiting: Set<UUID> = []
    /// Of those, the ones that will record.
    private var recordings: Set<UUID> = []
    /// What waits on the key question while it is up, by provider: one question for all.
    private var asking: [AIProvider: [(Bool) -> Void]] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var players: [UUID: AVAudioPlayer] = [:]
    private var playerEnds: [UUID: PlayerEnd] = [:]
    private var recorders: [UUID: AVAudioRecorder] = [:]

    init(keys: AIKeys = .shared) {
        self.keys = keys
    }

    func handle(_ request: AIRequest) {
        switch request.phase {
        case .cancel:
            cancel(request.id)
        case .startRecording:
            startRecording(request)
        case .stopRecording:
            stopRecording(request)
        case .send:
            permitted(request.provider, request.id) { [weak self] in self?.start(request) }
        }
    }

    /// Runs `go` if request `id` is still wanted after waiting on the person.
    private func whileWanted(_ id: UUID, _ go: @escaping () -> Void) -> () -> Void {
        waiting.insert(id)
        return { [weak self] in
            guard let self, self.waiting.remove(id) != nil else { return }
            go()
        }
    }

    /// Stops speaking and listening, and says so, as if each had ended: the Viewer was hidden.
    /// What was heard is not sent.
    func quiet() {
        hidden = true
        for (id, player) in players {
            player.stop()
            players[id] = nil
            playerEnds[id] = nil
            deliver(id, .playing(false))
        }
        // One still waiting on a prompt is left alone: the prompt itself can hide the Viewer.
        for id in Set(recorders.keys) {
            cancel(id)
            deliver(id, .recording(false))
            deliver(id, .finished(text: "", picture: ""))
        }
    }

    /// Set while the Viewer is out of sight: speech that arrives then is not played.
    var hidden = false

    /// Stops everything: the prototype restarted or its Viewer closed.
    func stopAll() {
        for id in Set(tasks.keys).union(players.keys).union(recorders.keys).union(waiting) { cancel(id) }
    }

    private func cancel(_ id: UUID) {
        waiting.remove(id)
        recordings.remove(id)
        tasks.removeValue(forKey: id)?.cancel()
        players.removeValue(forKey: id)?.stop()
        playerEnds[id] = nil
        if let recorder = recorders.removeValue(forKey: id) {
            recorder.stop()
            recorder.deleteRecording()
        }
    }

    /// Runs `go` once the provider's key is there and the person allowed the prototype to use it.
    private func permitted(_ provider: AIProvider, _ id: UUID, _ next: @escaping () -> Void) {
        guard keys.hasKey(for: provider) else {
            recordings.remove(id)
            deliver(id, .failed("Add your \(provider.name) API key in Settings (Command-comma) to use this patch."))
            return
        }
        if refused.contains(provider) {
            recordings.remove(id)
            deliver(id, .failed("This prototype was not allowed to use your \(provider.name) key."))
            return
        }
        let go = whileWanted(id, next)
        guard let ask, !allowed.contains(provider), UserDefaults.standard.object(forKey: AIKeys.asksFirstKey) as? Bool ?? true else {
            return go()
        }
        let answered: (Bool) -> Void = { [weak self] yes in
            guard let self else { return }
            if yes {
                go()
            } else if self.waiting.remove(id) != nil {
                self.deliver(id, .failed("This prototype was not allowed to use your \(provider.name) key."))
            }
        }
        // A question already up answers this request too.
        if asking[provider] != nil {
            asking[provider]?.append(answered)
            return
        }
        asking[provider] = [answered]
        ask(provider) { [weak self] yes in
            guard let self else { return }
            if yes { self.allowed.insert(provider) } else { self.refused.insert(provider) }
            for waiter in self.asking.removeValue(forKey: provider) ?? [] { waiter(yes) }
        }
    }

    private func start(_ request: AIRequest) {
        guard let key = keys.key(for: request.provider) else {
            deliver(request.id, .failed("Your \(request.provider.name) API key could not be read from the keychain."))
            return
        }
        let id = request.id
        let deliver = self.deliver
        switch request.task {
        case .text:
            let picture = request.picture.isEmpty ? nil : self.picture(request.picture).flatMap(Self.jpeg)
            let history = request.conversation.map { turn in
                (turn, turn.picture.isEmpty ? nil : self.picture(turn.picture).flatMap(Self.jpeg))
            }
            let urlRequest = Self.textRequest(request, key: key, picture: picture, history: history)
            let lines = self.lines
            tasks[id] = Task { [weak self] in
                do {
                    let (status, stream) = try await lines(urlRequest)
                    var reader = AIStream(provider: request.provider)
                    var collected: [String] = []
                    for try await line in stream {
                        if Task.isCancelled { return }
                        guard (200..<300).contains(status) else { collected.append(line); continue }
                        switch reader.read(line) {
                        case .partial: deliver(id, .partial(reader.text))
                        case let .failed(problem): deliver(id, .failed(problem)); self?.tasks[id] = nil; return
                        case nil: break
                        }
                    }
                    if Task.isCancelled { return }
                    if (200..<300).contains(status) {
                        deliver(id, .finished(text: reader.text, picture: ""))
                    } else {
                        deliver(id, .failed(Self.problem(status: status, body: Data(collected.joined(separator: "\n").utf8), provider: request.provider)))
                    }
                } catch {
                    if !Task.isCancelled { deliver(id, .failed(error.localizedDescription)) }
                }
                self?.tasks[id] = nil
            }

        case .image:
            let reference = request.picture.isEmpty ? nil : self.picture(request.picture).flatMap(Self.png)
            let urlRequest = Self.imageRequest(request, key: key, reference: reference)
            let send = self.send
            tasks[id] = Task { [weak self] in
                do {
                    let (data, status) = try await send(urlRequest)
                    if Task.isCancelled { return }
                    guard (200..<300).contains(status) else {
                        deliver(id, .failed(Self.problem(status: status, body: data, provider: .openAI)))
                        self?.tasks[id] = nil
                        return
                    }
                    guard let image = Self.image(fromGeneration: data) else {
                        deliver(id, .failed("OpenAI answered without a picture."))
                        self?.tasks[id] = nil
                        return
                    }
                    let name = AIRequest.pictureName(for: id)
                    self?.keep(name, image)
                    deliver(id, .finished(text: "", picture: name))
                } catch {
                    if !Task.isCancelled { deliver(id, .failed(error.localizedDescription)) }
                }
                self?.tasks[id] = nil
            }

        case .speech:
            let urlRequest = Self.speechRequest(request, key: key)
            let send = self.send
            tasks[id] = Task { [weak self] in
                do {
                    let (data, status) = try await send(urlRequest)
                    if Task.isCancelled { return }
                    guard (200..<300).contains(status) else {
                        deliver(id, .failed(Self.problem(status: status, body: data, provider: .openAI)))
                        self?.tasks[id] = nil
                        return
                    }
                    deliver(id, .finished(text: "", picture: ""))
                    self?.play(data, for: id)
                } catch {
                    if !Task.isCancelled { deliver(id, .failed(error.localizedDescription)) }
                }
                self?.tasks[id] = nil
            }

        case .transcription:
            break
        }
    }

    // MARK: Speech

    /// Tells the runtime when a voice has finished.
    private final class PlayerEnd: NSObject, AVAudioPlayerDelegate {
        let done: () -> Void
        init(_ done: @escaping () -> Void) { self.done = done }
        nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            Task { @MainActor in self.done() }
        }
        nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
            Task { @MainActor in self.done() }
        }
    }

    private func play(_ data: Data, for id: UUID) {
        guard !hidden else {
            deliver(id, .playing(false))
            return
        }
        guard let player = try? AVAudioPlayer(data: data) else {
            deliver(id, .failed("The speech that came back could not be played."))
            return
        }
        let end = PlayerEnd { [weak self] in
            guard let self, self.players[id] != nil else { return }
            self.players[id] = nil
            self.playerEnds[id] = nil
            self.deliver(id, .playing(false))
        }
        player.delegate = end
        guard player.play() else {
            deliver(id, .failed("The speech that came back could not be played."))
            return
        }
        players[id] = player
        playerEnds[id] = end
        deliver(id, .playing(true))
    }

    // MARK: Transcription

    private func startRecording(_ request: AIRequest) {
        let id = request.id
        recordings.insert(id)
        permitted(.openAI, id) { [weak self] in
            guard let self else { return }
            self.waiting.insert(id)
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    // Let go while the prompt was up: nothing is recorded.
                    guard self.waiting.remove(id) != nil else { return }
                    guard granted else {
                        self.deliver(id, .failed("tango may not use the microphone. Allow it in System Settings > Privacy & Security > Microphone."))
                        return
                    }
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("transcribe-\(id.uuidString).m4a")
                    let settings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
                    ]
                    guard let recorder = try? AVAudioRecorder(url: file, settings: settings), recorder.record() else {
                        self.deliver(id, .failed("The microphone could not start recording."))
                        return
                    }
                    self.recorders[id] = recorder
                    self.deliver(id, .recording(true))
                }
            }
        }
    }

    private func stopRecording(_ request: AIRequest) {
        let id = request.id
        recordings.remove(id)
        guard let recorder = recorders.removeValue(forKey: id) else {
            // Let go before the recording started (a prompt was up): nothing was heard.
            if waiting.remove(id) != nil {
                deliver(id, .recording(false))
                deliver(id, .finished(text: "", picture: ""))
            }
            return
        }
        let duration = recorder.currentTime
        recorder.stop()
        deliver(id, .recording(false))
        let file = recorder.url
        guard duration > 0.2, let audio = try? Data(contentsOf: file) else {
            recorder.deleteRecording()
            deliver(id, .finished(text: "", picture: ""))
            return
        }
        recorder.deleteRecording()
        guard let key = keys.key(for: .openAI) else {
            deliver(id, .failed("Your OpenAI API key could not be read from the keychain."))
            return
        }
        let urlRequest = Self.transcriptionRequest(model: request.model, audio: audio, key: key)
        let send = self.send
        let deliver = self.deliver
        tasks[id] = Task { [weak self] in
            do {
                let (data, status) = try await send(urlRequest)
                if Task.isCancelled { return }
                if (200..<300).contains(status) {
                    let text = (Value.parseJSON(data)?.value(atPath: "text")?.textValue) ?? ""
                    deliver(id, .finished(text: text, picture: ""))
                } else {
                    deliver(id, .failed(Self.problem(status: status, body: data, provider: .openAI)))
                }
            } catch {
                if !Task.isCancelled { deliver(id, .failed(error.localizedDescription)) }
            }
            self?.tasks[id] = nil
        }
    }

    // MARK: Building requests

    static let anthropicVersion = "2026-10-21"
    /// Lets the API answer with another model when the asked one declines (Opus and Sonnet).
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    static func textRequest(_ request: AIRequest, key: String, picture: Data?, history: [(AITurn, Data?)]) -> URLRequest {
        switch request.provider {
        case .anthropic:
            func content(_ text: String, _ picture: Data?) -> [[String: Any]] {
                var blocks: [[String: Any]] = []
                if let picture {
                    blocks.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": picture.base64EncodedString()]])
                }
                if !text.isEmpty || blocks.isEmpty { blocks.append(["type": "text", "text": text.isEmpty ? "…" : text]) }
                return blocks
            }
            var messages: [[String: Any]] = history.map { turn, picture in
                ["role": turn.role.rawValue, "content": turn.role == .user ? content(turn.text, picture) as Any : turn.text]
            }
            messages.append(["role": "user", "content": content(request.prompt, picture)])
            var body: [String: Any] = [
                "model": request.model,
                "max_tokens": 64_000,
                "stream": true,
                "messages": messages,
            ]
            if !request.instructions.isEmpty { body["system"] = request.instructions }
            if AIRequest.efforts.contains(request.effort) { body["output_config"] = ["effort": request.effort] }
            var outgoing = json(URL(string: "https://api.anthropic.com/v1/messages")!, body)
            outgoing.setValue(key, forHTTPHeaderField: "x-api-key")
            outgoing.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
            // Haiku has no server-side fallback; Opus and Sonnet do.
            if !request.model.contains("haiku") {
                body["fallbacks"] = "default"
                outgoing.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
                outgoing.setValue(fallbackBeta, forHTTPHeaderField: "anthropic-beta")
            }
            return outgoing

        case .openAI:
            func content(_ role: AITurn.Role, _ text: String, _ picture: Data?) -> [[String: Any]] {
                var blocks: [[String: Any]] = []
                if let picture, role == .user {
                    blocks.append(["type": "input_image", "image_url": "data:image/jpeg;base64," + picture.base64EncodedString()])
                }
                if !text.isEmpty || blocks.isEmpty {
                    blocks.append(["type": role == .user ? "input_text" : "output_text", "text": text])
                }
                return blocks
            }
            var input: [[String: Any]] = history.map { turn, picture in
                ["role": turn.role.rawValue, "content": content(turn.role, turn.text, picture)]
            }
            input.append(["role": "user", "content": content(.user, request.prompt, picture)])
            var body: [String: Any] = ["model": request.model, "stream": true, "input": input]
            if !request.instructions.isEmpty { body["instructions"] = request.instructions }
            var outgoing = json(URL(string: "https://api.openai.com/v1/responses")!, body)
            outgoing.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            return outgoing
        }
    }

    static func imageRequest(_ request: AIRequest, key: String, reference: Data?) -> URLRequest {
        var outgoing: URLRequest
        if let reference {
            var form = MultipartForm()
            form.field("model", request.model)
            form.field("prompt", request.prompt)
            if !request.size.isEmpty { form.field("size", request.size) }
            form.file("image[]", name: "reference.png", type: "image/png", data: reference)
            outgoing = URLRequest(url: URL(string: "https://api.openai.com/v1/images/edits")!, timeoutInterval: 180)
            outgoing.httpMethod = "POST"
            outgoing.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
            outgoing.httpBody = form.finished()
        } else {
            var body: [String: Any] = ["model": request.model, "prompt": request.prompt, "n": 1]
            if !request.size.isEmpty { body["size"] = request.size }
            outgoing = json(URL(string: "https://api.openai.com/v1/images/generations")!, body, timeout: 180)
        }
        outgoing.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        return outgoing
    }

    static func speechRequest(_ request: AIRequest, key: String) -> URLRequest {
        var body: [String: Any] = [
            "model": request.model, "input": request.prompt,
            "voice": request.voice.isEmpty ? AIRequest.voices[0] : request.voice, "response_format": "mp3",
        ]
        if !request.instructions.isEmpty { body["instructions"] = request.instructions }
        var outgoing = json(URL(string: "https://api.openai.com/v1/audio/speech")!, body)
        outgoing.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        return outgoing
    }

    static func transcriptionRequest(model: String, audio: Data, key: String) -> URLRequest {
        var form = MultipartForm()
        form.field("model", model)
        form.file("file", name: "speech.m4a", type: "audio/mp4", data: audio)
        var outgoing = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!, timeoutInterval: 120)
        outgoing.httpMethod = "POST"
        outgoing.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        outgoing.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        outgoing.httpBody = form.finished()
        return outgoing
    }

    private static func json(_ url: URL, _ body: [String: Any], timeout: TimeInterval = 120) -> URLRequest {
        var outgoing = URLRequest(url: url, timeoutInterval: timeout)
        outgoing.httpMethod = "POST"
        outgoing.setValue("application/json", forHTTPHeaderField: "Content-Type")
        outgoing.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return outgoing
    }

    // MARK: Reading answers

    /// The words for a failed call: the provider's own message when it sent one.
    static func problem(status: Int, body: Data, provider: AIProvider) -> String {
        problem(status: status, body: body, name: provider.name)
    }

    /// The same for anyone who answers like these providers, by name.
    static func problem(status: Int, body: Data, name: String) -> String {
        var text = body
        // A stream that failed may still carry the error as an event's data.
        if let lines = String(data: body, encoding: .utf8) {
            for line in lines.split(separator: "\n") where line.hasPrefix("data:") {
                text = Data(line.dropFirst(5).utf8)
            }
        }
        let message = Value.parseJSON(text)?.value(atPath: "error.message")?.textValue ?? ""
        switch status {
        case 401, 403:
            return "\(name) refused the API key. Check it in Settings (Command-comma)."
        case 429:
            return message.isEmpty ? "\(name) is receiving too many requests from this key. Try again shortly." : message
        default:
            return message.isEmpty ? "\(name) answered \(status)." : message
        }
    }

    static func image(fromGeneration data: Data) -> CGImage? {
        guard let encoded = Value.parseJSON(data)?.value(atPath: "data.0.b64_json")?.textValue,
              let bytes = Data(base64Encoded: encoded) else { return nil }
        return NSImage(data: bytes)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    static func jpeg(_ image: CGImage) -> Data? {
        AssistantMediaLoader.jpeg(image, longestSide: 1568, quality: 0.85)
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    // MARK: Transport

    static func load(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func stream(_ request: URLRequest) async throws -> (Int, AsyncThrowingStream<String, Error>) {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
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
}

/// Reads a streamed answer line by line: Server-Sent Events from the Messages API or the
/// Responses API.
struct AIStream {
    enum Event: Equatable {
        case partial
        case failed(String)
    }

    let provider: AIProvider
    private(set) var text = ""

    init(provider: AIProvider) { self.provider = provider }

    mutating func read(_ line: String) -> Event? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let event = Value.parseJSON(Data(payload.utf8)) else { return nil }
        let type = event.value(atPath: "type")?.textValue ?? ""
        switch provider {
        case .anthropic:
            switch type {
            case "content_block_delta":
                guard event.value(atPath: "delta.type")?.textValue == "text_delta",
                      let piece = event.value(atPath: "delta.text")?.textValue else { return nil }
                text += piece
                return .partial
            case "message_delta":
                if event.value(atPath: "delta.stop_reason")?.textValue == "refusal" {
                    return .failed("Claude declined to answer that.")
                }
                return nil
            case "error":
                return .failed(event.value(atPath: "error.message")?.textValue ?? "Claude could not answer.")
            default:
                return nil
            }
        case .openAI:
            switch type {
            case "response.output_text.delta":
                guard let piece = event.value(atPath: "delta")?.textValue else { return nil }
                text += piece
                return .partial
            case "response.failed":
                return .failed(event.value(atPath: "response.error.message")?.textValue ?? "OpenAI could not answer.")
            case "error":
                return .failed(event.value(atPath: "message")?.textValue ?? event.value(atPath: "error.message")?.textValue ?? "OpenAI could not answer.")
            default:
                return nil
            }
        }
    }
}

/// A multipart/form-data body.
struct MultipartForm {
    let boundary = "tango-" + UUID().uuidString
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func field(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func file(_ name: String, name file: String, type: String, data: Data) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(file)\"\r\nContent-Type: \(type)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    func finished() -> Data {
        body + Data("--\(boundary)--\r\n".utf8)
    }
}
