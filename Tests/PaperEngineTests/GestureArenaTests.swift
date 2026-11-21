import Foundation
import Testing
import PaperModel
@testable import PaperEngine

/// The gesture arena on its own: touches in, what each recognizer reports out.
@Suite struct GestureArenaTests {
    typealias Kind = GestureArena.Kind
    let frame = 1.0 / 60.0
    let photo = ResolvedLayer.Hit(layer: LayerID(), instance: 0)
    let list = ResolvedLayer.Hit(layer: LayerID(), instance: 0)

    /// An arena and its clock.
    struct Bench {
        var arena = GestureArena()
        var time = 0.0
        let frame = 1.0 / 60.0

        /// One frame: what the events of it did is read after this.
        mutating func tick(_ events: (inout GestureArena, Double) -> Void = { _, _ in }) {
            time += frame
            arena.beginFrame()
            events(&arena, time)
            arena.advance(time: time, dt: frame)
        }

        mutating func wait(_ seconds: Double) {
            for _ in 0..<Int((seconds / frame).rounded()) { tick() }
        }

        mutating func down(_ id: Int, _ x: Double, _ y: Double, _ candidates: [GestureArena.Candidate]) {
            tick { arena, time in arena.begin(id: id, at: Point2(x: x, y: y), time: time, candidates: candidates) }
        }

        /// Moves fingers to new places over `frames` frames, all together.
        mutating func move(_ targets: [Int: Point2], frames: Int = 6, canScroll: @escaping (Int, Double) -> Bool = { _, _ in true }) {
            let starts = targets.keys.reduce(into: [Int: Point2]()) { $0[$1] = arena.touch($1)?.current ?? .zero }
            for step in 1...frames {
                let t = Double(step) / Double(frames)
                tick { arena, _ in
                    for (id, target) in targets.sorted(by: { $0.key < $1.key }) {
                        let start = starts[id]!
                        arena.move(id: id, to: start + (target - start) * t)
                    }
                    arena.settle(canScroll: canScroll)
                }
            }
        }

        mutating func up(_ id: Int) {
            tick { arena, time in arena.end(id: id, at: arena.touch(id)?.current ?? .zero, time: time) }
        }
    }

    func candidate(_ owner: Int, _ kind: Kind, on hit: ResolvedLayer.Hit? = nil) -> GestureArena.Candidate {
        GestureArena.Candidate(owner: owner, hit: hit ?? photo, kind: kind)
    }

    func point(_ x: Double, _ y: Double) -> Point2 { Point2(x: x, y: y) }

    // MARK: One finger

    @Test func aTapIsADownAndAnUpInPlace() {
        var bench = Bench()
        let tap = [candidate(1, .tap(taps: 1, fingers: 1))]
        bench.down(0, 100, 100, tap)
        #expect(bench.arena.reading(owner: 1, hit: photo)?.recognized == false)
        bench.up(0)
        #expect(bench.arena.reading(owner: 1, hit: photo)?.recognized == true)
        bench.tick()
        // A pulse, and then the recognizer is forgotten.
        #expect(bench.arena.reading(owner: 1, hit: photo) == nil)
        #expect(!bench.arena.needsFrames)
    }

    @Test func aTapThatMovesOrIsHeldIsNotATap() {
        var bench = Bench()
        let tap = [candidate(1, .tap(taps: 1, fingers: 1))]
        bench.down(0, 100, 100, tap)
        bench.move([0: point(100, 130)])
        bench.up(0)
        #expect(bench.arena.reading(owner: 1, hit: photo)?.recognized != true)

        bench.tick()
        bench.down(0, 100, 100, tap)
        bench.wait(0.6)
        bench.up(0)
        #expect(bench.arena.reading(owner: 1, hit: photo)?.recognized != true)
    }

