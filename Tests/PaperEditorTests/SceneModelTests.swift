import AppKit
import Foundation
import ModelIO
import PaperEngine
import PaperHost
import PaperModel
import PaperRender
import Testing
import simd
@testable import PaperEditor

/// Model files in scene views: read through Model I/O from the document's assets, fitted
/// to one unit, and never able to stop the app.
@MainActor
@Suite struct SceneModelTests {
    static var cube: Data {
        get throws {
            try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fixtures/models/cube.obj"))
        }
    }

    static func document(model: String, values: [String: Value] = [:]) -> PaperModel.Document {
        var all = values
        all["rotationY"] = all["rotationY"] ?? .number(0)
        return SceneViewTests.document([SceneObject(id: "thing", name: "Thing", shape: .model, model: model, values: all)])
    }

    /// How many of the view's pixels are not the white behind it.
    static func drawn(_ picture: NSBitmapImageRep?) -> Int {
        var count = 0
        for x in stride(from: 21, to: 119, by: 2) {
            for y in stride(from: 31, to: 149, by: 2) where !ShaderViewTests.near(ShaderViewTests.color(picture, x, y), [255, 255, 255]) { count += 1 }
        }
        return count
    }

    @Test func aModelFromTheAssetsIsDrawnFittedToOneUnit() throws {
        try #require(LayerRenderer.drawsScenes)
        let document = Self.document(model: "cube.obj", values: ["color": .color(SceneViewTests.red)])
        let picture = ViewerSnapshot.bitmap(of: document, assets: ["cube.obj": try Self.cube])
        SceneViewTests.keep(picture, "model-obj")
        // The file's cube is four units across and a hundred away: it shows as one unit, in the middle.
        #expect(SceneViewTests.isMostly(0, try SceneViewTests.color(picture, at: SIMD3(0, 0, 0.5), in: document)))
        #expect(SceneViewTests.isMostly(0, try SceneViewTests.color(picture, at: SIMD3(0.42, 0.42, 0.5), in: document)))
        #expect(ShaderViewTests.near(try SceneViewTests.color(picture, at: SIMD3(0.62, 0, 0.5), in: document), [255, 255, 255]))
        // It had no normals of its own: its front is lit, not black.
        #expect(try SceneViewTests.color(picture, at: SIMD3(0, 0, 0.5), in: document)[0] > 120)
    }

    @Test func aUSDFileKeepsTheColorItsMaterialGives() throws {
        try #require(LayerRenderer.drawsScenes)
        let kind = ["usdz", "usdc", "usda"].first { MDLAsset.canExportFileExtension($0) }
        let type = try #require(kind, "Model I/O writes no USD here")
        let mesh = MDLMesh(sphereWithExtent: SIMD3(2, 2, 2), segments: SIMD2(24, 24), inwardNormals: false, geometryType: .triangles, allocator: nil)
        let material = MDLMaterial(name: "green", scatteringFunction: MDLPhysicallyPlausibleScatteringFunction())
        material.setProperty(MDLMaterialProperty(name: "baseColor", semantic: .baseColor, float3: SIMD3(0, 1, 0)))
        for case let submesh as MDLSubmesh in mesh.submeshes ?? [] { submesh.material = material }
        let asset = MDLAsset()
        asset.add(mesh)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tango-scene-test-\(UUID().uuidString).\(type)")
        defer { try? FileManager.default.removeItem(at: url) }
        try asset.export(to: url)
        let name = "ball.\(type)"
        let document = Self.document(model: name)
        let picture = ViewerSnapshot.bitmap(of: document, assets: [name: try Data(contentsOf: url)])
        SceneViewTests.keep(picture, "model-usd")
        #expect(Self.drawn(picture) > 300)
        // Nothing is set on the object, so the file's own green shows; set, the object's wins.
        #expect(SceneViewTests.isMostly(1, try SceneViewTests.color(picture, at: SIMD3(0, 0, 0.5), in: document)))
        let painted = Self.document(model: name, values: ["color": .color(SceneViewTests.blue)])
        let again = ViewerSnapshot.bitmap(of: painted, assets: [name: try Data(contentsOf: url)])
        #expect(SceneViewTests.isMostly(2, try SceneViewTests.color(again, at: SIMD3(0, 0, 0.5), in: painted)))
    }

    @Test func aFileThatIsNotAModelDrawsNothingAndStopsNothing() throws {
        try #require(LayerRenderer.drawsScenes)
        let whole = try Self.cube
        let files: [String: Data] = [
            "cut.obj": whole.prefix(whole.count / 3), "empty.obj": Data(), "words.obj": Data("f 1 2 3\nf 9 9 9\nv nan inf 1e400\n".utf8),
            "noise.usdz": Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 131) }), "picture.png": Data([0x89, 0x50, 0x4E, 0x47]),
            "faces.obj": Data("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\nf 1 2 400000000\nf -9 0 2\n".utf8),
        ]
        for name in files.keys.sorted() + ["missing.usdz"] {
            let picture = ViewerSnapshot.bitmap(of: Self.document(model: name), assets: files)
            #expect(picture != nil, "\(name)")
        }
        // What cannot be drawn says why.
        let renderer = LayerRenderer()
        renderer.modelURL = { VideoFiles.assetURL(for: $0, assets: files) }
        #expect(renderer.modelProblem("missing.usdz")?.contains("no file") == true)
        #expect(renderer.modelProblem("picture.png") != nil)
        #expect(renderer.modelProblem("empty.obj") != nil)
        renderer.modelURL = { VideoFiles.assetURL(for: $0, assets: ["cube.obj": whole]) }
        #expect(renderer.modelProblem("cube.obj") == nil)
    }

    @Test func aModelIsFoundByRaysLikeAShape() throws {
        try #require(LayerRenderer.tracesRays)
        let floor = SceneObject(id: "floor", shape: .plane, values: ["scale": .number(3), "y": .number(-0.5), "color": .color(.white), "roughness": .number(1)])
        let cube = SceneObject(id: "cube", shape: .model, model: "cube.obj", values: ["scale": .number(0.5), "x": .number(0.6), "color": .color(SceneViewTests.red)])
        let document = SceneViewTests.document([floor, cube], values: [
            "cameraPitch": .number(60), "lightPitch": .number(89), "exposure": .number(0.5),
        ])
        let picture = ViewerSnapshot.bitmap(of: document, assets: ["cube.obj": try Self.cube])
        SceneViewTests.keep(picture, "model-shadow")
        // Just in front of the cube, where it stands on nothing: its shadow on the floor.
        let shaded = try SceneViewTests.color(picture, at: SIMD3(0.6, -0.5, 0.2), in: document)
        let open = try SceneViewTests.color(picture, at: SIMD3(-0.6, -0.5, 0.2), in: document)
        #expect(shaded[0] + 20 < open[0], "\(shaded) against \(open)")
    }
}
