import Foundation
import Testing
import PaperModel
@testable import PaperEngine

/// AI patches: what they ask the host for, and how they show what it reports.
@Suite struct AITests {
    let frame = 1.0 / 60.0

    /// A card with an Interaction whose output `from` drives input `to` of an AI patch.
    func setUp(_ kind: String, from: String = "tap", to: String = "send", inputs: [String: Value] = [:]) -> (Runtime, NodeID, Box<[AIRequest]>) {
        let card = Layer(name: "Card", kind: .view, properties: [
            .position: .point(Point2(x: 0, y: 0)), .size: .size(Size2(width: 300, height: 300)),
        ])
        var screen = Layer(name: "Screen", kind: .screen)
        screen.children = [card]
        let touch = PatchNode(kind: PatchKind.interaction, layerID: card.id)
        let ai = PatchNode(kind: kind, inputs: inputs)
        var graph = Graph(nodes: [touch, ai])
        graph.connect(from: PortRef(node: touch.id, port: from), to: PortRef(node: ai.id, port: to))
        let runtime = Runtime(document: Document(screen: screen, graph: graph))
        let sent = Box<[AIRequest]>([])
        runtime.aiHandler = { sent.value.append($0) }
        runtime.tick(dt: frame)
        return (runtime, ai.id, sent)
    }

    final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    func tap(_ runtime: Runtime) {
        runtime.send(.touchDown(Point2(x: 50, y: 50)))
        runtime.tick(dt: frame)
        runtime.send(.touchUp(Point2(x: 50, y: 50)))
        runtime.tick(dt: frame)
    }

    func out(_ runtime: Runtime, _ node: NodeID, _ port: String) -> Value {
        runtime.outputValue(PortRef(node: node, port: port)) ?? .text("missing")
    }

