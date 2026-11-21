import Foundation
import Testing
import PaperModel
@testable import PaperEngine

@Suite struct LayoutTests {
    func box(_ name: String, _ width: Double, _ height: Double, _ extra: [LayerProperty: Value] = [:]) -> Layer {
        var properties = extra
        properties[.size] = .size(Size2(width: width, height: height))
        return Layer(name: name, kind: .view, properties: properties)
    }

    @Test func aRowPlacesChildrenWithSpacingAndPadding() {
        let a = box("A", 50, 20)
        let b = box("B", 30, 40)
        let row = Layer(kind: .view, properties: [
            .size: .size(Size2(width: 300, height: 100)),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .spacing: .number(10), .paddingHorizontal: .number(8), .paddingVertical: .number(8), .alignment: .text("Center"),
        ], children: [a, b])
        let tree = ResolvedLayer(row).laidOut()
        #expect(tree.find(a.id)?.frame == CGRect(x: 8, y: 40, width: 50, height: 20))
        #expect(tree.find(b.id)?.frame == CGRect(x: 68, y: 30, width: 30, height: 40))
    }

    @Test func growingChildrenShareTheSpaceThatIsLeft() {
        let fixed = box("Fixed", 60, 20)
        let one = box("One", 1, 20, [.widthMode: .text("Grow")])
        let two = box("Two", 1, 20, [.widthMode: .text("Grow"), .heightMode: .text("Grow")])
        let row = Layer(kind: .view, properties: [
            .size: .size(Size2(width: 300, height: 100)), .layout: .text("Stack"), .axis: .text("Horizontal"), .spacing: .number(20),
        ], children: [fixed, one, two])
        let tree = ResolvedLayer(row).laidOut()
        #expect(tree.find(one.id)?.size == Size2(width: 100, height: 20))
        #expect(tree.find(two.id)?.frame == CGRect(x: 200, y: 0, width: 100, height: 100))
    }

    @Test func anAutoContainerFitsItsContentAndAdaptsWhenContentChanges() {
        var label = Layer(kind: .text, properties: [
            .text: .text("Hi"), .widthMode: .text("Auto"), .heightMode: .text("Auto"),
        ])
        func button() -> ResolvedLayer {
            ResolvedLayer(Layer(kind: .view, properties: [
                .layout: .text("Stack"), .axis: .text("Horizontal"), .paddingHorizontal: .number(12), .paddingVertical: .number(12),
                .widthMode: .text("Auto"), .heightMode: .text("Auto"),
            ], children: [label])).laidOut()
        }
        let short = button().size
        label.set(.text, .text("A much longer label than before"))
        let long = button().size
        #expect(short.width > 24 && short.height > 24)
        #expect(long.width > short.width + 100)
        #expect(long.height == short.height)
    }

    @Test func textWrapsToAFixedWidthAndGrowsTaller() {
        let text = "one two three four five six seven eight nine ten eleven twelve"
        let wide = TextMeasurer.measure(text, fontSize: 17, weight: 400, maxWidth: nil)
        let narrow = TextMeasurer.measure(text, fontSize: 17, weight: 400, maxWidth: 120)
        #expect(narrow.width <= 120)
        #expect(narrow.height > wide.height * 2)
    }

    @Test func layersThatIgnoreLayoutKeepTheirPosition() {
        let badge = box("Badge", 10, 10, [.absolute: .bool(true), .position: .point(Point2(x: 77, y: 5))])
        let a = box("A", 50, 20)
        let column = Layer(kind: .view, properties: [.layout: .text("Stack")], children: [badge, a])
        let tree = ResolvedLayer(column).laidOut()
        #expect(tree.find(badge.id)?.position == Point2(x: 77, y: 5))
        #expect(tree.find(a.id)?.position == .zero)
    }

    @Test func theListExampleAdaptsToItemCountAndWidth() {
        let example = SampleDocuments.scrollingList()
        var document = example.document
        typealias List = SampleDocuments.ScrollingList
        var tree = ResolvedLayer(document.screen).laidOut()
        // The list is a scroll view as tall as the screen below the header; its content is longer.
        #expect(tree.find(example.list)?.size == Size2(width: 390, height: 844 - List.top))
        #expect(tree.find(example.list)?.contentLength == List.contentHeight)
        #expect(tree.find(example.rows[1])?.frame == CGRect(x: 16, y: 16 + 76 + 12, width: 358, height: 76))

        // Fewer rows and a narrower list: everything follows.
        document.screen.update(example.list) { list in
            list.children.removeLast(4)
            list.set(.size, .size(Size2(width: 300, height: 100)))
        }
        tree = ResolvedLayer(document.screen).laidOut()
        #expect(tree.find(example.list)?.contentLength == List.contentHeight - 4 * (76 + 12))
        #expect(tree.find(example.rows[0])?.size.width == 268)
    }
}

@Suite struct ScrollTests {
    func run() -> (Runtime, SampleDocuments.ScrollingList) {
        let example = SampleDocuments.scrollingList()
        let runtime = Runtime(document: example.document)
        runtime.tick(dt: frame)
        return (runtime, example)
    }

