import Foundation
import Testing
import PaperModel
@testable import PaperEngine

/// Documents saved before views became patches (version 2) open and play as they did.
/// `Tests/Fixtures/v2` holds each example as it was saved then, and beside it how it
/// played then: where every layer was after a tap, a drag and a pinch.
@Suite struct MigrationTests {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/v2")

    static let names = [
        "Camera", "Card", "Controls", "HoverButton", "List", "LiveList", "People",
        "PinchZoom", "SearchList", "Sheet", "SignIn", "StickyHeader", "SwipeMenu",
    ]

    /// Plays a fixed set of touches and writes down every layer's place after each.
    static func playback(_ document: Document) -> String {
        let runtime = Runtime(document: document)
        let frame = 1.0 / 60.0
        var lines: [String] = []

        func note(_ title: String) {
            lines.append("# \(title)")
            func walk(_ layer: ResolvedLayer, depth: Int) {
                func r(_ value: Double) -> String { String(format: "%.2f", value == 0 ? 0 : value) }
                let origin = layer.origin
                lines.append([
                    String(repeating: " ", count: depth) + layer.id.uuidString.prefix(8), "\(layer.instance)",
                    r(origin.x), r(origin.y), r(layer.size.width), r(layer.size.height),
                    r(layer.opacity), r(layer.scale), r(layer.rotation),
                ].joined(separator: " "))
                layer.children.forEach { walk($0, depth: depth + 1) }
            }
            walk(runtime.resolved, depth: 0)
        }
        func drag(from: Point2, to: Point2) {
            runtime.send(.touchDown(from))
            runtime.tick(dt: frame)
            for step in 1...8 {
                let t = Double(step) / 8
                runtime.send(.touchMoved(Point2(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)))
                runtime.tick(dt: frame)
            }
            runtime.send(.touchUp(to))
            runtime.tick(dt: frame)
        }

        runtime.advance(seconds: 0.5)
        note("start")
        for point in [Point2(x: 195, y: 420), Point2(x: 195, y: 200), Point2(x: 195, y: 700)] {
            runtime.send(.touchDown(point))
            runtime.tick(dt: frame)
            runtime.send(.touchUp(point))
            runtime.advance(seconds: 0.4)
            note("tap \(Int(point.y))")
        }
        drag(from: Point2(x: 195, y: 600), to: Point2(x: 195, y: 300))
        runtime.advance(seconds: 0.1)
        note("drag up")
        drag(from: Point2(x: 300, y: 420), to: Point2(x: 100, y: 420))
        runtime.advance(seconds: 0.6)
        note("drag left")
        runtime.send(.hover(Point2(x: 195, y: 410)))
        runtime.advance(seconds: 0.3)
        note("hover")
        runtime.send(.pinchBegan(Point2(x: 195, y: 420)))
        runtime.tick(dt: frame)
        runtime.send(.pinchChanged(scale: 1.6, rotation: 20))
        runtime.tick(dt: frame)
        note("pinch")
        runtime.send(.pinchEnded)
        runtime.advance(seconds: 1)
        note("end")
        return lines.joined(separator: "\n") + "\n"
    }

    @Test(arguments: names) func aVersionTwoDocumentPlaysAsItDid(name: String) throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("\(name).json"))
        let document = try Document.decode(from: data)
        let played = Self.playback(document)
        // Recorded with the last version that ran version 2 documents as they were saved.
        // Two were recorded again since, for one line each: List and StickyHeader, when
        // scroll views began to follow a finger from where it leaves the slop (ten points
        // after it lands) and not from where it lands, so the same drag scrolls ten less.
        // Text began to be measured at the weight it is drawn with (medium and semibold
        // were measured as regular and bold), so in Controls, List, People, SearchList,
        // StickyHeader and SwipeMenu a label and what a stack places after it are a point
        // or two narrower or wider. Those six were recorded again for that.
        // `TANGO_V2_PLAYBACK_OUT=<folder>` writes how each plays now, to compare.
        if let folder = ProcessInfo.processInfo.environment["TANGO_V2_PLAYBACK_OUT"] {
            try played.write(toFile: "\(folder)/\(name).frames.txt", atomically: true, encoding: .utf8)
        }
        let expected = Self.fixtures.appendingPathComponent("\(name).frames.txt")
        #expect(try String(contentsOf: expected, encoding: .utf8) == played)
    }

    @Test(arguments: names) func aVersionTwoDocumentBecomesViewsAsPatches(name: String) throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("\(name).json"))
        let document = try Document.decode(from: data)
        #expect(document.version == Document.currentVersion)

        func check(_ root: Layer, _ graph: Graph) {
            // No patch of the old kinds is left, and every layer has exactly one view patch.
            #expect(!graph.nodes.contains { $0.kind == PatchKind.layerProperty || $0.kind == PatchKind.component })
            let views = graph.nodes.filter { $0.kind == PatchKind.view }
            #expect(views.compactMap(\.layerID).sorted { $0.uuidString < $1.uuidString }
                == root.flattened.map(\.id).sorted { $0.uuidString < $1.uuidString })
            // Every cable still ends on a port its patch has.
            let registry = PatchRegistry.standard.with(components: document.components)
            for connection in graph.connections {
                #expect(registry.canConnect(from: connection.from, to: connection.to, in: graph), "\(name): \(connection)")
            }
        }
        check(document.screen, document.graph)
        for component in document.components { check(component.root, component.graph) }

        // Saved again it opens as the same document: the upgrade happens once.
        let again = try Document.decode(from: document.encoded())
        #expect(again == document)
    }
}
