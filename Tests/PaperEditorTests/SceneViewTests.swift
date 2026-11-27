import AppKit
import Foundation
import PaperEngine
import PaperModel
import PaperRender
import Testing
import simd
@testable import PaperEditor

/// Scene views as they are drawn: Metal with depth, under the views inside the view.
/// `SCENE_TEST_PICTURES=<folder>` keeps the pictures, to look at.
@MainActor
@Suite struct SceneViewTests {
    static let size = Size2(width: 100, height: 120)
    static let origin = Point2(x: 20, y: 30)

    /// A 200 × 200 white screen with one scene view at 20, 30, 100 × 120: not the same
    /// distance from the top as from the bottom, so a picture upside down is found out.
    static func document(_ objects: [SceneObject], values: [String: Value] = [:], children: [Layer] = []) -> PaperModel.Document {
        var view = Layer.new(.scene, name: "Scene")
        var all = values
        if all["cameraPitch"] == nil { all["cameraPitch"] = .number(0) }
        view.scene = SceneUse(objects: objects, values: all)
        view.properties[.position] = .point(origin)
        view.properties[.size] = .size(size)
        view.children = children
        var screen = Layer.new(.screen)
        screen.properties[.size] = .size(Size2(width: 200, height: 200))
        screen.children = [view]
        return PaperModel.Document(screen: screen)
    }

    static func ball(_ id: String, _ color: ColorValue, at place: SIMD3<Double> = .zero, scale: Double = 1) -> SceneObject {
        SceneObject(id: id, name: id, shape: .sphere, values: [
            "x": .number(place.x), "y": .number(place.y), "z": .number(place.z), "scale": .number(scale), "color": .color(color),
        ])
    }

    static let red = ColorValue(red: 1, green: 0, blue: 0), green = ColorValue(red: 0, green: 1, blue: 0)
    static let blue = ColorValue(red: 0, green: 0, blue: 1)

    /// The color at the place on the screen where a point of the scene shows.
    static func color(_ bitmap: NSBitmapImageRep?, at point: SIMD3<Float>, in document: PaperModel.Document) throws -> [Int] {
        let scene = try #require(document.screen.children.first?.scene)
        let spot = try #require(SceneMath.screenPoint(point, in: scene, size: size))
        return ShaderViewTests.color(bitmap, Int((origin.x + spot.x).rounded()), Int((origin.y + spot.y).rounded()))
    }

    static func keep(_ bitmap: NSBitmapImageRep?, _ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["SCENE_TEST_PICTURES"], let data = bitmap?.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
    }

    static let white = [255, 255, 255]

    static func isMostly(_ channel: Int, _ color: [Int]) -> Bool {
        color.count == 3 && color.indices.allSatisfy { $0 == channel || color[channel] > color[$0] + 60 }
    }

    @Test func aSceneIsDrawnOverTheViewsFillAndClearRoundItsObjects() throws {
        try #require(ShaderCompiler.shared != nil)
        let document = Self.document([Self.ball("ball", Self.red)])
        let picture = ViewerSnapshot.bitmap(of: document)
        Self.keep(picture, "sphere")
        #expect(Self.isMostly(0, try Self.color(picture, at: SIMD3(0, 0, 0.5), in: document)))
        // Round the ball the view is clear: the white screen shows, inside the view and out.
        #expect(ShaderViewTests.near(ShaderViewTests.color(picture, 23, 33), Self.white))
        #expect(ShaderViewTests.near(ShaderViewTests.color(picture, 117, 147), Self.white))
        #expect(ShaderViewTests.near(ShaderViewTests.color(picture, 10, 10), Self.white))
    }

    @Test func upIsUpAndRightIsRight() throws {
        try #require(ShaderCompiler.shared != nil)
        let document = Self.document([
            Self.ball("up", Self.green, at: SIMD3(0, 0.6, 0), scale: 0.4), Self.ball("right", Self.blue, at: SIMD3(0.5, 0, 0), scale: 0.4),
        ])
        let picture = ViewerSnapshot.bitmap(of: document)
        Self.keep(picture, "directions")
        #expect(Self.isMostly(1, try Self.color(picture, at: SIMD3(0, 0.6, 0.2), in: document)))
        #expect(Self.isMostly(2, try Self.color(picture, at: SIMD3(0.5, 0, 0.2), in: document)))
        #expect(ShaderViewTests.near(try Self.color(picture, at: SIMD3(0, -0.6, 0), in: document), Self.white))
        #expect(ShaderViewTests.near(try Self.color(picture, at: SIMD3(-0.5, 0, 0), in: document), Self.white))
    }

