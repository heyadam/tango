import Foundation
import Testing
import PaperModel
@testable import PaperEngine

@Suite struct StockPickerExampleTests {
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

    @Test func pickingAStockMorphsToChartScrubsSwitchesRangeAndReturns() {
        let example = SampleDocuments.stockPicker()
        let runtime = Runtime(document: example.document)
        runtime.advance(seconds: 0.2)

        func visible(_ id: LayerID) -> Bool { runtime.resolved.find(id) != nil }
        func text(_ id: LayerID) -> String { runtime.resolved.find(id)!.value(.text).textValue }
        func thumbX() -> Double { runtime.resolved.find(example.rangeThumb)!.position.x }

        // Starts on Watchlist at rest with NVDA.
        #expect(visible(example.watchlist))
        #expect(!visible(example.chart))
        #expect(!runtime.needsAnotherFrame)

        // Tap AAPL row (y = 560..642) -> selects AAPL and morphs into Chart.
        tap(runtime, Point2(x: 201, y: 600))
        runtime.advance(seconds: 0.15)
        // Mid-morph, both screens are present while the card grows.
        #expect(visible(example.chart))
        runtime.settle(within: 3)
        #expect(!visible(example.watchlist))
        #expect(visible(example.chart))
        #expect(text(example.detailTicker) == "AAPL")
        #expect(text(example.detailPrice) == "$234.50")
        #expect(text(example.detailChange) == "+1.68%")
        #expect(text(example.openValue) == "$230.62")

        // Scrub across the chart curve (y = 390): crosshair wakes and price/timestamp update live.
        drag(runtime, from: Point2(x: 120, y: 390), to: Point2(x: 80, y: 390), frames: 12, lift: false)
        runtime.advance(seconds: 0.15)
        #expect(runtime.number(example.scrubActive, "value") > 0.7)
        let scrubbedPrice = text(example.detailPrice)
        let scrubbedTime = text(example.scrubTime)
        #expect(scrubbedPrice != "$234.50")
        #expect(scrubbedTime != "Today · 4:00 PM")

        // Lift finger -> crosshair settles off and price returns to close.
        runtime.send(.touchUp(Point2(x: 80, y: 390)))
        runtime.settle(within: 3)
        #expect(runtime.number(example.scrubActive, "value") < 0.02)
        #expect(text(example.detailPrice) == "$234.50")
        #expect(text(example.scrubTime) == "Today · 4:00 PM")

        // Switch timeframe to 1Y (tab at x = 261..377, y = 517..557).
        #expect(abs(thumbX() - 25) < 0.5)
        tap(runtime, Point2(x: 319, y: 537))
        runtime.settle(within: 3)
        #expect(abs(thumbX() - 261) < 0.5)
        #expect(text(example.detailChange) == "+26.0%")
        #expect(text(example.scrubTime) == "Past Year")

        // Tap Back (x = 20..64, y = 66..110) -> morphs back to Watchlist and rests.
        tap(runtime, Point2(x: 42, y: 88))
        runtime.settle(within: 3)
        #expect(visible(example.watchlist))
        #expect(!visible(example.chart))
        #expect(!runtime.needsAnotherFrame)
    }
}
