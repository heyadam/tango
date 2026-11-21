import Foundation
import Testing
import PaperModel
@testable import PaperEngine

/// A view can publish ports from inside it: they show on its patch, one level out, and a
/// cable there reaches the port inside (extends spec 6.5).
@Suite struct PublishedPortTests {
    typealias Builder = SampleDocuments.Builder

    struct Scene {
        var document: Document
        let card: LayerID
        let dot: LayerID
        var cardPatch: NodeID { document.graph.viewNode(layer: card)!.id }
        var dotPatch: NodeID { document.graph.viewNode(layer: dot)!.id }

        /// Publishes a port on the card's patch and returns its id there.
        mutating func publish(_ inner: PortRef, output: Bool, type: PortType = .number, on holder: NodeID? = nil) -> String {
            let port = PublishedPort(name: "Port", inner: inner, isOutput: output, type: type)
            document.graph.update(holder ?? cardPatch) { $0.published = ($0.published ?? []) + [port] }
            return port.id
        }

        @discardableResult
        mutating func add(_ kind: String, _ inputs: [String: Value] = [:], home: LayerID? = nil) -> NodeID {
            var node = PatchNode(kind: kind, inputs: inputs)
            node.home = home
            return document.graph.add(node)
        }

        mutating func connect(_ from: NodeID, _ output: String, _ to: NodeID, _ input: String) {
            document.graph.connect(from: PortRef(node: from, port: output), to: PortRef(node: to, port: input))
        }

        func run() -> Runtime {
            let runtime = Runtime(document: document)
            runtime.tick(dt: 1 / 60)
            return runtime
        }
    }

    /// A screen with a card that holds a dot.
    func scene() -> Scene {
        let dot = Layer(name: "Dot", kind: .view, properties: [.size: .size(Size2(width: 20, height: 20))])
        let card = Layer(name: "Card", kind: .view, properties: [.size: .size(Size2(width: 200, height: 100))], children: [dot])
        return Scene(document: Document(screen: Layer(kind: .screen, children: [card])), card: card.id, dot: dot.id)
    }

    @Test func aCableIntoAPublishedInputDrivesTheViewInside() {
        var s = scene()
        let opacity = s.publish(PortRef(node: s.dotPatch, port: "opacity"), output: false)
        let source = s.add("add", ["a": .number(0.25)])
        s.connect(source, "result", s.cardPatch, opacity)
        let runtime = s.run()
        #expect(runtime.resolved.find(s.dot)?.opacity == 0.25)
        // The card itself is untouched.
        #expect(runtime.resolved.find(s.card)?.opacity == 1)
        // The published port shows the value that arrives inside.
        #expect(runtime.inputValue(PortRef(node: s.cardPatch, port: opacity)) == .number(0.25))
    }

    @Test func aPublishedOutputCarriesAValueOutOfTheView() {
        var s = scene()
        let inner = s.add("add", ["a": .number(3), "b": .number(4)], home: s.card)
        let sum = s.publish(PortRef(node: inner, port: "result"), output: true)
        let outside = s.add("multiply", ["b": .number(2)])
        s.connect(s.cardPatch, sum, outside, "a")
        let runtime = s.run()
        #expect(runtime.number(outside, "result") == 14)
        #expect(runtime.outputValue(PortRef(node: s.cardPatch, port: sum)) == .number(7))
    }

    @Test func aPortPublishedTwiceReachesThroughBothViews() {
        let dot = Layer(name: "Dot", kind: .view)
        let inner = Layer(name: "Inner", kind: .view, children: [dot])
        let outer = Layer(name: "Outer", kind: .view, children: [inner])
        var s = Scene(document: Document(screen: Layer(kind: .screen, children: [outer])), card: outer.id, dot: dot.id)
        let innerPatch = s.document.graph.viewNode(layer: inner.id)!.id
        let first = s.publish(PortRef(node: s.dotPatch, port: "scale"), output: false, on: innerPatch)
        let second = s.publish(PortRef(node: innerPatch, port: first), output: false)
        let source = s.add("add", ["a": .number(2)])
        s.connect(source, "result", s.cardPatch, second)
        // Settling keeps both: each stands for a port in its own level.
        PatchRegistry.standard.settlePublished(in: &s.document)
        #expect(s.document.graph.node(s.cardPatch)?.published?.count == 1)
        #expect(s.run().resolved.find(dot.id)?.scale == 2)
    }