    @Test func aSingleTapWaitsForADoubleTapOnTheSameViewToFail() {
        var bench = Bench()
        let both = [candidate(1, .tap(taps: 1, fingers: 1)), candidate(2, .tap(taps: 2, fingers: 1))]
        bench.down(0, 100, 100, both)
        bench.up(0)
        // Not yet: a second tap may come.
        #expect(bench.arena.reading(owner: 1, hit: photo)?.recognized == false)
        #expect(bench.arena.needsFrames)
        var single = false
        for _ in 0..<30 {
            bench.tick()
            if bench.arena.reading(owner: 1, hit: photo)?.recognized == true { single = true }
            #expect(bench.arena.reading(owner: 2, hit: photo)?.recognized != true)
        }
        #expect(single)
        #expect(!bench.arena.needsFrames)

        // Two taps: the double tap, and never the single.
        bench.down(0, 100, 100, both)
        bench.up(0)
        bench.tick()
        bench.down(0, 100, 100, both)
        bench.up(0)
        #expect(bench.arena.reading(owner: 2, hit: photo)?.recognized == true)
        for _ in 0..<30 {
            #expect(bench.arena.reading(owner: 1, hit: photo)?.recognized != true)
            bench.tick()
        }
    }

    @Test func aTapWithoutADoubleTapDoesNotWait() {
        var bench = Bench()
        bench.down(0, 100, 100, [candidate(1, .tap(taps: 1, fingers: 1)), candidate(2, .tap(taps: 2, fingers: 2))])
        bench.up(0)
        // The other tap is for two fingers: nothing to wait for.
        #expect(bench.arena.reading(owner: 1, hit: photo)?.recognized == true)
    }

    @Test func aTwoFingerTapNeedsBothFingers() {
        var bench = Bench()
        let two = [candidate(1, .tap(taps: 1, fingers: 2))]
        bench.down(0, 100, 100, two)
        bench.down(1, 160, 100, two)
        bench.up(0)
        #expect(bench.arena.reading(owner: 1, hit: photo)?.recognized == false)
        bench.up(1)
        #expect(bench.arena.reading(owner: 1, hit: photo)?.recognized == true)

        bench.tick()
        bench.down(0, 100, 100, two)
        bench.up(0)
        #expect(bench.arena.reading(owner: 1, hit: photo)?.recognized != true)
    }

    @Test func aLongPressBeginsAfterItsTimeFailsTheTapAndEndsWhenLifted() {
        var bench = Bench()
        let both = [candidate(1, .tap(taps: 1, fingers: 1)), candidate(2, .longPress(duration: 0.4, fingers: 1))]
        bench.down(0, 100, 100, both)
        bench.wait(0.3)
        #expect(bench.arena.reading(owner: 2, hit: photo)?.isActive == false)
        bench.wait(0.15)
        #expect(bench.arena.reading(owner: 2, hit: photo)?.isActive == true)
        // It may move once it has begun.
        bench.move([0: point(140, 100)])
        #expect(bench.arena.reading(owner: 2, hit: photo)?.isActive == true)
        #expect(bench.arena.reading(owner: 2, hit: photo)?.position == point(140, 100))
        bench.up(0)
        #expect(bench.arena.reading(owner: 2, hit: photo)?.ended == true)
        #expect(bench.arena.reading(owner: 2, hit: photo)?.isActive == false)
        #expect(bench.arena.reading(owner: 1, hit: photo)?.recognized != true)
    }

    @Test func aLongPressThatMovesFirstNeverBegins() {
        var bench = Bench()
        bench.down(0, 100, 100, [candidate(2, .longPress(duration: 0.4, fingers: 1))])
        bench.move([0: point(100, 140)])
        bench.wait(0.6)
        #expect(bench.arena.reading(owner: 2, hit: photo)?.isActive != true)
    }

