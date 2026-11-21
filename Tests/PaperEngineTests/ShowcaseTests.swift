import Foundation
import Testing
import PaperModel
@testable import PaperEngine

/// The three showcase examples do what their hints say.
@Suite struct ShowcaseTests {
    let frame = 1.0 / 60.0

    func tap(_ runtime: Runtime, _ point: Point2) {
        runtime.send(.touchDown(point))
        runtime.tick(dt: frame)
        runtime.send(.touchUp(point))
    }

    func drag(_ runtime: Runtime, from start: Point2, to end: Point2, frames: Int = 20, lift: Bool = true) {
        runtime.send(.touchDown(start))
        runtime.tick(dt: frame)
        for step in 1...frames {
            let t = Double(step) / Double(frames)
            runtime.send(.touchMoved(Point2(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)))
            runtime.tick(dt: frame)
        }
        if lift { runtime.send(.touchUp(end)) }
    }

    @Test func pausingSettlesThePlayerAndStopsTheClock() {
        let example = SampleDocuments.nowPlaying()
        let runtime = Runtime(document: example.document)
        runtime.advance(seconds: 0.5)
        func cover() -> ResolvedLayer { runtime.resolved.find(example.cover)! }
        func glyph() -> String { runtime.resolved.find(example.glyph)!.value(.symbol).textValue }
        func played() -> Double { runtime.resolved.find(example.played)!.size.width }
        #expect(abs(cover().scale - 1) < 0.01)
        #expect(glyph() == "pause.fill")
        let before = played()
        runtime.advance(seconds: 2)
        #expect(played() > before)

        // The play button is in the middle of the controls.
        tap(runtime, Point2(x: ExampleStyle.device.width / 2, y: 684))
        runtime.advance(seconds: 2)
        #expect(glyph() == "play.fill")
        #expect(abs(cover().scale - 0.82) < 0.01)
        #expect(abs(runtime.number(example.energy, "value")) < 0.01)
        let paused = played()
        runtime.advance(seconds: 2)
        #expect(played() == paused)
    }

    @Test func draggingTheCardScrubsTheHourAndItStaysThere() {
        typealias Weather = SampleDocuments.Weather
        let example = SampleDocuments.weather()
        let runtime = Runtime(document: example.document)
        runtime.advance(seconds: 0.2)
        func hour() -> Double { runtime.number(example.hour, "value") }
        func clock() -> String { runtime.resolved.find(example.clock)!.value(.text).textValue }
        #expect(abs(hour() - Weather.startHour) < 0.001)
        #expect(clock() == "5:30 PM")

        // Leftwards across the card, a quarter of the track: six hours earlier.
        drag(runtime, from: Point2(x: 300, y: 700), to: Point2(x: 300 - Weather.track.width / 4, y: 700))
        runtime.advance(seconds: 1)
        // A raw touch has no slop: the hour moves with the finger from the start.
        let moved = 6.0
        #expect(abs(hour() - (Weather.startHour - moved)) < 0.05)
        runtime.advance(seconds: 2)
        #expect(abs(hour() - (Weather.startHour - moved)) < 0.05)
        #expect(clock().hasSuffix("AM") || clock().hasPrefix("12"))
        #expect(runtime.resolved.find(example.temperature)!.value(.text).textValue.hasSuffix("°"))
    }

    @Test func draggingTheCardTiltsItAndLettingGoSettlesIt() {
        typealias Holo = SampleDocuments.HoloCard
        let example = SampleDocuments.holoCard()
        let runtime = Runtime(document: example.document)
        runtime.advance(seconds: 0.2)
        func card() -> ResolvedLayer { runtime.resolved.find(example.card)! }
        let middle = Point2(x: Holo.cardPosition.x + Holo.cardSize.width / 2, y: Holo.cardPosition.y + Holo.cardSize.height / 2)
        drag(runtime, from: middle, to: Point2(x: middle.x + 80, y: middle.y + 40), lift: false)
        runtime.advance(seconds: 0.5)
        #expect(runtime.number(example.tiltX, "value") > 0.3)
        #expect(runtime.number(example.tiltY, "value") > 0.1)
        #expect(card().rotation > 2)
        #expect(card().scale > 1.03)

        runtime.send(.touchUp(Point2(x: middle.x + 80, y: middle.y + 40)))
        runtime.advance(seconds: 3)
        #expect(abs(runtime.number(example.tiltX, "value")) < 0.01)
        #expect(abs(card().rotation) < 0.1)
        #expect(abs(card().scale - 1) < 0.01)
        #expect(!runtime.needsAnotherFrame)
    }
}
