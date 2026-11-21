import Foundation
import Testing
import PaperModel
@testable import PaperEngine

/// Stacks, grids and scroll views (spec 7.1): the containers a UI engineer already knows.
@Suite struct ContainerTests {
    func box(_ width: Double, _ height: Double, _ extra: [LayerProperty: Value] = [:]) -> Layer {
        Layer(kind: .view, properties: [.size: .size(Size2(width: width, height: height))].merging(extra) { _, new in new })
    }

    /// A 300×100 horizontal stack of three 40×20 boxes.
    func row(_ settings: [LayerProperty: Value]) -> ResolvedLayer {
        var stack = Layer.new(.stack)
        stack.set(.axis, .text("Horizontal"))
        stack.set(.size, .size(Size2(width: 300, height: 100)))
        for (property, value) in settings { stack.set(property, value) }
        stack.children = [box(40, 20), box(40, 20), box(40, 20)]
        return ResolvedLayer(Layer(kind: .screen, children: [stack])).laidOut().children[0]
    }

    @Test func aStackIsAViewWithAnAxisAndAGridOneWithColumns() {
        #expect(Layer.new(.stack).type == .stack)
        #expect(Layer.new(.grid).type == .grid)
        #expect(Layer.new(.scrollView).type == .scrollView)
        #expect(Layer.new(.view).type == .view)
        #expect(Layer.new(.stack).kind == .view)
        // Each shows its own settings and not the others'.
        #expect(Layer.new(.stack).applicable.contains(.distribution))
        #expect(!Layer.new(.stack).applicable.contains(.columns))
        #expect(Layer.new(.grid).applicable.contains(.columns))
        #expect(!Layer.new(.view).applicable.contains(.spacing))
        #expect(Layer.new(.scrollView).applicable.contains(.pageSize))
        // Position and size are four numbers.
        #expect(Layer.new(.view).inputs.prefix(4).map(\.id) == ["x", "y", "width", "height"])
    }

    @Test func distributionHandsOutTheSpaceTheChildrenLeave() {
        func xs(_ distribution: String) -> [Double] {
            row([.distribution: .text(distribution), .spacing: .number(10), .paddingHorizontal: .number(20)]).children.map(\.position.x)
        }
        // 300 wide, 20 padding each side, three 40s and two gaps of 10: 120 left over.
        #expect(xs("Start") == [20, 70, 120])
        #expect(xs("Center") == [80, 130, 180])
        #expect(xs("End") == [140, 190, 240])
        #expect(xs("Space Between") == [20, 130, 240])
    }

    @Test func aChildThatGrowsTakesTheSpaceBeforeDistributionDoes() {
        var stack = Layer.new(.stack)
        stack.set(.axis, .text("Horizontal"))
        stack.set(.size, .size(Size2(width: 300, height: 100)))
        stack.set(.distribution, .text("End"))
        stack.children = [box(40, 20), box(40, 20, [.widthMode: .text("Grow")]), box(40, 20)]
        let laid = ResolvedLayer(Layer(kind: .screen, children: [stack])).laidOut().children[0]
        #expect(laid.children.map(\.position.x) == [0, 40, 260])
        #expect(laid.children[1].size.width == 220)
    }

