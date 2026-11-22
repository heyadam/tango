import Foundation
import Testing
import PaperModel
@testable import PaperEngine

/// On-Device Chat does what its hint says: a suggestion or what is typed asks Apple's
/// model, the answer streams into the thread, the chat is kept, and New Chat starts over.
extension ShowcaseTests {
    @Test func theChatAsksTheOnDeviceModelAndKeepsTheConversation() {
        typealias Chat = SampleDocuments.OnDeviceChat
        let example = SampleDocuments.onDeviceChat()
        let runtime = Runtime(document: example.document)
        var sent: [AIRequest] = []
        runtime.aiHandler = { sent.append($0) }
        runtime.advance(seconds: 0.2)
        func shown() -> [Value] { runtime.outputValue(PortRef(node: example.thread, port: "shown"))?.arrayValue ?? [] }
        func texts() -> [String] { shown().map { $0.value(atPath: "text")?.textValue ?? "" } }
        func welcome() -> Bool { runtime.resolved.find(example.welcome) != nil }
        func glow() -> Double { runtime.number(example.thinking, "value") }
        #expect(welcome())
        #expect(shown().isEmpty)
        #expect(!runtime.needsAnotherFrame)

        // The first suggestion card asks with its words, on the device.
        tap(runtime, Point2(x: 100, y: Chat.suggestionsY + 35))
        runtime.tick(dt: frame)
        #expect(sent.count == 1)
        let first = sent[0]
        #expect(first.task == .text && first.provider == .apple && first.model == AIRequest.onDevice)
        #expect(first.prompt == Chat.suggestions[0].prompt && first.instructions == Chat.instructions)
        #expect(!welcome())
        #expect(texts() == [Chat.suggestions[0].prompt, "Thinking…"])
        runtime.advance(seconds: 0.6)
        #expect(glow() > 0.5)

        // The answer streams in with a dot after it, then stands alone.
        runtime.update(ai: first.id, .partial("Day one"))
        runtime.tick(dt: frame)
        #expect(texts().last == "Day one ●")
        runtime.update(ai: first.id, .finished(text: "Day one: temples.", picture: ""))
        runtime.tick(dt: frame)
        #expect(texts().last == "Day one: temples.")
        #expect(shown().map { $0.value(atPath: "user")?.boolValue ?? false } == [true, false])
        runtime.settle(within: 3)
        #expect(glow() < 0.01)
        #expect(!runtime.needsAnotherFrame)

        // Typed words follow on from the conversation; the field empties once sent.
        let field = runtime.resolved.find(example.field)!
        tap(runtime, Point2(x: 150, y: Chat.composerY + 27))
        runtime.tick(dt: frame)
        runtime.send(.text("Shorter"))
        runtime.tick(dt: frame)
        runtime.send(.submit)
        runtime.tick(dt: frame)
        runtime.tick(dt: frame)
        #expect(sent.count == 2 && sent[1].prompt == "Shorter")
        #expect(sent[1].conversation == [AITurn(.user, Chat.suggestions[0].prompt), AITurn(.assistant, "Day one: temples.")])
        #expect(runtime.resolved.find(field.id)!.value(.text).textValue.isEmpty)

        // A failure shows in the thread, dimmed.
        runtime.update(ai: sent[1].id, .failed("Turn on Apple Intelligence in System Settings to use apple-on-device."))
        runtime.tick(dt: frame)
        #expect(texts().last?.hasPrefix("Turn on Apple Intelligence") == true)
        #expect(shown().last?.value(atPath: "dim")?.boolValue == true)

        // New Chat starts over, back to the suggestions.
        tap(runtime, Point2(x: ExampleStyle.device.width - 36, y: ExampleStyle.top + 22))
        runtime.tick(dt: frame)
        runtime.tick(dt: frame)
        #expect(shown().isEmpty)
        #expect(welcome())
    }

    /// The newest messages that fit are shown, never one cut off at the bottom.
    @Test func aLongChatKeepsTheNewestMessages() {
        let example = SampleDocuments.onDeviceChat()
        let runtime = Runtime(document: example.document)
        var sent: [AIRequest] = []
        runtime.aiHandler = { sent.append($0) }
        runtime.advance(seconds: 0.2)
        let long = String(repeating: "A long answer that goes on. ", count: 12)
        for round in 0..<4 {
            tap(runtime, Point2(x: 100, y: SampleDocuments.OnDeviceChat.suggestionsY + 35))
            if round > 0 {
                // After the first, the cards are gone: ask by typing.
                tap(runtime, Point2(x: 150, y: SampleDocuments.OnDeviceChat.composerY + 27))
                runtime.tick(dt: frame)
                runtime.send(.text("More \(round)"))
                runtime.tick(dt: frame)
                runtime.send(.submit)
            }
            runtime.tick(dt: frame)
            runtime.tick(dt: frame)
            runtime.update(ai: sent.last!.id, .finished(text: long + "\(round)", picture: ""))
            runtime.tick(dt: frame)
        }
        let shown = runtime.outputValue(PortRef(node: example.thread, port: "shown"))?.arrayValue ?? []
        #expect(sent.count == 4)
        #expect(shown.count < 8)
        #expect(shown.last?.value(atPath: "text")?.textValue.hasSuffix("3") == true)
        // What is shown fits the room for messages.
        let messages = runtime.resolved.children.first { $0.name == "Messages" }!
        let bottom = messages.children.map { $0.position.y + $0.size.height }.max() ?? 0
        #expect(bottom <= SampleDocuments.OnDeviceChat.messagesHeight + 0.5)
        #expect(messages.children.allSatisfy { $0.position.y >= -0.5 })
    }
}
