import Foundation
import Testing
import PaperModel
@testable import PaperEngine

@Suite struct LoopTests {
    typealias Builder = SampleDocuments.Builder

    /// An screen with one 40×40 box, and a graph builder for it.
    func scene() -> (Builder, LayerID) {
        let box = Layer(name: "Box", kind: .view, properties: [.size: .size(Size2(width: 40, height: 40))])
        return (Builder(screen: Layer(kind: .screen, children: [box])), box.id)
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

    @Test func aLoopRunsDownstreamPatchesPerIndexAndRepeatsTheLayer() {
        var (b, box) = scene()
        let loop = b.add("loop", at: .zero, inputs: ["count": .number(4)])
        let times = b.add("multiply", at: .zero, inputs: ["b": .number(50)])
        let point = b.add("makePoint", at: .zero, inputs: ["y": .number(10)])
        let position = b.property(.position, of: box, at: .zero)
        b.connect(loop, "index", to: times, "a")
        b.connect(times, "result", to: point, "x")
        b.connect(point, "point", to: position, "value")

        let runtime = Runtime(document: b.document)
        runtime.tick(dt: 1 / 60)
        #expect(instances(runtime, box).map(\.position) == [0, 50, 100, 150].map { Point2(x: $0, y: 10) })
        #expect(instances(runtime, box).map(\.instance) == [0, 1, 2, 3])
        #expect(runtime.outputValues(PortRef(node: times, port: "result")).count == 4)

        // Changing the rule changes the instances; an empty loop removes the layer.
        var edited = b.document
        edited.graph.update(loop) { $0.inputs["count"] = .number(2) }
        runtime.update(document: edited)
        runtime.tick(dt: 1 / 60)
        #expect(instances(runtime, box).count == 2)
        edited.graph.update(loop) { $0.inputs["count"] = .number(0) }
        runtime.update(document: edited)
        runtime.tick(dt: 1 / 60)
        #expect(instances(runtime, box).isEmpty)
    }

    @Test func eachIndexKeepsItsOwnState() {
        // A spring per index: targets 0, 100, 200 settle independently.
        var (b, box) = scene()
        let loop = b.add("loop", at: .zero, inputs: ["count": .number(3)])
        let times = b.add("multiply", at: .zero, inputs: ["b": .number(0)])
        let spring = b.add("spring", at: .zero)
        let opacity = b.property(.rotation, of: box, at: .zero)
        b.connect(loop, "index", to: times, "a")
        b.connect(times, "result", to: spring, "target")
        b.connect(spring, "value", to: opacity, "value")

        let runtime = Runtime(document: b.document)
        runtime.advance(seconds: 0.1)
        var edited = b.document
        edited.graph.update(times) { $0.inputs["b"] = .number(100) }
        runtime.update(document: edited)
        runtime.advance(seconds: 0.1)
        let midway = instances(runtime, box).map(\.rotation)
        #expect(midway[0] == 0)
        #expect(midway[1] > 0 && midway[1] < 100)
        #expect(abs(midway[2] - midway[1] * 2) < 0.001)
        runtime.advance(seconds: 3)
        let settled = instances(runtime, box).map(\.rotation)
        #expect(zip(settled, [0.0, 100, 200]).allSatisfy { abs($0 - $1) < 0.01 })
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func loopBuilderMakesALoopFromItsInputs() {
        var (b, box) = scene()
        let builder = b.document.graph.add(PatchNode(
            kind: "loopBuilder",
            inputs: ["value0": .text("Red"), "value1": .text("Green"), "value2": .text("Blue"), "value3": .text("Pink")],
            valueType: .text, inputCount: 4
        ))
        let count = b.add("loopCount", at: .zero, type: .text)
        let pick = b.add("loopSelect", at: .zero, type: .text, inputs: ["index": .number(2)])
        b.connect(builder, "loop", to: count, "loop")
        b.connect(builder, "loop", to: pick, "loop")
        _ = box

        let runtime = Runtime(document: b.document)
        runtime.tick(dt: 1 / 60)
        #expect(runtime.outputValues(PortRef(node: builder, port: "loop")) == ["Red", "Green", "Blue", "Pink"].map(Value.text))
        #expect(runtime.outputValues(PortRef(node: count, port: "count")) == [.number(4)])
        #expect(runtime.outputValues(PortRef(node: pick, port: "value")) == [.text("Blue")])
        #expect(PatchRegistry.standard.ports(for: PatchNode(kind: "loopBuilder")).inputs.map(\.id) == ["value0", "value1", "value2"])
    }

    @Test func loopOverArrayFollowsTheData() {
        var (b, box) = scene()
        let split = b.add("splitText", at: .zero, inputs: ["text": .text("10, 20, 35")])
        let each = b.add("loopOverArray", at: .zero, type: .number)
        let rotation = b.property(.rotation, of: box, at: .zero)
        b.connect(split, "array", to: each, "array")
        b.connect(each, "value", to: rotation, "value")

        let runtime = Runtime(document: b.document)
        runtime.tick(dt: 1 / 60)
        #expect(instances(runtime, box).map(\.rotation) == [10, 20, 35])

        var edited = b.document
        edited.graph.update(split) { $0.inputs["text"] = .text("1, 2, 3, 4, 5") }
        runtime.update(document: edited)
        runtime.tick(dt: 1 / 60)
        #expect(instances(runtime, box).map(\.rotation) == [1, 2, 3, 4, 5])
    }

    @Test func arraysRoundTripThroughJSON() throws {
        let value = Value.array([.text("a"), .number(2), .array([.bool(true)])])
        let decoded = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
        #expect(!Value.canConnect(from: .array, to: .text))
    }

    @Test func layersInsideARepeatedGroupRepeatWithIt() {
        let example = SampleDocuments.people()
        let runtime = Runtime(document: example.document)
        runtime.advance(seconds: 0.1)
        typealias People = SampleDocuments.People

        let rows = instances(runtime, example.row)
        let titles = instances(runtime, example.title)
        #expect(rows.count == People.names.count)
        #expect(titles.map { $0.value(.text).textValue } == People.names)
        // Layout arranges the repetitions like any other children.
        let tops = rows.map { Double($0.frame.minY) }
        let expected = People.names.indices.map { People.padding + Double($0) * (People.rowHeight + People.spacing) }
        #expect(tops == expected)
        #expect(rows.allSatisfy { $0.size.width == 390 - People.padding * 2 })
    }

    @Test func tappingARepeatedLayerIdentifiesWhichOne() {
        let example = SampleDocuments.people()
        let runtime = Runtime(document: example.document)
        runtime.advance(seconds: 0.1)
        typealias People = SampleDocuments.People
        func header() -> String { runtime.resolved.find(example.header)!.value(.text).textValue }
        func fills() -> [ColorValue] { instances(runtime, example.row).map { $0.value(.fill).colorValue } }
        #expect(header() == "Ada")

        // Tap the fourth row.
        let y = People.top + People.padding + 3 * (People.rowHeight + People.spacing) + 20
        runtime.send(.touchDown(Point2(x: 120, y: y)))
        runtime.tick(dt: 1 / 60)
        runtime.send(.touchUp(Point2(x: 120, y: y)))
        runtime.advance(seconds: 2)

        #expect(runtime.outputValue(PortRef(node: example.selection, port: "option")) == .number(3))
        #expect(header() == "Margaret")
        let blue = ColorValue(hex: "#3D7BF7")!
        for (index, fill) in fills().enumerated() {
            let expected = index == 3 ? blue : ColorValue.white
            #expect(abs(fill.red - expected.red) < 0.01 && abs(fill.blue - expected.blue) < 0.01)
        }
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func theListFollowsItsDataWhileRunning() {
        let example = SampleDocuments.people()
        let runtime = Runtime(document: example.document)
        runtime.advance(seconds: 0.1)
        var edited = example.document
        edited.graph.update(example.names) { $0.inputs["text"] = .text("Ada, Grace") }
        runtime.update(document: edited)
        runtime.advance(seconds: 0.1)
        #expect(instances(runtime, example.row).count == 2)
        #expect(runtime.outputValues(PortRef(node: edited.graph.nodes.first { $0.kind == PatchKind.interaction }!.id, port: "tap")).count == 2)
    }
}
