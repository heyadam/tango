import CoreGraphics
import Foundation
import Testing
import PaperModel
@testable import PaperEngine

/// On-Device Chat does what ChatGPT does, on Apple's model: a suggestion, typed words or
/// words said into the microphone ask; the answer streams in and can be stopped; each
/// answer can be copied, rated and read aloud; New Chat starts over.
extension ShowcaseTests {
    typealias Chat = SampleDocuments.OnDeviceChat

    final class Chatting {
        let example = SampleDocuments.onDeviceChat()
        let runtime: Runtime
        var sent: [AIRequest] = []
        let frame = 1.0 / 60.0

        init() {
            runtime = Runtime(document: example.document)
            runtime.aiHandler = { [unowned self] in sent.append($0) }
            runtime.advance(seconds: 0.2)
        }

        func tap(_ point: Point2) {
            runtime.send(.touchDown(point))
            runtime.tick(dt: frame)
            runtime.send(.touchUp(point))
            runtime.tick(dt: frame)
            runtime.tick(dt: frame)
        }
        func type(_ words: String) {
            tap(Point2(x: 150, y: Chat.composerY + 27))
            runtime.send(.text(words))
            runtime.tick(dt: frame)
        }
        var shown: [Value] { runtime.outputValue(PortRef(node: example.thread, port: "shown"))?.arrayValue ?? [] }
        var texts: [String] { shown.map { $0.value(atPath: "text")?.textValue ?? "" } }
        var marks: Value { runtime.outputValue(PortRef(node: example.feedback, port: "marks")) ?? .object([:]) }
        var welcome: Bool { runtime.resolved.find(example.welcome) != nil }
        var lastAsk: AIRequest { sent.last { $0.task == .text && $0.phase == .send }! }
        func answer(_ text: String) {
            runtime.update(ai: lastAsk.id, .finished(text: text, picture: ""))
            runtime.tick(dt: frame)
            runtime.tick(dt: frame)
        }
        /// Where the last copy of a repeated view is: the newest message's.
        func newest(_ id: LayerID) -> Point2 {
            var centers: [CGPoint] = []
            func walk(_ layer: ResolvedLayer, _ toRoot: CGAffineTransform) {
                let here = layer.transformToParent.concatenating(toRoot)
                if layer.id == id { centers.append(CGPoint(x: layer.size.width / 2, y: layer.size.height / 2).applying(here)) }
                for child in layer.children { walk(child, here) }
            }
            for child in runtime.resolved.children { walk(child, .identity) }
            return Point2(x: centers.last!.x, y: centers.last!.y)
        }
    }

    @Test func aSuggestionAsksTheOnDeviceModelAndTheAnswerStreamsIn() {
        let c = Chatting()
        #expect(c.welcome && c.shown.isEmpty)
        #expect(!c.runtime.needsAnotherFrame)

        c.tap(Point2(x: 100, y: Chat.suggestionsY + 35))
        let first = c.lastAsk
        #expect(first.provider == .apple && first.model == AIRequest.onDevice)
        #expect(first.prompt == Chat.suggestions[0].prompt && first.instructions == Chat.instructions)
        #expect(!c.welcome)
        // Before its first word, the answer is a dot; the composer glows.
        #expect(c.texts == [Chat.suggestions[0].prompt, "●"])
        c.runtime.advance(seconds: 0.6)
        #expect(c.runtime.number(c.example.thinking, "value") > 0.5)

        c.runtime.update(ai: first.id, .partial("Day one"))
        c.runtime.tick(dt: c.frame)
        #expect(c.texts.last == "Day one ●")
        // No actions on an answer still being written.
        #expect(c.shown.last?.value(atPath: "actions")?.boolValue == false)
        c.answer("Day one: temples.")
        #expect(c.texts.last == "Day one: temples.")
        #expect(c.shown.last?.value(atPath: "actions")?.boolValue == true)
        c.runtime.settle(within: 3)
        #expect(c.runtime.number(c.example.thinking, "value") < 0.01)
        #expect(!c.runtime.needsAnotherFrame)

        // A failure shows as the model's message, dimmed; New Chat starts over.
        c.type("Again")
        c.runtime.send(.submit)
        c.runtime.tick(dt: c.frame)
        c.runtime.tick(dt: c.frame)
        c.runtime.update(ai: c.lastAsk.id, .failed("Turn on Apple Intelligence in System Settings to use apple-on-device."))
        c.runtime.tick(dt: c.frame)
        #expect(c.texts.last?.hasPrefix("Turn on Apple Intelligence") == true)
        c.tap(Point2(x: ExampleStyle.device.width - 36, y: ExampleStyle.top + 22))
        #expect(c.shown.isEmpty && c.welcome)
    }

