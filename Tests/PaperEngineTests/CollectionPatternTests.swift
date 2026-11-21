import Foundation
import Testing
import PaperModel
@testable import PaperEngine

private func copies(_ runtime: Runtime, _ id: LayerID) -> [ResolvedLayer] {
    var found: [ResolvedLayer] = []
    func walk(_ layer: ResolvedLayer) {
        if layer.id == id { found.append(layer) }
        layer.children.forEach(walk)
    }
    walk(runtime.resolved)
    return found
}

private func drag(_ runtime: Runtime, from: Point2, to: Point2, frames: Int = 10) {
    runtime.send(.touchDown(from))
    runtime.tick(dt: frame)
    for step in 1...frames {
        let t = Double(step) / Double(frames)
        runtime.send(.touchMoved(Point2(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)))
        runtime.tick(dt: frame)
    }
    runtime.send(.touchUp(to))
    runtime.tick(dt: frame)
}

/// A vertical page of horizontal carousels: the direction a drag starts in picks the one
/// that scrolls, and taps still reach the cards (spec 7.2, 7.11).
@Suite struct NestedScrollTests {
    typealias Nested = SampleDocuments.NestedScroll

    func run() -> (Runtime, Nested) {
        let example = SampleDocuments.nestedScroll()
        let runtime = Runtime(document: example.document)
        runtime.advance(seconds: 0.1)
        return (runtime, example)
    }

    /// The middle of the first card of a carousel, in screen points.
    func firstCard(_ runtime: Runtime, of carousel: Int, _ example: Nested) -> Point2 {
        let card = copies(runtime, example.cards[carousel])[0]
        let transform = runtime.resolved.transform(toRootFrom: card.id)!
        let middle = CGPoint(x: card.size.width / 2, y: card.size.height / 2).applying(transform)
        return Point2(x: middle.x, y: middle.y)
    }

    func offset(_ runtime: Runtime, _ node: NodeID) -> Double { runtime.number(node, "offset") }

    @Test func everyCarouselIsOneRepeatedCard() {
        let (runtime, example) = run()
        for (index, shelf) in Nested.shelves.enumerated() {
            #expect(copies(runtime, example.cards[index]).count == shelf.titles.count)
        }
    }