    @Test func paddingIsSetForEachDirection() {
        let laid = row([.paddingHorizontal: .number(30), .paddingVertical: .number(8), .alignment: .text("End")])
        #expect(laid.children[0].position == Point2(x: 30, y: 100 - 8 - 20))

        // A stack that fits its content adds both paddings.
        var stack = Layer.new(.stack)
        stack.set(.paddingHorizontal, .number(30))
        stack.set(.paddingVertical, .number(8))
        stack.set(.widthMode, .text("Auto"))
        stack.set(.heightMode, .text("Auto"))
        stack.children = [box(40, 20), box(60, 20)]
        let fitted = ResolvedLayer(Layer(kind: .screen, children: [stack])).laidOut().children[0]
        #expect(fitted.size == Size2(width: 60 + 60, height: 40 + 16))

        var grid = Layer.new(.grid)
        grid.set(.size, .size(Size2(width: 220, height: 10)))
        grid.set(.paddingHorizontal, .number(10))
        grid.set(.paddingVertical, .number(4))
        grid.set(.heightMode, .text("Auto"))
        grid.children = (0..<4).map { _ in box(100, 30, [.widthMode: .text("Grow")]) }
        let cells = ResolvedLayer(Layer(kind: .screen, children: [grid])).laidOut().children[0]
        #expect(cells.children.map(\.position) == [
            Point2(x: 10, y: 4), Point2(x: 110, y: 4), Point2(x: 10, y: 34), Point2(x: 110, y: 34),
        ])
        #expect(cells.size.height == 68)
    }

    // MARK: Scroll view

    /// A scroll view 200 tall holding five 100-tall rows, and its patch.
    func scrolling(axis: String = "Vertical", page: Double = 0) -> (Runtime, list: LayerID, patch: NodeID, rows: [LayerID]) {
        var list = Layer.new(.scrollView, name: "List")
        list.set(.axis, .text(axis))
        list.set(.size, .size(Size2(width: 200, height: 200)))
        list.set(.pageSize, .number(page))
        list.children = (0..<5).map { _ in box(100, 100) }
        let document = Document(screen: Layer(kind: .screen, children: [list]))
        let runtime = Runtime(document: document)
        runtime.tick(dt: 1 / 60)
        return (runtime, list.id, document.graph.viewNode(layer: list.id)!.id, list.children.map(\.id))
    }

    func drag(_ runtime: Runtime, from: Point2, to: Point2) {
        runtime.send(.touchDown(from))
        runtime.tick(dt: 1 / 60)
        for step in 1...6 {
            let t = Double(step) / 6
            runtime.send(.touchMoved(Point2(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)))
            runtime.tick(dt: 1 / 60)
        }
        runtime.send(.touchUp(to))
        runtime.tick(dt: 1 / 60)
    }

    @Test func aScrollViewMovesItsContentAndReportsTheOffset() {
        let (runtime, list, patch, rows) = scrolling()
        func offset() -> Double { runtime.outputValue(PortRef(node: patch, port: "offset"))!.numberValue }
        #expect(runtime.resolved.find(list)?.contentLength == 500)
        #expect(offset() == 0)

        runtime.send(.touchDown(Point2(x: 50, y: 150)))
        runtime.tick(dt: 1 / 60)
        runtime.send(.touchMoved(Point2(x: 50, y: 90)))
        runtime.tick(dt: 1 / 60)
        // It follows from where the finger left the slop, ten points on: nothing jumps.
        #expect(offset() == -50)
        #expect(runtime.outputValue(PortRef(node: patch, port: "dragging")) == .bool(true))
        // The rows moved; the scroll view did not.
        #expect(runtime.resolved.find(rows[0])?.position.y == -50)
        #expect(runtime.resolved.find(rows[1])?.position.y == 50)
        #expect(runtime.resolved.find(list)?.position == .zero)
        runtime.send(.touchUp(Point2(x: 50, y: 90)))

        // However hard it is flung it stops where the content ends: 200 − 500.
        for _ in 0..<5 { drag(runtime, from: Point2(x: 50, y: 190), to: Point2(x: 50, y: 10)) }
        runtime.advance(seconds: 6)
        #expect(abs(offset() + 300) < 1e-6)
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func contentThatFitsDoesNotScroll() {
        var list = Layer.new(.scrollView)
        list.set(.size, .size(Size2(width: 200, height: 400)))
        list.children = [box(100, 100)]
        let document = Document(screen: Layer(kind: .screen, children: [list]))
        let runtime = Runtime(document: document)
        runtime.tick(dt: 1 / 60)
        drag(runtime, from: Point2(x: 50, y: 300), to: Point2(x: 50, y: 100))
        runtime.advance(seconds: 3)
        let patch = document.graph.viewNode(layer: list.id)!.id
        #expect(runtime.outputValue(PortRef(node: patch, port: "offset")) == .number(0))
    }

    @Test func aHorizontalScrollViewWithAPageSizeStopsOnPages() {
        let (runtime, _, patch, rows) = scrolling(axis: "Horizontal", page: 100)
        func offset() -> Double { runtime.outputValue(PortRef(node: patch, port: "offset"))!.numberValue }
        drag(runtime, from: Point2(x: 180, y: 50), to: Point2(x: 110, y: 50))
        runtime.advance(seconds: 3)
        // The flick carries it on, and it comes to rest on a whole page.
        #expect(offset() < 0 && offset() >= -300)
        #expect(offset().truncatingRemainder(dividingBy: 100) == 0)
        #expect(runtime.resolved.find(rows[0])?.position.x == offset())
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func aPlainStacksPatchHasNoScrolling() {
        var stack = Layer.new(.stack)
        stack.set(.size, .size(Size2(width: 200, height: 200)))
        stack.children = (0..<5).map { _ in box(100, 100) }
        let document = Document(screen: Layer(kind: .screen, children: [stack]))
        let runtime = Runtime(document: document)
        runtime.tick(dt: 1 / 60)
        drag(runtime, from: Point2(x: 50, y: 190), to: Point2(x: 50, y: 10))
        #expect(runtime.resolved.find(stack.children[0].id)?.position.y == 0)
    }
}
