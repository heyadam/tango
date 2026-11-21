import Foundation
import Testing
import PaperModel
@testable import PaperEngine

let frame = 1.0 / 60.0

/// A document with one tappable rectangle, plus helpers to wire patches by port name.
struct Rig {
    var builder: SampleDocuments.Builder
    let box: LayerID

    init() {
        let box = Layer(name: "Box", kind: .view, properties: [
            .position: .point(Point2(x: 100, y: 100)),
            .size: .size(Size2(width: 100, height: 100)),
        ])
        builder = SampleDocuments.Builder(screen: Layer(kind: .screen, children: [box]))
        self.box = box.id
    }

    @discardableResult
    mutating func add(_ kind: String, type: PortType? = nil, _ inputs: [String: Value] = [:]) -> NodeID {
        builder.add(kind, at: .zero, type: type, inputs: inputs)
    }

    mutating func connect(_ from: NodeID, _ output: String, _ to: NodeID, _ input: String) {
        builder.connect(from, output, to: to, input)
    }

    var document: Document { builder.document }
}

extension Runtime {
    func number(_ node: NodeID, _ port: String) -> Double {
        outputValue(PortRef(node: node, port: port))?.numberValue ?? .nan
    }

    func bool(_ node: NodeID, _ port: String) -> Bool {
        outputValue(PortRef(node: node, port: port))?.boolValue ?? false
    }

    func tap(at point: Point2) {
        send(.touchDown(point))
        send(.touchUp(point))
    }
}

@Suite struct GraphEvaluationTests {
    @Test func valuesFlowThroughCables() {
        var rig = Rig()
        let sum = rig.add("add", ["a": .number(2), "b": .number(3)])
        let product = rig.add("multiply", ["b": .number(4)])
        let opacity = rig.builder.property(.opacity, of: rig.box, at: .zero)
        rig.connect(sum, "result", product, "a")
        rig.connect(product, "result", opacity, "value")

        let runtime = Runtime(document: rig.document)
        runtime.tick(dt: frame)
        #expect(runtime.number(product, "result") == 20)
        #expect(runtime.resolved.find(rig.box)?.opacity == 20)
    }

    @Test func unconnectedPropertyPatchLeavesTheLayerValueAlone() {
        var rig = Rig()
        rig.builder.property(.position, of: rig.box, at: .zero)
        let runtime = Runtime(document: rig.document)
        runtime.tick(dt: frame)
        #expect(runtime.resolved.find(rig.box)?.position == Point2(x: 100, y: 100))
    }

    @Test func evaluationOrderDoesNotDependOnInsertionOrder() {
        var rig = Rig()
        // Consumer added before its source.
        let doubled = rig.add("multiply", ["b": .number(2)])
        let source = rig.add("add", ["a": .number(5)])
        rig.connect(source, "result", doubled, "a")
        let runtime = Runtime(document: rig.document)
        runtime.tick(dt: frame)
        #expect(runtime.number(doubled, "result") == 10)
    }

    @Test func aCycleReadsThePreviousFrame() {
        var rig = Rig()
        let sum = rig.add("add", ["b": .number(1)])
        let pass = rig.add("value", type: .number)
        rig.connect(sum, "result", pass, "value")
        rig.connect(pass, "value", sum, "a")
        let runtime = Runtime(document: rig.document)
        var seen: [Double] = []
        for _ in 0..<4 {
            runtime.tick(dt: frame)
            seen.append(runtime.number(sum, "result"))
        }
        // Grows by a bounded amount per frame instead of looping forever.
        #expect(seen == seen.sorted())
        #expect(seen.last! <= 8)
        #expect(seen.last! > seen.first!)
    }

    @Test func anIdleGraphAsksForNoMoreFrames() {
        var rig = Rig()
        rig.add("add", ["a": .number(1)])
        let runtime = Runtime(document: rig.document)
        runtime.tick(dt: frame)
        #expect(runtime.tick(dt: frame) == false)
        #expect(runtime.needsAnotherFrame == false)
    }

    @Test func incompatibleCablesFallBackToTheLiteralDefault() {
        var rig = Rig()
        let color = rig.add("makeColor")
        let sum = rig.add("add", ["b": .number(2)])
        rig.connect(color, "color", sum, "a")
        let runtime = Runtime(document: rig.document)
        runtime.tick(dt: frame)
        #expect(runtime.number(sum, "result") == 2)
        #expect(!runtime.registry.canConnect(
            from: PortRef(node: color, port: "color"), to: PortRef(node: sum, port: "a"), in: rig.document.graph
        ))
    }
}