    @Test func theNearerThingHidesTheOneBehindWhicheverIsDrawnFirst() throws {
        try #require(ShaderCompiler.shared != nil)
        for nearFirst in [true, false] {
            let near = Self.ball("near", Self.red, at: SIMD3(0, 0, 0.6), scale: 0.3)
            let far = Self.ball("far", Self.green, at: SIMD3(0, 0, -0.6), scale: 0.9)
            let document = Self.document(nearFirst ? [near, far] : [far, near])
            let picture = ViewerSnapshot.bitmap(of: document)
            Self.keep(picture, "depth-\(nearFirst)")
            #expect(Self.isMostly(0, try Self.color(picture, at: SIMD3(0, 0, 0.75), in: document)))
            // Past the edge of the small one, the large one behind it shows.
            #expect(Self.isMostly(1, try Self.color(picture, at: SIMD3(0.33, 0, -0.6), in: document)))
        }
    }

    @Test func turningTheCameraMovesWhatIsInFrontOfIt() throws {
        try #require(ShaderCompiler.shared != nil)
        let front = Self.ball("front", Self.red, at: SIMD3(0, 0, 0.6), scale: 0.4)
        let ahead = Self.document([front])
        #expect(Self.isMostly(0, ShaderViewTests.color(ViewerSnapshot.bitmap(of: ahead), 70, 90)))
        // From the right, what was in front is on the left.
        let side = Self.document([front], values: ["cameraYaw": .number(90)])
        let picture = ViewerSnapshot.bitmap(of: side)
        Self.keep(picture, "yaw")
        #expect(ShaderViewTests.near(ShaderViewTests.color(picture, 70, 90), Self.white))
        let scene = try #require(side.screen.children.first?.scene)
        let spot = try #require(SceneMath.screenPoint(SIMD3(0.2, 0, 0.6), in: scene, size: Self.size))
        #expect(spot.x < 50)
        #expect(Self.isMostly(0, try Self.color(picture, at: SIMD3(0.2, 0, 0.6), in: side)))
    }

    @Test func theViewsInsideAreDrawnOverTheScene() throws {
        try #require(ShaderCompiler.shared != nil)
        var label = Layer.new(.view, name: "Label")
        label.properties[.position] = .point(Point2(x: 40, y: 50))
        label.properties[.size] = .size(Size2(width: 20, height: 20))
        label.properties[.fill] = .color(.black)
        let document = Self.document([Self.ball("ball", Self.red)], children: [label])
        let picture = ViewerSnapshot.bitmap(of: document)
        #expect(ShaderViewTests.near(ShaderViewTests.color(picture, 70, 90), [0, 0, 0]))
        #expect(Self.isMostly(0, ShaderViewTests.color(picture, 70, 115)))
    }

    @Test func aCableTurnsWhatIsDrawn() throws {
        try #require(ShaderCompiler.shared != nil)
        var document = Self.document([Self.ball("ball", Self.red, at: SIMD3(0, 0, 0.6), scale: 0.4)])
        let view = try #require(document.screen.children.first)
        let node = try #require(document.graph.viewNode(layer: view.id))
        let value = document.graph.add(PatchNode(kind: "value", inputs: ["value": .number(-0.3)]))
        document.graph.connect(from: PortRef(node: value, port: "value"), to: PortRef(node: node.id, port: "scene.ball.y"))
        let picture = ViewerSnapshot.bitmap(of: document)
        #expect(ShaderViewTests.near(ShaderViewTests.color(picture, 70, 90 - 25), Self.white))
        #expect(Self.isMostly(0, try Self.color(picture, at: SIMD3(0, -0.3, 0.8), in: document)))
    }

    @Test func everyShapeAndSurroundingIsDrawn() throws {
        try #require(ShaderCompiler.shared != nil)
        for shape in SceneObject.Shape.builtIn {
            let object = SceneObject(id: "a", shape: shape, values: ["rotationX": .number(25), "rotationY": .number(30), "color": .color(Self.red)])
            let document = Self.document([object], values: ["cameraPitch": .number(20)])
            let picture = ViewerSnapshot.bitmap(of: document)
            Self.keep(picture, "shape-\(shape.rawValue)")
            // Something of it is on the picture: some pixel in the view is far from white.
            var drawn = 0
            for x in stride(from: 25, to: 115, by: 3) {
                for y in stride(from: 35, to: 145, by: 3) where Self.isMostly(0, ShaderViewTests.color(picture, x, y)) { drawn += 1 }
            }
            #expect(drawn > 20, "\(shape)")
        }
        for name in SceneUse.environments {
            let metal = SceneObject(id: "a", shape: .sphere, values: ["metalness": .number(1), "roughness": .number(0.1), "color": .color(.white)])
            let picture = ViewerSnapshot.bitmap(of: Self.document([metal], values: ["environment": .text(name)]))
            Self.keep(picture, "around-\(name)")
            #expect(!ShaderViewTests.near(ShaderViewTests.color(picture, 70, 90), Self.white) || name == "Studio", "\(name)")
        }
    }

