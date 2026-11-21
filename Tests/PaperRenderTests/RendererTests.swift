import Foundation
import QuartzCore
import Testing
import PaperEngine
import PaperModel
@testable import PaperRender

@MainActor
@Suite struct RendererTests {
    @Test func layersAreReusedAndReorderedInPlace() {
        let a = Layer(name: "A", kind: .view, properties: [.position: .point(Point2(x: 10, y: 20)), .size: .size(Size2(width: 30, height: 40))])
        let b = Layer(name: "B", kind: .ellipse)
        var screen = Layer(kind: .screen, children: [a, b])
        let renderer = LayerRenderer()
        renderer.render(ResolvedLayer(screen))
        let first = renderer.layer(for: a.id)!
        #expect(first.bounds.size == CGSize(width: 30, height: 40))
        #expect(first.position == CGPoint(x: 25, y: 40))
        #expect(renderer.layer(for: b.id) is CAShapeLayer)
        #expect(renderer.layer(for: screen.id)?.sublayers?.count == 2)

        screen.children = [b, a]
        renderer.render(ResolvedLayer(screen))
        #expect(renderer.layer(for: a.id) === first)
        #expect(renderer.layer(for: screen.id)?.sublayers?.last === first)

        screen.children = [b]
        renderer.render(ResolvedLayer(screen))
        #expect(renderer.layer(for: a.id) == nil)
    }
}