    @Test func aSidewaysDragOnACardScrollsItsCarouselOnly() {
        let (runtime, example) = run()
        let start = firstCard(runtime, of: 0, example)
        drag(runtime, from: start, to: Point2(x: start.x - 200, y: start.y + 12))
        #expect(offset(runtime, example.carouselPatches[0]) < -100)
        #expect(offset(runtime, example.feedPatch) == 0)
        // Featured pages: it settles on the next card, and the page has not moved.
        runtime.advance(seconds: 2)
        #expect(abs(offset(runtime, example.carouselPatches[0]) + Nested.shelves[0].page) < 0.5)
        #expect(offset(runtime, example.feedPatch) == 0)
        #expect(offset(runtime, example.carouselPatches[1]) == 0)
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func anUpwardDragOnACardScrollsThePageNotTheCarousel() {
        let (runtime, example) = run()
        let start = firstCard(runtime, of: 1, example)
        drag(runtime, from: start, to: Point2(x: start.x + 14, y: start.y - 160))
        #expect(offset(runtime, example.feedPatch) < -100)
        #expect(offset(runtime, example.carouselPatches[1]) == 0)
        runtime.advance(seconds: 3)
        #expect(offset(runtime, example.feedPatch) < -100)
        #expect(offset(runtime, example.carouselPatches[1]) == 0)
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func aDragOnTheHeadingScrollsThePage() {
        let (runtime, example) = run()
        drag(runtime, from: Point2(x: 120, y: 100), to: Point2(x: 160, y: 40))
        #expect(offset(runtime, example.feedPatch) < -40)
        #expect(example.carouselPatches.allSatisfy { offset(runtime, $0) == 0 })
    }

    @Test func aTapOnACardSavesItAndScrollsNothing() {
        let (runtime, example) = run()
        func hearts(_ carousel: Int) -> [String] {
            copies(runtime, example.hearts[carousel]).map { $0.value(.symbol).textValue }
        }
        #expect(hearts(1).allSatisfy { $0 == "heart" })
        let point = firstCard(runtime, of: 1, example)
        runtime.tap(at: point)
        runtime.advance(seconds: 0.05)
        // It bumps for a moment.
        #expect(copies(runtime, example.cards[1])[0].scale < 1)
        runtime.advance(seconds: 1)
        #expect(hearts(1) == ["heart.fill"] + Array(repeating: "heart", count: Nested.shelves[1].titles.count - 1))
        #expect(copies(runtime, example.cards[1])[0].scale == 1)
        #expect(offset(runtime, example.feedPatch) == 0)
        #expect(offset(runtime, example.carouselPatches[1]) == 0)
        #expect(!runtime.needsAnotherFrame)

        // After a sideways scroll, the card under the finger is the one tapped.
        let start = firstCard(runtime, of: 0, example)
        drag(runtime, from: start, to: Point2(x: start.x - 200, y: start.y))
        runtime.advance(seconds: 2)
        #expect(abs(offset(runtime, example.carouselPatches[0]) + Nested.shelves[0].page) < 0.5)
        runtime.tap(at: start)
        runtime.advance(seconds: 0.5)
        #expect(hearts(0) == ["heart", "heart.fill", "heart", "heart"])
    }
}

/// A photo grid you choose from (spec 7.11): one repeated view, a mode, and a count.
@Suite struct PhotoSelectionTests {
    typealias Photos = SampleDocuments.PhotoSelection

    func run() -> (Runtime, Photos) {
        let example = SampleDocuments.photoSelection()
        let runtime = Runtime(document: example.document)
        runtime.advance(seconds: 0.2)
        return (runtime, example)
    }

    func photo(column: Int, row: Int) -> Point2 {
        let width = (390 - 2 * Photos.spacing) / 3
        return Point2(x: Double(column) * (width + Photos.spacing) + width / 2,
                      y: Photos.top + Double(row) * (Photos.side + Photos.spacing) + Photos.side / 2)
    }

    let selectButton = Point2(x: 326, y: 84)

    func title(_ runtime: Runtime, _ example: Photos) -> String {
        runtime.resolved.find(example.title)!.value(.text).textValue
    }

    func button(_ runtime: Runtime, _ example: Photos) -> String {
        runtime.resolved.find(example.buttonLabel)!.value(.text).textValue
    }

    func picked(_ runtime: Runtime, _ example: Photos) -> [Int] {
        copies(runtime, example.check).enumerated().filter { $0.element.opacity > 0.5 }.map(\.offset)
    }

    @Test func theGridIsOneRepeatedPhoto() {
        let (runtime, example) = run()
        let photos = copies(runtime, example.photo)
        #expect(photos.count == Photos.pictures.count)
        #expect(Set(photos.map { $0.value(.fill).colorValue.hex }).count == Photos.pictures.count)
        #expect(Set(photos.map { Int($0.frame.minX) }).count == 3)
        #expect(title(runtime, example) == "Library")
        #expect(button(runtime, example) == "Select")
    }

    @Test func photosTakeTapsOnlyWhileSelecting() {
        let (runtime, example) = run()
        runtime.tap(at: photo(column: 1, row: 0))
        runtime.advance(seconds: 0.5)
        #expect(picked(runtime, example).isEmpty)
        #expect(title(runtime, example) == "Library")

        runtime.tap(at: selectButton)
        runtime.advance(seconds: 0.5)
        #expect(button(runtime, example) == "Cancel")
        #expect(title(runtime, example) == "Select Items")
    }

    @Test func tappingPicksPhotosAndTheTitleCountsThem() {
        let (runtime, example) = run()
        runtime.tap(at: selectButton)
        runtime.advance(seconds: 0.5)
        // Taps one frame apart, as fast as a replay sends them: each still counts.
        for point in [photo(column: 0, row: 0), photo(column: 1, row: 1), photo(column: 2, row: 2)] {
            runtime.tap(at: point)
            runtime.tick(dt: frame)
        }
        runtime.advance(seconds: 1)
        #expect(picked(runtime, example) == [0, 4, 8])
        #expect(title(runtime, example) == "3 Selected")
        let photos = copies(runtime, example.photo)
        #expect(abs(photos[4].scale - Photos.selectedScale) < 1e-6)
        #expect(photos[5].scale == 1)
        #expect(!runtime.needsAnotherFrame)

        // A second tap lets one go.
        runtime.tap(at: photo(column: 1, row: 1))
        runtime.advance(seconds: 1)
        #expect(picked(runtime, example) == [0, 8])
        #expect(title(runtime, example) == "2 Selected")

        // Cancel lets everything go, and the next round starts from none.
        runtime.tap(at: selectButton)
        runtime.advance(seconds: 1)
        #expect(picked(runtime, example).isEmpty)
        #expect(title(runtime, example) == "Library")
        #expect(button(runtime, example) == "Select")
        runtime.tap(at: selectButton)
        runtime.advance(seconds: 1)
        #expect(title(runtime, example) == "Select Items")
        runtime.tap(at: photo(column: 2, row: 0))
        runtime.advance(seconds: 1)
        #expect(title(runtime, example) == "1 Selected")
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func aTapOnTheBarDoesNotPickAPhotoUnderIt() {
        let (runtime, example) = run()
        runtime.tap(at: selectButton)
        runtime.advance(seconds: 0.5)
        drag(runtime, from: Point2(x: 195, y: 600), to: Point2(x: 195, y: 400))
        runtime.advance(seconds: 3)
        // The bar's title, with photos scrolled under it.
        runtime.tap(at: Point2(x: 60, y: 84))
        runtime.advance(seconds: 1)
        #expect(picked(runtime, example).isEmpty)
        #expect(title(runtime, example) == "Select Items")
    }

    @Test func theButtonWorksWhileTheGridIsStillMoving() {
        let (runtime, example) = run()
        drag(runtime, from: Point2(x: 195, y: 700), to: Point2(x: 195, y: 300), frames: 4)
        runtime.tick(dt: frame)
        #expect(runtime.needsAnotherFrame)
        runtime.tap(at: selectButton)
        runtime.advance(seconds: 0.5)
        #expect(button(runtime, example) == "Cancel")
    }

    @Test func theGridScrollsUnderTheBar() {
        let (runtime, example) = run()
        func top() -> Double { Double(runtime.resolved.transform(toRootFrom: example.photo)!.ty) }
        #expect(abs(top() - Photos.top) < 1e-6)
        drag(runtime, from: Point2(x: 195, y: 600), to: Point2(x: 195, y: 400))
        runtime.advance(seconds: 3)
        #expect(top() < Photos.top - 100)
        #expect(!runtime.needsAnotherFrame)
    }
}

/// Scroll views inside scroll views (spec 7.2): which one a finger moves.
@Suite struct NestedScrollViewTests {
    func page(innerAxis: String) -> (Document, outer: NodeID, inner: NodeID) {
        let boxes = (0..<3).map { _ in
            Layer(kind: .view, properties: [.size: .size(Size2(width: 300, height: 200)), .fill: .color(.white)])
        }
        var inner = Layer.new(.scrollView, name: "Inner")
        inner.set(.axis, .text(innerAxis))
        inner.set(.size, .size(Size2(width: 390, height: 200)))
        inner.children = boxes
        let filler = Layer(kind: .view, properties: [.size: .size(Size2(width: 390, height: 1000))])
        var outer = Layer.new(.scrollView, name: "Outer")
        outer.set(.size, .size(Size2(width: 390, height: 844)))
        outer.children = [inner, filler]
        var document = Document(screen: Layer(name: "Screen", kind: .screen, children: [outer]))
        document.normalize()
        return (document, document.graph.viewNode(layer: outer.id)!.id, document.graph.viewNode(layer: inner.id)!.id)
    }

    @Test func theDirectionOfTheDragPicksBetweenScrollViewsOfDifferentAxes() {
        let (document, outer, inner) = page(innerAxis: "Horizontal")
        let runtime = Runtime(document: document)
        runtime.tick(dt: frame)
        // Sideways, on the row: only the row moves.
        drag(runtime, from: Point2(x: 300, y: 100), to: Point2(x: 100, y: 108), frames: 8)
        #expect(runtime.number(inner, "offset") < -150)
        #expect(runtime.number(outer, "offset") == 0)
        runtime.advance(seconds: 3)
        let sideways = runtime.number(inner, "offset")

        // Neither follows a finger that has not yet left the slop; then the page does.
        runtime.send(.touchDown(Point2(x: 200, y: 100)))
        runtime.tick(dt: frame)
        runtime.send(.touchMoved(Point2(x: 205, y: 95)))
        runtime.tick(dt: frame)
        #expect(!runtime.bool(outer, "dragging") && !runtime.bool(inner, "dragging"))
        runtime.send(.touchMoved(Point2(x: 205, y: 60)))
        runtime.tick(dt: frame)
        #expect(runtime.bool(outer, "dragging") && !runtime.bool(inner, "dragging"))
        runtime.send(.touchMoved(Point2(x: 195, y: 20)))
        runtime.tick(dt: frame)
        runtime.send(.touchUp(Point2(x: 195, y: 20)))
        runtime.advance(seconds: 3)
        #expect(runtime.number(outer, "offset") < -40)
        #expect(runtime.number(inner, "offset") == sideways)
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func anInnerScrollViewAtItsEndHandsTheDragOut() {
        let (document, outer, inner) = page(innerAxis: "Vertical")
        let runtime = Runtime(document: document)
        runtime.tick(dt: frame)
        // Up, slowly, until the inner list is at its end.
        drag(runtime, from: Point2(x: 200, y: 190), to: Point2(x: 200, y: 10), frames: 20)
        drag(runtime, from: Point2(x: 200, y: 190), to: Point2(x: 200, y: 10), frames: 20)
        drag(runtime, from: Point2(x: 200, y: 190), to: Point2(x: 200, y: 10), frames: 20)
        runtime.advance(seconds: 3)
        #expect(runtime.number(inner, "offset") == -400)
        #expect(runtime.number(outer, "offset") == 0)
        // Up again: the page moves now.
        drag(runtime, from: Point2(x: 200, y: 190), to: Point2(x: 200, y: 150), frames: 30)
        runtime.advance(seconds: 3)
        #expect(runtime.number(inner, "offset") == -400)
        #expect(runtime.number(outer, "offset") < -20)
        // Down, on the list: it is not at that end, so it moves.
        let bottom = 200 + runtime.number(outer, "offset")
        #expect(bottom > 30)
        drag(runtime, from: Point2(x: 200, y: bottom - 20), to: Point2(x: 200, y: bottom + 20), frames: 20)
        runtime.advance(seconds: 3)
        #expect(runtime.number(inner, "offset") > -400)
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func aFingerOnAFlungPageStopsItAndIsNotATap() {
        let (document, outer, inner) = page(innerAxis: "Horizontal")
        var tappable = document
        // An Interaction on the row's first box, to see whether a tap reaches it.
        let box = tappable.screen.children[0].children[0].children[0].id
        let touch = tappable.graph.add(PatchNode(kind: PatchKind.interaction, layerID: box))
        let runtime = Runtime(document: tappable)
        runtime.tick(dt: frame)
        // Flick the page up, fast.
        drag(runtime, from: Point2(x: 200, y: 400), to: Point2(x: 200, y: 340), frames: 3)
        runtime.tick(dt: frame)
        #expect(runtime.needsAnotherFrame)
        // A finger down on the row, where its box has come to be, holding still.
        let row = Double(runtime.resolved.transform(toRootFrom: box)!.ty)
        #expect(row + 180 > 20)
        let at = Point2(x: 100, y: row + 180)
        runtime.send(.touchDown(at))
        runtime.tick(dt: frame)
        #expect(runtime.bool(outer, "dragging"))
        let held = runtime.number(outer, "offset")
        runtime.advance(seconds: 0.2)
        #expect(abs(runtime.number(outer, "offset") - held) < 1)
        runtime.send(.touchUp(at))
        runtime.tick(dt: frame)
        #expect(runtime.outputValue(PortRef(node: touch, port: "tap")) != .pulse(true))
        #expect(runtime.number(inner, "offset") == 0)
    }

    @Test func aFingerThatCatchesAScrollDoesNotLongPress() {
        let (document, outer, _) = page(innerAxis: "Horizontal")
        var held = document
        let filler = held.screen.children[0].children[1].id
        let touch = held.graph.add(PatchNode(kind: PatchKind.interaction, layerID: filler))
        let runtime = Runtime(document: held)
        runtime.tick(dt: frame)
        drag(runtime, from: Point2(x: 200, y: 700), to: Point2(x: 200, y: 600), frames: 3)
        runtime.tick(dt: frame)
        runtime.send(.touchDown(Point2(x: 200, y: 600)))
        var longPressed = false
        for _ in 0..<60 {
            runtime.tick(dt: frame)
            if runtime.outputValue(PortRef(node: touch, port: "longPress")) == .pulse(true) { longPressed = true }
        }
        #expect(runtime.bool(outer, "dragging"))
        #expect(!longPressed)
    }

    @Test func alongOneAxisTheInnermostScrollViewFollowsOnceTheFingerLeavesTheSlop() {
        let (document, outer, inner) = page(innerAxis: "Vertical")
        let runtime = Runtime(document: document)
        runtime.tick(dt: frame)
        runtime.send(.touchDown(Point2(x: 200, y: 100)))
        runtime.tick(dt: frame)
        // Not yet: this could still be a tap.
        runtime.send(.touchMoved(Point2(x: 200, y: 96)))
        runtime.tick(dt: frame)
        #expect(!runtime.bool(inner, "dragging"))
        #expect(runtime.number(inner, "offset") == 0)
        runtime.send(.touchMoved(Point2(x: 200, y: 84)))
        runtime.tick(dt: frame)
        #expect(runtime.bool(inner, "dragging"))
        #expect(runtime.number(inner, "offset") < 0)
        #expect(runtime.number(outer, "offset") == 0)
    }
}
