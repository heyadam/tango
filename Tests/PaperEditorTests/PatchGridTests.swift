import CoreGraphics
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

@MainActor
@Suite struct PatchGridTests {
    @Test func snappingRoundsToTheNearestUnit() {
        #expect(PatchGrid.snap(5) == 0)
        #expect(PatchGrid.snap(7) == 12)
        #expect(PatchGrid.snap(-7) == -12)
        #expect(PatchGrid.snap(Point2(x: 61, y: 130)) == Point2(x: 60, y: 132))
    }

    @Test func newPatchesLandOnTheGrid() {
        let store = DocumentStore()
        let first = store.addPatch("switch", at: Point2(x: 47, y: 93))
        let second = store.addPatch("spring")
        for id in [first, second] {
            let position = store.document.graph.node(id)!.position
            #expect(position == PatchGrid.snap(position))
        }
    }

    /// The point of the grid: with patches on it, every port is on it too, so a cable
    /// between two ports at the same height is a straight line.
    @Test func portsOfAPatchOnTheGridAreOnTheGrid() {
        let registry = PatchRegistry.standard
        let unit = CGFloat(PatchGrid.unit)
        let plain = PatchNode(kind: "spring", position: Point2(x: 120, y: 240))
        let attached = PatchNode.interaction(on: LayerID(), position: Point2(x: 120, y: 240))
        for node in [plain, attached] {
            let layout = PatchLayout(node: node, ports: registry.ports(for: node))
            let centers = layout.ports.inputs.indices.map(layout.inputPort) + layout.ports.outputs.indices.map(layout.outputPort)
            #expect(!centers.isEmpty)
            for center in centers {
                #expect(center.x.truncatingRemainder(dividingBy: unit) == 0)
                #expect(center.y.truncatingRemainder(dividingBy: unit) == 0)
            }
            #expect(layout.size.height.truncatingRemainder(dividingBy: unit) == 0)
        }
    }

    @Test func sampleGraphsSitOnTheGrid() {
        let documents = Gallery.items.map { $0.make() }
        for document in documents {
            let graphs = [document.graph] + document.components.map(\.graph)
            for node in graphs.flatMap(\.nodes) { #expect(node.position == PatchGrid.snap(node.position)) }
        }
    }

    @Test func beadsAreSpacedEvenlyAlongACable() {
        let cable = PatchEditorView.Cable(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 300, y: 120))
        #expect(cable.point(at: 0) == cable.from)
        #expect(cable.point(at: 1) == cable.to)
        let beads = cable.points(every: 30, offset: 10)
        #expect(beads.count >= 10)
        for (a, b) in zip(beads, beads.dropFirst()) {
            // Measured straight across a curve, so a little under the spacing.
            let gap = hypot(b.x - a.x, b.y - a.y)
            #expect(gap > 27 && gap <= 30.5)
        }
        // Moving the offset moves every bead toward the input.
        let later = cable.points(every: 30, offset: 20)
        #expect(later[0].x > beads[0].x)
    }
}
