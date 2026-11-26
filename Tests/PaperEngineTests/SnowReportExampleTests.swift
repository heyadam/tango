import Foundation
import Testing
import PaperModel
@testable import PaperEngine

@Suite struct SnowReportExampleTests {
    let frame = 1.0 / 60.0

    func tap(_ runtime: Runtime, _ point: Point2) {
        runtime.send(.touchDown(point))
        runtime.tick(dt: frame)
        runtime.send(.touchUp(point))
        runtime.tick(dt: frame)
    }

    func drag(_ runtime: Runtime, from start: Point2, to end: Point2, frames: Int = 8) {
        runtime.send(.touchDown(start))
        runtime.tick(dt: frame)
        for step in 1...frames {
            let t = Double(step) / Double(frames)
            runtime.send(.touchMoved(Point2(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)))
            runtime.tick(dt: frame)
        }
        runtime.send(.touchUp(end))
        runtime.tick(dt: frame)
    }

    @Test func tappingTheMountainMorphsToSummitSwitchesElevationAndReturns() {
        let example = SampleDocuments.snowReport()
        let runtime = Runtime(document: example.document)
        runtime.advance(seconds: 0.2)
        // Starts on Report, resting at zero CPU.
        #expect(runtime.resolved.find(example.report) != nil)
        #expect(runtime.resolved.find(example.summit) == nil)
        #expect(!runtime.needsAnotherFrame)

        // Tap the mountain hero card (20..382, 152..492): morphs smoothly into Summit.
        tap(runtime, Point2(x: 200, y: 320))
        runtime.advance(seconds: 0.12)
        // Mid-morph: both screens exist and the Summit mountain is growing toward full-bleed.
        let midMountain = runtime.resolved.find(example.summitMountain)
        #expect(midMountain != nil)
        #expect((midMountain?.size.height ?? 0) > 350 && (midMountain?.size.height ?? 900) < 874)

        runtime.settle(within: 3)
        #expect(runtime.resolved.find(example.report) == nil)
        #expect(runtime.resolved.find(example.summit) != nil)
        #expect(runtime.resolved.find(example.snowfall)?.value(.text).textValue == "14″")
        #expect(runtime.resolved.find(example.temp)?.value(.text).textValue == "16°F")
        #expect(runtime.resolved.find(example.liftName)?.value(.text).textValue == "Alpine Tram")
        #expect(abs((runtime.resolved.find(example.thumb)?.position.x ?? 0) - 25) < 0.5)
        #expect(!runtime.needsAnotherFrame)

        // Tap Mid (143..259, 491..533): pill slides to center, shader altitude and snow data update.
        tap(runtime, Point2(x: 201, y: 512))
        runtime.settle(within: 3)
        #expect(runtime.resolved.find(example.snowfall)?.value(.text).textValue == "11″")
        #expect(runtime.resolved.find(example.temp)?.value(.text).textValue == "21°F")
        #expect(runtime.resolved.find(example.liftName)?.value(.text).textValue == "Collins Express")
        #expect(abs((runtime.resolved.find(example.thumb)?.position.x ?? 0) - 143) < 0.5)
        #expect(abs((runtime.resolved.find(example.summitMountain)?.shader?.values["altitude"]?.numberValue ?? -1) - 0.5) < 0.01)

        // Tap Base (261..377, 491..533): pill slides to right, Base Village report shows.
        tap(runtime, Point2(x: 319, y: 512))
        runtime.settle(within: 3)
        #expect(runtime.resolved.find(example.snowfall)?.value(.text).textValue == "7″")
        #expect(runtime.resolved.find(example.temp)?.value(.text).textValue == "26°F")
        #expect(runtime.resolved.find(example.liftName)?.value(.text).textValue == "Wildcat Quad")
        #expect(abs((runtime.resolved.find(example.thumb)?.position.x ?? 0) - 261) < 0.5)
        #expect(abs((runtime.resolved.find(example.summitMountain)?.shader?.values["altitude"]?.numberValue ?? -1) - 0.0) < 0.01)
        #expect(!runtime.needsAnotherFrame)

        // Swipe down on the mountain returns to Report.
        drag(runtime, from: Point2(x: 200, y: 260), to: Point2(x: 200, y: 420))
        runtime.settle(within: 3)
        #expect(runtime.resolved.find(example.report) != nil)
        #expect(runtime.resolved.find(example.summit) == nil)
        #expect(!runtime.needsAnotherFrame)

        // Tapping Featured Lifts also opens Summit, and tapping Back returns to Report.
        tap(runtime, Point2(x: 200, y: 680))
        runtime.settle(within: 3)
        #expect(runtime.resolved.find(example.summit) != nil)
        tap(runtime, Point2(x: 42, y: 88))
        runtime.settle(within: 3)
        #expect(runtime.resolved.find(example.report) != nil)
        #expect(runtime.resolved.find(example.summit) == nil)
    }
}