    @Test func textStreamsInAndTheConversationIsKept() {
        let (runtime, ai, sent) = setUp("aiText", inputs: ["prompt": .text("Name a color"), "instructions": .text("Be brief.")])
        #expect(sent.value.isEmpty)
        tap(runtime)
        #expect(sent.value.count == 1)
        let first = sent.value[0]
        #expect(first.task == .text && first.phase == .send)
        #expect(first.provider == .anthropic && first.model == "claude-opus-5-5")
        #expect(first.prompt == "Name a color" && first.instructions == "Be brief." && first.effort == "low")
        #expect(first.conversation.isEmpty)
        #expect(out(runtime, ai, "loading") == .bool(true))
        // Waiting costs no frames.
        runtime.tick(dt: frame)
        #expect(!runtime.needsAnotherFrame)

        runtime.update(ai: first.id, .partial("Te"))
        runtime.tick(dt: frame)
        #expect(out(runtime, ai, "text") == .text("Te"))
        // While it streams, the conversation shows the question and the answer so far.
        #expect(out(runtime, ai, "conversation").arrayValue.count == 2)

        runtime.update(ai: first.id, .partial("Teal"))
        runtime.update(ai: first.id, .finished(text: "Teal", picture: ""))
        runtime.tick(dt: frame)
        #expect(out(runtime, ai, "text") == .text("Teal"))
        #expect(out(runtime, ai, "loading") == .bool(false))
        #expect(out(runtime, ai, "done").pulseValue)
        runtime.tick(dt: frame)
        #expect(!out(runtime, ai, "done").pulseValue)
        runtime.tick(dt: frame)
        #expect(!runtime.needsAnotherFrame)

        // The next prompt carries the conversation so far.
        tap(runtime)
        #expect(sent.value.count == 2)
        #expect(sent.value[1].conversation == [AITurn(.user, "Name a color"), AITurn(.assistant, "Teal")])
        // An answer to a request nobody waits for any more is ignored.
        runtime.tick(dt: frame)
        runtime.update(ai: first.id, .partial("stale"))
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func resetForgetsAndAFailureSaysWhy() {
        let card = Layer(name: "Card", kind: .view, properties: [.size: .size(Size2(width: 300, height: 300))])
        var screen = Layer(name: "Screen", kind: .screen)
        screen.children = [card]
        let touch = PatchNode(kind: PatchKind.interaction, layerID: card.id)
        let ai = PatchNode(kind: "aiText", inputs: ["prompt": .text("Hi"), "model": .text("gpt-6.2-sol")])
        var graph = Graph(nodes: [touch, ai])
        graph.connect(from: PortRef(node: touch.id, port: "tap"), to: PortRef(node: ai.id, port: "send"))
        graph.connect(from: PortRef(node: touch.id, port: "doubleTap"), to: PortRef(node: ai.id, port: "reset"))
        let runtime = Runtime(document: Document(screen: screen, graph: graph))
        var sent: [AIRequest] = []
        runtime.aiHandler = { sent.append($0) }
        runtime.tick(dt: frame)

        tap(runtime)
        #expect(sent.last?.provider == .openAI)
        runtime.update(ai: sent[0].id, .failed("OpenAI refused the API key."))
        runtime.tick(dt: frame)
        #expect(out(runtime, ai.id, "failed").pulseValue)
        #expect(out(runtime, ai.id, "error") == .text("OpenAI refused the API key."))
        #expect(out(runtime, ai.id, "loading") == .bool(false))
    }

    @Test func withoutAHostItFailsAtOnce() {
        let (runtime, ai, _) = setUp("aiText", inputs: ["prompt": .text("Hi")])
        runtime.aiHandler = nil
        tap(runtime)
        runtime.tick(dt: frame)
        #expect(out(runtime, ai, "error") == .text("This player cannot use AI."))
    }

    @Test func anImageComesBackAsAPictureName() {
        let (runtime, ai, sent) = setUp("aiImage", inputs: ["prompt": .text("A red bicycle"), "size": .text("Portrait"), "reference": .text("capture:1")])
        tap(runtime)
        let request = sent.value[0]
        #expect(request.task == .image && request.model == "gpt-image-2.6-flare")
        #expect(request.size == "1024x1536" && request.picture == "capture:1")
        let name = AIRequest.pictureName(for: request.id)
        runtime.update(ai: request.id, .finished(text: "", picture: name))
        runtime.tick(dt: frame)
        #expect(out(runtime, ai, "image") == .text(name))
        #expect(out(runtime, ai, "done").pulseValue)
    }

    @Test func speechIsSpeakingUntilItFinishesPlaying() {
        let (runtime, ai, sent) = setUp("aiSpeech", from: "tap", to: "speak", inputs: ["text": .text("Hello there"), "voice": .text("cedar")])
        tap(runtime)
        let request = sent.value[0]
        #expect(request.task == .speech && request.voice == "cedar" && request.prompt == "Hello there")
        #expect(out(runtime, ai, "loading") == .bool(true))
        runtime.update(ai: request.id, .finished(text: "", picture: ""))
        runtime.update(ai: request.id, .playing(true))
        runtime.tick(dt: frame)
        #expect(out(runtime, ai, "loading") == .bool(false))
        #expect(out(runtime, ai, "speaking") == .bool(true))
        #expect(!out(runtime, ai, "done").pulseValue)
        runtime.update(ai: request.id, .playing(false))
        runtime.tick(dt: frame)
        #expect(out(runtime, ai, "speaking") == .bool(false))
        #expect(out(runtime, ai, "done").pulseValue)

        // Speaking again stops what is playing first.
        tap(runtime)
        tap(runtime)
        #expect(sent.value.filter { $0.phase == .cancel }.map(\.id) == [sent.value[1].id])
    }

    @Test func holdingRecordListensThenTranscribes() {
        let (runtime, ai, sent) = setUp("aiTranscribe", from: "down", to: "record")
        #expect(runtime.capabilities.contains(.microphone))
        runtime.send(.touchDown(Point2(x: 50, y: 50)))
        runtime.tick(dt: frame)
        #expect(sent.value.map(\.phase) == [.startRecording])
        let id = sent.value[0].id
        runtime.update(ai: id, .recording(true))
        runtime.tick(dt: frame)
        #expect(out(runtime, ai, "recording") == .bool(true))

        runtime.send(.touchUp(Point2(x: 50, y: 50)))
        runtime.tick(dt: frame)
        #expect(sent.value.map(\.phase) == [.startRecording, .stopRecording])
        #expect(sent.value[1].id == id)
        #expect(out(runtime, ai, "loading") == .bool(true))
        runtime.update(ai: id, .recording(false))
        runtime.update(ai: id, .finished(text: "Book a table for two", picture: ""))
        runtime.tick(dt: frame)
        #expect(out(runtime, ai, "text") == .text("Book a table for two"))
        #expect(out(runtime, ai, "recording") == .bool(false))
        #expect(out(runtime, ai, "done").pulseValue)
    }

    @Test func recordingAgainKeepsWhatIsBeingTranscribed() {
        let (runtime, ai, sent) = setUp("aiTranscribe", from: "down", to: "record")
        func hold() {
            runtime.send(.touchDown(Point2(x: 50, y: 50)))
            runtime.tick(dt: frame)
        }
        func letGo() {
            runtime.send(.touchUp(Point2(x: 50, y: 50)))
            runtime.tick(dt: frame)
        }
        hold()
        let first = sent.value[0].id
        runtime.update(ai: first, .recording(true))
        letGo()
        runtime.update(ai: first, .recording(false))
        // A second recording starts before the first is heard.
        hold()
        let second = sent.value.last!.id
        #expect(second != first)
        #expect(!sent.value.contains { $0.phase == .cancel })
        runtime.update(ai: second, .recording(true))
        runtime.update(ai: first, .finished(text: "First", picture: ""))
        runtime.tick(dt: frame)
        #expect(out(runtime, ai, "text") == .text("First"))
        #expect(out(runtime, ai, "recording") == .bool(true))
        #expect(out(runtime, ai, "loading") == .bool(false))
        letGo()
        runtime.update(ai: second, .finished(text: "Second", picture: ""))
        runtime.tick(dt: frame)
        #expect(out(runtime, ai, "text") == .text("Second"))
        #expect(out(runtime, ai, "recording") == .bool(false))
    }

    @Test func restartingCancelsWhatIsInFlight() {
        let (runtime, _, sent) = setUp("aiText", inputs: ["prompt": .text("Hi")])
        tap(runtime)
        runtime.restart()
        #expect(sent.value.last?.phase == .cancel)
        #expect(sent.value.last?.id == sent.value[0].id)
    }

    @Test func deletingAPatchMidRequestStopsWhatItAskedFor() {
        let (runtime, ai, sent) = setUp("aiSpeech", from: "tap", to: "speak", inputs: ["text": .text("Hello")])
        tap(runtime)
        let id = sent.value[0].id
        runtime.update(ai: id, .finished(text: "", picture: ""))
        runtime.update(ai: id, .playing(true))
        runtime.tick(dt: frame)
        var document = runtime.document
        document.graph.remove(ai)
        runtime.update(document: document)
        #expect(sent.value.last?.phase == .cancel && sent.value.last?.id == id)
        // What comes for it afterwards wakes nothing.
        runtime.tick(dt: frame)
        runtime.update(ai: id, .playing(false))
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func anEmptyAnswerIsNotRemembered() {
        let (runtime, _, sent) = setUp("aiText", inputs: ["prompt": .text("Hi")])
        tap(runtime)
        runtime.update(ai: sent.value[0].id, .partial("x"))
        runtime.update(ai: sent.value[0].id, .partial("xy"))
        #expect(runtime.aiUpdates[sent.value[0].id]?.count == 1)
        runtime.update(ai: sent.value[0].id, .finished(text: "", picture: ""))
        runtime.tick(dt: frame)
        tap(runtime)
        #expect(sent.value[1].conversation.isEmpty)
    }

    @Test func theModelNamesWhoAnswers() {
        #expect(AIProvider.of(model: "claude-haiku-5-5") == .anthropic)
        #expect(AIProvider.of(model: "gpt-6-luna") == .openAI)
        for kind in ["aiText", "aiImage", "aiSpeech", "aiTranscribe"] {
            #expect(PatchRegistry.standard.definition(kind)?.category == .ai)
        }
    }
}