    @Test func numbersNoPictureCanBeMadeFromDrawNothingAndStopNothing() throws {
        try #require(ShaderCompiler.shared != nil)
        let odd = SceneObject(id: "a", shape: .box, values: ["scale": .number(0), "x": .number(1e300)])
        let huge = SceneObject(id: "b", shape: .torus, values: ["scale": .number(1e9), "rotationX": .number(1e200)])
        let document = Self.document([odd, huge], values: ["cameraDistance": .number(0), "fieldOfView": .number(-4), "exposure": .number(1e30)])
        #expect(ViewerSnapshot.bitmap(of: document) != nil)
    }

    // MARK: Rays

    /// A white floor with a ball over it, lit from straight above and seen from above.
    static func ballOverFloor(rays: Bool) -> PaperModel.Document {
        let floor = SceneObject(id: "floor", shape: .plane, values: ["scale": .number(3), "y": .number(-0.5), "color": .color(.white), "roughness": .number(1)])
        let ball = SceneObject(id: "ball", shape: .sphere, values: ["scale": .number(0.5), "x": .number(0.6), "color": .color(red)])
        return document([floor, ball], values: [
            "cameraPitch": .number(60), "lightPitch": .number(89), "lightYaw": .number(0), "rayTracing": .bool(rays), "exposure": .number(0.5),
        ])
    }

    @Test func aThingCastsAShadowWhenRaysAreTraced() throws {
        try #require(LayerRenderer.tracesRays)
        // Under the ball, on the floor: beside it the same floor in the light.
        let under = SIMD3<Float>(0.6, -0.5, 0.15), beside = SIMD3<Float>(-0.6, -0.5, 0.15)
        let traced = Self.ballOverFloor(rays: true)
        let picture = ViewerSnapshot.bitmap(of: traced)
        Self.keep(picture, "shadow")
        let shaded = try Self.color(picture, at: under, in: traced), open = try Self.color(picture, at: beside, in: traced)
        #expect(shaded[0] + 20 < open[0], "\(shaded) against \(open)")

        let plain = Self.ballOverFloor(rays: false)
        let flat = ViewerSnapshot.bitmap(of: plain)
        Self.keep(flat, "shadow-none")
        let unshaded = try Self.color(flat, at: under, in: plain)
        #expect(ShaderViewTests.near(unshaded, try Self.color(flat, at: beside, in: plain)))
    }

    @Test func aMirrorShowsTheThingBesideItWhenRaysAreTraced() throws {
        try #require(LayerRenderer.tracesRays)
        func document(rays: Bool) -> PaperModel.Document {
            let mirror = SceneObject(id: "mirror", shape: .sphere, values: [
                "x": .number(-0.35), "scale": .number(0.7), "metalness": .number(1), "roughness": .number(0.05), "color": .color(.white),
            ])
            let ball = SceneObject(id: "ball", shape: .sphere, values: ["x": .number(0.45), "scale": .number(0.6), "color": .color(Self.red)])
            return Self.document([mirror, ball], values: ["rayTracing": .bool(rays), "cameraDistance": .number(2.4)])
        }
        // The side of the mirror that faces the red ball.
        let spot = SIMD3<Float>(-0.35 + 0.35 * 0.8, 0, 0.35 * 0.6)
        let traced = document(rays: true)
        let picture = ViewerSnapshot.bitmap(of: traced)
        Self.keep(picture, "mirror")
        #expect(Self.isMostly(0, try Self.color(picture, at: spot, in: traced)))
        let plain = document(rays: false)
        #expect(!Self.isMostly(0, try Self.color(ViewerSnapshot.bitmap(of: plain), at: spot, in: plain)))
    }

    @Test func theSamePictureEveryTime() throws {
        try #require(ShaderCompiler.shared != nil)
        let document = Self.ballOverFloor(rays: true)
        let first = ViewerSnapshot.bitmap(of: document)?.representation(using: .png, properties: [:])
        let second = ViewerSnapshot.bitmap(of: document)?.representation(using: .png, properties: [:])
        #expect(first != nil && first == second)
    }

