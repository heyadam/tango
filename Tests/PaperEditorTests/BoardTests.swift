import CoreGraphics
import Foundation
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

/// Where screens sit on the Canvas, and what the Canvas draws in each frame.
@MainActor
@Suite struct BoardTests {
    func document(pages: [String]) -> Document {
        let children = pages.map { name -> Layer in
            var page = Layer.newPage(name: name)
            page.children = [Layer(name: "\(name) Button", kind: .view, properties: [.position: .point(Point2(x: 10, y: 20))])]
            return page
        }
        return Document(screen: Layer(name: "Screen", kind: .screen, properties: [.size: .size(Size2(width: 400, height: 800))], children: children))
    }

    @Test func aDocumentWithoutScreensIsOneFrame() {
        let plain = document(pages: [])
        let board = Board(plain)
        #expect(board.frames.count == 1)
        #expect(board.frames[0].id == plain.screen.id && !board.frames[0].isPage)
        #expect(board.frames[0].rect == CGRect(x: 0, y: 0, width: 400, height: 800))
    }

    @Test func screensSitSideBySideInOrder() {
        let made = document(pages: ["A", "B", "C"])
        let board = Board(made)
        #expect(board.frames.map(\.name) == ["A", "B", "C"])
        #expect(board.frames[1].rect.minX == 400 + Board.gap)
        #expect(board.bounds.width == 3 * 400 + 2 * Board.gap)
        #expect(board.index(at: CGPoint(x: 400 + Board.gap / 2, y: 10)) == nil)
        #expect(board.index(at: CGPoint(x: 400 + Board.gap + 10, y: 10)) == 1)
        #expect(board.nearestIndex(to: CGPoint(x: 5000, y: -40)) == 2)
        // A view is in its screen's frame; a point goes there and back.
        let button = made.screen.children[2].children[0].id
        #expect(board.index(holding: button, in: made) == 2)
        let there = board.boardPoint(CGPoint(x: 10, y: 20), inFrame: 2)
        #expect(there.x == 2 * (400 + Board.gap) + 10)
        #expect(board.screenPoint(there, inFrame: 2) == CGPoint(x: 10, y: 20))
    }

    @Test func eachFrameShowsItsOwnScreenFillingTheDevice() {
        let made = document(pages: ["A", "B"])
        let resolved = CanvasView.resolve(made)
        // At rest every screen is there, unlike in the running prototype.
        #expect(resolved.children.count == 2)
        let trees = CanvasView.trees(of: resolved, on: Board(made))
        #expect(trees.map { $0.children.map(\.name) } == [["A"], ["B"]])
        #expect(trees[1].children[0].frame == CGRect(x: 0, y: 0, width: 400, height: 800))
    }

    @Test func aDraggedViewLinesUpWithItsNeighborsAndItsContainer() {
        let other = CGRect(x: 100, y: 300, width: 80, height: 40)
        let size = CGSize(width: 400, height: 800)
        // Three points off the other's left edge, and nowhere near anything vertically.
        let near = Snapping.snap(CGRect(x: 103, y: 500, width: 50, height: 50), to: [other], in: size, threshold: 6)
        #expect(near.dx == -3 && near.linesX == [100])
        #expect(near.dy == 0 && near.linesY.isEmpty)
        // The middle of the container.
        let centered = Snapping.snap(CGRect(x: 172, y: 500, width: 50, height: 50), to: [], in: size, threshold: 6)
        #expect(centered.dx == 3 && centered.linesX == [200])
        // Too far from everything: left alone.
        #expect(Snapping.snap(CGRect(x: 30, y: 500, width: 50, height: 50), to: [other], in: size, threshold: 6) == Snapping.Result())
    }

    @Test func aViewDraggedInAStackGoesAfterTheSiblingsWhoseMiddleItPassed() {
        // A short row above a tall one.
        let rows = [CGRect(x: 0, y: 0, width: 200, height: 40), CGRect(x: 0, y: 40, width: 200, height: 120)]
        #expect(Snapping.place(of: CGPoint(x: 50, y: 45), among: rows, dragged: 0, flow: .vertical) == 0)
        #expect(Snapping.place(of: CGPoint(x: 50, y: 101), among: rows, dragged: 0, flow: .vertical) == 1)
        // Once they have changed places it stays put under the same pointer.
        let swapped = [CGRect(x: 0, y: 0, width: 200, height: 120), CGRect(x: 0, y: 120, width: 200, height: 40)]
        #expect(Snapping.place(of: CGPoint(x: 50, y: 101), among: swapped, dragged: 1, flow: .vertical) == 1)
        // A grid reads in rows.
        let cells = [CGRect(x: 0, y: 0, width: 90, height: 90), CGRect(x: 100, y: 0, width: 90, height: 90), CGRect(x: 0, y: 100, width: 90, height: 90)]
        #expect(Snapping.place(of: CGPoint(x: 150, y: 50), among: cells, dragged: 0, flow: .grid) == 1)
        #expect(Snapping.place(of: CGPoint(x: 60, y: 150), among: cells, dragged: 0, flow: .grid) == 2)
        #expect(Snapping.place(of: .zero, among: [], dragged: 0, flow: .vertical) == nil)
    }

    @Test func anArrowLeavesTheSideThatFacesItsScreen() {
        let right = CanvasView.arrow(from: CGRect(x: 0, y: 100, width: 50, height: 20), to: CGRect(x: 300, y: 0, width: 200, height: 400))
        #expect(right.tip == CGPoint(x: 300, y: 110) && right.angle == 0)
        let left = CanvasView.arrow(from: CGRect(x: 600, y: 100, width: 50, height: 20), to: CGRect(x: 300, y: 0, width: 200, height: 400))
        #expect(left.tip.x == 500 && left.angle == .pi)
        // Round underneath, it comes up into the bottom.
        let under = CanvasView.arrowUnder(from: CGRect(x: 0, y: 100, width: 50, height: 20), to: CGRect(x: 900, y: 0, width: 200, height: 400), below: 400)
        #expect(under.tip == CGPoint(x: 1000, y: 400))
        #expect(under.path.boundingBoxOfPath.maxY > 400)
    }
}
