import Foundation
import Testing
import PaperModel
@testable import PaperEngine

/// Every view's patch has outputs for where layout put it: x, y, width and height. They
/// are read from the last layout, as the View Size patch always was.
@Suite struct FrameOutputTests {
    typealias Builder = SampleDocuments.Builder

    func box(_ name: String, _ width: Double, _ height: Double, _ extra: [LayerProperty: Value] = [:]) -> Layer {
        var properties: [LayerProperty: Value] = [.size: .size(Size2(width: width, height: height))]
        properties.merge(extra) { _, new in new }
        return Layer(name: name, kind: .view, properties: properties)
    }

    /// A 300-wide horizontal stack at (10, 30) with 20 padding, 10 spacing, and boxes of
    /// 40, a growing one, and 40.
    func stackScene() -> (Builder, stack: Layer, LayerID) {
        var stack = Layer.new(.stack, name: "Row")
        stack.set(.axis, .text("Horizontal"))
        stack.set(.position, .point(Point2(x: 10, y: 30)))
        stack.set(.size, .size(Size2(width: 300, height: 100)))
        stack.set(.spacing, .number(10))
        stack.set(.paddingHorizontal, .number(20))
        let grower = box("Grower", 40, 20, [.widthMode: .text("Grow")])
        stack.children = [box("A", 40, 20), grower, box("C", 40, 20)]
        return (Builder(screen: Layer(kind: .screen, children: [stack])), stack, grower.id)
    }

    /// A patch that passes a number through, to cable a frame output into.
    func probe(_ b: inout Builder) -> NodeID { b.add("add", at: .zero, inputs: ["b": .number(0)]) }

    func value(_ runtime: Runtime, _ node: NodeID) -> Double? {
        runtime.outputValue(PortRef(node: node, port: "result"))?.numberValue
    }

    @Test func everyViewPatchHasFrameOutputsAfterTheScrollOnes() {
        let ports = PatchRegistry.standard.ports(for: .view(of: LayerID()))
        #expect(ports.outputs.map(\.id) == ["offset", "velocity", "dragging", "frameX", "frameY", "frameWidth", "frameHeight"])
        #expect(ports.outputs.suffix(4).map(\.name) == ["X", "Y", "Width", "Height"])
        #expect(ports.outputs.suffix(4).allSatisfy { $0.type == .number })
    }

    @Test func aStacksChildReportsWhereItWasPlaced() {
        var (b, _, grower) = stackScene()
        let view = b.view(grower)
        let x = probe(&b), y = probe(&b), width = probe(&b), height = probe(&b)
        b.connect(view, "frameX", to: x, "a")
        b.connect(view, "frameY", to: y, "a")
        b.connect(view, "frameWidth", to: width, "a")
        b.connect(view, "frameHeight", to: height, "a")
        let runtime = Runtime(document: b.document)
        runtime.advance(seconds: 0.1)
        // 300 wide less 40 padding, two 40s and two gaps of 10: the grower gets 160, after
        // the first box and a gap.
        #expect(value(runtime, x) == 70)
        #expect(value(runtime, width) == 160)
        // Stacks align their children at the start across the axis.
        #expect(value(runtime, y) == 0)
        #expect(value(runtime, height) == 20)
        #expect(runtime.outputValue(PortRef(node: view, port: "frameWidth")) == .number(160))
    }