    @Test func theRoundButtonTalksSendsAndStops() {
        let c = Chatting()
        let circle = Chat.circleCenter
        // Typed words, then the button: it sends, and the field empties.
        c.type("Shorter")
        c.tap(circle)
        #expect(c.lastAsk.prompt == "Shorter")
        let field = c.runtime.resolved.find(c.example.field)!
        #expect(field.value(.text).textValue.isEmpty)
        // While the answer is written the same button stops it; what was written stays.
        c.runtime.update(ai: c.lastAsk.id, .partial("Sure, here"))
        c.runtime.tick(dt: c.frame)
        let asking = c.lastAsk
        c.tap(circle)
        #expect(c.sent.contains { $0.id == asking.id && $0.phase == .cancel })
        #expect(c.texts == ["Shorter", "Sure, here"])
        #expect(c.shown.last?.value(atPath: "actions")?.boolValue == true)
        // The next question follows on from what was kept.
        c.type("Go on")
        c.runtime.send(.submit)
        c.runtime.tick(dt: c.frame)
        c.runtime.tick(dt: c.frame)
        #expect(c.lastAsk.conversation == [AITurn(.user, "Shorter"), AITurn(.assistant, "Sure, here")])
    }

    @Test func holdingTheMicrophoneAsksOutLoud() {
        let c = Chatting()
        let mic = Chat.micCenter
        c.runtime.send(.touchDown(mic))
        c.runtime.tick(dt: c.frame)
        c.runtime.tick(dt: c.frame)
        let listening = c.sent.first { $0.task == .transcription && $0.phase == .startRecording }
        #expect(listening?.model == AIRequest.onDevice)
        c.runtime.update(ai: listening!.id, .recording(true))
        c.runtime.tick(dt: c.frame)
        c.runtime.send(.touchUp(mic))
        c.runtime.tick(dt: c.frame)
        #expect(c.sent.contains { $0.id == listening!.id && $0.phase == .stopRecording })
        c.runtime.update(ai: listening!.id, .finished(text: "What is a quasar?", picture: ""))
        c.runtime.tick(dt: c.frame)
        c.runtime.tick(dt: c.frame)
        #expect(c.lastAsk.prompt == "What is a quasar?")
        // The round button, held while the field is empty, listens too.
        c.answer("A bright galaxy core.")
        c.runtime.send(.touchDown(Chat.circleCenter))
        c.runtime.tick(dt: c.frame)
        c.runtime.tick(dt: c.frame)
        #expect(c.sent.filter { $0.task == .transcription && $0.phase == .startRecording }.count == 2)
        c.runtime.send(.touchUp(Chat.circleCenter))
        c.runtime.tick(dt: c.frame)
    }

    @Test func anAnswerCanBeRatedCopiedAndReadAloud() {
        let c = Chatting()
        c.tap(Point2(x: 100, y: Chat.suggestionsY + 35))
        c.answer("Black holes are heavy.")
        let key = c.shown.last!.value(atPath: "key")!.textValue
        c.tap(c.newest(c.example.like))
        #expect(c.marks.value(atPath: key + ".vote") == .text("up"))
        // The other thumb takes its place; the same one again takes it back.
        let dislike = Point2(x: c.newest(c.example.like).x + 38, y: c.newest(c.example.like).y)
        c.tap(dislike)
        #expect(c.marks.value(atPath: key + ".vote") == .text("down"))
        c.tap(dislike)
        #expect(c.marks.value(atPath: key + ".vote") == .text(""))
        // Copy shows a tick.
        let copy = Point2(x: c.newest(c.example.like).x - 38, y: c.newest(c.example.like).y)
        c.tap(copy)
        #expect(c.marks.value(atPath: key + ".copied") == .bool(true))
        // Read aloud says the answer in the device's voice.
        c.tap(c.newest(c.example.speaker))
        let reading = c.sent.last { $0.task == .speech && $0.phase == .send }
        #expect(reading?.prompt == "Black holes are heavy." && reading?.model == AIRequest.onDevice)
        c.runtime.update(ai: reading!.id, .finished(text: "", picture: ""))
        c.runtime.update(ai: reading!.id, .playing(true))
        c.runtime.tick(dt: c.frame)
        c.runtime.tick(dt: c.frame)
        #expect(c.marks.value(atPath: key + ".reading") == .bool(true))
        // A new chat does not carry the marks to its messages.
        c.tap(Point2(x: ExampleStyle.device.width - 36, y: ExampleStyle.top + 22))
        c.tap(Point2(x: 100, y: Chat.suggestionsY + 35))
        c.answer("Again.")
        let fresh = c.shown.last!.value(atPath: "key")!.textValue
        #expect(fresh != key)
        #expect(c.marks.value(atPath: fresh + ".copied") == .bool(false))
    }

    /// The newest messages that fit are shown, never one cut off at the bottom.
    @Test func aLongChatKeepsTheNewestMessages() {
        let c = Chatting()
        let long = String(repeating: "A long answer that goes on. ", count: 12)
        c.tap(Point2(x: 100, y: Chat.suggestionsY + 35))
        c.answer(long + "0")
        for round in 1..<4 {
            c.type("More \(round)")
            c.runtime.send(.submit)
            c.runtime.tick(dt: c.frame)
            c.runtime.tick(dt: c.frame)
            c.answer(long + "\(round)")
        }
        #expect(c.sent.filter { $0.task == .text && $0.phase == .send }.count == 4)
        #expect(c.shown.count < 8)
        #expect(c.texts.last?.hasSuffix("3") == true)
        let messages = c.runtime.resolved.children.first { $0.name == "Messages" }!
        let bottom = messages.children.map { $0.position.y + $0.size.height }.max() ?? 0
        #expect(bottom <= Chat.messagesHeight + 0.5)
        #expect(messages.children.allSatisfy { $0.position.y >= -0.5 })
    }
}
