import Foundation
import Testing
import PaperModel
@testable import PaperEngine

/// The Weather in 3D example does what its hint says: a day brings its weather, and a drag
/// tilts the scene and lets go.
@Suite struct WeatherSceneExampleTests {
    typealias W = SampleDocuments.WeatherScene
    let frame = 1.0 / 60.0

    func start() -> (W, Runtime) {
        let example = SampleDocuments.weatherScene()
        let runtime = Runtime(document: example.document)
        runtime.settle(within: 2)
        return (example, runtime)
    }

    func scene(_ runtime: Runtime, _ example: W) -> SceneUse { runtime.resolved.find(example.stage)!.scene! }
    func text(_ runtime: Runtime, _ id: LayerID) -> Value? { runtime.resolved.find(id)?.value(.text) }

    func tap(_ runtime: Runtime, day index: Int, of example: W) {
        let day = runtime.resolved.find(example.days[index])!
        let middle = Point2(x: day.position.x + day.size.width / 2, y: day.position.y + day.size.height / 2)
        runtime.send(.touchDown(middle))
        runtime.tick(dt: frame)
        runtime.send(.touchUp(middle))
        runtime.tick(dt: frame)
    }


    func object(_ id: String, _ runtime: Runtime, _ example: W) -> SceneObject { scene(runtime, example).object(id)! }

    @Test func itOpensOnTodayAndRests() {
        let (example, runtime) = start()
        #expect(!runtime.needsAnotherFrame)
        #expect(text(runtime, example.condition) == .text("Partly Cloudy"))
        #expect(text(runtime, example.temperature) == .text("72°"))
        let stage = scene(runtime, example)
        #expect(stage.object(W.sun)!.number("scale") > 0.7)
        // The sun glows, and the picture blooms round it.
        #expect(stage.object(W.sun)!.number("emission") > 1 && stage.number("bloom") > 0)
        // The clouds are vapor: cloud volumes, as wide as a cumulus.
        #expect([W.cloud, W.backCloud, W.frontCloud].allSatisfy { stage.object($0)!.shape == .cloud })
        #expect(stage.object(W.cloud)!.number("scaleX") > 1.5 && stage.object(W.cloud)!.number("coverage") > 0.4)
        #expect(stage.object(W.rain)!.number("count") == 0 && stage.object(W.snow)!.number("count") == 0)
    }

    @Test func eachDayBringsItsWeather() {
        let (example, runtime) = start()
        for index in [1, 2, 3, 4, 0] {
            tap(runtime, day: index, of: example)
            runtime.advance(seconds: 3)
            let day = W.forecast[index]
            #expect(text(runtime, example.condition) == .text(day.condition), "\(index)")
            #expect(text(runtime, example.temperature) == .text("\(day.temperature)°"), "\(index)")
            #expect(text(runtime, example.range) == .text("H:\(day.high)°  L:\(day.low)°"), "\(index)")
            let stage = scene(runtime, example)
            let sun = stage.object(W.sun)!.number("scale"), cloud = stage.object(W.cloud)!.number("scaleX")
            let rain = stage.object(W.rain)!.number("count"), snow = stage.object(W.snow)!.number("count")
            switch day.condition {
            case "Sunny": #expect(sun > 1 && cloud < 0.01 && rain == 0)
            case "Partly Cloudy": #expect(sun > 0.7 && cloud > 1.5 && rain == 0 && snow == 0)
            case "Snow": #expect(sun < 0.01 && snow > 500 && rain == 0)
            default: #expect(sun < 0.01 && cloud > 1.8 && rain > 500 && snow == 0, "\(day.condition)")
            }
            // A storm piles the cloud up dense and dark; fair weather leaves it light.
            let density = stage.object(W.cloud)!.number("density")
            switch day.condition {
            case "Thunderstorms": #expect(density > 2)
            case "Partly Cloudy": #expect(density < 1.5)
            default: break
            }
            // The pill comes to rest behind the day.
            let pill = runtime.resolved.find(example.pill)!.position.x
            #expect(abs(pill - runtime.resolved.find(example.days[index])!.position.x) < 0.5, "\(index)")
        }
        #expect(scene(runtime, example).value("environment") == .text("Daylight"))
    }

    @Test func rainFallsOnTheClockAndStopsWhenTheSunComesOut() {
        let (example, runtime) = start()
        tap(runtime, day: 2, of: example)
        runtime.advance(seconds: 2)
        #expect(runtime.needsAnotherFrame)
        let before = object(W.rain, runtime, example).number("time")
        runtime.advance(seconds: 0.5)
        let rain = object(W.rain, runtime, example)
        // The emitter's time is the clock's: half a second later it is half a second on.
        #expect(abs(rain.number("time") - before - 0.5) < 0.05)
        #expect(rain.number("count") > 500 && rain.number("size") > 0.01)
        #expect(object(W.snow, runtime, example).number("count") == 0)

        tap(runtime, day: 1, of: example)
        runtime.settle(within: 10)
        #expect(!runtime.needsAnotherFrame)
        #expect(object(W.rain, runtime, example).number("count") == 0)
    }

