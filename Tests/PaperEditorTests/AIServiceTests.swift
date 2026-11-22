import AppKit
import Foundation
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

/// How the AI patches' calls are built, read and guarded. Nothing here reaches a network.
@MainActor
@Suite struct AIServiceTests {
    func body(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    @Test func aClaudeRequestStreamsWithTheKeyInItsHeader() {
        let ask = AIRequest(
            task: .text, model: "claude-opus-5-5", prompt: "And in French?", instructions: "Be brief.", effort: "low",
            conversation: [AITurn(.user, "Say hello"), AITurn(.assistant, "Hello")]
        )
        let request = AIService.textRequest(ask, key: "sk-ant-test", picture: Data([1, 2, 3]), history: ask.conversation.map { ($0, nil) })
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == AIService.fallbackBeta)
        let sent = body(request)
        #expect(sent["model"] as? String == "claude-opus-5-5")
        #expect(sent["stream"] as? Bool == true)
        #expect(sent["system"] as? String == "Be brief.")
        #expect((sent["output_config"] as? [String: String])?["effort"] == "low")
        #expect(sent["fallbacks"] as? String == "default")
        // Sampling settings are gone from current models; sending one is an error.
        #expect(sent["temperature"] == nil && sent["thinking"] == nil)
        let messages = sent["messages"] as? [[String: Any]] ?? []
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        let last = messages.last?["content"] as? [[String: Any]] ?? []
        #expect(last.map { $0["type"] as? String } == ["image", "text"])
        #expect((last[0]["source"] as? [String: String])?["data"] == Data([1, 2, 3]).base64EncodedString())
        // The key is in a header only.
        #expect(!(String(data: request.httpBody!, encoding: .utf8) ?? "").contains("sk-ant-test"))

        let haiku = AIService.textRequest(AIRequest(task: .text, model: "claude-haiku-5-5", prompt: "Hi"), key: "k", picture: nil, history: [])
        #expect(haiku.value(forHTTPHeaderField: "anthropic-beta") == nil)
        #expect(body(haiku)["fallbacks"] == nil)
    }

    @Test func anOpenAIRequestUsesTheResponsesAPI() {
        let ask = AIRequest(task: .text, model: "gpt-6.2-astra", prompt: "What is this?", instructions: "Answer in one line.",
                            conversation: [AITurn(.user, "Hi"), AITurn(.assistant, "Hello")])
        let request = AIService.textRequest(ask, key: "sk-oa", picture: Data([9]), history: ask.conversation.map { ($0, nil) })
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-oa")
        let sent = body(request)
        #expect(sent["instructions"] as? String == "Answer in one line.")
        let input = sent["input"] as? [[String: Any]] ?? []
        #expect(input.count == 3)
        let assistant = input[1]["content"] as? [[String: String]] ?? []
        #expect(assistant.first?["type"] == "output_text")
        let last = input[2]["content"] as? [[String: String]] ?? []
        #expect(last.map { $0["type"] } == ["input_image", "input_text"])
        #expect(last[0]["image_url"] == "data:image/jpeg;base64," + Data([9]).base64EncodedString())
    }

    @Test func imagesSpeechAndTranscriptionGoWhereTheyShould() {
        let generate = AIService.imageRequest(AIRequest(task: .image, model: "gpt-image-2.6-flare", prompt: "A fox", size: "1024x1024"), key: "k", reference: nil)
        #expect(generate.url?.path == "/v1/images/generations")
        #expect(body(generate)["size"] as? String == "1024x1024")
        let edit = AIService.imageRequest(AIRequest(task: .image, model: "gpt-image-2.6-flare", prompt: "Make it blue"), key: "k", reference: Data([1]))
        #expect(edit.url?.path == "/v1/images/edits")
        #expect(edit.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let form = String(decoding: edit.httpBody ?? Data(), as: UTF8.self)
        #expect(form.contains("name=\"image[]\"; filename=\"reference.png\"") && form.contains("Make it blue"))

        let speech = AIService.speechRequest(AIRequest(task: .speech, model: "gpt-4o-mini-tts", prompt: "Hi", instructions: "Warmly", voice: "cedar"), key: "k")
        #expect(speech.url?.path == "/v1/audio/speech")
        #expect(body(speech)["voice"] as? String == "cedar")
        #expect(body(speech)["instructions"] as? String == "Warmly")

        let heard = AIService.transcriptionRequest(model: "gpt-transcribe", audio: Data([0, 1]), key: "k")
        #expect(heard.url?.path == "/v1/audio/transcriptions")
        let parts = String(decoding: heard.httpBody ?? Data(), as: UTF8.self)
        #expect(parts.contains("name=\"model\"\r\n\r\ngpt-transcribe") && parts.contains("filename=\"speech.m4a\""))
    }

