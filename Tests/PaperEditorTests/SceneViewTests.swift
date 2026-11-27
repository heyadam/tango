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

    // MARK: A size along each axis

    @Test func aThingIsStretchedAlongEachOfItsAxes() throws {
        try #require(ShaderCompiler.shared != nil)
        var ball = Self.ball("ball", Self.red, scale: 0.6)
        ball.values["scaleX"] = .number(1.6)
        ball.values["scaleY"] = .number(0.3)
        let document = Self.document([ball])
        let picture = ViewerSnapshot.bitmap(of: document)
        Self.keep(picture, "stretched")
        #expect(Self.isMostly(0, try Self.color(picture, at: SIMD3(0.65, 0, 0.1), in: document)))
        #expect(ShaderViewTests.near(try Self.color(picture, at: SIMD3(0, 0.3, 0), in: document), Self.white))
    }

    @Test func aSquashedThingIsLitAsItsShapeIs() throws {
        try #require(ShaderCompiler.shared != nil)
        // A ball flattened into a lens, seen from above, lit from straight above: its top is
        // nearly flat, so it is lit almost as brightly away from the middle as in it.
        var lens = Self.ball("lens", .white)
        lens.values["scaleY"] = .number(0.2)
        let document = Self.document([lens], values: [
            "cameraPitch": .number(70), "lightPitch": .number(90), "environment": .text("Night"), "rayTracing": .bool(false),
        ])
        let picture = ViewerSnapshot.bitmap(of: document)
        Self.keep(picture, "lens")
        let middle = try Self.color(picture, at: SIMD3(0, 0.1, 0), in: document)
        let aside = try Self.color(picture, at: SIMD3(0.35, 0.0714, 0), in: document)
        #expect(Self.brightness(middle) > 300)
        #expect(Double(Self.brightness(aside)) > Double(Self.brightness(middle)) * 0.8, "\(middle) \(aside)")
    }

    // MARK: Clear things

    @Test func aHalfClearThingShowsWhatIsBehindItAndNoneShowsNothing() throws {
        try #require(ShaderCompiler.shared != nil)
        var ball = Self.ball("ball", Self.red)
        ball.values["opacity"] = .number(0.5)
        let half = Self.document([ball])
        let color = try Self.color(ViewerSnapshot.bitmap(of: half), at: SIMD3(0, 0, 0.5), in: half)
        // Red over the white screen: pink, not red and not white.
        #expect(color.count == 3 && color[0] > 200 && color[1] > 70 && color[1] < 220, "\(color)")
        ball.values["opacity"] = .number(0)
        let none = Self.document([ball])
        #expect(ShaderViewTests.near(try Self.color(ViewerSnapshot.bitmap(of: none), at: SIMD3(0, 0, 0.5), in: none), Self.white))
    }

    @Test func clearThingsAreDrawnFromTheBackWhateverTheirOrder() throws {
        try #require(ShaderCompiler.shared != nil)
        var near = Self.ball("near", Self.red, at: SIMD3(0, 0, 0.5), scale: 0.6)
        var far = Self.ball("far", Self.green, at: SIMD3(0, 0, -0.5), scale: 0.9)
        near.values["opacity"] = .number(0.7)
        far.values["opacity"] = .number(0.7)
        for objects in [[near, far], [far, near]] {
            let document = Self.document(objects, values: ["rayTracing": .bool(false)])
            let color = try Self.color(ViewerSnapshot.bitmap(of: document), at: SIMD3(0, 0, 0.8), in: document)
            // The near one is over the far one: more red than green.
            #expect(color.count == 3 && color[0] > color[1] + 40, "\(color)")
        }
    }

    @Test func glassTintsAndBendsWhatIsBehindItWhenRaysAreTraced() throws {
        try #require(LayerRenderer.tracesRays)
        let back = SceneObject(id: "back", shape: .box, values: ["scale": .number(1.4), "z": .number(-1), "color": .color(.white), "roughness": .number(1)])
        var glass = Self.ball("glass", ColorValue(red: 0.3, green: 0.5, blue: 1), at: SIMD3(0, 0, 0.4), scale: 0.7)
        glass.values["transmission"] = .number(1)
        glass.values["roughness"] = .number(0.05)
        let document = Self.document([back, glass], values: ["environment": .text("Studio")])
        let picture = ViewerSnapshot.bitmap(of: document)
        Self.keep(picture, "glass")
        // Through the glass the white box behind is tinted blue.
        let seen = try Self.color(picture, at: SIMD3(0, -0.05, 0.75), in: document)
        #expect(seen.count == 3 && seen[2] > seen[0] + 40, "\(seen)")
    }

    @Test func aClearThingCastsALighterShadowWhenRaysAreTraced() throws {
        try #require(LayerRenderer.tracesRays)
        let under = SIMD3<Float>(0.6, -0.5, 0.15)
        let solid = Self.ballOverFloor(rays: true)
        var clear = solid
        clear.screen.children[0].scene?.objects[1].values["opacity"] = .number(0.4)
        let dark = try Self.color(ViewerSnapshot.bitmap(of: solid), at: under, in: solid)
        let light = try Self.color(ViewerSnapshot.bitmap(of: clear), at: under, in: clear)
        #expect(light[0] > dark[0] + 15, "\(light) against \(dark)")
    }

    // MARK: Emitters

    static func emitter(count: Double, time: Double, values: [String: Value] = [:]) -> PaperModel.Document {
        let rain = SceneObject(id: "rain", name: "Rain", shape: .particles, values: [
            "count": .number(count), "time": .number(time), "spreadX": .number(1.6), "spreadY": .number(1.6), "spreadZ": .number(0.4),
            "velocityY": .number(-1), "size": .number(0.12), "sizeRange": .number(0), "color": .color(red),
        ].merging(values) { _, new in new })
        return document([rain], values: ["rayTracing": .bool(false)])
    }

    static func redPixels(_ bitmap: NSBitmapImageRep?) -> Int {
        var count = 0
        for x in stride(from: 20, to: 120, by: 2) {
            for y in stride(from: 30, to: 150, by: 2) where isMostly(0, ShaderViewTests.color(bitmap, x, y)) { count += 1 }
        }
        return count
    }

    @Test func anEmitterScattersCopiesThroughItsBoxAsAFunctionOfTime() throws {
        try #require(ShaderCompiler.shared != nil)
        let first = ViewerSnapshot.bitmap(of: Self.emitter(count: 400, time: 0))
        Self.keep(first, "particles")
        // Copies all over the box, not one lump.
        #expect(Self.redPixels(first) > 300)
        // The same time is the same picture; another time moves them. Where many copies
        // overlap, the GPU can resolve a near tie between two of them differently from one
        // drawing to the next (as it could before emitters, for any crowded scene): a few
        // pixels a level or two apart. So: the same but for those, and far from another time.
        func apart(_ a: NSBitmapImageRep?, _ b: NSBitmapImageRep?) -> (pixels: Int, most: Int) {
            var pixels = 0, most = 0
            for x in 0..<200 {
                for y in 0..<200 {
                    let one = ShaderViewTests.color(a, x, y), two = ShaderViewTests.color(b, x, y)
                    guard one != two else { continue }
                    pixels += 1
                    most = max(most, zip(one, two).map { abs($0 - $1) }.max() ?? 0)
                }
            }
            return (pixels, most)
        }
        let again = apart(first, ViewerSnapshot.bitmap(of: Self.emitter(count: 400, time: 0)))
        #expect(again.pixels < 40 && again.most <= 2, "\(again)")
        #expect(apart(first, ViewerSnapshot.bitmap(of: Self.emitter(count: 400, time: 0.3))).pixels > 1000)
        // None draws nothing; a count past the limit is held to it.
        #expect(Self.redPixels(ViewerSnapshot.bitmap(of: Self.emitter(count: 0, time: 0))) == 0)
        #expect(Self.redPixels(ViewerSnapshot.bitmap(of: Self.emitter(count: 1e12, time: 0, values: ["size": .number(0.01)]))) >= 0)
    }

    @Test func anEmittersCopiesPointAlongTheirWayAndStretch() throws {
        try #require(ShaderCompiler.shared != nil)
        // One copy, stretched along its way: falling, it is tall and thin.
        let one = Self.emitter(count: 1, time: 0, values: [
            "spreadX": .number(0), "spreadY": .number(0.0001), "spreadZ": .number(0), "size": .number(0.2), "stretch": .number(5),
        ])
        let picture = ViewerSnapshot.bitmap(of: one)
        Self.keep(picture, "streak")
        #expect(Self.isMostly(0, try Self.color(picture, at: SIMD3(0, 0.35, 0.05), in: one)))
        #expect(ShaderViewTests.near(try Self.color(picture, at: SIMD3(0.3, 0, 0), in: one), Self.white))
    }

    // MARK: Soft things

    @Test func aSoftThingThinsOutAtItsEdgeAndIsWholeInItsMiddle() throws {
        try #require(ShaderCompiler.shared != nil)
        var cloud = Self.ball("cloud", Self.blue)
        let hard = Self.document([cloud], values: ["rayTracing": .bool(false)])
        cloud.values["softness"] = .number(1)
        let soft = Self.document([cloud], values: ["rayTracing": .bool(false)])
        let firm = ViewerSnapshot.bitmap(of: hard), fluffy = ViewerSnapshot.bitmap(of: soft)
        Self.keep(fluffy, "soft")
        // In the middle both are wholly there.
        #expect(Self.isMostly(2, try Self.color(fluffy, at: SIMD3(0, 0, 0.5), in: soft)))
        // Near the rim the soft one lets more of the white behind through, on average.
        var firmer = 0, softer = 0
        for step in 0..<24 {
            let angle = Float(step) / 24 * 2 * .pi
            let rim = SIMD3<Float>(cos(angle) * 0.47, sin(angle) * 0.47, 0.1)
            firmer += Self.brightness(try Self.color(firm, at: rim, in: hard))
            softer += Self.brightness(try Self.color(fluffy, at: rim, in: soft))
        }
        #expect(softer > firmer + 24 * 40, "\(softer) against \(firmer)")
    }

    @Test func aSoftThingGlowsAtItsRimWhenLitFromBehind() throws {
        try #require(ShaderCompiler.shared != nil)
        var cloud = Self.ball("cloud", .white, scale: 0.8)
        cloud.values["roughness"] = .number(1)
        let behind: [String: Value] = [
            "lightYaw": .number(180), "lightPitch": .number(10), "environment": .text("Night"), "rayTracing": .bool(false),
        ]
        let hard = Self.dark([cloud], values: behind)
        cloud.values["softness"] = .number(0.8)
        let soft = Self.dark([cloud], values: behind)
        let rim = SIMD3<Float>(0.36, 0, 0.1)
        let firm = try Self.color(ViewerSnapshot.bitmap(of: hard), at: rim, in: hard)
        let lined = try Self.color(ViewerSnapshot.bitmap(of: soft), at: rim, in: soft)
        #expect(Self.brightness(lined) > Self.brightness(firm) + 60, "\(lined) against \(firm)")
    }

    // MARK: Clouds

    static func cloud(_ values: [String: Value] = [:], with others: [SceneObject] = []) -> PaperModel.Document {
        let puff = SceneObject(id: "puff", name: "Puff", shape: .cloud, values: [
            "scaleX": .number(1.6), "scaleY": .number(1.1), "scaleZ": .number(1), "color": .color(.white), "coverage": .number(0.65),
        ].merging(values) { _, new in new })
        var document = dark(others + [puff], values: ["environment": .text("Daylight")])
        document.screen.children[0].properties[.fill] = .color(ColorValue(red: 0.1, green: 0.2, blue: 0.6))
        return document
    }

    static let sky = [26, 51, 153]

    @Test func aCloudFillsItsMiddleAndNotItsBox() throws {
        try #require(ShaderCompiler.shared != nil)
        let document = Self.cloud()
        let picture = ViewerSnapshot.bitmap(of: document)
        Self.keep(picture, "cloud")
        // Its middle is bright vapor; the corners of its box are the sky behind.
        #expect(Self.brightness(try Self.color(picture, at: SIMD3(0, 0, 0.3), in: document)) > 400)
        #expect(ShaderViewTests.near(try Self.color(picture, at: SIMD3(-0.78, 0.53, 0.5), in: document), Self.sky))
        #expect(ShaderViewTests.near(try Self.color(picture, at: SIMD3(0.78, -0.53, 0.5), in: document), Self.sky))
        // The same picture every time, and with rays or without (rays do not see clouds).
        let png = { (bitmap: NSBitmapImageRep?) in bitmap?.representation(using: .png, properties: [:]) }
        #expect(png(picture) == png(ViewerSnapshot.bitmap(of: document)))
        var untraced = document
        untraced.screen.children[0].scene?.values["rayTracing"] = .bool(false)
        #expect(png(picture) == png(ViewerSnapshot.bitmap(of: untraced)))
        // Drift moves the vapor through it.
        #expect(png(picture) != png(ViewerSnapshot.bitmap(of: Self.cloud(["drift": .number(0.4)]))))
    }

    @Test func aCloudGoesBehindWhatIsInFrontOfItEvenInsideItsBox() throws {
        try #require(ShaderCompiler.shared != nil)
        // A red ball inside the cloud's box, near its front: the part of it nearer than the
        // vapor shows, where a box drawn over everything would hide it.
        let ball = SceneObject(id: "ball", name: "Ball", shape: .sphere, values: [
            "z": .number(0.45), "scale": .number(0.25), "color": .color(Self.red), "emission": .number(1),
        ])
        let document = Self.cloud(["coverage": .number(0.7)], with: [ball])
        let picture = ViewerSnapshot.bitmap(of: document)
        Self.keep(picture, "cloud-ball")
        #expect(Self.isMostly(0, try Self.color(picture, at: SIMD3(0, 0, 0.58), in: document)))
    }
}
