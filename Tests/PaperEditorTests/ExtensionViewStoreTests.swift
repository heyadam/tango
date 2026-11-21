import AppKit
import Foundation
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

/// Views an extension draws, as the editor adds them and the renderer shows them.
@MainActor
@Suite struct ExtensionViewStoreTests {
    static func package(script: String, inputs: String = ##"{ "id": "amount", "type": "number", "default": 0.5 }, { "id": "tint", "type": "color", "default": "#FF0000" }"##, files: [String: Data] = [:]) throws -> PaperExtension {
        let manifest = """
        {
          "format": 1, "id": "com.example.charts", "name": "Charts", "version": "1.0.0",
          "views": [
            { "id": "bar", "name": "Bar", "summary": "A bar that fills by an amount.", "draw": "views/bar.js", "size": [120, 24], "inputs": [\(inputs)] },
            { "id": "glow", "name": "Glow", "summary": "A soft glow.", "shader": "shaders/glow.metal" }
          ]
        }
        """
        var all = files
        all[ExtensionManifest.fileName] = Data(manifest.utf8)
        all["views/bar.js"] = Data(script.utf8)
        all["shaders/glow.metal"] = Data("""
        struct Inputs { float strength = 0.5; };
        float4 shader(Frame frame, Inputs in) { return float4(in.strength, 0, 0, 1); }
        """.utf8)
        return try PaperExtension(files: all)
    }

    static let bar = "function draw(canvas, inputs, size) { canvas.fillStyle = inputs.tint; canvas.fillRect(0, 0, size.width * inputs.amount, size.height); }"
    static let kind = "com.example.charts/bar"

    @Test func aViewOfAnExtensionIsAddedAndItsInputsAreSet() throws {
        let package = try Self.package(script: Self.bar)
        let (store, undo) = Fixture.store(registry: Fixture.registry(package))
        let view = try #require(store.registry.view(Self.kind))
        var id: LayerID!
        undo.step { id = store.addExtensionView(view) }
        let layer = try #require(store.document.layer(id))
        #expect(layer.type == .custom)
        #expect(layer.name == "Bar")
        #expect(layer.value(.size).sizeValue == Size2(width: 120, height: 24))
        #expect(layer.custom == CustomViewUse(kind: Self.kind, inputCount: 2))
        let patch = try #require(store.viewNode(for: id))
        #expect(store.subtitle(for: patch) == "Bar")
        // The extension's inputs always show on the patch, after the view's own.
        let ports = store.visiblePorts(for: patch).inputs
        #expect(ports.map(\.id).suffix(2) == ["ext.amount", "ext.tint"])
        #expect(store.literal(for: ports.last!, of: patch) == .color(ColorValue(hex: "#FF0000")!))

        undo.step { store.setLiteral(.number(0.9), node: patch.id, port: "ext.amount") }
        #expect(store.document.layer(id)?.custom?.inputs == ["amount": .number(0.9)])
        #expect(store.literal(for: ports[ports.count - 2], of: store.viewNode(for: id)!) == .number(0.9))
        // It is one undo step.
        undo.undo()
        #expect(store.document.layer(id)?.custom?.inputs.isEmpty == true)
        undo.redo()
        // A value of the wrong type, or for an input there is not, is not stored.
        undo.step { store.setCustomInput("amount", of: id, to: .text("lots")) }
        undo.step { store.setCustomInput("nothing", of: id, to: .number(1)) }
        #expect(store.document.layer(id)?.custom?.inputs == ["amount": .number(0.9)])

        // It is carried with the document like an extension's patch.
        #expect(store.package.carried == [package])
        #expect(store.usedExtensionIDs == ["com.example.charts"])

        // A cable can drive an input.
        var source: NodeID!
        undo.step { source = store.addPatch("add") }
        var connected = false
        undo.step { connected = store.connect(from: PortRef(node: source, port: "result"), to: PortRef(node: patch.id, port: "ext.amount")) }
        #expect(connected)
        undo.step { connected = store.connect(from: PortRef(node: source, port: "result"), to: PortRef(node: patch.id, port: "ext.tint")) }
        #expect(!connected)
    }

    @Test func aCopyKeepsWhatItIsAndChangingItsTypeLetsGo() throws {
        let (store, undo) = Fixture.store(registry: Fixture.registry(try Self.package(script: Self.bar)))
        var id: LayerID!
        undo.step { id = store.addExtensionView(store.registry.view(Self.kind)!) }
        undo.step { store.setCustomInput("amount", of: id, to: .number(0.3)) }
        store.selectedLayers = [id]
        undo.step { store.duplicateSelectedLayers() }
        let copies = store.document.screen.children.filter { $0.custom != nil }
        #expect(copies.count == 2)
        #expect(copies.allSatisfy { $0.custom?.inputs == ["amount": .number(0.3)] })
        #expect(copies.allSatisfy { store.viewNode(for: $0.id)?.custom == Self.kind })

        undo.step { store.convert(id, to: .stack) }
        #expect(store.document.layer(id)?.custom == nil)
        #expect(store.document.layer(id)?.type == .stack)
        #expect(store.viewNode(for: id)?.custom == nil)
        undo.undo()
        #expect(store.document.layer(id)?.type == .custom)
    }