    func drag(_ runtime: Runtime, by distance: Double, frames: Int) {
        let start = Point2(x: 195, y: 500)
        runtime.send(.touchDown(start))
        runtime.tick(dt: frame)
        for step in 1...frames {
            runtime.send(.touchMoved(Point2(x: 195, y: 500 + distance * Double(step) / Double(frames))))
            runtime.tick(dt: frame)
        }
        runtime.send(.touchUp(Point2(x: 195, y: 500 + distance)))
    }

    @Test func contentFollowsTheFingerThenCoastsAndStops() {
        let (runtime, example) = run()
        // The scroll view stays where it is; its rows move inside it.
        func y() -> Double { runtime.resolved.find(example.rows[0])!.position.y }
        #expect(runtime.resolved.find(example.list)!.position.y == 110)
        #expect(y() == 16)
        drag(runtime, by: -120, frames: 10)
        // The first ten points told a scroll from a tap; the content follows from there.
        #expect(abs(runtime.number(example.scroll, "offset") + 110) < 1e-6)
        runtime.tick(dt: frame)
        let afterRelease = runtime.number(example.scroll, "offset")
        // It keeps going the way the finger was moving.
        #expect(afterRelease < -110)
        runtime.advance(seconds: 6)
        let rested = runtime.number(example.scroll, "offset")
        #expect(rested < afterRelease)
        #expect(runtime.needsAnotherFrame == false)
        #expect(y() == 16 + rested)
        #expect(runtime.resolved.find(example.list)!.position.y == 110)
    }

    @Test func pullingPastTheTopRubberBandsAndSpringsBack() {
        let (runtime, example) = run()
        drag(runtime, by: 200, frames: 12)
        let pulled = runtime.number(example.scroll, "offset")
        #expect(pulled > 20 && pulled < 200)
        runtime.advance(seconds: 3)
        #expect(runtime.number(example.scroll, "offset") == 0)
    }

    @Test func aFlingStopsAtTheEnd() {
        let (runtime, example) = run()
        let low = 844 - 110 - SampleDocuments.ScrollingList.contentHeight
        for _ in 0..<4 {
            drag(runtime, by: -400, frames: 5)
            runtime.advance(seconds: 0.3)
        }
        runtime.advance(seconds: 6)
        #expect(abs(runtime.number(example.scroll, "offset") - low) < 1e-6)
    }

    @Test func aTappableRowInsideTheScrollingListStillTaps() {
        var example = SampleDocuments.scrollingList().document
        let rowID = example.screen.flattened.first { $0.name == "Row 3" }!.id
        let touch = example.graph.add(.interaction(on: rowID))
        let picked = example.graph.add(PatchNode(kind: "switch"))
        example.graph.connect(from: PortRef(node: touch, port: "tap"), to: PortRef(node: picked, port: "flip"))
        let runtime = Runtime(document: example)
        runtime.tick(dt: frame)

        // Row 3 spans y 110+16+2*88 ... +76.
        let point = Point2(x: 195, y: 110 + 16 + 2 * 88 + 30)
        runtime.tap(at: point)
        runtime.advance(seconds: 0.2)
        #expect(runtime.bool(picked, "on"))

        // A drag that starts on the row scrolls the list and does not count as a tap.
        runtime.send(.touchDown(point))
        runtime.tick(dt: frame)
        runtime.send(.touchMoved(Point2(x: 195, y: point.y - 80)))
        runtime.tick(dt: frame)
        runtime.send(.touchUp(Point2(x: 195, y: point.y - 80)))
        runtime.advance(seconds: 0.2)
        #expect(runtime.bool(picked, "on"))
        #expect(runtime.resolved.find(example.screen.children[0].children[0].id)!.position.y < 16)
    }
}

@Suite struct VariableTests {
    @Test func aReceiveOutputsWhatTheMatchingBroadcastGets() {
        var rig = Rig()
        let source = rig.add("add", ["a": .number(4), "b": .number(5)])
        let send = rig.add("broadcast", type: .number, ["name": .text("Total")])
        let other = rig.add("broadcast", type: .number, ["name": .text("Other"), "value": .number(99)])
        // Receivers are added first to show order does not matter.
        let receive = rig.add("receive", type: .number, ["name": .text("Total")])
        let doubled = rig.add("multiply", ["b": .number(2)])
        rig.connect(source, "result", send, "value")
        rig.connect(receive, "value", doubled, "a")
        _ = other
        let runtime = Runtime(document: rig.document)
        runtime.tick(dt: frame)
        #expect(runtime.number(doubled, "result") == 18)
    }

    @Test func theListExampleCarriesItsOffsetThroughAVariable() {
        let example = SampleDocuments.scrollingList()
        let runtime = Runtime(document: example.document)
        runtime.tick(dt: frame)
        let header = example.document.screen.children[1].id
        #expect(runtime.resolved.find(header)?.opacity == 1)
        runtime.send(.touchDown(Point2(x: 195, y: 500)))
        runtime.tick(dt: frame)
        // Thirty points of scrolling, after the ten that began it.
        runtime.send(.touchMoved(Point2(x: 195, y: 460)))
        runtime.tick(dt: frame)
        runtime.tick(dt: frame)
        #expect(abs(runtime.resolved.find(header)!.opacity - 0.5) < 1e-6)
    }
}
