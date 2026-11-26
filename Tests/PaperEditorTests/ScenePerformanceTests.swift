import AppKit
import Foundation
import PaperEngine
import PaperModel
import PaperRender
import QuartzCore
import Testing
@testable import PaperEditor

/// What a frame of a scene costs while it moves. `SCENE_PERF=1` prints the numbers; the
/// test itself only holds a generous ceiling, so a slow machine does not fail it.
@MainActor
@Suite struct ScenePerformanceTests {
    /// The Product example with its camera turned by the clock, so every frame is drawn anew.
    static func turning(rays: Bool, objects: Int = 0) throws -> PaperModel.Document {
        let example = SampleDocuments.productScene()
        var document = example.document
        document.screen.update(example.stage) { view in
            view.scene?.values["rayTracing"] = .bool(rays)
            for index in 0..<objects {
                view.scene?.objects.append(SceneObject(id: "extra\(index)", shape: .sphere, values: [
                    "scale": .number(0.2), "x": .number(Double(index % 8) * 0.25 - 0.9), "y": .number(0.9), "z": .number(Double(index / 8) * 0.25 - 0.5),
                    "metalness": .number(1), "roughness": .number(0.1),
                ]))
            }
        }
        document.normalize()
        let node = try #require(document.graph.viewNode(layer: example.stage))
        let port = PortRef(node: node.id, port: SceneUse.portID("cameraYaw"))
        document.graph.disconnect(input: port)
        let clock = document.graph.add(PatchNode(kind: "time"))
        let speed = document.graph.add(PatchNode(kind: "multiply", inputs: ["b": .number(40)]))
        document.graph.connect(from: PortRef(node: clock, port: "time"), to: PortRef(node: speed, port: "a"))
        document.graph.connect(from: PortRef(node: speed, port: "result"), to: port)
        return document
    }

    static func milliseconds(_ document: PaperModel.Document, frames: Int = 90) -> Double {
        let runtime = Runtime(document: document)
        let renderer = LayerRenderer()
        renderer.contentsScale = 2
        renderer.rootLayer.bounds = CGRect(x: 0, y: 0, width: 402, height: 874)
        // The first frames compile and build; they are not what a moving scene costs.
        for _ in 0..<5 {
            runtime.tick(dt: 1.0 / 60)
            renderer.render(runtime.resolved)
        }
        let start = CACurrentMediaTime()
        for _ in 0..<frames {
            runtime.tick(dt: 1.0 / 60)
            renderer.render(runtime.resolved)
        }
        return (CACurrentMediaTime() - start) / Double(frames) * 1000
    }

    @Test func aMovingSceneIsDrawnWellInsideAFrame() throws {
        try #require(LayerRenderer.drawsScenes)
        let plain = Self.milliseconds(try Self.turning(rays: false))
        let traced = Self.milliseconds(try Self.turning(rays: true))
        let crowded = Self.milliseconds(try Self.turning(rays: true, objects: 32))
        if ProcessInfo.processInfo.environment["SCENE_PERF"] != nil {
            print("SCENE_PERF plain \(plain) ms, traced \(traced) ms, traced with 32 more \(crowded) ms")
        }
        #expect(plain < 50 && traced < 100 && crowded < 150)
    }
}