@Suite struct PulseAndStateTests {
    @Test func aTapPulsesForExactlyOneFrameAndFlipsTheSwitchOnce() {
        var rig = Rig()
        let touch = rig.builder.interaction(on: rig.box, at: .zero)
        let toggle = rig.add("switch")
        rig.connect(touch, "tap", toggle, "flip")

        let runtime = Runtime(document: rig.document)
        runtime.tick(dt: frame)
        runtime.tap(at: Point2(x: 150, y: 150))

        var pulseFrames = 0
        var downFrames = 0
        for _ in 0..<6 {
            runtime.tick(dt: frame)
            if runtime.outputValue(PortRef(node: touch, port: "tap"))?.pulseValue == true { pulseFrames += 1 }
            if runtime.bool(touch, "down") { downFrames += 1 }
        }
        #expect(pulseFrames == 1)
        #expect(downFrames == 1)
        #expect(runtime.bool(toggle, "on"))
        #expect(runtime.needsAnotherFrame == false)

        runtime.tap(at: Point2(x: 150, y: 150))
        runtime.advance(seconds: 0.1)
        #expect(!runtime.bool(toggle, "on"))
    }

    @Test func aDragIsNotATap() {
        var rig = Rig()
        let touch = rig.builder.interaction(on: rig.box, at: .zero)
        let toggle = rig.add("switch")
        rig.connect(touch, "tap", toggle, "flip")
        let runtime = Runtime(document: rig.document)
        runtime.tick(dt: frame)

        runtime.send(.touchDown(Point2(x: 150, y: 150)))
        runtime.tick(dt: frame)
        runtime.send(.touchMoved(Point2(x: 150, y: 200)))
        runtime.tick(dt: frame)
        #expect(runtime.outputValue(PortRef(node: touch, port: "drag")) == .point(Point2(x: 0, y: 50)))
        runtime.send(.touchUp(Point2(x: 150, y: 200)))
        runtime.advance(seconds: 0.1)
        #expect(!runtime.bool(toggle, "on"))
    }

    @Test func touchesOutsideTheLayerAreIgnored() {
        var rig = Rig()
        let touch = rig.builder.interaction(on: rig.box, at: .zero)
        let runtime = Runtime(document: rig.document)
        runtime.tick(dt: frame)
        runtime.send(.touchDown(Point2(x: 10, y: 10)))
        runtime.tick(dt: frame)
        #expect(!runtime.bool(touch, "down"))
    }

    @Test func pulsePatchTurnsStateChangesIntoEvents() {
        var rig = Rig()
        let touch = rig.builder.interaction(on: rig.box, at: .zero)
        let edges = rig.add("pulse")
        let presses = rig.add("counter")
        let releases = rig.add("counter")
        rig.connect(touch, "down", edges, "value")
        rig.connect(edges, "turnedOn", presses, "increase")
        rig.connect(edges, "turnedOff", releases, "increase")

        let runtime = Runtime(document: rig.document)
        runtime.tick(dt: frame)
        #expect(runtime.number(presses, "value") == 0)

        runtime.send(.touchDown(Point2(x: 150, y: 150)))
        runtime.advance(seconds: 0.2)
        #expect(runtime.number(presses, "value") == 1)
        #expect(runtime.number(releases, "value") == 0)

        runtime.send(.touchUp(Point2(x: 150, y: 150)))
        runtime.advance(seconds: 0.2)
        #expect(runtime.number(presses, "value") == 1)
        #expect(runtime.number(releases, "value") == 1)
    }

    @Test func statePersistsWhenTheGraphIsEdited() {
        var rig = Rig()
        let touch = rig.builder.interaction(on: rig.box, at: .zero)
        let toggle = rig.add("switch")
        rig.connect(touch, "tap", toggle, "flip")
        let runtime = Runtime(document: rig.document)
        runtime.tick(dt: frame)
        runtime.tap(at: Point2(x: 150, y: 150))
        runtime.advance(seconds: 0.1)
        #expect(runtime.bool(toggle, "on"))

        // Rewire while running: add a patch and a cable.
        let opacity = rig.builder.property(.opacity, of: rig.box, at: .zero)
        rig.connect(toggle, "on", opacity, "value")
        runtime.update(document: rig.document)
        runtime.tick(dt: frame)
        #expect(runtime.bool(toggle, "on"))
        #expect(runtime.resolved.find(rig.box)?.opacity == 1)
    }

    @Test func editedLiteralsTakeEffectOnTheNextFrame() {
        var rig = Rig()
        let sum = rig.add("add", ["a": .number(1)])
        let runtime = Runtime(document: rig.document)
        runtime.tick(dt: frame)
        rig.builder.document.graph.update(sum) { $0.inputs["a"] = .number(7) }
        runtime.update(document: rig.document)
        runtime.tick(dt: frame)
        #expect(runtime.number(sum, "result") == 7)
    }

