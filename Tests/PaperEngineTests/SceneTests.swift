import Foundation
import Testing
import PaperModel
import simd
@testable import PaperEngine

/// Scene views (the spec's "3D: a scene layer"): what a scene stores, the ports it gives
/// its view's patch, and how values reach it.
@Suite struct SceneTests {
    let frame = 1.0 / 60.0

    func document(_ scene: SceneUse) -> (Document, Layer) {
        var view = Layer.new(.scene)
        view.scene = scene
        var screen = Layer.new(.screen)
        screen.children = [view]
        return (Document(screen: screen), view)
    }

    @Test func aSceneViewIsAViewWithAScene() throws {
        let view = Layer.new(.scene)
        #expect(view.kind == .view && view.type == .scene)
        #expect(view.scene?.objects.map(\.shape) == [.roundedBox])
        // It can hold views and arrange them, like a shader view.
        #expect(view.kind.canHaveChildren)
        #expect(view.applicable.contains(.layout))
        var plain = view
        plain.scene = nil
        #expect(plain.type == .view)
    }

    @Test func theSceneAndEveryObjectGiveThePatchInputs() throws {
        let ball = SceneObject(id: "ball", name: "Ball", shape: .sphere)
        let (document, view) = document(SceneUse(objects: [ball]))
        let node = try #require(document.graph.viewNode(layer: view.id))
        #expect(node.scene == [SceneEntry(id: "ball", name: "Ball")])
        let ports = PatchRegistry.standard.ports(for: node)
        #expect(ports.input("scene.cameraYaw")?.name == "Camera Yaw")
        #expect(ports.input("scene.environment")?.options == SceneUse.environments)
        #expect(ports.input("scene.ball.rotationY")?.name == "Ball Rotation Y")
        #expect(ports.input("scene.ball.color")?.type == .color)
        #expect(ports.input("scene.ball.visible")?.type == .bool)
        #expect(ports.input("scene.nobody.x") == nil)
        // Every one of them is a port id that reads back as what it names.
        for port in ports.inputs where port.id.hasPrefix(SceneUse.portPrefix) {
            let key = try #require(SceneUse.key(port: port.id))
            #expect(key.port == port.id)
            #expect(view.scene?.input(for: key) != nil)
        }
        #expect(SceneUse.key(port: "opacity") == nil)
        #expect(SceneUse.key(port: "scene.a.b.c") == nil)
    }

