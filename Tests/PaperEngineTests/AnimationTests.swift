import Foundation
import Testing
import PaperModel
@testable import PaperEngine

@Suite struct SpringTests {
    @Test func settlesOnItsTarget() {
        var position = 0.0
        var velocity = 0.0
        for _ in 0..<240 {
            (position, velocity) = Spring.step(
                position: position, velocity: velocity, target: 1, response: 0.4, dampingRatio: 0.8, dt: frame
            )
        }
        #expect(abs(position - 1) < 1e-4)
        #expect(abs(velocity) < 1e-3)
    }

    @Test(arguments: [0.5, 1.0, 1.6])
    func doesNotDependOnFrameRate(damping: Double) {
        func run(steps: Int) -> Double {
            var position = 0.0
            var velocity = 0.0
            for _ in 0..<steps {
                (position, velocity) = Spring.step(
                    position: position, velocity: velocity, target: 1, response: 0.5,
                    dampingRatio: damping, dt: 0.2 / Double(steps)
                )
            }
            return position
        }
        #expect(abs(run(steps: 12) - run(steps: 24)) < 1e-9)
    }

    @Test func underdampedSpringsOvershoot() {
        var position = 0.0
        var velocity = 0.0
        var peak = 0.0
        for _ in 0..<240 {
            (position, velocity) = Spring.step(
                position: position, velocity: velocity, target: 1, response: 0.4, dampingRatio: 0.4, dt: frame
            )
            peak = max(peak, position)
        }
        #expect(peak > 1.05)
    }
}

@Suite struct AnimationPatchTests {
    /// A switch driving a spring, flipped by tapping the box.
    func rig() -> (Runtime, spring: NodeID) {
        var rig = Rig()
        let touch = rig.builder.interaction(on: rig.box, at: .zero)
        let toggle = rig.add("switch")
        let spring = rig.add("spring")
        rig.connect(touch, "tap", toggle, "flip")
        rig.connect(toggle, "on", spring, "target")
        let runtime = Runtime(document: rig.document)
        runtime.tick(dt: frame)
        return (runtime, spring)
    }

    @Test func nothingAnimatesOnLaunch() {
        var rig = Rig()
        let spring = rig.add("spring", ["target": .number(5)])
        let runtime = Runtime(document: rig.document)
        #expect(runtime.tick(dt: frame) == false)
        #expect(runtime.number(spring, "value") == 5)
    }

    @Test func reversingMidwayIsContinuous() {
        let (runtime, spring) = rig()
        runtime.tap(at: Point2(x: 150, y: 150))
        runtime.advance(seconds: 0.12)
        let before = runtime.number(spring, "value")
        #expect(before > 0.05 && before < 0.95)
        #expect(runtime.number(spring, "velocity") > 1)

        // Tap again mid-flight, then watch each frame.
        runtime.tap(at: Point2(x: 150, y: 150))
        var previous = before
        var largestStep = 0.0
        var kept = 0
        for index in 0..<30 {
            runtime.tick(dt: frame)
            let value = runtime.number(spring, "value")
            largestStep = max(largestStep, abs(value - previous))
            // Momentum carries on for a few frames after the target changes: the value keeps
            // rising before it turns around, instead of reversing instantly.
            if index < 4, value > previous { kept += 1 }
            previous = value
        }
        #expect(largestStep < 0.12)
        #expect(kept >= 2)

        runtime.advance(seconds: 2)
        #expect(runtime.number(spring, "value") == 0)
        #expect(runtime.needsAnotherFrame == false)
    }

    @Test func repeatedTapsNeverLeaveTheRangeByMuch() {
        let (runtime, spring) = rig()
        for _ in 0..<12 {
            runtime.tap(at: Point2(x: 150, y: 150))
            runtime.advance(seconds: 0.05)
            let value = runtime.number(spring, "value")
            #expect(value > -0.3 && value < 1.3)
        }
    }