    @Test func aPanBeginsBeyondTheSlopAndDoesNotJump() {
        var bench = Bench()
        let pan = [candidate(1, .pan(direction: .any, minFingers: 1, maxFingers: 0))]
        bench.down(0, 100, 100, pan)
        bench.move([0: point(108, 100)], frames: 4)
        #expect(bench.arena.reading(owner: 1, hit: photo)?.isActive == false)
        bench.move([0: point(111, 100)], frames: 1)
        let began = bench.arena.reading(owner: 1, hit: photo)
        #expect(began?.isActive == true)
        #expect(began?.began == true)
        // One point past the slop is one point of travel, not eleven.
        #expect(abs((began?.translation.x ?? 0) - 1) < 0.001)
        bench.move([0: point(200, 150)])
        let reading = bench.arena.reading(owner: 1, hit: photo)
        #expect(abs((reading?.translation.x ?? 0) - 90) < 0.001)
        #expect(abs((reading?.translation.y ?? 0) - 50) < 0.001)
        #expect(reading?.began == false)
        #expect((reading?.velocity.x ?? 0) > 100)
        bench.up(0)
        let ended = bench.arena.reading(owner: 1, hit: photo)
        #expect(ended?.ended == true)
        #expect(ended?.isActive == false)
        // The speed it was let go at is still there to throw with.
        #expect((ended?.velocity.x ?? 0) > 100)
    }

    @Test func aPanWithADirectionFailsTheOtherWay() {
        var bench = Bench()
        let pan = [candidate(1, .pan(direction: .horizontal, minFingers: 1, maxFingers: 0))]
        bench.down(0, 100, 100, pan)
        bench.move([0: point(104, 160)])
        #expect(bench.arena.reading(owner: 1, hit: photo)?.isActive != true)
        // Turning sideways afterwards does not bring it back.
        bench.move([0: point(200, 160)])
        #expect(bench.arena.reading(owner: 1, hit: photo)?.isActive != true)
        bench.up(0)
        bench.tick()

        bench.down(0, 100, 100, pan)
        bench.move([0: point(160, 104)])
        #expect(bench.arena.reading(owner: 1, hit: photo)?.isActive == true)
    }

    @Test func aFlickIsASwipeAndASlowDragIsNot() {
        var bench = Bench()
        let swipe = [candidate(1, .swipe(fingers: 1))]
        bench.down(0, 300, 100, swipe)
        bench.move([0: point(180, 104)], frames: 5)
        bench.up(0)
        #expect(bench.arena.reading(owner: 1, hit: photo)?.swipe == .left)

        bench.tick()
        bench.down(0, 300, 100, swipe)
        bench.move([0: point(180, 104)], frames: 90)
        bench.up(0)
        #expect(bench.arena.reading(owner: 1, hit: photo)?.swipe == nil)
    }

    @Test func aRawTouchReportsDownDragTapDoubleTapAndLongPress() {
        var bench = Bench()
        let touch = [candidate(1, .touch)]
        bench.down(0, 100, 100, touch)
        #expect(bench.arena.reading(owner: 1, hit: photo)?.isActive == true)
        bench.up(0)
        #expect(bench.arena.reading(owner: 1, hit: photo)?.tapped == true)
        #expect(bench.arena.reading(owner: 1, hit: photo)?.doubleTapped == false)
        bench.tick()
        bench.down(0, 100, 100, touch)
        bench.up(0)
        #expect(bench.arena.reading(owner: 1, hit: photo)?.doubleTapped == true)

        bench.wait(0.5)
        bench.down(0, 100, 100, touch)
        var pressed = 0
        for _ in 0..<40 {
            bench.tick()
            if bench.arena.reading(owner: 1, hit: photo)?.longPressed == true { pressed += 1 }
        }
        #expect(pressed == 1)
        bench.move([0: point(150, 100)])
        #expect(bench.arena.reading(owner: 1, hit: photo)?.translation == point(50, 0))
        bench.up(0)
        #expect(bench.arena.reading(owner: 1, hit: photo)?.tapped == false)
    }

    // MARK: Two fingers

    var manipulation: [GestureArena.Candidate] {
        [
            candidate(1, .pan(direction: .any, minFingers: 1, maxFingers: 0)),
            candidate(2, .pinch),
            candidate(3, .rotation),
        ]
    }

