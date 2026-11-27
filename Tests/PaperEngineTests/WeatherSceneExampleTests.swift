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

    func heights(_ ids: [String], _ runtime: Runtime, _ example: W) -> [Double] {
        ids.map { scene(runtime, example).object($0)!.number("y") }
    }

    @Test func itOpensOnTodayAndRests() {
        let (example, runtime) = start()
        #expect(!runtime.needsAnotherFrame)
        #expect(text(runtime, example.condition) == .text("Partly Cloudy"))
        #expect(text(runtime, example.temperature) == .text("72°"))
        let stage = scene(runtime, example)
        #expect(stage.object(W.sun)!.number("scale") > 0.8)
        #expect(stage.object(W.cloud)!.number("scale") > 1.5)
        #expect(heights(W.drops, runtime, example).allSatisfy { $0 == W.parked })
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
            let sun = stage.object(W.sun)!.number("scale"), cloud = stage.object(W.cloud)!.number("scale")
            switch day.condition {
            case "Sunny": #expect(sun > 1.1 && cloud < 0.01)
            case "Partly Cloudy": #expect(sun > 0.8 && cloud > 1.5)
            default: #expect(sun < 0.01 && cloud > 1.8, "\(day.condition)")
            }
            // The pill comes to rest behind the day.
            let pill = runtime.resolved.find(example.pill)!.position.x
            #expect(abs(pill - runtime.resolved.find(example.days[index])!.position.x) < 0.5, "\(index)")
        }
        #expect(scene(runtime, example).value("environment") == .text("Daylight"))
    }

    @Test func rainFallsWhileItRainsAndStopsWhenTheSunComesOut() {
        let (example, runtime) = start()
        tap(runtime, day: 2, of: example)
        runtime.advance(seconds: 2)
        #expect(runtime.needsAnotherFrame)
        let first = heights(W.drops, runtime, example)
        let falling = first.filter { $0 != W.parked }
        #expect(falling.count >= 5, "\(first)")
        #expect(falling.allSatisfy { $0 > W.fallsTo && $0 < 1 })
        runtime.advance(seconds: 0.1)
        // Every drop that is falling went down.
        for (before, after) in zip(first, heights(W.drops, runtime, example)) where before != W.parked && after != W.parked {
            #expect(after < before || after > before + 0.5)
        }
        #expect(heights(W.flakes, runtime, example).allSatisfy { $0 == W.parked })

        tap(runtime, day: 1, of: example)
        runtime.settle(within: 10)
        #expect(!runtime.needsAnotherFrame)
        #expect(heights(W.drops, runtime, example).allSatisfy { $0 == W.parked })
    }

    @Test func rainAndSnowShrinkAwayBeforeTheyReachTheCard() {
        let (example, runtime) = start()
        for day in [3, 4] {
            tap(runtime, day: day, of: example)
            for _ in 0..<(60 * 5) {
                runtime.tick(dt: frame)
                for object in scene(runtime, example).objects where object.id.hasPrefix("drop") || object.id.hasPrefix("flake") {
                    let y = object.number("y"), size = object.number("scale")
                    // Nothing below where it is gone, and nothing at full size near the card.
                    #expect(y == W.parked || y >= W.fallsTo, "\(object.id) \(y)")
                    if y != W.parked, y < W.fallsTo + W.fades / 3 { #expect(size < 0.06, "\(object.id) \(size)") }
                }
            }
        }
        // The card starts below where the weather is gone (the scene's middle is 451 points
        // down the screen, about 142 points to a unit).
        #expect(451 - (W.fallsTo) * 142 < 620)
    }

    @Test func snowFallsMoreSlowlyThanRain() {
        let (example, runtime) = start()
        tap(runtime, day: 4, of: example)
        runtime.advance(seconds: 3)
        let before = heights(W.flakes, runtime, example)
        runtime.advance(seconds: 0.5)
        let after = heights(W.flakes, runtime, example)
        let falls = zip(before, after).filter { $0.0 != W.parked && $0.1 != W.parked && $0.1 < $0.0 }.map { $0.0 - $0.1 }
        #expect(!falls.isEmpty)
        #expect(falls.allSatisfy { $0 < 0.5 }, "\(falls)")
        #expect(heights(W.drops, runtime, example).allSatisfy { $0 == W.parked })
    }

    @Test func aStormFlashesLightning() {
        let (example, runtime) = start()
        tap(runtime, day: 3, of: example)
        var flashes = 0, brightest = 0.0
        for _ in 0..<(60 * 7) {
            runtime.tick(dt: frame)
            let stage = scene(runtime, example)
            if stage.object(W.bolt)!.number("scale") > 0 { flashes += 1 }
            brightest = max(brightest, stage.number("exposure"))
        }
        #expect(flashes > 4)
        #expect(brightest > 1.55)
        #expect(scene(runtime, example).value("environment") == .text("Night"))
        // Most of the time the bolt is not there.
        #expect(flashes < 60)
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
        for mesh in [WeatherModels.cloud, WeatherModels.drop, WeatherModels.bolt] {
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