    @Test func optionSwitchAndPickerSelectAValue() {
        var rig = Rig()
        let keyA = rig.add("keyboard", ["key": .text("a")])
        let keyB = rig.add("keyboard", ["key": .text("b")])
        let option = rig.add("optionSwitch")
        let picker = rig.add("optionPicker", type: .number, [
            "value0": .number(10), "value1": .number(20), "value2": .number(30),
        ])
        rig.connect(keyA, "pressed", option, "set1")
        rig.connect(keyB, "pressed", option, "set2")
        rig.connect(option, "option", picker, "option")
        let runtime = Runtime(document: rig.document)
        runtime.tick(dt: frame)
        #expect(runtime.number(picker, "value") == 10)
        runtime.send(.keyDown("a"))
        runtime.advance(seconds: 0.05)
        #expect(runtime.number(picker, "value") == 20)
        runtime.send(.keyUp("a"))
        runtime.send(.keyDown("B"))
        runtime.advance(seconds: 0.05)
        #expect(runtime.number(picker, "value") == 30)
    }

    @Test func delayPassesAValueThroughLater() {
        var rig = Rig()
        let touch = rig.builder.interaction(on: rig.box, at: .zero)
        let delayed = rig.add("delay", type: .bool, ["duration": .number(0.5)])
        rig.connect(touch, "down", delayed, "value")
        let runtime = Runtime(document: rig.document)
        runtime.tick(dt: frame)
        runtime.send(.touchDown(Point2(x: 150, y: 150)))
        runtime.advance(seconds: 0.3)
        #expect(!runtime.bool(delayed, "value"))
        runtime.advance(seconds: 0.3)
        #expect(runtime.bool(delayed, "value"))
    }
}

@Suite struct HitTestingTests {
    @Test func layersWithoutAnInteractionDoNotBlockTouches() {
        let button = Layer(name: "Button", kind: .view, properties: [.size: .size(Size2(width: 200, height: 200))])
        let label = Layer(name: "Label", kind: .text, properties: [.size: .size(Size2(width: 200, height: 200))])
        var builder = SampleDocuments.Builder(screen: Layer(kind: .screen, children: [button, label]))
        let touch = builder.interaction(on: button.id, at: .zero)
        let runtime = Runtime(document: builder.document)
        runtime.tick(dt: frame)
        #expect(runtime.resolved.hitTest(Point2(x: 50, y: 50)).first == label.id)
        runtime.send(.touchDown(Point2(x: 50, y: 50)))
        runtime.tick(dt: frame)
        #expect(runtime.bool(touch, "down"))
    }

    @Test func disabledAndTransparentLayersAreSkipped() {
        let hidden = Layer(name: "Hidden", kind: .view, properties: [.opacity: .number(0)])
        let disabled = Layer(name: "Disabled", kind: .view, properties: [.enabled: .bool(false)])
        let tree = ResolvedLayer(Layer(kind: .screen, children: [hidden, disabled]))
        #expect(tree.hitTest(Point2(x: 50, y: 50), options: .touch) == [tree.id])
        #expect(tree.hitTest(Point2(x: 50, y: 50), options: .editing) == [disabled.id, hidden.id, tree.id])
    }

    @Test func hitTestingFollowsTransforms() {
        let child = Layer(name: "Child", kind: .view, properties: [
            .position: .point(Point2(x: 10, y: 10)), .size: .size(Size2(width: 20, height: 20)),
        ])
        let group = Layer(name: "Group", kind: .view, properties: [
            .position: .point(Point2(x: 100, y: 100)), .size: .size(Size2(width: 100, height: 100)), .scale: .number(2),
        ], children: [child])
        let tree = ResolvedLayer(Layer(kind: .screen, children: [group]))
        // The group scales around its center (150,150), so its child spans 70...110.
        #expect(tree.hitTest(Point2(x: 80, y: 80)).first == child.id)
        #expect(tree.hitTest(Point2(x: 120, y: 120)).first == group.id)
        #expect(tree.hitTest(Point2(x: 40, y: 40)) == [tree.id])
    }

    @Test func anchorOffsetsTheFrame() {
        let layer = Layer(kind: .view, properties: [
            .position: .point(Point2(x: 100, y: 100)),
            .size: .size(Size2(width: 40, height: 20)),
            .anchor: .point(Point2(x: 0.5, y: 0.5)),
        ])
        #expect(ResolvedLayer(layer).frame == CGRect(x: 80, y: 90, width: 40, height: 20))
    }
}