    @Test func streamsAreReadAsTheyArrive() {
        var claude = AIStream(provider: .anthropic)
        #expect(claude.read("event: content_block_delta") == nil)
        #expect(claude.read(#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#) == .partial)
        #expect(claude.read(#"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#) == nil)
        #expect(claude.read(#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}"#) == .partial)
        #expect(claude.text == "Hello")
        #expect(claude.read(#"data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"#) == .failed("Claude declined to answer that."))
        #expect(claude.read(#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#) == .failed("Overloaded"))

        var openAI = AIStream(provider: .openAI)
        #expect(openAI.read(#"data: {"type":"response.output_text.delta","delta":"Bon"}"#) == .partial)
        #expect(openAI.read(#"data: {"type":"response.output_text.delta","delta":"jour"}"#) == .partial)
        #expect(openAI.read(#"data: {"type":"response.completed"}"#) == nil)
        #expect(openAI.text == "Bonjour")
    }

    @Test func failuresAreWordedForAPerson() {
        let refused = Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)
        #expect(AIService.problem(status: 401, body: refused, provider: .anthropic).contains("refused the API key"))
        let limit = Data(#"{"error":{"message":"Rate limit reached for requests"}}"#.utf8)
        #expect(AIService.problem(status: 429, body: limit, provider: .openAI) == "Rate limit reached for requests")
        #expect(AIService.problem(status: 500, body: Data(), provider: .openAI) == "OpenAI answered 500.")
    }

    @Test func keysAreSavedAndOnlyTheirEndsAreShown() throws {
        let defaults = try #require(UserDefaults(suiteName: "AIServiceTests.keys"))
        defaults.removePersistentDomain(forName: "AIServiceTests.keys")
        let vault = MemoryVault()
        let keys = AIKeys(vault: vault, defaults: defaults)
        #expect(!keys.hasKey(for: .anthropic))
        try keys.set("  sk-ant-abcd1234  ", for: .anthropic)
        #expect(keys.key(for: .anthropic) == "sk-ant-abcd1234")
        #expect(keys.hints[AIProvider.anthropic.rawValue] == "1234")
        // A new launch knows a key is saved without asking the keychain.
        let later = AIKeys(vault: vault, defaults: defaults)
        #expect(later.hasKey(for: .anthropic) && !later.hasKey(for: .openAI))
        try later.remove(.anthropic)
        #expect(!later.hasKey(for: .anthropic) && vault.value(for: "anthropic") == nil)
    }