    @Test func rainAndSnowFallFromTheCloudToJustAboveTheCard() throws {
        let (example, runtime) = start()
        tap(runtime, day: 3, of: example)
        runtime.advance(seconds: 3)
        let stage = scene(runtime, example)
        let size = runtime.resolved.find(example.stage)!.size
        for id in [W.rain, W.snow] {
            let emitter = try #require(stage.object(id))
            let middle = emitter.number("y"), half = emitter.number("spreadY") / 2
            // The bottom of the box it falls through is on screen above the card's top.
            let bottom = try #require(SceneMath.screenPoint(SIMD3(0, Float(middle - half), 0), in: stage, size: size))
            #expect(262 + bottom.y < 620, "\(id) \(bottom)")
            // Its top is inside the cloud's body, so drops come out of the cloud.
            let cloud = try #require(stage.object(W.cloud))
            #expect(middle + half < cloud.number("y") + cloud.number("scaleY") * 0.2)
            #expect(middle + half > cloud.number("y") - cloud.number("scaleY") * 0.5)
        }
    }

    @Test func snowDriftsMoreSlowlyThanRainFalls() {
        let (example, runtime) = start()
        let rain = object(W.rain, runtime, example), snow = object(W.snow, runtime, example)
        #expect(abs(snow.number("velocityY")) * 4 < abs(rain.number("velocityY")))
        #expect(snow.number("sway") > 0 && rain.number("stretch") > 3)
    }

    @Test func aStormFlashesLightningOnceItHasSetIn() {
        let (example, runtime) = start()
        tap(runtime, day: 3, of: example)
        var flashes = 0, early = 0, brightest = 0.0, cloudGlow = 0.0
        for frame in 0..<(60 * 7) {
            runtime.tick(dt: self.frame)
            let stage = scene(runtime, example)
            if stage.object(W.bolt)!.number("scale") > 0 {
                flashes += 1
                if frame < 30 { early += 1 }
                #expect(stage.object(W.bolt)!.number("emission") > 2)
            }
            brightest = max(brightest, stage.number("lightIntensity"))
            cloudGlow = max(cloudGlow, stage.object(W.cloud)!.number("emission"))
        }
        #expect(flashes > 4 && flashes < 60)
        // Not the moment the storm is chosen, while the sky is still clear.
        #expect(early == 0)
        // The flash lights the cloud from inside and brightens the light.
        #expect(cloudGlow > 0.1 && brightest > 4)
        #expect(scene(runtime, example).value("environment") == .text("Night"))
    }

    @Test func aDragTiltsTheWeatherAndItSpringsBack() {
        let (example, runtime) = start()
        let start = Point2(x: 120, y: 420)
        runtime.send(.touchDown(start))
        runtime.tick(dt: frame)
        for step in 1...24 {
            runtime.send(.touchMoved(Point2(x: start.x + Double(step) * 5, y: start.y + Double(step) * 3)))
            runtime.tick(dt: frame)
        }
        runtime.advance(seconds: 0.4)
        #expect(scene(runtime, example).number("cameraYaw") < -20)
        #expect(scene(runtime, example).number("cameraPitch") > 15)
        runtime.send(.touchUp(Point2(x: start.x + 120, y: start.y + 72)))
        runtime.settle(within: 5)
        #expect(abs(scene(runtime, example).number("cameraYaw")) < 0.05)
        #expect(abs(scene(runtime, example).number("cameraPitch") - 6) < 0.05)
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func theModelsAreSoundAndTheExampleCarriesThem() throws {
        for mesh in [WeatherModels.bolt] {
            #expect(mesh.triangles.count > 500)
            #expect(mesh.points.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
            #expect(mesh.triangles.allSatisfy { max($0.x, $0.y, $0.z) < mesh.points.count && min($0.x, $0.y, $0.z) >= 0 })
        }
        let bytes = WeatherModels.assets.values.reduce(0) { $0 + $1.count }
        #expect(bytes < 4_000_000, "\(bytes)")
        let item = try #require(Gallery.items.first { $0.id == "forecast" })
        func scenes(_ layer: Layer) -> [SceneUse] { (layer.scene.map { [$0] } ?? []) + layer.children.flatMap(scenes) }
        let models = scenes(item.make().screen).flatMap(\.objects).compactMap(\.model)
        #expect(Set(models) == Set(item.assets().keys))
    }
}
