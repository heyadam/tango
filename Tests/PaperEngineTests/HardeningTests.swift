import Foundation
import Testing
import PaperModel
@testable import PaperEngine

/// Values at the edges of what a Double holds, found by `RandomizedTests`. Each is checked
/// here by itself, so it stays caught whatever the random tests happen to try.
@Suite struct HardeningTests {
    let frame = 1.0 / 60.0

    func run(_ graph: Graph, screen: Layer = Layer(name: "Screen", kind: .screen)) -> Runtime {
        let runtime = Runtime(document: Document(screen: screen, graph: graph))
        runtime.tick(dt: frame)
        return runtime
    }

    @Test func aLoopOfAnyCountRunsWithoutStopping() {
        for count in [-Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude, -1e300, .nan, .infinity] {
            let loop = PatchNode(kind: "loop", inputs: ["count": .number(count)])
            let runtime = run(Graph(nodes: [loop]))
            #expect(runtime.outputValues(PortRef(node: loop.id, port: "index")).count <= 2000)
        }
    }

    @Test func jsonWithANumberTooLargeForADoubleGivesAFiniteOne() {
        // Foundation reads a bare number past the largest Double as infinity.
        #expect(Value.parseJSON("-1e309") == .number(-Double.greatestFiniteMagnitude))
        // (A positive one it refuses as not JSON.)
        #expect(Value.parseJSON("1e309")?.isFinite ?? true)
    }

    @Test func layoutOfHugeChildrenPlacesThemSomewhereFinite() {
        func huge(_ name: String) -> Layer {
            Layer(name: name, kind: .view, properties: [.size: .size(Size2(width: 1.7e308, height: 1.7e308)), .anchor: .point(Point2(x: 1, y: 1))])
        }
        for layout in ["Stack", "Grid"] {
            var stack = Layer(name: "Stack", kind: .view, properties: [.layout: .text(layout), .spacing: .number(1e308)])
            stack.children = [huge("A"), huge("B"), huge("C")]
            var screen = Layer(name: "Screen", kind: .screen)
            screen.children = [stack]
            let runtime = run(Graph(), screen: screen)
            for child in runtime.resolved.children[0].children {
                #expect(child.value(.position).isFinite, "\(layout): \(child.name) at \(child.value(.position))")
            }
        }
    }

    @Test func normalizeKeepsEveryStoredNumberSavable() throws {
        var screen = Layer(name: "Screen", kind: .screen)
        screen.children = [Layer(name: "Box", kind: .view, properties: [
            .position: .point(Point2(x: .infinity, y: 0)), .opacity: .number(.nan), .size: .size(Size2(width: 10, height: 10)),
        ])]
        let patch = PatchNode(kind: "add", position: Point2(x: .nan, y: 0), inputs: ["a": .number(-.infinity), "b": .number(2)])
        let document = Document(screen: screen, graph: Graph(nodes: [patch]))
        let box = document.screen.children[0]
        #expect(box.properties[.position] == nil && box.properties[.opacity] == nil)
        #expect(box.properties[.size] != nil)
        let node = try #require(document.graph.node(patch.id))
        #expect(node.inputs == ["b": .number(2)] && node.position == Point2(x: 0, y: 0))
        _ = try JSONEncoder().encode(document)
    }

    @Test func aContainersOnePaddingIsSplitAsReadingAFileWould() throws {
        var screen = Layer(name: "Screen", kind: .screen)
        screen.children = [Layer(name: "Stack", kind: .view, properties: [.layout: .text("Stack"), .padding: .number(12)]),
                           Layer(name: "Field", kind: .textField, properties: [.padding: .number(4)])]
        let document = Document(screen: screen, graph: Graph())
        let stack = document.screen.children[0], field = document.screen.children[1]
        #expect(stack.properties[.padding] == nil)
        #expect(stack.properties[.paddingHorizontal] == .number(12) && stack.properties[.paddingVertical] == .number(12))
        // A text field's padding is its own.
        #expect(field.properties[.padding] == .number(4))
        let read = try JSONDecoder().decode(Document.self, from: JSONEncoder().encode(document))
        #expect(read == document)
    }
}