    @Test func noKeyOrNoPermissionSendsNothing() throws {
        let defaults = try #require(UserDefaults(suiteName: "AIServiceTests.ask"))
        defaults.removePersistentDomain(forName: "AIServiceTests.ask")
        let keys = AIKeys(vault: MemoryVault(), defaults: defaults)
        let service = AIService(keys: keys)
        var updates: [AIUpdate] = []
        var sent = 0
        service.deliver = { _, update in updates.append(update) }
        service.lines = { _ in
            sent += 1
            return (200, AsyncThrowingStream { $0.finish() })
        }
        service.handle(AIRequest(task: .text, model: "claude-opus-5-5", prompt: "Hi"))
        #expect(updates.count == 1)
        if case let .failed(problem) = updates[0] { #expect(problem.contains("Add your Claude API key")) } else { Issue.record("expected a failure") }

        try keys.set("sk-ant-1", for: .anthropic)
        var asked = 0
        service.ask = { _, answer in asked += 1; answer(false) }
        service.handle(AIRequest(task: .text, model: "claude-opus-5-5", prompt: "Hi"))
        service.handle(AIRequest(task: .text, model: "claude-opus-5-5", prompt: "Again"))
        // Asked once; refused for the rest of the run.
        #expect(asked == 1)
        #expect(sent == 0)
        #expect(updates.count == 3)
    }

    @Test func whatIsCancelledWhileThePersonIsAskedNeverGoesOut() async throws {
        let defaults = try #require(UserDefaults(suiteName: "AIServiceTests.waiting"))
        defaults.removePersistentDomain(forName: "AIServiceTests.waiting")
        let keys = AIKeys(vault: MemoryVault(), defaults: defaults)
        try keys.set("sk-ant-1", for: .anthropic)
        let service = AIService(keys: keys)
        var updates: [(UUID, AIUpdate)] = []
        var sent = 0
        service.deliver = { id, update in updates.append((id, update)) }
        service.lines = { _ in
            sent += 1
            return (200, AsyncThrowingStream { $0.finish() })
        }
        var answers: [(Bool) -> Void] = []
        service.ask = { _, answer in answers.append(answer) }
        let first = AIRequest(task: .text, model: "claude-opus-5-5", prompt: "Hi")
        let second = AIRequest(task: .text, model: "claude-opus-5-5", prompt: "Again")
        service.handle(first)
        service.handle(second)
        // One question for both.
        #expect(answers.count == 1)
        service.handle(AIRequest(id: first.id, task: .text, phase: .cancel, model: ""))
        answers[0](true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(sent == 1)

        // Let go of Record while a prompt is up: the patch hears that nothing was said.
        let record = AIRequest(task: .transcription, phase: .startRecording, model: "gpt-transcribe")
        var held: [(Bool) -> Void] = []
        service.ask = { _, answer in held.append(answer) }
        try keys.set("sk-oa", for: .openAI)
        service.handle(record)
        service.handle(AIRequest(id: record.id, task: .transcription, phase: .stopRecording, model: "gpt-transcribe"))
        #expect(updates.contains { $0.0 == record.id && $0.1 == .finished(text: "", picture: "") })
        held.first?(false)
        #expect(!updates.contains { $0.0 == record.id && $0.1 == .recording(true) })
    }

    @Test func hidingTheViewerLeavesARecordingWaitingOnAPrompt() throws {
        let defaults = try #require(UserDefaults(suiteName: "AIServiceTests.quiet"))
        defaults.removePersistentDomain(forName: "AIServiceTests.quiet")
        let keys = AIKeys(vault: MemoryVault(), defaults: defaults)
        try keys.set("sk-oa", for: .openAI)
        let service = AIService(keys: keys)
        var updates: [AIUpdate] = []
        service.deliver = { _, update in updates.append(update) }
        service.ask = { _, _ in }
        let record = AIRequest(task: .transcription, phase: .startRecording, model: "gpt-transcribe")
        service.handle(record)
        // Waiting on a prompt, which can itself hide the Viewer: left alone.
        service.quiet()
        #expect(updates.isEmpty)
        service.handle(AIRequest(id: record.id, task: .transcription, phase: .stopRecording, model: "gpt-transcribe"))
        #expect(updates == [.recording(false), .finished(text: "", picture: "")])
    }

    @Test func aRunningViewerHandsAIRequestsToTheService() {
        // A Viewer made for pictures sends nothing, so an AI patch stays loading.
        var document = PaperModel.Document()
        document.graph.add(PatchNode(kind: "aiText", inputs: ["prompt": .text("Hi")]))
        let quiet = ViewerView(store: DocumentStore(package: DocumentPackage(document: document)), sendsRequests: false)
        for _ in 0..<5 { quiet.advance(by: 1.0 / 60.0) }
        #expect(quiet.runtime.aiHandler != nil)
    }
}
