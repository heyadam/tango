import Foundation
import Testing
import PaperModel
@testable import PaperEngine

/// The Product in 3D example does what its hint says.
@Suite struct ProductSceneExampleTests {
    let frame = 1.0 / 60.0

    func scene(_ runtime: Runtime, _ example: SampleDocuments.ProductScene) -> SceneUse {
        runtime.resolved.find(example.stage)!.scene!
    }

    @Test func aDragCirclesTheSpeakerAndLettingGoBringsItHome() {
        let example = SampleDocuments.productScene()
        let runtime = Runtime(document: example.document)
        runtime.settle(within: 2)
        #expect(scene(runtime, example).number("cameraYaw") == 0)
        #expect(!runtime.needsAnotherFrame)

        // A drag of 120 points to the right across the stage.
        let start = Point2(x: 140, y: 360)
        runtime.send(.touchDown(start))
        runtime.tick(dt: frame)
        for step in 1...24 {
            runtime.send(.touchMoved(Point2(x: start.x + Double(step) * 5, y: start.y)))
            runtime.tick(dt: frame)
        }
        runtime.advance(seconds: 0.3)
        // The camera goes the other way round, so the speaker turns with the finger; the
        // first ten points are the slop a pan leaves before it begins.
        let turned = scene(runtime, example).number("cameraYaw")
        #expect(turned < -45 && turned > -62, "\(turned)")

        runtime.send(.touchUp(Point2(x: start.x + 120, y: start.y)))
        runtime.advance(seconds: 0.2)
        #expect(scene(runtime, example).number("cameraYaw") > turned)
        runtime.settle(within: 5)
        #expect(abs(scene(runtime, example).number("cameraYaw")) < 0.05)
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func aSwatchGivesTheBodyItsFinish() {
        let example = SampleDocuments.productScene()
        let runtime = Runtime(document: example.document)
        runtime.settle(within: 2)
        typealias P = SampleDocuments.ProductScene
        func body() -> Value { scene(runtime, example).object(P.body)!.value("color") }
        #expect(body() == .color(P.finishes[0]))
        for index in [1, 2, 0] {
            let swatch = runtime.resolved.find(example.swatches[index])!
            let middle = Point2(x: swatch.position.x + swatch.size.width / 2, y: swatch.position.y + swatch.size.height / 2)
            runtime.send(.touchDown(middle))
            runtime.tick(dt: frame)
            runtime.send(.touchUp(middle))
            runtime.settle(within: 2)
            #expect(body() == .color(P.finishes[index]), "\(index)")
        }
        // The band keeps its metal whatever the finish.
        #expect(scene(runtime, example).object(P.band)?.number("metalness") == 1)
    }
}