    @Test func cablesAndStoredValuesReachTheScene() throws {
        var ball = SceneObject(id: "ball", name: "Ball", shape: .sphere)
        ball.values["metalness"] = .number(1)
        let (made, view) = document(SceneUse(objects: [ball], values: ["exposure": .number(2)]))
        var document = made
        let node = try #require(document.graph.viewNode(layer: view.id))
        let turn = document.graph.add(PatchNode(kind: "value", inputs: ["value": .number(40)]))
        let yaw = document.graph.add(PatchNode(kind: "value", inputs: ["value": .number(-25)]))
        let from = PortRef(node: turn, port: "value"), to = PortRef(node: node.id, port: "scene.ball.rotationY")
        #expect(PatchRegistry.standard.canConnect(from: from, to: to, in: document.graph))
        document.graph.connect(from: from, to: to)
        document.graph.connect(from: PortRef(node: yaw, port: "value"), to: PortRef(node: node.id, port: "scene.cameraYaw"))

        let runtime = Runtime(document: document)
        runtime.tick(dt: frame)
        let scene = try #require(runtime.resolved.find(view.id)?.scene)
        #expect(scene.object("ball")?.number("rotationY") == 40)
        #expect(scene.object("ball")?.number("metalness") == 1)
        #expect(scene.number("cameraYaw") == -25)
        #expect(scene.number("exposure") == 2)
        // What is stored is untouched, and a scene at rest asks for no frame.
        #expect(runtime.document.screen.find(view.id)?.scene?.object("ball")?.values["rotationY"] == nil)
        runtime.tick(dt: frame)
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func aCableKeepsItsObjectThroughARenameAndGoesWithIt() throws {
        let ball = SceneObject(id: "ball", name: "Ball", shape: .sphere)
        let (made, view) = document(SceneUse(objects: [ball, SceneObject(id: "box", name: "Box", shape: .box)]))
        var document = made
        let node = try #require(document.graph.viewNode(layer: view.id))
        let value = document.graph.add(PatchNode(kind: "value", inputs: ["value": .number(2)]))
        document.graph.connect(from: PortRef(node: value, port: "value"), to: PortRef(node: node.id, port: "scene.ball.scale"))

        document.screen.update(view.id) { $0.scene?.objects[0].name = "Planet" }
        document.normalize()
        PatchRegistry.standard.settlePublished(in: &document)
        let renamed = try #require(document.graph.viewNode(layer: view.id))
        #expect(PatchRegistry.standard.ports(for: renamed).input("scene.ball.scale")?.name == "Planet Scale")
        #expect(document.graph.connections.count == 1)

        document.screen.update(view.id) { $0.scene?.objects.removeFirst() }
        document.normalize()
        PatchRegistry.standard.settlePublished(in: &document)
        #expect(document.graph.connections.isEmpty)
        // Settling again changes nothing.
        let settled = document
        document.normalize()
        PatchRegistry.standard.settlePublished(in: &document)
        #expect(document == settled)
    }

    @Test func aSceneIsSavedAndReadBack() throws {
        var ball = SceneObject(id: "ball", name: "Ball", shape: .model, model: "ball.usdz")
        ball.values["color"] = .color(ColorValue(red: 1, green: 0, blue: 0))
        let (document, view) = document(SceneUse(objects: [ball], values: ["environment": .text("Sunset")]))
        let read = try JSONDecoder().decode(Document.self, from: JSONEncoder().encode(document))
        #expect(read == document)
        #expect(read.screen.find(view.id)?.scene?.object("ball")?.model == "ball.usdz")
        // A file with a shape this app does not know, and nothing else, still opens.
        let odd = try JSONDecoder().decode(SceneUse.self, from: Data(#"{"objects":[{"id":"a","shape":"teapot"}]}"#.utf8))
        #expect(odd.objects.first?.shape == .box)
        #expect(odd.number("cameraDistance") == 3)
    }

    @Test func whatCannotBeStoredIsNot() {
        var scene = SceneUse(objects: [
            SceneObject(id: "same", shape: .box), SceneObject(id: "same", shape: .sphere), SceneObject(id: "a.b", shape: .cone),
        ])
        scene.values["cameraYaw"] = .number(.infinity)
        scene.objects[0].values["x"] = .number(.nan)
        scene.settleStoredValues()
        #expect(scene.values["cameraYaw"] == nil)
        #expect(scene.objects[0].values["x"] == nil)
        #expect(Set(scene.objects.map(\.id)).count == 3)
        #expect(scene.objects.allSatisfy { $0.id.allSatisfy { $0.isLetter || $0.isNumber } })
        // A value of the wrong type, or for nothing that is there, is not stored.
        scene.set(.number(.infinity), for: SceneUse.Key(input: "exposure"))
        scene.set(.number(4), for: SceneUse.Key(object: "nobody", input: "x"))
        scene.set(.number(4), for: SceneUse.Key(input: "nothing"))
        #expect(scene.values.isEmpty)
        scene.set(.number(4), for: SceneUse.Key(object: "same", input: "x"))
        #expect(scene.object("same")?.number("x") == 4)
    }

    // MARK: Shapes and the camera

    @Test func everyShapeIsSoundAndFitsItsBox() throws {
        for shape in SceneObject.Shape.particleShapes {
            let mesh = try #require(SceneMesh.shape(shape), "\(shape)")
            #expect(mesh.isSound, "\(shape)")
            #expect(mesh.triangleCount > 0 && mesh.triangleCount < 20_000, "\(shape)")
            let bounds = try #require(mesh.bounds)
            #expect(simd_reduce_min(bounds.low) >= -0.5001 && simd_reduce_max(bounds.high) <= 0.5001, "\(shape)")
            #expect(simd_reduce_max(bounds.high - bounds.low) > 0.99, "\(shape)")
            for normal in mesh.normals { #expect(abs(simd_length(normal) - 1) < 0.001, "\(shape)") }
        }
        #expect(SceneMesh.shape(.model) == nil)
    }

    @Test func everyTriangleFacesTheWayItsNormalsDo() throws {
        for shape in SceneObject.Shape.particleShapes {
            let mesh = try #require(SceneMesh.shape(shape))
            var wrong = 0, counted = 0
            for index in stride(from: 0, to: mesh.indices.count, by: 3) {
                let (a, b, c) = (Int(mesh.indices[index]), Int(mesh.indices[index + 1]), Int(mesh.indices[index + 2]))
                let face = simd_cross(mesh.positions[b] - mesh.positions[a], mesh.positions[c] - mesh.positions[a])
                // A triangle at a pole has no area and so no side.
                guard simd_length(face) > 1e-7 else { continue }
                counted += 1
                if simd_dot(face, mesh.normals[a] + mesh.normals[b] + mesh.normals[c]) <= 0 { wrong += 1 }
            }
            #expect(wrong == 0 && counted > 0, "\(shape): \(wrong) of \(counted)")
        }
    }

    @Test func theCameraLooksAtTheMiddleFromWhereItsAnglesSay() throws {
        var scene = SceneUse()
        let size = Size2(width: 200, height: 100)
        let middle = try #require(SceneMath.screenPoint(SIMD3(0, 0, 0), in: scene, size: size))
        #expect(abs(middle.x - 100) < 0.01 && abs(middle.y - 50) < 0.01)
        // From the front and level: right is right and up is up.
        scene.values["cameraPitch"] = .number(0)
        let right = try #require(SceneMath.screenPoint(SIMD3(0.5, 0, 0), in: scene, size: size))
        let up = try #require(SceneMath.screenPoint(SIMD3(0, 0.5, 0), in: scene, size: size))
        #expect(right.x > 100 && abs(right.y - 50) < 0.01)
        #expect(up.y < 50 && abs(up.x - 100) < 0.01)
        // Yaw 90 stands to the right: what was nearest (+z) is now on the left.
        scene.values["cameraYaw"] = .number(90)
        let near = try #require(SceneMath.screenPoint(SIMD3(0, 0, 0.5), in: scene, size: size))
        #expect(near.x < 100)
        // The field of view is across the shorter side, whichever that is.
        scene.values["cameraYaw"] = .number(0)
        let wide = try #require(SceneMath.screenPoint(SIMD3(0, 0.5, 0), in: scene, size: Size2(width: 300, height: 100)))
        let tall = try #require(SceneMath.screenPoint(SIMD3(0.5, 0, 0), in: scene, size: Size2(width: 100, height: 300)))
        #expect(abs((50 - wide.y) - (tall.x - 50)) < 0.01)
        // Behind the camera there is nothing to show.
        #expect(SceneMath.screenPoint(SIMD3(0, 0, 10), in: scene, size: size) == nil)
    }

    @Test func numbersNoMatrixCanHoldAreMadeSafe() {
        var scene = SceneUse(objects: [SceneObject(id: "a", shape: .box, values: [
            "x": .number(1e300), "scale": .number(-5), "rotationY": .number(.greatestFiniteMagnitude),
        ])])
        scene.values = ["cameraDistance": .number(0), "fieldOfView": .number(1e9), "cameraPitch": .number(400)]
        let all = [SceneMath.view(of: scene), SceneMath.projection(of: scene, aspect: 0), SceneMath.placement(of: scene.objects[0])]
        for matrix in all {
            for column in 0..<4 { for row in 0..<4 { #expect(matrix[column][row].isFinite) } }
        }
    }

    @Test func aModelOfAnySizeIsFittedToOneUnit() {
        let fit = SceneMesh.fitting(low: SIMD3(10, 20, 30), high: SIMD3(14, 28, 32))
        let low = fit * SIMD4(10, 20, 30, 1), high = fit * SIMD4(14, 28, 32, 1)
        #expect(abs(high.y - low.y - 1) < 1e-5)
        #expect(abs(low.x + 0.25) < 1e-5 && abs(high.z - 0.125) < 1e-5)
        #expect(SceneMesh.fitting(low: SIMD3(1, 1, 1), high: SIMD3(1, 1, 1)) == matrix_identity_float4x4)
    }

    @Test func lightOfItsOwnFollowsTheColorUntilItIsGivenOne() throws {
        var ball = SceneObject(id: "ball", name: "Ball", shape: .sphere, values: ["color": .color(ColorValue(red: 1, green: 0, blue: 0))])
        #expect(ball.number("emission") == 0)
        #expect(ball.value("emissionColor") == .color(ColorValue(red: 1, green: 0, blue: 0)))
        ball.values["emissionColor"] = .color(.white)
        #expect(ball.value("emissionColor") == .color(.white))
        // Both are ports, and so is the scene's bloom.
        let (document, view) = document(SceneUse(objects: [ball]))
        let node = try #require(document.graph.viewNode(layer: view.id))
        let ports = PatchRegistry.standard.ports(for: node)
        #expect(ports.input("scene.ball.emission")?.type == .number)
        #expect(ports.input("scene.ball.emissionColor")?.type == .color)
        #expect(ports.input("scene.bloom")?.type == .number)
        // A file from before has neither, and reads with the defaults.
        let old = #"{"objects":[{"id":"ball","name":"Ball","shape":"sphere","values":{}}],"values":{}}"#
        let read = try JSONDecoder().decode(SceneUse.self, from: Data(old.utf8))
        #expect(read.number("bloom") == 0 && read.objects[0].number("emission") == 0)
    }

    @Test func eachAxisFollowsTheScaleUntilItIsSet() throws {
        var ball = SceneObject(id: "ball", name: "Ball", shape: .sphere, values: ["scale": .number(2)])
        #expect(SceneMath.size(of: ball) == SIMD3(2, 2, 2))
        ball.values["scaleY"] = .number(0.5)
        #expect(SceneMath.size(of: ball) == SIMD3(2, 0.5, 2))
        // Along its own axes: turned a quarter round z, its height lies along x.
        ball.values["rotationZ"] = .number(90)
        let top = SceneMath.placement(of: ball) * SIMD4<Float>(0, 0.5, 0, 1)
        #expect(abs(top.x + 0.25) < 1e-5 && abs(top.y) < 1e-5)
        // A size that is not a number is made safe, and each is a port.
        ball.values["scaleX"] = .number(.infinity)
        #expect(SceneMath.size(of: ball).x.isFinite)
        let (document, view) = document(SceneUse(objects: [ball]))
        let node = try #require(document.graph.viewNode(layer: view.id))
        #expect(PatchRegistry.standard.ports(for: node).input("scene.ball.scaleZ")?.name == "Ball Scale Z")
    }

    @Test func anEmitterHasInputsOfItsOwnThatOtherThingsDoNot() throws {
        let rain = SceneObject(id: "rain", name: "Rain", shape: .particles)
        #expect(SceneObject.Shape(named: "Particles") == .particles)
        #expect(SceneObject.Shape.builtIn.contains(.particles) && !SceneObject.Shape.particleShapes.contains(.particles))
        let own = Set(SceneObject.inputs(for: .particles).map(\.id))
        #expect(own.isSuperset(of: ["count", "time", "spreadX", "velocityY", "size", "stretch", "sway", "particle", "seed"]))
        #expect(!SceneObject.inputs(for: .sphere).contains { $0.id == "count" })
        #expect(rain.value("particle") == .text("Sphere") && rain.number("count") == 300)
        // Its inputs are ports, so a Time patch can drive it.
        let (document, view) = document(SceneUse(objects: [rain]))
        let node = try #require(document.graph.viewNode(layer: view.id))
        #expect(PatchRegistry.standard.ports(for: node).input("scene.rain.time")?.name == "Rain Time")
        // It has no mesh of its own: it draws copies of another shape.
        #expect(SceneMesh.shape(.particles) == nil)
    }
}