    @Test func holdTracksThenReleasesWithoutAJump() {
        var rig = Rig()
        let touch = rig.builder.interaction(on: rig.box, at: .zero)
        let split = rig.add("splitPoint")
        let spring = rig.add("spring", ["target": .number(0)])
        rig.connect(touch, "down", spring, "hold")
        rig.connect(touch, "drag", split, "point")
        rig.connect(split, "y", spring, "held")
        let runtime = Runtime(document: rig.document)
        runtime.tick(dt: frame)

        runtime.send(.touchDown(Point2(x: 150, y: 150)))
        runtime.tick(dt: frame)
        for step in 1...20 {
            runtime.send(.touchMoved(Point2(x: 150, y: 150 + Double(step) * 5)))
            runtime.tick(dt: frame)
            #expect(runtime.number(spring, "value") == Double(step) * 5)
        }
        let atRelease = runtime.number(spring, "value")
        #expect(runtime.number(spring, "velocity") > 200)

        runtime.send(.touchUp(Point2(x: 150, y: 250)))
        runtime.tick(dt: frame)
        let afterRelease = runtime.number(spring, "value")
        // One frame after release the value keeps moving the way the finger was going,
        // by about one frame of finger travel: no snap back and no leap.
        #expect(afterRelease > atRelease)
        #expect(afterRelease - atRelease < 8)

        runtime.advance(seconds: 3)
        #expect(runtime.number(spring, "value") == 0)
    }

    @Test func easingReachesItsTargetOnTimeAndRetargets() {
        var rig = Rig()
        let touch = rig.builder.interaction(on: rig.box, at: .zero)
        let toggle = rig.add("switch")
        let easing = rig.add("easing", ["duration": .number(0.5), "curve": .text("Linear")])
        rig.connect(touch, "tap", toggle, "flip")
        rig.connect(toggle, "on", easing, "target")
        let runtime = Runtime(document: rig.document)
        runtime.tick(dt: frame)

        runtime.tap(at: Point2(x: 150, y: 150))
        runtime.advance(seconds: 0.3)
        let midway = runtime.number(easing, "value")
        #expect(midway > 0.3 && midway < 0.7)

        runtime.tap(at: Point2(x: 150, y: 150))
        runtime.tick(dt: frame)
        runtime.tick(dt: frame)
        #expect(abs(runtime.number(easing, "value") - midway) < 0.1)
        runtime.advance(seconds: 0.6)
        #expect(runtime.number(easing, "value") == 0)
        #expect(runtime.needsAnotherFrame == false)
    }
}

@Suite struct ExampleTests {
    @Test func cardOpensAndOneProgressDrivesEverything() {
        let example = SampleDocuments.card()
        let runtime = Runtime(document: example.document)
        runtime.tick(dt: frame)
        typealias Card = SampleDocuments.Card

        func card() -> ResolvedLayer { runtime.resolved.find(example.card)! }
        #expect(card().size == Card.collapsedSize)
        #expect(card().position == Card.collapsedPosition)
        #expect(runtime.resolved.find(example.dim)?.opacity == 0)

        runtime.tap(at: Point2(x: 150, y: 400))
        var sawMidway = false
        for _ in 0..<240 {
            runtime.tick(dt: frame)
            let progress = runtime.number(example.spring, "value")
            // Every driven property reflects the same progress on the same frame.
            let expectedWidth = Card.collapsedSize.width + (Card.expandedSize.width - Card.collapsedSize.width) * progress
            #expect(abs(card().size.width - expectedWidth) < 1e-9)
            #expect(abs(runtime.resolved.find(example.dim)!.opacity - 0.4 * progress) < 1e-9)
            #expect(abs(runtime.resolved.find(example.close)!.opacity - progress) < 1e-9)
            if progress > 0.4, progress < 0.6 { sawMidway = true }
        }
        #expect(sawMidway)
        #expect(card().size == Card.expandedSize)
        #expect(card().position == Card.expandedPosition)
        #expect(runtime.needsAnotherFrame == false)

        // The card moved, so tapping where it is now closes it.
        runtime.tap(at: Point2(x: 200, y: 600))
        runtime.advance(seconds: 3)
        #expect(card().size == Card.collapsedSize)
    }