    @Test func theCableFromOutsideWinsOverOneInside() {
        var s = scene()
        let inside = s.add("add", ["a": .number(0.9)], home: s.card)
        s.connect(inside, "result", s.dotPatch, "opacity")
        let opacity = s.publish(PortRef(node: s.dotPatch, port: "opacity"), output: false)
        #expect(s.run().resolved.find(s.dot)?.opacity == 0.9)
        let outside = s.add("add", ["a": .number(0.1)])
        s.connect(outside, "result", s.cardPatch, opacity)
        #expect(s.run().resolved.find(s.dot)?.opacity == 0.1)
    }

    @Test func aPublishedInputOfAPatchInsideIsFedFromOutside() {
        var s = scene()
        let doubled = s.add("multiply", ["b": .number(2)], home: s.card)
        s.connect(doubled, "result", s.dotPatch, "x")
        let amount = s.publish(PortRef(node: doubled, port: "a"), output: false)
        let source = s.add("add", ["a": .number(30)])
        s.connect(source, "result", s.cardPatch, amount)
        #expect(s.run().resolved.find(s.dot)?.position.x == 60)
    }

    @Test func settlingDropsAPortWhoseInsideIsGoneAndItsCable() {
        var s = scene()
        let inner = s.add("add", ["a": .number(1)], home: s.card)
        let out = s.publish(PortRef(node: inner, port: "result"), output: true)
        let opacity = s.publish(PortRef(node: s.dotPatch, port: "opacity"), output: false)
        let outside = s.add("add")
        s.connect(s.cardPatch, out, outside, "a")
        s.connect(outside, "result", s.cardPatch, opacity)
        var settled = s.document
        PatchRegistry.standard.settlePublished(in: &settled)
        #expect(settled == s.document)

        // The patch inside is deleted: its port and the cable from it go.
        s.document.graph.remove(inner)
        PatchRegistry.standard.settlePublished(in: &s.document)
        #expect(s.document.graph.node(s.cardPatch)?.published?.map(\.id) == [opacity])
        #expect(s.document.graph.connection(into: PortRef(node: outside, port: "a")) == nil)

        // The dot moves out of the card: nothing of it is inside any more.
        let dot = s.document.screen.find(s.dot)!
        s.document.screen.update(s.card) { $0.children = [] }
        s.document.screen.children.append(dot)
        PatchRegistry.standard.settlePublished(in: &s.document)
        #expect(s.document.graph.node(s.cardPatch)?.published == nil)
        #expect(s.document.graph.connection(into: PortRef(node: s.cardPatch, port: opacity)) == nil)
    }

    @Test func aPublishedPortFollowsTheTypeOfThePortInside() {
        var s = scene()
        var chooser = PatchNode(kind: "transition", valueType: .number)
        chooser.home = s.card
        let inner = s.document.graph.add(chooser)
        let value = s.publish(PortRef(node: inner, port: "value"), output: true)
        s.document.graph.update(inner) { $0.valueType = .color }
        PatchRegistry.standard.settlePublished(in: &s.document)
        #expect(s.document.graph.node(s.cardPatch)?.published?.first?.type == .color)
        let ports = PatchRegistry.standard.ports(for: s.document.graph.node(s.cardPatch)!)
        #expect(ports.output(value)?.type == .color)
    }

    @Test func aDocumentWithPublishedPortsSurvivesSaving() throws {
        var s = scene()
        _ = s.publish(PortRef(node: s.dotPatch, port: "opacity"), output: false)
        let copy = try Document.decode(from: s.document.encoded())
        #expect(copy == s.document)
    }
}
