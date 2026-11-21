import Foundation
import Testing
import PaperModel
@testable import PaperEngine

/// Things a prototype must survive: scripts that never end, and numbers too large or not
/// numbers at all. Found in QA.
@Suite struct RobustnessTests {
    let frame = 1.0 / 60.0

    @Test func aScriptThatNeverEndsIsStopped() {
        let started = Date()
        let forever = Script.interface(of: "inputs = {a: 0}; outputs = {r: 0}; while (true) {}")
        #expect(forever.error == Script.tooLong)
        #expect(Date().timeIntervalSince(started) < 3)

        // The loop is in the function this time: the patch stops, and stays stopped.
        let script = "inputs = {n: 5}; outputs = {r: 0}; function evaluate(i, o) { var k = i.n; while (k != 0) { k -= 2; } o.r = 1; }"
        var node = PatchNode(kind: PatchKind.javascript, position: .zero)
        node.script = script
        let runtime = Runtime(document: Document(graph: Graph(nodes: [node])))
        let before = Date()
        runtime.tick(dt: frame)
        #expect(Date().timeIntervalSince(before) < 3)
        let after = Date()
        runtime.advance(seconds: 0.5)
        #expect(Date().timeIntervalSince(after) < 1)
        #expect(runtime.outputValue(PortRef(node: node.id, port: "r"))?.numberValue == 0)

        // An ordinary script is unaffected.
        var fine = PatchNode(kind: PatchKind.javascript, position: .zero, inputs: ["a": .number(2), "b": .number(3)])
        fine.script = "inputs = {a: 0, b: 0}; outputs = {r: 0}; function evaluate(i, o) { var t = 0; for (var k = 0; k < 10000; k++) { t += k; } o.r = i.a + i.b; }"
        let working = Runtime(document: Document(graph: Graph(nodes: [fine])))
        working.tick(dt: frame)
        #expect(working.outputValue(PortRef(node: fine.id, port: "r"))?.numberValue == 5)
    }

    @Test func aScriptCannotHandOutGeometryThatIsNotANumber() {
        var node = PatchNode(kind: PatchKind.javascript, position: .zero)
        node.script = "inputs = {a: 0, b: 0}; outputs = {p: point(0, 0), s: size(10, 10)}; function evaluate(i, o) { o.p.x = i.a / i.b; o.p.y = 1 / i.b; o.s.width = i.a / i.b; }"
        let runtime = Runtime(document: Document(graph: Graph(nodes: [node])))
        runtime.tick(dt: frame)
        let point = runtime.outputValue(PortRef(node: node.id, port: "p"))!.pointValue
        let size = runtime.outputValue(PortRef(node: node.id, port: "s"))!.sizeValue
        #expect(point.x.isFinite && point.y.isFinite && size.width.isFinite)
    }

    @Test func enormousNumbersDoNotStopTheProgram() {
        #expect(Double.nan.whole == 0)
        #expect(Double.infinity.whole == 0)
        #expect(1e300.whole == Int(1e15))
        #expect((-1e300).whole == -Int(1e15))
        #expect(2.6.whole == 3)

        // A grid with an absurd number of columns.
        let child = Layer(kind: .view)
        let grid = Layer(kind: .view, properties: [
            .size: .size(Size2(width: 300, height: 300)), .layout: .text("Grid"), .columns: .number(1e19),
        ], children: [child])
        #expect(ResolvedLayer(grid).laidOut().find(child.id) != nil)

        // Three multiplications reach 1e26 with ordinary inputs; it then picks an option and an index.
        func times(_ a: Double, _ b: Double) -> PatchNode {
            PatchNode(kind: "multiply", position: .zero, inputs: ["a": .number(a), "b": .number(b)])
        }
        let one = times(1e6, 1e6), two = times(1, 1e6), three = times(1, 1e8)
        let picker = PatchNode(kind: "optionPicker", position: .zero)
        let loop = PatchNode(kind: "loop", position: .zero, inputs: ["count": .number(3)])
        let select = PatchNode(kind: "loopSelect", position: .zero)
        func cable(_ from: PatchNode, _ output: String, _ to: PatchNode, _ input: String) -> Connection {
            Connection(from: PortRef(node: from.id, port: output), to: PortRef(node: to.id, port: input))
        }
        let graph = Graph(nodes: [one, two, three, picker, loop, select], connections: [
            cable(one, "result", two, "a"), cable(two, "result", three, "a"),
            cable(three, "result", picker, "option"), cable(three, "result", select, "index"),
            cable(loop, "index", select, "loop"),
        ])
        let runtime = Runtime(document: Document(graph: graph))
        runtime.advance(seconds: 0.1)
        #expect(runtime.outputValue(PortRef(node: three.id, port: "result"))?.numberValue == 1e26)
    }
}