    // MARK: Light of its own, and bloom

    /// The scene view on black, so light that spills off a thing can be seen.
    static func dark(_ objects: [SceneObject], values: [String: Value] = [:]) -> PaperModel.Document {
        var document = Self.document(objects, values: values)
        document.screen.children[0].properties[.fill] = .color(.black)
        return document
    }

    static func brightness(_ color: [Int]) -> Int { color.reduce(0, +) }

    @Test func aThingWithLightOfItsOwnIsBrighterThanItsColor() throws {
        try #require(ShaderCompiler.shared != nil)
        var ball = Self.ball("ball", ColorValue(red: 0.7, green: 0.12, blue: 0.08))
        let unlit = Self.dark([ball], values: ["environment": .text("Night"), "lightIntensity": .number(0)])
        ball.values["emission"] = .number(3)
        let lit = Self.dark([ball], values: ["environment": .text("Night"), "lightIntensity": .number(0)])
        let before = try Self.color(ViewerSnapshot.bitmap(of: unlit), at: SIMD3(0, 0, 0.5), in: unlit)
        let after = try Self.color(ViewerSnapshot.bitmap(of: lit), at: SIMD3(0, 0, 0.5), in: lit)
        #expect(Self.brightness(after) > Self.brightness(before) + 150, "\(before) \(after)")
        // Its light is in its own color: still mostly red.
        #expect(Self.isMostly(0, after))
        // A color of its own for the light wins over its color.
        ball.values["emissionColor"] = .color(Self.blue)
        let blue = Self.dark([ball], values: ["environment": .text("Night"), "lightIntensity": .number(0)])
        #expect(Self.isMostly(2, try Self.color(ViewerSnapshot.bitmap(of: blue), at: SIMD3(0, 0, 0.5), in: blue)))
    }

    @Test func bloomSpillsBrightLightOntoWhatIsRoundItOnlyWhenAsked() throws {
        try #require(ShaderCompiler.shared != nil)
        var ball = Self.ball("ball", ColorValue(red: 1, green: 0.8, blue: 0.4), scale: 0.5)
        ball.values["emission"] = .number(6)
        let plain = Self.dark([ball])
        let blooming = Self.dark([ball], values: ["bloom": .number(1.5)])
        let still = ViewerSnapshot.bitmap(of: plain), glowing = ViewerSnapshot.bitmap(of: blooming)
        Self.keep(glowing, "bloom")
        // Just outside the ball: black without bloom, lit with it.
        let beside = SIMD3<Float>(0, 0.38, 0)
        #expect(Self.brightness(try Self.color(still, at: beside, in: plain)) < 30)
        #expect(Self.brightness(try Self.color(glowing, at: beside, in: blooming)) > 90)
        // Far away it is still dark.
        #expect(Self.brightness(ShaderViewTests.color(glowing, 23, 33)) < 30)
        // The same picture every time.
        let again = ViewerSnapshot.bitmap(of: blooming)
        #expect(glowing?.representation(using: .png, properties: [:]) == again?.representation(using: .png, properties: [:]))
    }

    @Test func aGlowingThingLightsWhatIsNearIt() throws {
        try #require(ShaderCompiler.shared != nil)
        let wall = SceneObject(id: "wall", name: "Wall", shape: .box, values: [
            "x": .number(0.3), "scale": .number(0.5), "color": .color(.white), "rotationY": .number(0),
        ])
        var lamp = Self.ball("lamp", ColorValue(red: 1, green: 0.6, blue: 0.2), at: SIMD3(-0.25, 0, 0.6), scale: 0.2)
        let values: [String: Value] = ["environment": .text("Night"), "lightIntensity": .number(0), "rayTracing": .bool(false)]
        let dim = Self.dark([wall, lamp], values: values)
        lamp.values["emission"] = .number(8)
        let bright = Self.dark([wall, lamp], values: values)
        // The front of the wall, which faces the camera and the lamp in front of it.
        let face = SIMD3<Float>(0.2, -0.12, 0.25)
        let before = try Self.color(ViewerSnapshot.bitmap(of: dim), at: face, in: dim)
        let after = try Self.color(ViewerSnapshot.bitmap(of: bright), at: face, in: bright)
        #expect(Self.brightness(after) > Self.brightness(before) + 60, "\(before) \(after)")
        // Warm, as the lamp is.
        #expect(after.count == 3 && after[0] > after[2])
    }
}