    @Test func sheetFollowsTheFingerAndSettlesWithoutAJump() {
        let example = SampleDocuments.sheet()
        let runtime = Runtime(document: example.document)
        runtime.tick(dt: frame)
        typealias Sheet = SampleDocuments.Sheet

        func y() -> Double { runtime.resolved.find(example.sheet)!.position.y }
        #expect(y() == Sheet.closedY)

        /// Drags from `start` by `distance` over `frames`, releases, and returns the largest
        /// per-frame movement seen in the frames around the release.
        func drag(from start: Point2, by distance: Double, frames: Int) -> Double {
            runtime.send(.touchDown(start))
            runtime.tick(dt: frame)
            let base = y()
            var previous = base
            var perFrame = 0.0
            for step in 1...frames {
                let offset = distance * Double(step) / Double(frames)
                runtime.send(.touchMoved(Point2(x: start.x, y: start.y + offset)))
                runtime.tick(dt: frame)
                // While the finger is down the sheet is attached to it.
                #expect(abs(y() - (base + offset)) < 1e-9)
                perFrame = abs(y() - previous)
                previous = y()
            }
            runtime.send(.touchUp(Point2(x: start.x, y: start.y + distance)))
            var largest = 0.0
            for _ in 0..<4 {
                runtime.tick(dt: frame)
                largest = max(largest, abs(y() - previous))
                previous = y()
            }
            // Right after release the sheet moves about as fast as the finger did.
            #expect(largest < perFrame * 2.5 + 2)
            return largest
        }

        // Drag up past the threshold: settles open.
        _ = drag(from: Point2(x: 195, y: 700), by: -320, frames: 24)
        runtime.advance(seconds: 3)
        #expect(y() == Sheet.openY)
        #expect(abs(runtime.resolved.find(example.dim)!.opacity - 0.35) < 1e-9)
        #expect(runtime.needsAnotherFrame == false)

        // A small drag down springs back open.
        _ = drag(from: Point2(x: 195, y: 200), by: 80, frames: 12)
        runtime.advance(seconds: 3)
        #expect(y() == Sheet.openY)

        // A long drag down closes it.
        _ = drag(from: Point2(x: 195, y: 200), by: 360, frames: 24)
        runtime.advance(seconds: 3)
        #expect(y() == Sheet.closedY)
        #expect(runtime.resolved.find(example.dim)!.opacity == 0)
    }

    @Test func grabbingTheSheetMidFlightDoesNotJump() {
        let example = SampleDocuments.sheet()
        let runtime = Runtime(document: example.document)
        runtime.tick(dt: frame)
        func y() -> Double { runtime.resolved.find(example.sheet)!.position.y }

        runtime.send(.touchDown(Point2(x: 195, y: 700)))
        runtime.tick(dt: frame)
        runtime.send(.touchMoved(Point2(x: 195, y: 380)))
        runtime.tick(dt: frame)
        runtime.send(.touchUp(Point2(x: 195, y: 380)))
        runtime.advance(seconds: 0.08)
        let midFlight = y()
        #expect(midFlight != SampleDocuments.Sheet.openY)

        // Catch it wherever it is.
        runtime.send(.touchDown(Point2(x: 195, y: midFlight + 20)))
        runtime.tick(dt: frame)
        let caught = y()
        runtime.tick(dt: frame)
        #expect(abs(caught - midFlight) < 25)
        #expect(abs(y() - caught) < 1e-9)
    }

    @Test func examplesSurviveSerialization() throws {
        for document in [SampleDocuments.card().document, SampleDocuments.sheet().document] {
            #expect(try Document.decode(from: document.encoded()) == document)
        }
    }
}
