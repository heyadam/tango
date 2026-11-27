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

    /// The whole Weather in 3D screen in a storm, its heaviest state: soft clouds, a
    /// thousand raindrops, lightning, bloom, the sky shader and the glass card.
    @Test func theWeatherInAStormIsDrawnInsideAFrame() throws {
        try #require(LayerRenderer.drawsScenes)
        let milliseconds = try Self.storm()
        if ProcessInfo.processInfo.environment["SCENE_PERF"] != nil {
            print("SCENE_PERF weather in a storm \(milliseconds) ms")
            if ProcessInfo.processInfo.environment["SCENE_PERF_PARTS"] != nil {
                let example = SampleDocuments.weatherScene()
                func without(_ change: (inout PaperModel.Document) -> Void) throws -> Double {
                    var document = example.document
                    change(&document)
                    return try Self.storm(document, example: example)
                }
                print("SCENE_PERF storm without rays", try without { $0.screen.update(example.stage) { $0.scene?.values["rayTracing"] = .bool(false) } })
                print("SCENE_PERF storm without rain", try without { $0.screen.update(example.stage) { $0.scene?.objects.removeAll { $0.id == "rain" } } })
                print("SCENE_PERF storm without card", try without { doc in doc.screen.children.removeAll { $0.name == "Forecast" } })
                print("SCENE_PERF storm without sky", try without { doc in doc.screen.children.removeAll { $0.name == "Sky" } })
            }
        }
        #expect(milliseconds < 150)
    }

    static func storm(_ document: PaperModel.Document? = nil, example given: SampleDocuments.WeatherScene? = nil) throws -> Double {
        let example = given ?? SampleDocuments.weatherScene()
        let runtime = Runtime(document: document ?? example.document)
        let renderer = LayerRenderer()
        renderer.contentsScale = 2
        renderer.rootLayer.bounds = CGRect(x: 0, y: 0, width: 402, height: 874)
        let models = WeatherModels.assets
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("weather-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, data) in models { try data.write(to: folder.appendingPathComponent(name)) }
        renderer.modelURL = { folder.appendingPathComponent($0) }
        runtime.tick(dt: 1.0 / 60)
        let sunday = try #require(runtime.resolved.find(example.days[3]))
        let middle = Point2(x: sunday.position.x + sunday.size.width / 2, y: sunday.position.y + sunday.size.height / 2)
        runtime.send(.touchDown(middle))
        runtime.tick(dt: 1.0 / 60)
        runtime.send(.touchUp(middle))
        for _ in 0..<180 {
            runtime.tick(dt: 1.0 / 60)
            renderer.render(runtime.resolved)
        }
        let start = CACurrentMediaTime()
        for _ in 0..<90 {
            runtime.tick(dt: 1.0 / 60)
            renderer.render(runtime.resolved)
        }
        return (CACurrentMediaTime() - start) / 90 * 1000
    }
}