    @Test func panPinchAndRotationOnOneViewGoTogether() {
        var bench = Bench()
        bench.down(0, 150, 300, manipulation)
        bench.down(1, 250, 300, manipulation)
        // Both fingers travel right and down, spread to twice as far apart, and turn a quarter.
        bench.move([0: point(260, 300), 1: point(260, 500)], frames: 30)
        let pan = bench.arena.reading(owner: 1, hit: photo)
        let pinch = bench.arena.reading(owner: 2, hit: photo)
        let rotation = bench.arena.reading(owner: 3, hit: photo)
        #expect(pan?.isActive == true)
        #expect(pinch?.isActive == true)
        #expect(rotation?.isActive == true)
        // Each is measured from where it began, a slop short of what the fingers did.
        #expect(abs((pan?.translation.length ?? 0) - (point(60, 100).length - 10)) < 0.5)
        // (The fingers came closer before they spread, so the pinch began on the way in.)
        #expect(abs((pinch?.scale ?? 0) - 200.0 / 92.0) < 0.01)
        #expect(abs((rotation?.rotation ?? 0) - 85) < 0.5)
        #expect(pinch?.position == point(260, 400))

        bench.up(1)
        #expect(bench.arena.reading(owner: 2, hit: photo)?.ended == true)
        #expect(bench.arena.reading(owner: 3, hit: photo)?.ended == true)
        // The pan carries on with the finger that stayed, and does not jump to it.
        let after = bench.arena.reading(owner: 1, hit: photo)
        #expect(after?.isActive == true)
        #expect(after?.translation == pan?.translation)
        bench.move([0: point(280, 300)])
        #expect(abs((bench.arena.reading(owner: 1, hit: photo)?.translation.x ?? 0) - ((pan?.translation.x ?? 0) + 20)) < 0.001)
    }

    @Test func aPinchReportsNothingUntilTheSpreadChanges() {
        var bench = Bench()
        let pinch = [candidate(2, .pinch)]
        bench.down(0, 150, 300, pinch)
        bench.down(1, 250, 300, pinch)
        // Both move together: a pan, were there one, but no pinch.
        bench.move([0: point(150, 400), 1: point(250, 400)])
        #expect(bench.arena.reading(owner: 2, hit: photo)?.isActive == false)
        bench.move([0: point(100, 400), 1: point(300, 400)])
        let reading = bench.arena.reading(owner: 2, hit: photo)
        #expect(reading?.isActive == true)
        #expect(abs((reading?.scale ?? 0) - 200.0 / 108.0) < 0.001)
        #expect((reading?.scaleVelocity ?? 0) > 0)
    }

    @Test func aTwoFingerPanNeedsTwoFingers() {
        var bench = Bench()
        let pan = [candidate(1, .pan(direction: .any, minFingers: 2, maxFingers: 2))]
        bench.down(0, 150, 300, pan)
        bench.move([0: point(150, 380)])
        #expect(bench.arena.reading(owner: 1, hit: photo)?.isActive == false)
        bench.down(1, 250, 300, pan)
        bench.move([0: point(150, 420), 1: point(250, 340)])
        let reading = bench.arena.reading(owner: 1, hit: photo)
        #expect(reading?.isActive == true)
        #expect(abs((reading?.translation.y ?? 0) - 30) < 0.001)
        bench.up(0)
        #expect(bench.arena.reading(owner: 1, hit: photo)?.ended == true)
    }

    // MARK: Who wins

    @Test func theFirstToBeginWinsAndTheDeeperViewIsAskedFirst() {
        var bench = Bench()
        let card = ResolvedLayer.Hit(layer: LayerID(), instance: 0)
        let both = [
            candidate(1, .pan(direction: .any, minFingers: 1, maxFingers: 0)),
            candidate(2, .pan(direction: .any, minFingers: 1, maxFingers: 0), on: card),
            candidate(3, .swipe(fingers: 1), on: card),
        ]
        bench.down(0, 300, 100, both)
        bench.move([0: point(180, 100)], frames: 5)
        #expect(bench.arena.reading(owner: 1, hit: photo)?.isActive == true)
        #expect(bench.arena.reading(owner: 2, hit: card)?.isActive == false)
        bench.up(0)
        #expect(bench.arena.reading(owner: 3, hit: card)?.swipe == nil)
    }