    @Test func aPackagedShaderIsCopiedInAsAnOrdinaryShaderView() throws {
        let package = try Self.package(script: Self.bar)
        let (store, undo) = Fixture.store(registry: Fixture.registry(package))
        let glow = try #require(store.registry.view("com.example.charts/glow"))
        #expect(glow.shader?.contains("strength") == true)
        var id: LayerID!
        undo.step { id = store.addExtensionView(glow) }
        let layer = try #require(store.document.layer(id))
        #expect(layer.type == .shader)
        #expect(layer.custom == nil)
        #expect(layer.shader?.source == glow.shader)
        #expect(store.visiblePorts(for: store.viewNode(for: id)!).inputs.contains { $0.id == "shader.strength" })
        // It is the document's own now: nothing of the extension is needed to open it.
        #expect(store.usedExtensionIDs.isEmpty)
        #expect(store.package.extensions.isEmpty)
        let (elsewhere, _) = Fixture.store(store.package, registry: .standard)
        #expect(elsewhere.document.layer(id)?.shader?.source == glow.shader)
    }

    @Test func withoutTheExtensionTheViewSaysWhatItNeeds() throws {
        let package = try Self.package(script: Self.bar)
        let (store, undo) = Fixture.store(registry: Fixture.registry(package))
        var id: LayerID!
        undo.step { id = store.addExtensionView(store.registry.view(Self.kind)!) }
        let saved = try DocumentPackage(fileWrapper: store.package.fileWrapper())

        let folder = Fixture.Folder()
        let installed = ExtensionStore(directory: folder.url)
        let (bare, bareUndo) = Fixture.store(saved, registry: installed.registry(carrying: saved.carried))
        let patch = try #require(bare.viewNode(for: id))
        #expect(bare.missingExtension(for: patch) == "Charts")
        #expect(bare.subtitle(for: patch) == "Needs Charts")
        #expect(installed.offers(used: bare.usedExtensionIDs, carried: bare.carriedExtensions).map(\.id) == ["com.example.charts"])
        // Its inputs are known from the carried copy, so they still show.
        #expect(bare.visiblePorts(for: patch).inputs.contains { $0.id == "ext.amount" })
        // Edited and saved there, it is still the same view.
        bareUndo.step { bare.setInput(ViewInput(id: "x")!, of: id, to: .number(7)) }
        #expect(bare.package.carried == [package])
        #expect(bare.document.layer(id)?.custom?.kind == Self.kind)
        // A picture of it draws the view empty and does not run the script.
        #expect(ViewerSnapshot.bitmap(of: bare.runtimeDocument, registry: bare.runtimeRegistry) != nil)
    }

    // MARK: Pixels

    /// A 200 × 200 white screen with one drawn view at 20, 20, 100 × 100.
    func picture(_ script: String, files: [String: Data] = [:], fill: ColorValue? = nil, children: [Layer] = []) throws -> NSBitmapImageRep? {
        let package = try Self.package(script: script, files: files)
        var view = Layer.new(.custom, name: "Drawn")
        view.custom = CustomViewUse(kind: Self.kind)
        view.properties[.position] = .point(Point2(x: 20, y: 20))
        view.properties[.size] = .size(Size2(width: 100, height: 100))
        if let fill { view.properties[.fill] = .color(fill) }
        view.children = children
        var screen = Layer.new(.screen)
        screen.properties[.size] = .size(Size2(width: 200, height: 200))
        screen.children = [view]
        let store = DocumentStore(package: DocumentPackage(document: PaperModel.Document(screen: screen)), registry: Fixture.registry(package))
        return ViewerSnapshot.bitmap(of: store.runtimeDocument, registry: store.runtimeRegistry)
    }

    func color(_ bitmap: NSBitmapImageRep?, _ x: Int, _ y: Int) -> [Int] { ShaderViewTests.color(bitmap, x, y) }
    func near(_ a: [Int], _ b: [Int]) -> Bool { ShaderViewTests.near(a, b) }

