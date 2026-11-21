import Foundation
import Testing
import PaperModel
@testable import PaperEngine

@Suite struct ScriptTests {
    func node(_ source: String, inputs: [String: Value] = [:]) -> PatchNode {
        PatchNode(kind: PatchKind.javascript, inputs: inputs, script: source)
    }

    @Test func aScriptDeclaresItsPorts() {
        let source = """
        inputs = { amount: 2, label: "hi", on: true, where: point(1, 2), tint: color("#FF0000"), go: pulse(), items: [] };
        outputs = { doubled: 0, shout: "", fired: pulse() };
        function evaluate(inputs, outputs) {}
        """
        let ports = PatchRegistry.standard.ports(for: node(source))
        #expect(ports.inputs.map(\.name) == ["Amount", "Label", "On", "Where", "Tint", "Go", "Items"])
        #expect(ports.inputs.map(\.type) == [.number, .text, .bool, .point, .color, .pulse, .array])
        #expect(ports.inputs[0].defaultValue == .number(2))
        #expect(ports.outputs.map(\.type) == [.number, .text, .pulse])
        #expect(Script.interface(of: source).error == nil)
        #expect(PatchRegistry.standard.ports(for: node(Script.template)).outputs.map(\.id) == ["result"])
    }

    @Test func aScriptComputesItsOutputsAndKeepsItsOwnState() {
        let source = """
        inputs = { value: 0, add: pulse() };
        outputs = { total: 0, text: "" };
        var total = 0;
        function evaluate(inputs, outputs) {
          if (inputs.add) total += inputs.value;
          outputs.total = total;
          outputs.text = "Total " + total;
        }
        """
        var graph = Graph()
        let button = Layer(kind: .view, properties: [.size: .size(Size2(width: 100, height: 100))])
        let touch = graph.add(.interaction(on: button.id))
        let script = graph.add(node(source, inputs: ["value": .number(5)]))
        graph.connect(from: PortRef(node: touch, port: "tap"), to: PortRef(node: script, port: "add"))
        let runtime = Runtime(document: Document(screen: Layer(kind: .screen, children: [button]), graph: graph))
        runtime.tick(dt: 1 / 60)
        for _ in 0..<3 {
            runtime.send(.touchDown(Point2(x: 50, y: 50)))
            runtime.tick(dt: 1 / 60)
            runtime.send(.touchUp(Point2(x: 50, y: 50)))
            runtime.advance(seconds: 0.5)
        }
        #expect(runtime.outputValue(PortRef(node: script, port: "total")) == .number(15))
        #expect(runtime.outputValue(PortRef(node: script, port: "text")) == .text("Total 15"))
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func aScriptInALoopRunsPerItemAndCanRunEveryFrame() {
        let source = """
        inputs = { index: 0 };
        outputs = { where: point(0, 0), frames: 0 };
        everyFrame = true;
        var frames = 0;
        function evaluate(inputs, outputs, time) {
          frames += 1;
          outputs.where = point(inputs.index * 10, time > 0 ? 1 : 0);
          outputs.frames = frames;
        }
        """
        var graph = Graph()
        let loop = graph.add(PatchNode(kind: "loop", inputs: ["count": .number(3)]))
        let script = graph.add(node(source))
        graph.connect(from: PortRef(node: loop, port: "index"), to: PortRef(node: script, port: "index"))
        let runtime = Runtime(document: Document(graph: graph))
        for _ in 0..<4 { runtime.tick(dt: 1 / 60) }
        #expect(runtime.outputValues(PortRef(node: script, port: "where")) == [0, 10, 20].map { .point(Point2(x: $0, y: 1)) })
        // Each index has its own copy of the script's variables.
        #expect(runtime.outputValues(PortRef(node: script, port: "frames")) == [.number(4), .number(4), .number(4)])
        #expect(runtime.needsAnotherFrame)
    }

    @Test func aBrokenScriptReportsWhyAndDoesNotCrash() {
        let broken = Script.interface(of: "inputs = { a: 0 ;")
        #expect(broken.error?.contains("SyntaxError") == true)
        #expect(Script.interface(of: "inputs = { a: 0 };").error == "The script needs a function named evaluate.")

        // Throwing while running leaves the outputs as they were.
        var graph = Graph()
        let script = graph.add(node("outputs = { x: 7 }; function evaluate() { throw new Error('no'); }"))
        let runtime = Runtime(document: Document(graph: graph))
        runtime.tick(dt: 1 / 60)
        #expect(runtime.outputValue(PortRef(node: script, port: "x")) == .number(7))
    }
}
