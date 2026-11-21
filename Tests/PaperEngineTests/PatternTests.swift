import Foundation
import Testing
import PaperModel
@testable import PaperEngine

/// The gallery's prototypes (spec 7.11) do what their cards say.
@Suite struct PatternTests {
    let frame = 1.0 / 60.0

    func drag(_ runtime: Runtime, from: Point2, to: Point2, frames: Int = 6) {
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

    @Test func everyGalleryItemIsAWorkingDocument() throws {
        #expect(Set(Gallery.items.map(\.id)).count == Gallery.items.count)
        #expect(Set(Gallery.items.map(\.fileName)).count == Gallery.items.count)
        for section in GalleryItem.Section.allCases { #expect(Gallery.items.contains { $0.section == section }) }
        for item in Gallery.items {
            let document = item.make()
            // Every cable joins two ports that exist and whose types fit.
            let registry = PatchRegistry.standard.with(components: document.components)
            for connection in document.graph.connections {
                let from = try #require(document.graph.node(connection.from.node), "\(item.id)")
                let to = try #require(document.graph.node(connection.to.node), "\(item.id)")
                let output = try #require(registry.ports(for: from).outputs.first { $0.id == connection.from.port }, "\(item.id) \(connection.from.port)")
                let input = try #require(registry.ports(for: to).inputs.first { $0.id == connection.to.port }, "\(item.id) \(connection.to.port)")
                #expect(Value.canConnect(from: output.type, to: input.type), "\(item.id): \(output.id) to \(input.id)")
            }
            // It survives a round trip to a file and runs.
            let copy = try Document.decode(from: try document.encoded())
            #expect(copy == document)
            let runtime = Runtime(document: document)
            runtime.advance(seconds: 0.2)
        }
        #expect(Gallery.item("card") != nil && Gallery.item("nope") == nil)
    }

    @Test func typingANameGreetsItAndWakesTheButton() {
        let example = SampleDocuments.signIn()
        let runtime = Runtime(document: example.document)
        runtime.advance(seconds: 0.5)
        func greeting() -> String { runtime.resolved.find(example.greeting)!.value(.text).textValue }
        func opacity() -> Double { runtime.resolved.find(example.button)!.opacity }
        #expect(greeting() == "Hello, ")
        #expect(abs(opacity() - 0.35) < 0.01)

        runtime.send(.touchDown(Point2(x: 100, y: 210)))
        runtime.tick(dt: frame)
        runtime.send(.touchUp(Point2(x: 100, y: 210)))
        runtime.tick(dt: frame)
        runtime.send(.text("Ada"))
        runtime.advance(seconds: 1.5)
        #expect(greeting() == "Hello, Ada")
        #expect(abs(opacity() - 1) < 0.01)
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func typingNarrowsTheListAndClearingBringsItBack() {
        let example = SampleDocuments.searchList()
        let runtime = Runtime(document: example.document)
        runtime.advance(seconds: 0.1)
        func rows() -> [String] {
            var names: [String] = []
            func walk(_ layer: ResolvedLayer) {
                if layer.id == example.row { names.append(layer.children.first?.value(.text).textValue ?? "") }
                layer.children.forEach(walk)
            }
            walk(runtime.resolved)
            return names
        }
        #expect(rows() == SampleDocuments.SearchList.names)
        runtime.send(.touchDown(Point2(x: 100, y: 144)))
        runtime.tick(dt: frame)
        runtime.send(.touchUp(Point2(x: 100, y: 144)))
        runtime.tick(dt: frame)
        runtime.send(.text("al"))
        runtime.advance(seconds: 0.1)
        #expect(rows() == ["Alan Turing", "Linus Torvalds"])
        runtime.send(.text("zz"))
        runtime.advance(seconds: 0.1)
        #expect(rows().isEmpty)
        for _ in 0..<4 { runtime.send(.deleteBackward) }
        runtime.advance(seconds: 0.1)
        #expect(rows().count == SampleDocuments.SearchList.names.count)
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func aSwipeRevealsTheActionAndAnotherHidesIt() {
        let example = SampleDocuments.swipeMenu()
        let runtime = Runtime(document: example.document)
        runtime.tick(dt: frame)
        func x() -> Double { runtime.resolved.find(example.row)!.position.x }
        #expect(x() == SampleDocuments.SwipeMenu.restX)
        drag(runtime, from: Point2(x: 300, y: 180), to: Point2(x: 120, y: 180))
        runtime.advance(seconds: 1.5)
        #expect(abs(x() - SampleDocuments.SwipeMenu.openX) < 0.5)
        // The row is still under the finger where it now sits.
        drag(runtime, from: Point2(x: 60, y: 180), to: Point2(x: 240, y: 180))
        runtime.advance(seconds: 1.5)
        #expect(abs(x() - SampleDocuments.SwipeMenu.restX) < 0.5)
    }

    @Test func twoFingersMoveZoomAndTurnThePictureAtOnceAndLettingGoSpringsItBack() {
        let example = SampleDocuments.pinchZoom()
        let runtime = Runtime(document: example.document)
        runtime.advance(seconds: 0.2)
        func photo() -> ResolvedLayer { runtime.resolved.find(example.photo)! }
        #expect(abs(photo().scale - 1) < 0.001)

        // Two fingers on the picture, 100 points apart.
        let frame = 1.0 / 60.0
        runtime.send(.touchBegan(id: 0, Point2(x: 145, y: 400)))
        runtime.send(.touchBegan(id: 1, Point2(x: 245, y: 400)))
        runtime.tick(dt: frame)
        // Over half a second they spread to twice as far apart, turn 30 degrees and
        // travel 60 points right and 40 down.
        var seen: [Double] = []
        for step in 1...30 {
            let t = Double(step) / 30
            let middle = Point2(x: 195 + 60 * t, y: 400 + 40 * t)
            let reach = 50 * (1 + t), angle = 30 * t * .pi / 180
            let arm = Point2(x: cos(angle) * reach, y: sin(angle) * reach)
            runtime.send(.touchChanged(id: 0, middle - arm))
            runtime.send(.touchChanged(id: 1, middle + arm))
            runtime.tick(dt: frame)
            seen.append(photo().scale)
        }
        // All three at once, each counted from where it began: a slop short of what the
        // fingers did (and the frame it began in, which the springs took hold in).
        #expect(runtime.bool(example.pan, "panning") && runtime.bool(example.pinch, "pinching") && runtime.bool(example.rotation, "rotating"))
        #expect(abs(runtime.number(example.pinch, "scale") - 200.0 / 108) < 0.001)
        #expect(abs(runtime.number(example.rotation, "rotation") - 25) < 0.001)
        #expect(abs(photo().scale - 200.0 / 108) < 0.05)
        #expect(abs(photo().rotation - 25) < 1.5)
        #expect(abs(photo().position.x - (40 + 60 - 10 * 60 / Point2(x: 60, y: 40).length)) < 3)
        #expect(abs(photo().position.y - (250 + 40 - 10 * 40 / Point2(x: 60, y: 40).length)) < 3)
        // Nothing jumped on the way: the picture grew a little at a time.
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $1 >= $0 && $1 - $0 < 0.06 })

        runtime.send(.touchEnded(id: 0, Point2(x: 168, y: 415)))
        runtime.send(.touchEnded(id: 1, Point2(x: 342, y: 465)))
        runtime.advance(seconds: 2)
        #expect(abs(photo().scale - 1) < 0.01)
        #expect(abs(photo().rotation) < 0.3)
        #expect(abs(photo().position.x - 40) < 0.5)
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func oneFingerDragsThePictureAndDoesNotZoomIt() {
        let example = SampleDocuments.pinchZoom()
        let runtime = Runtime(document: example.document)
        runtime.advance(seconds: 0.2)
        func photo() -> ResolvedLayer { runtime.resolved.find(example.photo)! }
        runtime.send(.touchDown(Point2(x: 195, y: 400)))
        runtime.tick(dt: 1.0 / 60)
        for step in 1...30 {
            runtime.send(.touchMoved(Point2(x: 195 + 2 * Double(step), y: 400)))
            runtime.tick(dt: 1.0 / 60)
        }
        // 60 points, less the ten that told a drag from a tap: it follows the finger.
        #expect(abs(photo().position.x - 90) < 2.5)
        #expect(photo().scale == 1)
        #expect(runtime.bool(example.pan, "panning"))
        #expect(!runtime.bool(example.pinch, "pinching"))
        runtime.send(.touchUp(Point2(x: 255, y: 400)))
        runtime.advance(seconds: 2)
        #expect(abs(photo().position.x - 40) < 0.5)
    }

    /// A trackpad's pinch has no fingers: the Mac recognized it, and it drives the same patches.
    @Test func aTrackpadPinchZoomsAndTurnsThePictureToo() {
        let example = SampleDocuments.pinchZoom()
        let runtime = Runtime(document: example.document)
        runtime.advance(seconds: 0.2)
        func photo() -> ResolvedLayer { runtime.resolved.find(example.photo)! }
        runtime.send(.pinchBegan(Point2(x: 195, y: 400)))
        runtime.tick(dt: 1.0 / 60)
        runtime.send(.pinchChanged(scale: 1.6, rotation: 30))
        runtime.advance(seconds: 0.5)
        #expect(abs(photo().scale - 1.6) < 0.01)
        #expect(abs(photo().rotation - 30) < 0.3)
        runtime.send(.pinchEnded)
        runtime.advance(seconds: 2)
        #expect(abs(photo().scale - 1) < 0.01)
        #expect(abs(photo().rotation) < 0.3)
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func aRestingPointerLiftsTheButton() {
        let example = SampleDocuments.hoverButton()
        let runtime = Runtime(document: example.document)
        runtime.tick(dt: frame)
        func scale() -> Double { runtime.resolved.find(example.button)!.scale }
        runtime.send(.hover(Point2(x: 195, y: 410)))
        runtime.advance(seconds: 1.5)
        #expect(abs(scale() - 1.08) < 0.005)
        runtime.send(.hover(nil))
        runtime.advance(seconds: 1.5)
        #expect(abs(scale() - 1) < 0.005)
    }

    @Test func theHeaderShrinksAsTheListScrollsAndThenStays() {
        typealias Header = SampleDocuments.StickyHeader
        let example = SampleDocuments.stickyHeader()
        let runtime = Runtime(document: example.document)
        runtime.tick(dt: frame)
        func height() -> Double { runtime.resolved.find(example.header)!.size.height }
        // Where the rows begin on screen: the first one, less the list's padding.
        func listTop() -> Double { runtime.resolved.find(example.list)!.children[1].position.y - 16 }
        #expect(height() == Header.tall)
        #expect(listTop() == Header.tall)

        // Half way: the header has given up exactly what the list has moved.
        runtime.send(.touchDown(Point2(x: 195, y: 600)))
        runtime.tick(dt: frame)
        runtime.send(.touchMoved(Point2(x: 195, y: 548)))
        runtime.advance(seconds: 0.1)
        #expect(abs(height() - (Header.tall - 42)) < 0.5)
        #expect(abs(listTop() - height()) < 0.5)

        // Far past the collapse: the header stays a bar.
        runtime.send(.touchMoved(Point2(x: 195, y: 300)))
        runtime.advance(seconds: 0.1)
        #expect(height() == Header.short)
        #expect(runtime.resolved.find(example.title)!.value(.fontSize).numberValue == 20)
    }
}
