import Foundation
import Testing
import PaperModel
@testable import PaperEngine

/// Plan a Day does what its hint says: a city asks Apple's model, the card fills in as the
/// answer streams, the glow runs only while it thinks, and a failure is shown, not lost.
extension ShowcaseTests {
    @Test func aCityAsksTheOnDeviceModelAndTheCardFillsInAsItStreams() {
        typealias Plan = SampleDocuments.PlanADay
        let example = SampleDocuments.planADay()
        let runtime = Runtime(document: example.document)
        var sent: [AIRequest] = []
        runtime.aiHandler = { sent.append($0) }
        runtime.advance(seconds: 0.2)
        func text(_ id: LayerID) -> String { runtime.resolved.find(id)!.value(.text).textValue }
        func glow() -> Double { runtime.number(example.thinking, "value") }
        // Before anything is asked, the card shows the plan it was drawn with, at rest.
        #expect(text(example.title) == "Temples, Tea and Lantern Light")
        #expect(text(example.buttonLabel) == "Plan again")
        #expect(!runtime.needsAnotherFrame)

        // Lisbon is the second chip.
        tap(runtime, Point2(x: 150, y: 215))
        runtime.tick(dt: frame)
        #expect(sent.count == 1)
        let ask = sent[0]
        #expect(ask.task == .object && ask.provider == .apple)
        #expect(ask.prompt == "Plan one perfect day in Lisbon")
        #expect(ask.fields == Plan.fields && ask.instructions == Plan.instructions)
        #expect(AIField.parse(ask.fields).map(\.name) == ["title", "vibe", "morning", "afternoon", "evening", "tip"])
        #expect(text(example.buttonLabel) == "Planning…")

        // The glow fades in and turns while the model thinks, and the last plan fades back.
        runtime.advance(seconds: 0.6)
        #expect(glow() > 0.5)
        #expect(runtime.needsAnotherFrame)
        #expect(runtime.resolved.find(example.card)!.children[0].opacity < 0.5)

        // Fields arrive one at a time; what has not come yet is blank.
        runtime.update(ai: ask.id, .partial(#"{"title": "Tiles and Tram 28"}"#))
        runtime.tick(dt: frame)
        #expect(text(example.title) == "Tiles and Tram 28")
        #expect(text(example.morning).isEmpty)
        runtime.advance(seconds: 0.6)
        #expect(runtime.resolved.find(example.card)!.children[0].opacity > 0.95)
        runtime.update(ai: ask.id, .finished(text: #"""
        {"title": "Tiles and Tram 28", "vibe": "lively", "morning": "Ride Tram 28 up to Graça.", "afternoon": "Pastéis in Belém.", "evening": "Fado in Alfama.", "tip": "Go early."}
        """#, picture: ""))
        runtime.tick(dt: frame)
        #expect(text(example.morning) == "Ride Tram 28 up to Graça.")
        #expect(text(example.tip) == "Go early.")
        #expect(text(example.buttonLabel) == "Plan again")

        // Once it is in, everything comes to rest.
        runtime.settle(within: 3)
        #expect(glow() < 0.01)
        #expect(!runtime.needsAnotherFrame)

        // The button asks again, for the same city; a failure says why in the tip.
        tap(runtime, Point2(x: 200, y: Plan.buttonY + 28))
        runtime.tick(dt: frame)
        #expect(sent.count == 2 && sent[1].prompt == ask.prompt)
        runtime.update(ai: sent[1].id, .failed("Turn on Apple Intelligence in System Settings to use apple-on-device."))
        runtime.tick(dt: frame)
        #expect(text(example.tip).hasPrefix("Turn on Apple Intelligence"))
        // The plan that was there stays.
        #expect(text(example.title) == "Tiles and Tram 28")
    }
}
