import Foundation
import Testing
import PaperModel
@testable import PaperEngine

/// A view is a patch (spec 6.5): its properties are the patch's inputs, and a cable into
/// one drives it.
@Suite struct ViewPatchTests {
    typealias Builder = SampleDocuments.Builder

    /// A screen with one 40×40 box at (10, 20), the box's view patch, and a builder.
    func scene() -> (Builder, LayerID, NodeID) {
        let box = Layer(name: "Box", kind: .view, properties: [
            .position: .point(Point2(x: 10, y: 20)), .size: .size(Size2(width: 40, height: 40)),
        ])
        var b = Builder(screen: Layer(kind: .screen, children: [box]))
        let view = b.document.graph.viewNode(layer: box.id)?.id
            ?? b.document.graph.add(.view(of: box.id))
        return (b, box.id, view)
    }

    func instances(_ runtime: Runtime, _ id: LayerID) -> [ResolvedLayer] {
        var found: [ResolvedLayer] = []
        func walk(_ layer: ResolvedLayer) {
            if layer.id == id { found.append(layer) }
            layer.children.forEach(walk)
        }
        walk(runtime.resolved)
        return found
    }

    func constant(_ b: inout Builder, _ value: Double) -> NodeID {
        b.add("add", at: .zero, inputs: ["a": .number(value)])
    }

    @Test func aCableIntoOneNumberLeavesTheOtherHalfAsStored() {
        var (b, box, view) = scene()
        let x = constant(&b, 200)
        b.connect(x, "result", to: view, "x")
        var runtime = Runtime(document: b.document)
        runtime.tick(dt: 1 / 60)
        #expect(runtime.resolved.find(box)?.position == Point2(x: 200, y: 20))

        var (c, box2, view2) = scene()
        let height = constant(&c, 90)
        c.connect(height, "result", to: view2, "height")
        runtime = Runtime(document: c.document)
        runtime.tick(dt: 1 / 60)
        #expect(runtime.resolved.find(box2)?.size == Size2(width: 40, height: 90))
        #expect(runtime.resolved.find(box2)?.position == Point2(x: 10, y: 20))
    }

    @Test func aPropertyInputIsDrivenLikeAnyOther() {
        var (b, box, view) = scene()
        let opacity = constant(&b, 0.25)
        b.connect(opacity, "result", to: view, "opacity")
        let runtime = Runtime(document: b.document)
        runtime.tick(dt: 1 / 60)
        #expect(runtime.resolved.find(box)?.opacity == 0.25)
        #expect(runtime.inputValue(PortRef(node: view, port: "opacity")) == .number(0.25))
        // An input with no cable reports nothing: the stored value is in charge.
        #expect(runtime.inputValue(PortRef(node: view, port: "scale")) == nil)
    }

    @Test func aLoopIntoXRepeatsTheViewAndYWinsOverPosition() {
        var (b, box, view) = scene()
        let loop = b.add("loop", at: .zero, inputs: ["count": .number(3)])
        let times = b.add("multiply", at: .zero, inputs: ["b": .number(50)])
        b.connect(loop, "index", to: times, "a")
        b.connect(times, "result", to: view, "x")
        let runtime = Runtime(document: b.document)
        runtime.tick(dt: 1 / 60)
        #expect(instances(runtime, box).map(\.position) == [0, 50, 100].map { Point2(x: $0, y: 20) })

        // A point into `position` and a number into `y`: the number wins its half.
        let point = b.add("makePoint", at: .zero, inputs: ["x": .number(7), "y": .number(7)])
        let y = constant(&b, 300)
        b.connect(point, "point", to: view, "position")
        b.connect(y, "result", to: view, "y")
        runtime.update(document: b.document)
        runtime.tick(dt: 1 / 60)
        #expect(instances(runtime, box).map(\.position) == [0, 50, 100].map { Point2(x: $0, y: 300) })

        // An empty loop on either half leaves no copies.
        var edited = b.document
        edited.graph.update(loop) { $0.inputs["count"] = .number(0) }
        runtime.update(document: edited)
        runtime.tick(dt: 1 / 60)
        #expect(instances(runtime, box).isEmpty)
    }

    @Test func aViewWithNoCablesCostsNoFrames() {
        let (b, box, _) = scene()
        let runtime = Runtime(document: b.document)
        runtime.tick(dt: 1 / 60)
        #expect(!runtime.needsAnotherFrame)
        #expect(runtime.resolved.find(box)?.position == Point2(x: 10, y: 20))
    }

    // MARK: Component instances

    /// A component whose root dims itself to 0.2 from inside and whose Offset input moves
    /// its dot, used once on a screen with the instance's own view patch.
    func componentScene() -> (Builder, instance: LayerID, patch: NodeID, dot: LayerID, offset: String) {
        let dot = Layer(name: "Dot", kind: .ellipse, properties: [.size: .size(Size2(width: 10, height: 10))])
        let root = Layer(name: "Root", kind: .view, properties: [.size: .size(Size2(width: 100, height: 40))], children: [dot])
        var graph = Graph()
        let input = graph.add(PatchNode(kind: PatchKind.componentInput, name: "Offset", valueType: .number))
        let dotView = graph.add(.view(of: dot.id))
        let rootView = graph.add(.view(of: root.id))
        let dim = graph.add(PatchNode(kind: "add", inputs: ["a": .number(0.2)]))
        graph.connect(from: PortRef(node: input, port: "value"), to: PortRef(node: dotView, port: "x"))
        graph.connect(from: PortRef(node: dim, port: "result"), to: PortRef(node: rootView, port: "opacity"))
        let definition = ComponentDefinition(name: "Meter", root: root, graph: graph)

        let instance = definition.instance(at: Point2(x: 5, y: 5))
        var b = Builder(screen: Layer(kind: .screen, children: [instance]))
        b.document.adopt(definition)
        let patch = b.document.graph.viewNode(layer: instance.id)?.id
            ?? b.document.graph.add(.view(of: instance.id, component: definition.id))
        b.document.graph.update(patch) { $0.componentID = definition.id }
        return (b, instance.id, patch, dot.id, input.uuidString)
    }

    @Test func anInstanceIsDrivenOnAViewInputAndAComponentInputAtOnce() {
        var (b, instance, patch, dot, offset) = componentScene()
        let sixty = constant(&b, 60)
        let far = constant(&b, 400)
        b.connect(sixty, "result", to: patch, offset)
        b.connect(far, "result", to: patch, "y")
        let runtime = Runtime(document: b.document)
        runtime.tick(dt: 1 / 60)
        #expect(runtime.resolved.find(instance)?.position == Point2(x: 5, y: 400))
        let inner = ComponentExpansion.derive(instance, dot)
        #expect(runtime.resolved.find(inner)?.position.x == 60)
    }

    @Test func theInstancesPatchWinsOverTheRootsPatchInside() {
        var (b, instance, patch, _, _) = componentScene()
        var runtime = Runtime(document: b.document)
        runtime.tick(dt: 1 / 60)
        #expect(runtime.resolved.find(instance)?.opacity == 0.2)

        let most = constant(&b, 0.7)
        b.connect(most, "result", to: patch, "opacity")
        runtime = Runtime(document: b.document)
        runtime.tick(dt: 1 / 60)
        #expect(runtime.resolved.find(instance)?.opacity == 0.7)
    }
}
