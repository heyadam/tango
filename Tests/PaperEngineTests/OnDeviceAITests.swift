import Foundation
import Testing
import PaperModel
@testable import PaperEngine

/// Apple's models: who answers, the fields Generate Object reads, and how Generate Object
/// and Translate ask and show what comes back.
extension AITests {
    @Test func appleModelsNeedNoKey() {
        #expect(AIProvider.of(model: AIRequest.onDevice) == .apple)
        #expect(AIProvider.of(model: "Apple-On-Device") == .apple)
        #expect(AIProvider.of(model: "claude-haiku-5-5") == .anthropic)
        #expect(AIProvider.of(model: "gpt-6-luna") == .openAI)
        #expect(!AIProvider.apple.needsKey)
        #expect(AIProvider.keyed == [.anthropic, .openAI])
        // Every patch that can run on the device offers it.
        #expect(AIRequest.textModels.contains(AIRequest.onDevice))
        #expect(AIRequest.speechModels.contains(AIRequest.onDevice))
        #expect(AIRequest.transcriptionModels.contains(AIRequest.onDevice))
        // A document that never chose a model keeps the one it had.
        #expect(AIRequest.textModels[0] == "claude-opus-5-5")
    }

    @Test func fieldsAreReadOneALine() {
        let fields = AIField.parse("""
        title: text - A short name
        rating: number
        minutes: whole — how long it takes
        vegan: yes/no
        tags: list
        steps: list of 3 text
        scores: 5 numbers
        mood: happy | sad | calm
        moods: list of Happy | sad
        picks: 2 red | blue

        - "note"
        title: number
        : nothing
        """)
        #expect(fields == [
            AIField("title", .text, about: "A short name"),
            AIField("rating", .number),
            AIField("minutes", .whole, about: "how long it takes"),
            AIField("vegan", .bool),
            AIField("tags", .list(.text, count: nil)),
            AIField("steps", .list(.text, count: 3)),
            AIField("scores", .list(.number, count: 5)),
            AIField("mood", .choice(["happy", "sad", "calm"])),
            AIField("moods", .list(.choice(["Happy", "sad"]), count: nil)),
            AIField("picks", .list(.choice(["red", "blue"]), count: 2)),
            AIField("note", .text),
        ])
        #expect(AIField.parse("").isEmpty)
        // A count no model could make is held to a hundred.
        #expect(AIField.parse("x: list of 99999999999 numbers") == [AIField("x", .list(.number, count: 100))])
        #expect(AIField.parse("x: 1000 numbers") == [AIField("x", .list(.number, count: 100))])
    }

    @Test func languagesAreNamedOrCoded() {
        #expect(AIRequest.languageCode("Spanish") == "es")
        #expect(AIRequest.languageCode("japanese") == "ja")
        #expect(AIRequest.languageCode(" pt-PT ") == "pt-PT")
        #expect(AIRequest.languageCode("Detect") == "")
        #expect(AIRequest.languageCode("") == "")
    }

    @Test func anObjectFillsInAsItStreams() {
        let (runtime, ai, sent) = setUp("aiObject", inputs: [
            "prompt": .text("A recipe for toast"), "fields": .text("title: text\nminutes: whole"),
        ])
        tap(runtime)
        #expect(sent.value.count == 1)
        let request = sent.value[0]
        #expect(request.task == .object && request.provider == .apple && request.model == AIRequest.onDevice)
        #expect(request.prompt == "A recipe for toast" && request.fields == "title: text\nminutes: whole")
        #expect(out(runtime, ai, "loading") == .bool(true))
        runtime.tick(dt: frame)
        #expect(!runtime.needsAnotherFrame)

        runtime.update(ai: request.id, .partial(#"{"title": "Hot"}"#))
        runtime.tick(dt: frame)
        #expect(out(runtime, ai, "object") == .object(["title": .text("Hot")]))
        // A partial that does not parse leaves what was shown.
        runtime.update(ai: request.id, .partial(#"{"title": "Hot b"#))
        runtime.tick(dt: frame)
        #expect(out(runtime, ai, "object") == .object(["title": .text("Hot")]))

        runtime.update(ai: request.id, .finished(text: #"{"title": "Hot buttered toast", "minutes": 4}"#, picture: ""))
        runtime.tick(dt: frame)
        #expect(out(runtime, ai, "object").value(atPath: "minutes") == .number(4))
        #expect(out(runtime, ai, "loading") == .bool(false))
        #expect(out(runtime, ai, "done").pulseValue)

        // A failure says why and keeps the last object.
        tap(runtime)
        runtime.update(ai: sent.value[1].id, .failed("Declined"))
        runtime.tick(dt: frame)
        #expect(out(runtime, ai, "failed").pulseValue && out(runtime, ai, "error") == .text("Declined"))
        #expect(out(runtime, ai, "object").value(atPath: "minutes") == .number(4))
    }

    @Test func anObjectNeedsAPromptOrAPicture() {
        let (runtime, _, sent) = setUp("aiObject")
        tap(runtime)
        #expect(sent.value.isEmpty)
    }

    @Test func translateAsksInCodes() {
        let (runtime, ai, sent) = setUp("aiTranslate", inputs: ["text": .text("Good morning"), "to": .text("French")])
        tap(runtime)
        #expect(sent.value.count == 1)
        let request = sent.value[0]
        #expect(request.task == .translation && request.provider == .apple)
        #expect(request.prompt == "Good morning" && request.target == "fr" && request.source == "")
        #expect(out(runtime, ai, "loading") == .bool(true))
        runtime.update(ai: request.id, .finished(text: "Bonjour", picture: ""))
        runtime.tick(dt: frame)
        #expect(out(runtime, ai, "text") == .text("Bonjour"))
        #expect(out(runtime, ai, "done").pulseValue)

        // Blank text sends nothing.
        let (quiet, _, none) = setUp("aiTranslate", inputs: ["text": .text("  ")])
        tap(quiet)
        #expect(none.value.isEmpty)
    }
}