    @Test func aRawTouchGoesOnBesideARecognizer() {
        var bench = Bench()
        bench.down(0, 300, 100, [candidate(1, .touch), candidate(2, .pan(direction: .any, minFingers: 1, maxFingers: 0))])
        bench.move([0: point(200, 100)])
        #expect(bench.arena.reading(owner: 1, hit: photo)?.isActive == true)
        #expect(bench.arena.reading(owner: 1, hit: photo)?.translation == point(-100, 0))
        #expect(bench.arena.reading(owner: 2, hit: photo)?.isActive == true)
    }

    // MARK: Scroll views

    @Test func aScrollViewBeginsAlongItsAxisAndCancelsTheContentsTouch() {
        var bench = Bench()
        let row = [candidate(1, .touch), candidate(9, .scroll(horizontal: false, moving: false), on: list)]
        bench.down(0, 100, 300, row)
        #expect(bench.arena.reading(owner: 1, hit: photo)?.isActive == true)
        bench.move([0: point(100, 308)], frames: 2)
        #expect(bench.arena.reading(owner: 9, hit: list)?.isActive == false)
        bench.move([0: point(100, 360)])
        let scroll = bench.arena.reading(owner: 9, hit: list)
        #expect(scroll?.isActive == true)
        // From where it began, a slop after the finger came down.
        #expect(scroll?.translation == point(0, 50))
        #expect(bench.arena.reading(owner: 1, hit: photo)?.isActive == false)
        let touch = bench.lift(0)
        #expect(touch?.isTap == false)
        #expect(bench.arena.reading(owner: 1, hit: photo)?.tapped != true)
        #expect(bench.arena.reading(owner: 9, hit: list)?.ended == true)
    }

    @Test func aDragAcrossAScrollViewIsLeftToContentThatWantsIt() {
        var bench = Bench()
        let row = [candidate(1, .touch), candidate(9, .scroll(horizontal: false, moving: false), on: list)]
        bench.down(0, 200, 300, row)
        bench.move([0: point(120, 306)])
        #expect(bench.arena.reading(owner: 9, hit: list)?.isActive == false)
        #expect(bench.arena.reading(owner: 1, hit: photo)?.isActive == true)
        // Having let go, it does not take the touch back.
        bench.move([0: point(120, 400)])
        #expect(bench.arena.reading(owner: 9, hit: list)?.isActive == false)
        bench.up(0)
        bench.tick()

        // With nothing in the content to mean it, the same drag scrolls.
        bench.down(0, 200, 300, [candidate(9, .scroll(horizontal: false, moving: false), on: list)])
        bench.move([0: point(120, 306)])
        #expect(bench.arena.reading(owner: 9, hit: list)?.isActive == true)
    }

    /// A tap or a long press around the list is about to fail on the same move; it is
    /// not content that wants the drag.
    @Test func aTapOnAViewAroundAListDoesNotKeepItFromScrollingOnASidewaysStart() {
        let container = ResolvedLayer.Hit(layer: LayerID(), instance: 0)
        var bench = Bench()
        bench.down(0, 200, 300, [
            candidate(9, .scroll(horizontal: false, moving: false), on: list),
            candidate(1, .tap(taps: 1, fingers: 1), on: container),
            candidate(2, .longPress(duration: 0.5, fingers: 1), on: container),
        ])
        bench.move([0: point(212, 309)], frames: 1)
        #expect(bench.arena.reading(owner: 9, hit: list)?.isActive == true)
        bench.up(0)
        #expect(bench.arena.reading(owner: 1, hit: container)?.recognized != true)
    }

    @Test func recognizersFollowTheirOwnersWhenTheHostRenumbersThem() {
        var bench = Bench()
        let pan = [candidate(4, .pan(direction: .any, minFingers: 1, maxFingers: 0)), candidate(5, .touch)]
        bench.down(0, 100, 100, pan)
        bench.move([0: point(160, 100)])
        bench.tick { arena, _ in arena.renumberOwners { $0 == 4 ? 7 : nil } }
        #expect(bench.arena.reading(owner: 4, hit: photo) == nil)
        #expect(bench.arena.reading(owner: 5, hit: photo) == nil)
        bench.move([0: point(200, 100)])
        #expect(bench.arena.reading(owner: 7, hit: photo)?.translation == point(90, 0))
        bench.up(0)
        #expect(bench.arena.reading(owner: 7, hit: photo)?.ended == true)
        bench.tick()
        #expect(!bench.arena.needsFrames)
    }

