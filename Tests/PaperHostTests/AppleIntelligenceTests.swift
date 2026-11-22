import Foundation
import FoundationModels
import Testing
import Translation
import PaperEngine
import PaperModel
@testable import PaperHost

/// Apple's models on the device: what is built for them, what fails at once and why, and,
/// where this Mac has the models, a real answer through the same host the iPhone player uses.
@Suite struct AppleIntelligenceTests {
    @Test func everyKindOfFieldMakesASchema() throws {
        let fields = AIField.parse("""
        title: text - a name
        rating: number
        minutes: whole
        vegan: yes/no
        tags: list
        steps: list of 3 text
        scores: 2 numbers
        mood: happy | sad
        moods: list of happy | sad
        """)
        #expect(fields.map(\.kind) == [
            .text, .number, .whole, .bool, .list(.text, count: nil), .list(.text, count: 3), .list(.number, count: 2),
            .choice(["happy", "sad"]), .list(.choice(["happy", "sad"]), count: nil),
        ])
        _ = try AppleIntelligence.schema(for: fields)
        // Names that a schema inside might also have do not collide.
        _ = try AppleIntelligence.schema(for: AIField.parse("Object: a | b\nx: list of c | d\nxItem: e | f"))
    }

    @Test func aConversationBecomesATranscript() {
        let transcript = AppleIntelligence.transcript(instructions: "Be brief.", history: [
            AITurn(.user, "Hi"), AITurn(.assistant, "Hello."), AITurn(.user, "", picture: "photo"),
        ])
        #expect(transcript.count == 4)
        guard case .instructions = transcript[0], case .prompt = transcript[1], case .response = transcript[2], case .prompt = transcript[3] else {
            Issue.record("Entries are out of order: \(transcript)")
            return
        }
        #expect(AppleIntelligence.transcript(instructions: "", history: []).isEmpty)
    }

    @Test func whatCannotRunFailsAtOnce() {
        let apple = AppleIntelligence()
        var updates: [(UUID, AIUpdate)] = []
        apple.deliver = { updates.append(($0, $1)) }
        let image = AIRequest(task: .image, model: AIRequest.onDevice, prompt: "A cat")
        apple.handle(image)
        let object = AIRequest(task: .object, model: AIRequest.onDevice, prompt: "A cat", fields: "\n\n")
        apple.handle(object)
        let translation = AIRequest(task: .translation, model: AIRequest.onDevice, prompt: "Hi")
        apple.handle(translation)
        #expect(updates.count == 3)
        #expect(updates.allSatisfy { if case .failed = $0.1 { true } else { false } })
        #expect(!apple.isBusy)
    }

    /// The player has no keys: a cloud model fails with a way out, and Transcribe says it
    /// does not record here.
    @Test func thePlayerRunsOnlyApplesModels() async throws {
        let (cloud, text) = try await run("aiText", ["prompt": .text("Hi"), "model": .text("claude-haiku-5-5")])
        #expect(cloud.runtime.outputValue(PortRef(node: text, port: "error")) == .text(PrototypeHost.noAI))
        #expect(PrototypeHost.noAI.contains(AIRequest.onDevice))
        let (listening, transcribe) = try await run("aiTranscribe", ["model": .text(AIRequest.onDevice)], from: "down", to: "record")
        #expect(listening.runtime.outputValue(PortRef(node: transcribe, port: "error")) == .text(PrototypeHost.noRecording))
        #expect(!listening.apple.isBusy)
    }

    /// A prototype taken off screen falls silent, and one that is shown again speaks:
    /// a kept live prototype is never heard over another.
    @Test func aPrototypeOffScreenIsSilent() {
        let host = PrototypeHost(package: DocumentPackage(document: Document(screen: Layer(name: "Screen", kind: .screen))))
        host.playsVideo = true
        var updates: [AIUpdate] = []
        host.apple.deliver = { _, update in updates.append(update) }
        host.isOnScreen = false
        #expect(!host.playsVideo && host.apple.hidden)
        // Speech asked for while hidden ends at once, and nothing speaks.
        host.apple.handle(AIRequest(task: .speech, model: AIRequest.onDevice, prompt: "Hello"))
        #expect(updates == [.finished(text: "", picture: ""), .playing(false)])
        #expect(!host.apple.isBusy)
        host.isOnScreen = true
        #expect(host.playsVideo && !host.apple.hidden)
    }

    // MARK: On this Mac's own models

    nonisolated static var modelIsHere: Bool { AppleIntelligence.unavailable == nil }

    /// Runs `kind` with `inputs` in a host, sends, and waits for Done or Failed.
    func run(_ kind: String, _ inputs: [String: Value], from: String = "tap", to: String = "send") async throws -> (PrototypeHost, NodeID) {
        let card = Layer(name: "Card", kind: .view, properties: [
            .position: .point(Point2(x: 0, y: 0)), .size: .size(Size2(width: 300, height: 300)),
        ])
        var screen = Layer(name: "Screen", kind: .screen)
        screen.children = [card]
        let touch = PatchNode(kind: PatchKind.interaction, layerID: card.id)
        let ai = PatchNode(kind: kind, inputs: inputs)
        var graph = Graph(nodes: [touch, ai])
        graph.connect(from: PortRef(node: touch.id, port: from), to: PortRef(node: ai.id, port: to))
        let host = PrototypeHost(package: DocumentPackage(document: Document(screen: screen, graph: graph)))
        host.send(.touchDown(Point2(x: 50, y: 50)))
        host.step(dt: 1 / 60)
        if from == "tap" {
            host.send(.touchUp(Point2(x: 50, y: 50)))
            host.step(dt: 1 / 60)
        }
        host.step(dt: 1 / 60)
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            host.step(dt: 1 / 60)
            if host.runtime.outputValue(PortRef(node: ai.id, port: "loading")) == .bool(false) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        return (host, ai.id)
    }

    @Test(.enabled(if: modelIsHere, "Apple Intelligence is not on in this Mac"))
    func theOnDeviceModelMakesAnObjectWithTheFieldsAskedFor() async throws {
        let (host, ai) = try await run("aiObject", [
            "prompt": .text("A quick breakfast."),
            "fields": .text("title: text\nminutes: whole\nmood: sweet | savory"),
        ])
        let object = host.runtime.outputValue(PortRef(node: ai, port: "object")) ?? .text("")
        let error = host.runtime.outputValue(PortRef(node: ai, port: "error"))?.textValue ?? ""
        #expect(error.isEmpty, "\(error)")
        let title = object.value(atPath: "title")?.textValue ?? ""
        #expect(!title.isEmpty, "\(object)")
        #expect(object.value(atPath: "minutes")?.numberValue != nil)
        #expect(["sweet", "savory"].contains(object.value(atPath: "mood")?.textValue ?? ""))
    }

    @Test(.enabled(if: modelIsHere, "Apple Intelligence is not on in this Mac"))
    func theOnDeviceModelAnswersInText() async throws {
        let (host, ai) = try await run("aiText", ["prompt": .text("Say the word yes."), "model": .text(AIRequest.onDevice)])
        let error = host.runtime.outputValue(PortRef(node: ai, port: "error"))?.textValue ?? ""
        #expect(error.isEmpty, "\(error)")
        let answer = host.runtime.outputValue(PortRef(node: ai, port: "text"))?.textValue ?? ""
        #expect(!answer.isEmpty)
    }

    @Test func translationRunsOnTheDeviceWhereTheLanguagesAre() async throws {
        let status = await LanguageAvailability().status(from: .init(identifier: "en"), to: .init(identifier: "es"))
        guard status == .installed else { return }
        let (host, ai) = try await run("aiTranslate", ["text": .text("Good morning, friend."), "to": .text("Spanish")])
        let translated = host.runtime.outputValue(PortRef(node: ai, port: "text"))?.textValue ?? ""
        #expect(translated.lowercased().contains("buen"), "\(translated)")
    }
}
