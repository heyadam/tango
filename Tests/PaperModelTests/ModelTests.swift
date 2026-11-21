import Foundation
import Testing
@testable import PaperModel

@Suite struct ValueTests {
    @Test func coercionFollowsTheConnectTable() {
        for from in PortType.allCases {
            for to in PortType.allCases {
                let value = Value.defaultValue(for: from)
                #expect((value.coerced(to: to) != nil) == Value.canConnect(from: from, to: to))
            }
        }
    }

    @Test func booleanCannotFeedAPulse() {
        #expect(!Value.canConnect(from: .bool, to: .pulse))
        #expect(Value.canConnect(from: .pulse, to: .bool))
    }

    @Test func lerpIsUnclamped() {
        #expect(Value.lerp(.number(0), .number(10), 1.2) == .number(12))
        #expect(Value.lerp(.point(Point2(x: 0, y: 0)), .point(Point2(x: 10, y: 20)), 0.5) == .point(Point2(x: 5, y: 10)))
        #expect(Value.lerp(.text("a"), .text("b"), 0.4) == .text("a"))
    }

    @Test func hexColorsRoundTrip() {
        #expect(ColorValue(hex: "#3D7BF7")?.hex == "#3D7BF7")
        #expect(ColorValue(hex: "#00000080")?.alpha == 128.0 / 255.0)
        #expect(ColorValue(hex: "nope") == nil)
    }

    @Test func numberFormatting() {
        #expect(Value.format(3) == "3")
        #expect(Value.format(0.5) == "0.5")
        #expect(Value.format(1.239) == "1.24")
    }
}

@Suite struct GraphTests {
    @Test func anInputAcceptsOneCable() {
        var graph = Graph()
        let a = graph.add(PatchNode(kind: "value"))
        let b = graph.add(PatchNode(kind: "value"))
        let c = graph.add(PatchNode(kind: "add"))
        let input = PortRef(node: c, port: "a")
        graph.connect(from: PortRef(node: a, port: "value"), to: input)
        graph.connect(from: PortRef(node: b, port: "value"), to: input)
        #expect(graph.connections.count == 1)
        #expect(graph.connection(into: input)?.from.node == b)
    }

    @Test func removingAPatchRemovesItsCables() {
        var graph = Graph()
        let a = graph.add(PatchNode(kind: "value"))
        let b = graph.add(PatchNode(kind: "add"))
        graph.connect(from: PortRef(node: a, port: "value"), to: PortRef(node: b, port: "a"))
        graph.remove(a)
        #expect(graph.connections.isEmpty)
        #expect(graph.nodes.count == 1)
    }
}

@Suite struct DocumentTests {
    func sample() -> (Document, LayerID, LayerID) {
        let inner = Layer(name: "Inner", kind: .view, properties: [.cornerRadius: .number(8)])
        let group = Layer(name: "Group", kind: .view, children: [inner])
        var document = Document(screen: Layer(kind: .screen, children: [group]))
        let touch = document.graph.add(.interaction(on: inner.id))
        let flip = document.graph.add(PatchNode(kind: "switch", position: Point2(x: 200, y: 0)))
        let view = document.graph.viewNode(layer: inner.id)!.id
        document.graph.connect(from: PortRef(node: touch, port: "tap"), to: PortRef(node: flip, port: "flip"))
        document.graph.connect(from: PortRef(node: flip, port: "on"), to: PortRef(node: view, port: "opacity"))
        return (document, group.id, inner.id)
    }

    @Test func jsonRoundTripPreservesEverything() throws {
        let (document, _, _) = sample()
        let decoded = try Document.decode(from: document.encoded())
        #expect(decoded == document)
    }

    @Test func newerVersionsAreRejected() throws {
        var (document, _, _) = sample()
        document.version = Document.currentVersion + 1
        let data = try document.encoded()
        #expect(throws: Document.LoadError.unsupportedVersion(Document.currentVersion + 1)) {
            try Document.decode(from: data)
        }
    }

    @Test func removingALayerRemovesPatchesBoundToItsDescendants() {
        var (document, group, _) = sample()
        document.removeLayer(group)
        #expect(document.screen.children.isEmpty)
        #expect(document.graph.patches.map(\.kind) == ["switch"])
        // Their view patches went with them; the screen keeps its own.
        #expect(document.graph.nodes.filter { $0.kind == PatchKind.view }.map(\.layerID) == [document.screen.id])
        #expect(document.graph.connections.isEmpty)
    }

    @Test func layerTreeEdits() {
        var (document, group, inner) = sample()
        #expect(document.screen.path(to: inner).map(\.name) == ["Screen", "Group", "Inner"])
        #expect(document.screen.parent(of: inner)?.id == group)

        let moved = document.screen.remove(inner)!
        let inserted = document.screen.insert(moved, into: document.screen.id, at: 0)
        #expect(inserted)
        #expect(document.screen.children.map(\.name) == ["Inner", "Group"])

        document.screen.update(inner) { $0.set(.opacity, .bool(false)) }
        #expect(document.layer(inner)?.value(.opacity) == .number(0))
        // Stored values are sparse: defaults are not written.
        #expect(document.layer(inner)?.properties.keys.sorted { $0.rawValue < $1.rawValue } == [.cornerRadius, .opacity])
    }
}