    @Test func aPanWithADirectionAndAScrollViewAreToldApartByTheDrag() {
        let row = [
            candidate(1, .pan(direction: .horizontal, minFingers: 1, maxFingers: 0)),
            candidate(9, .scroll(horizontal: false, moving: false), on: list),
        ]
        var bench = Bench()
        bench.down(0, 200, 300, row)
        bench.move([0: point(120, 306)])
        #expect(bench.arena.reading(owner: 1, hit: photo)?.isActive == true)
        #expect(bench.arena.reading(owner: 9, hit: list)?.isActive == false)

        bench = Bench()
        bench.down(0, 200, 300, row)
        bench.move([0: point(206, 380)])
        #expect(bench.arena.reading(owner: 1, hit: photo)?.isActive != true)
        #expect(bench.arena.reading(owner: 9, hit: list)?.isActive == true)
    }

    @Test func nestedScrollViewsGoByDirectionAndByWhoCanStillMove() {
        let page = ResolvedLayer.Hit(layer: LayerID(), instance: 0)
        let nested = [
            candidate(8, .scroll(horizontal: true, moving: false), on: list),
            candidate(9, .scroll(horizontal: false, moving: false), on: page),
        ]
        var bench = Bench()
        bench.down(0, 200, 300, nested)
        bench.move([0: point(120, 306)])
        #expect(bench.arena.reading(owner: 8, hit: list)?.isActive == true)
        #expect(bench.arena.reading(owner: 9, hit: page)?.isActive == false)

        bench = Bench()
        bench.down(0, 200, 300, nested)
        bench.move([0: point(206, 380)])
        #expect(bench.arena.reading(owner: 9, hit: page)?.isActive == true)

        // Two along one axis: the inner one, unless it is at its end and the outer is not.
        let stacked = [
            candidate(8, .scroll(horizontal: false, moving: false), on: list),
            candidate(9, .scroll(horizontal: false, moving: false), on: page),
        ]
        bench = Bench()
        bench.down(0, 200, 300, stacked)
        bench.move([0: point(200, 380)])
        #expect(bench.arena.reading(owner: 8, hit: list)?.isActive == true)
        bench = Bench()
        bench.down(0, 200, 300, stacked)
        bench.move([0: point(200, 380)], canScroll: { owner, _ in owner == 9 })
        #expect(bench.arena.reading(owner: 9, hit: page)?.isActive == true)
        #expect(bench.arena.reading(owner: 8, hit: list)?.isActive == false)
    }

    @Test func aMovingScrollViewIsCaughtAtOnceAndTheTouchIsNoTap() {
        var bench = Bench()
        bench.down(0, 200, 300, [candidate(1, .touch), candidate(9, .scroll(horizontal: false, moving: true), on: list)])
        #expect(bench.arena.reading(owner: 9, hit: list)?.isActive == true)
        #expect(bench.arena.reading(owner: 1, hit: photo)?.isActive == false)
        let touch = bench.lift(0)
        #expect(touch?.isTap == false)
        #expect(bench.arena.reading(owner: 1, hit: photo)?.tapped != true)
    }

    @Test func twoFingersOnAPinchAreNotAScroll() {
        var bench = Bench()
        let zoomable = [candidate(2, .pinch), candidate(9, .scroll(horizontal: false, moving: false), on: list)]
        bench.down(0, 150, 300, zoomable)
        bench.down(1, 250, 300, zoomable)
        bench.move([0: point(150, 380), 1: point(250, 380)])
        #expect(bench.arena.reading(owner: 9, hit: list)?.isActive != true)

        // A scroll already under way keeps the touch, and the pinch never begins.
        bench = Bench()
        bench.down(0, 150, 300, zoomable)
        bench.move([0: point(150, 380)])
        #expect(bench.arena.reading(owner: 9, hit: list)?.isActive == true)
        bench.down(1, 250, 300, zoomable)
        bench.move([1: point(350, 300)])
        #expect(bench.arena.reading(owner: 2, hit: photo)?.isActive != true)
        #expect(bench.arena.reading(owner: 9, hit: list)?.isActive == true)
    }