    @Test func whatIsDrawnAtTheTopLeftShowsAtTheTopLeft() throws {
        let picture = try picture("""
        function draw(canvas, inputs, size) {
          canvas.fillStyle = "#FF0000";
          canvas.fillRect(0, 0, 50, 50);
          canvas.fillStyle = "#0000FF";
          canvas.fillRect(50, 50, 50, 50);
        }
        """)
        #expect(near(color(picture, 30, 30), [255, 0, 0]))
        #expect(near(color(picture, 110, 110), [0, 0, 255]))
        // The other two quarters show what is behind the view.
        #expect(near(color(picture, 110, 30), [255, 255, 255]))
        #expect(near(color(picture, 30, 110), [255, 255, 255]))
        // And nothing is drawn outside it.
        #expect(near(color(picture, 10, 10), [255, 255, 255]))
        #expect(near(color(picture, 150, 150), [255, 255, 255]))
    }

    @Test func arcsTurnClockwiseAndTransformsPlaceWhatFollows() throws {
        let picture = try picture("""
        function draw(canvas, inputs, size) {
          // A quarter of a disc from 0 to a quarter turn: toward the bottom right.
          canvas.fillStyle = "#00FF00";
          canvas.beginPath();
          canvas.moveTo(50, 50);
          canvas.arc(50, 50, 40, 0, Math.PI / 2);
          canvas.closePath();
          canvas.fill();
          // Moved to the top left corner and doubled.
          canvas.save();
          canvas.translate(10, 10);
          canvas.scale(2, 2);
          canvas.fillStyle = "#FF0000";
          canvas.fillRect(0, 0, 10, 10);
          canvas.restore();
          canvas.fillStyle = "#0000FF";
          canvas.fillRect(90, 0, 10, 10);
        }
        """)
        #expect(near(color(picture, 20 + 65, 20 + 65), [0, 255, 0]))
        #expect(near(color(picture, 20 + 35, 20 + 35), [255, 255, 255]))
        #expect(near(color(picture, 20 + 65, 20 + 35), [255, 255, 255]))
        #expect(near(color(picture, 20 + 20, 20 + 20), [255, 0, 0]))
        #expect(near(color(picture, 20 + 28, 20 + 28), [255, 0, 0]))
        #expect(near(color(picture, 20 + 33, 20 + 33), [255, 255, 255]))
        #expect(near(color(picture, 20 + 95, 20 + 5), [0, 0, 255]))
    }

    @Test func theDrawingGoesOverTheFillAndUnderTheViewsInside() throws {
        var square = Layer.new(.view, name: "Square")
        square.properties[.fill] = .color(ColorValue(red: 0, green: 0, blue: 1))
        square.properties[.size] = .size(Size2(width: 30, height: 30))
        let picture = try picture(
            "function draw(canvas) { canvas.fillStyle = 'red'; canvas.fillRect(0, 0, 60, 60); }",
            fill: ColorValue(red: 0, green: 1, blue: 0), children: [square]
        )
        #expect(near(color(picture, 20 + 10, 20 + 10), [0, 0, 255]))
        #expect(near(color(picture, 20 + 45, 20 + 45), [255, 59, 48]))
        #expect(near(color(picture, 20 + 80, 20 + 80), [0, 255, 0]))
    }

    @Test func textGradientsAndPicturesAreDrawnTheRightWayUp() throws {
        // A 2 × 2 picture: red on top, blue below.
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        for x in 0..<2 {
            bitmap.setColor(.red, atX: x, y: 0)
            bitmap.setColor(.blue, atX: x, y: 1)
        }
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let picture = try picture("""
        function draw(canvas, inputs, size) {
          canvas.drawImage("assets/flag.png", 0, 0, 40, 40);
          var gradient = canvas.createLinearGradient(0, 0, 0, 40);
          gradient.addColorStop(0, "#000000");
          gradient.addColorStop(1, "#FFFFFF");
          canvas.fillStyle = gradient;
          canvas.fillRect(60, 0, 40, 40);
          canvas.fillStyle = "#000000";
          canvas.font = "bold 40px sans-serif";
          canvas.textBaseline = "top";
          canvas.fillText("█", 0, 50);
        }
        """, files: ["assets/flag.png": png])
        // The picture's top is at the top.
        #expect(color(picture, 20 + 20, 20 + 6)[0] > 200)
        #expect(color(picture, 20 + 20, 20 + 34)[2] > 200)
        // The gradient runs dark to light downward.
        #expect(color(picture, 20 + 80, 20 + 4)[0] < 60)
        #expect(color(picture, 20 + 80, 20 + 36)[0] > 200)
        // The text is below y = 50 where it was asked for, not mirrored above.
        #expect(near(color(picture, 20 + 12, 20 + 75), [0, 0, 0]))
        #expect(near(color(picture, 20 + 12, 20 + 46), [255, 255, 255]))
    }
}