    @Test func framesAreReadFromTheLastLayoutAndThenThePrototypeIdles() {
        var (b, _, grower) = stackScene()
        let view = b.view(grower)
        let width = probe(&b)
        b.connect(view, "frameWidth", to: width, "a")
        let runtime = Runtime(document: b.document)
        runtime.tick(dt: 1 / 60)
        runtime.tick(dt: 1 / 60)
        #expect(value(runtime, width) == 160)
        // Nothing changes after that, so nothing asks for a frame.
        runtime.tick(dt: 1 / 60)
        #expect(!runtime.tick(dt: 1 / 60))
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func aViewNobodyReadsCostsNothing() {
        var (b, _, grower) = stackScene()
        let view = b.view(grower)
        let runtime = Runtime(document: b.document)
        runtime.tick(dt: 1 / 60)
        #expect(!runtime.tick(dt: 1 / 60))
        // Not cabled or shown, so the outputs are left at zero.
        #expect(runtime.outputValue(PortRef(node: view, port: "frameWidth")) == .number(0))
    }

    @Test func aShownOutputHasItsValueWithoutACable() {
        var (b, _, grower) = stackScene()
        let view = b.view(grower)
        b.document.graph.update(view) { $0.shownPorts = ["frameWidth"] }
        let runtime = Runtime(document: b.document)
        runtime.advance(seconds: 0.1)
        #expect(runtime.outputValue(PortRef(node: view, port: "frameWidth")) == .number(160))
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func aViewCanFollowAnotherAndItselfWithoutRunningForever() {
        // B sits just right of A; A's x follows its own width.
        let a = box("A", 80, 40)
        let follower = box("B", 20, 20)
        var b = Builder(screen: Layer(kind: .screen, children: [a, follower]))
        let viewA = b.view(a.id)
        let viewB = b.view(follower.id)
        let right = b.add("add", at: .zero)
        b.connect(viewA, "frameX", to: right, "a")
        b.connect(viewA, "frameWidth", to: right, "b")
        b.connect(right, "result", to: viewB, "x")
        b.connect(viewA, "frameWidth", to: viewA, "x")
        let runtime = Runtime(document: b.document)
        runtime.advance(seconds: 0.2)
        #expect(runtime.resolved.find(a.id)?.position.x == 80)
        #expect(runtime.resolved.find(follower.id)?.position.x == 160)
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func aFrameThatAnimatesIsFollowedAFrameBehindUntilItSettles() {
        let a = box("A", 80, 40)
        let follower = box("B", 20, 20)
        var b = Builder(screen: Layer(kind: .screen, children: [a, follower]))
        let viewA = b.view(a.id)
        let viewB = b.view(follower.id)
        let spring = b.add("spring", at: .zero, inputs: ["target": .number(100)])
        b.connect(spring, "value", to: viewA, "width")
        b.connect(viewA, "frameWidth", to: viewB, "x")
        let runtime = Runtime(document: b.document)
        runtime.advance(seconds: 2)
        #expect(!runtime.needsAnotherFrame)

        var moved = b.document
        moved.graph.update(spring) { $0.inputs["target"] = .number(200) }
        runtime.update(document: moved)
        var widths: [Double] = []
        var followed: [Double] = []
        for _ in 0..<6 {
            runtime.tick(dt: 1 / 60)
            widths.append(runtime.resolved.find(a.id)?.size.width ?? 0)
            followed.append(runtime.resolved.find(follower.id)?.position.x ?? 0)
        }
        #expect(widths.last! > 100 && widths.last! < 200)
        // B's x on each frame is A's width on the frame before.
        #expect(Array(followed.dropFirst()) == Array(widths.dropLast()))
        runtime.advance(seconds: 5)
        #expect(abs((runtime.resolved.find(follower.id)?.position.x ?? 0) - 200) < 0.5)
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func aRepeatedViewGivesOneFramePerCopy() {
        var stack = Layer.new(.stack, name: "Column")
        stack.set(.size, .size(Size2(width: 100, height: 400)))
        stack.set(.spacing, .number(5))
        let row = box("Row", 100, 30)
        stack.children = [row]
        var b = Builder(screen: Layer(kind: .screen, children: [stack]))
        let view = b.view(row.id)
        let loop = b.add("loop", at: .zero, inputs: ["count": .number(3)])
        let height = b.add("add", at: .zero, inputs: ["a": .number(30)])
        b.connect(loop, "index", to: height, "b")
        b.connect(height, "result", to: view, "height")
        let probe = probe(&b)
        b.connect(view, "frameY", to: probe, "a")
        let runtime = Runtime(document: b.document)
        runtime.advance(seconds: 0.1)
        // Heights 30, 31, 32 with 5 between.
        #expect(runtime.outputValues(PortRef(node: view, port: "frameY")).map(\.numberValue) == [0, 35, 71])
        #expect(runtime.outputValues(PortRef(node: view, port: "frameHeight")).map(\.numberValue) == [30, 31, 32])
        #expect(runtime.outputValues(PortRef(node: probe, port: "result")).count == 3)
    }

    @Test func aHiddenCopyKeepsTheRowsAfterItWithTheirOwnCopies() {
        var stack = Layer.new(.stack, name: "Column")
        stack.set(.size, .size(Size2(width: 100, height: 400)))
        let row = box("Row", 100, 30)
        stack.children = [row]
        var b = Builder(screen: Layer(kind: .screen, children: [stack]))
        let view = b.view(row.id)
        let loop = b.add("loop", at: .zero, inputs: ["count": .number(3)])
        // Copy 1 is hidden: index ≠ 1.
        let shown = b.add("notEqual", at: .zero, inputs: ["b": .number(1)])
        b.connect(loop, "index", to: shown, "a")
        b.connect(shown, "result", to: view, LayerProperty.visible.rawValue)
        let probe = probe(&b)
        b.connect(view, "frameHeight", to: probe, "a")
        let runtime = Runtime(document: b.document)
        runtime.advance(seconds: 0.1)
        #expect(runtime.outputValues(PortRef(node: view, port: "frameHeight")).map(\.numberValue) == [30, 0, 30])
        #expect(runtime.outputValues(PortRef(node: view, port: "frameY")).map(\.numberValue) == [0, 0, 30])
    }

    @Test func aScrollViewReportsItsScrollAndItsFrame() {
        var scroller = Layer.new(.scrollView, name: "List")
        scroller.set(.position, .point(Point2(x: 0, y: 50)))
        scroller.set(.size, .size(Size2(width: 200, height: 300)))
        scroller.children = [box("Tall", 200, 900)]
        var b = Builder(screen: Layer(kind: .screen, children: [scroller]))
        let view = b.view(scroller.id)
        let probe = probe(&b)
        b.connect(view, "frameY", to: probe, "a")
        let runtime = Runtime(document: b.document)
        runtime.advance(seconds: 0.1)
        #expect(value(runtime, probe) == 50)
        #expect(runtime.outputValue(PortRef(node: view, port: "offset")) == .number(0))
        #expect(runtime.outputValue(PortRef(node: view, port: "dragging")) == .bool(false))
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func theViewSizePatchStillReportsTheLaidOutSize() {
        var (b, _, grower) = stackScene()
        let size = b.add("layerSize", at: .zero)
        b.document.graph.update(size) { $0.layerID = grower }
        let probe = probe(&b)
        b.connect(size, "width", to: probe, "a")
        let runtime = Runtime(document: b.document)
        runtime.advance(seconds: 0.1)
        #expect(runtime.outputValue(PortRef(node: size, port: "size")) == .size(Size2(width: 160, height: 20)))
        #expect(value(runtime, probe) == 160)
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func aCableFromAFrameOutputSurvivesSettling() {
        var (b, _, grower) = stackScene()
        let view = b.view(grower)
        let probe = probe(&b)
        b.connect(view, "frameWidth", to: probe, "a")
        var document = b.document
        PatchRegistry.standard.settlePublished(in: &document)
        #expect(document.graph.connection(into: PortRef(node: probe, port: "a"))?.from == PortRef(node: view, port: "frameWidth"))
    }
}