    @Test func aLongPressUnderWayKeepsAScrollViewFromBeginning() {
        var bench = Bench()
        bench.down(0, 200, 300, [
            candidate(1, .longPress(duration: 0.3, fingers: 1)),
            candidate(9, .scroll(horizontal: false, moving: false), on: list),
        ])
        bench.wait(0.4)
        bench.move([0: point(200, 400)])
        #expect(bench.arena.reading(owner: 1, hit: photo)?.isActive == true)
        #expect(bench.arena.reading(owner: 9, hit: list)?.isActive != true)
    }

    // MARK: Cancelling, and a pinch from a trackpad

    @Test func aCancelledTouchEndsWhatItWasDoingAndIsNoTap() {
        var bench = Bench()
        bench.down(0, 100, 100, [
            candidate(1, .touch), candidate(2, .tap(taps: 1, fingers: 1)),
            candidate(3, .pan(direction: .any, minFingers: 1, maxFingers: 0)),
        ])
        bench.tick { arena, _ in arena.cancel(id: 0) }
        #expect(bench.arena.reading(owner: 1, hit: photo)?.isActive == false)
        #expect(bench.arena.reading(owner: 1, hit: photo)?.tapped == false)
        #expect(bench.arena.reading(owner: 2, hit: photo)?.recognized == false)
        bench.tick()
        #expect(!bench.arena.needsFrames)
    }

    @Test func eventsOutOfOrderAreHarmless() {
        var bench = Bench()
        let pan = [candidate(1, .pan(direction: .any, minFingers: 1, maxFingers: 0))]
        bench.tick { arena, time in
            arena.move(id: 4, to: Point2(x: 1, y: 1))
            arena.end(id: 4, at: Point2(x: 1, y: 1), time: time)
            arena.cancel(id: 4)
            arena.begin(id: 0, at: .zero, time: time, candidates: pan)
            arena.begin(id: 0, at: Point2(x: 50, y: 50), time: time, candidates: pan)
        }
        bench.move([0: point(150, 50)])
        #expect(bench.arena.reading(owner: 1, hit: photo)?.translation == point(90, 0))
        bench.up(0)
        bench.tick()
        #expect(!bench.arena.needsFrames)
    }

    @Test func aPinchTheHostRecognizedDrivesPinchAndRotationAtOnce() {
        var bench = Bench()
        let both = [candidate(2, .pinch), candidate(3, .rotation)]
        bench.tick { arena, _ in arena.indirectBegan(at: Point2(x: 200, y: 300), candidates: both) }
        #expect(bench.arena.reading(owner: 2, hit: photo)?.began == true)
        bench.tick { arena, _ in arena.indirectChanged(scale: 1.5, rotation: 20) }
        #expect(bench.arena.reading(owner: 2, hit: photo)?.scale == 1.5)
        #expect(bench.arena.reading(owner: 3, hit: photo)?.rotation == 20)
        #expect(bench.arena.needsFrames)
        bench.tick { arena, _ in arena.indirectEnded() }
        #expect(bench.arena.reading(owner: 2, hit: photo)?.ended == true)
        #expect(bench.arena.reading(owner: 2, hit: photo)?.scale == 1.5)
        bench.tick()
        #expect(!bench.arena.needsFrames)
    }
}

extension GestureArenaTests.Bench {
    /// Lifts a finger and gives back how it ended.
    mutating func lift(_ id: Int) -> GestureArena.TouchPoint? {
        var touch: GestureArena.TouchPoint?
        tick { arena, time in touch = arena.end(id: id, at: arena.touch(id)?.current ?? .zero, time: time) }
        return touch
    }
}
