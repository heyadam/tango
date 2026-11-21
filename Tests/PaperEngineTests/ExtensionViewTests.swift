import Foundation
import Testing
import PaperModel
@testable import PaperEngine

/// Views that an extension draws with a script.
@Suite struct ExtensionViewTests {
    static let barScript = """
    function draw(canvas, inputs, size, time) {
      canvas.fillStyle = inputs.tint;
      canvas.fillRect(0, 0, size.width * inputs.amount, size.height);
      canvas.font = "bold 12px sans-serif";
      canvas.fillText(inputs.label, 4, 14);
    }
    """

    static func package(script: String = barScript, extra: String = "", version: String = "1.0.0") throws -> PaperExtension {
        let manifest = """
        {
          "format": 1, "id": "com.example.charts", "name": "Charts", "version": "\(version)",
          "views": [{
            "id": "bar", "name": "Bar", "summary": "A bar that fills by an amount.", "draw": "views/bar.js", "size": [120, 24],
            "inputs": [
              { "id": "amount", "type": "number", "default": 0.5 },
              { "id": "tint", "type": "color", "default": "#FF0000" },
              { "id": "label", "type": "text", "default": "" }\(extra)
            ]
          }]
        }
        """
        return try PaperExtension(files: [
            ExtensionManifest.fileName: Data(manifest.utf8), "views/bar.js": Data(script.utf8),
            "assets/logo.png": Data([0x89, 0x50]),
        ])
    }

    static let kind = "com.example.charts/bar"

    func registry(_ package: PaperExtension, available: Bool = true) -> PatchRegistry {
        PatchRegistry.standard.adding(available ? ExtensionSet([package]) : ExtensionSet(unavailable: [package]))
    }

    func bar(_ inputs: [String: Value] = [:], size: Size2 = Size2(width: 100, height: 20)) -> Layer {
        var layer = Layer(name: "Bar", kind: .view, properties: [.size: .size(size)])
        layer.custom = CustomViewUse(kind: Self.kind, inputs: inputs, inputCount: 3)
        return layer
    }

    func fills(_ drawing: Drawing?) -> [[Double]] {
        (drawing?.commands ?? []).compactMap { if case let .fillRect(x, y, w, h, _) = $0 { [x, y, w, h] } else { nil } }
    }

    // MARK: What the extension declares

    @Test func aViewIsInTheRegistryAndItsInputsArePortsOfItsPatch() throws {
        let registry = registry(try Self.package())
        let view = try #require(registry.view(Self.kind))
        #expect(view.name == "Bar")
        #expect(view.size == Size2(width: 120, height: 24))
        #expect(view.inputs.map(\.id) == ["amount", "tint", "label"])
        #expect(registry.viewLibrary.map(\.kind) == [Self.kind])
        #expect(try Self.package().problems().isEmpty)

        let layer = bar()
        #expect(layer.type == .custom)
        let document = Document(screen: Layer(kind: .screen, children: [layer]))
        let patch = try #require(document.graph.viewNode(layer: layer.id))
        // The patch knows which view it is without the layer.
        #expect(patch.custom == Self.kind)
        let ports = registry.ports(for: patch).inputs.filter { CustomViewUse.inputName(port: $0.id) != nil }
        #expect(ports.map(\.id) == ["ext.amount", "ext.tint", "ext.label"])
        #expect(ports.map(\.type) == [.number, .color, .text])
        // Without the extension it is a plain view's patch.
        #expect(PatchRegistry.standard.ports(for: patch).inputs.allSatisfy { CustomViewUse.inputName(port: $0.id) == nil })
        #expect(!PatchRegistry.standard.knows(patch))
        #expect(document.usedExtensionIDs == ["com.example.charts"])
        // Saved and read again, it is the same view.
        let again = try Document.decode(from: document.encoded())
        #expect(again.screen.children.first?.custom == layer.custom)
        #expect(again.graph.viewNode(layer: layer.id)?.custom == Self.kind)
    }

    @Test func aProblemInADrawScriptIsFound() throws {
        #expect(try Self.package(script: "function draw( {").problems().contains { $0.contains("views/bar.js") })
        #expect(try Self.package(script: "var x = 1;").problems().contains { $0.contains("draw") })
    }

    // MARK: Drawing

    @Test func theScriptDrawsWithTheViewsValuesAndSize() throws {
        let layer = bar(["amount": .number(0.25), "label": .text("Q1")])
        let runtime = Runtime(document: Document(screen: Layer(kind: .screen, children: [layer])), registry: registry(try Self.package()))
        runtime.tick(dt: 1 / 60)
        let drawing = try #require(runtime.resolved.find(layer.id)?.drawing)
        #expect(fills(drawing) == [[0, 0, 25, 20]])
        guard case let .fillRect(_, _, _, _, style)? = drawing.commands.first else {
            Issue.record("expected a filled rectangle first")
            return
        }
        // The input that was not set has the manifest's default.
        #expect(style.paint == .color(ColorValue(hex: "#FF0000")!))
        #expect(style.alpha == 1)
        guard case let .text(text, x, y, _, font)? = drawing.commands.last else {
            Issue.record("expected text last")
            return
        }
        #expect(text == "Q1")
        #expect([x, y] == [4, 14])
        #expect(font.size == 12)
        #expect(font.weight == 700)
        // Nothing moves, so nothing is drawn again.
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func itIsDrawnAgainOnlyWhenSomethingItUsesChanges() throws {
        var graph = Graph()
        let layer = bar()
        var document = Document(screen: Layer(kind: .screen, children: [layer]), graph: graph)
        graph = document.graph
        let patch = graph.viewNode(layer: layer.id)!.id
        let source = graph.add(PatchNode(kind: "add", inputs: ["a": .number(0.1)]))
        graph.connect(from: PortRef(node: source, port: "result"), to: PortRef(node: patch, port: "ext.amount"))
        document.graph = graph
        let runtime = Runtime(document: document, registry: registry(try Self.package()))
        runtime.tick(dt: 1 / 60)
        let first = try #require(runtime.resolved.find(layer.id)?.drawing)
        #expect(fills(first) == [[0, 0, 10, 20]])
        // The same again: the very same drawing, not one like it.
        runtime.tick(dt: 1 / 60)
        #expect(runtime.resolved.find(layer.id)?.drawing?.stamp == first.stamp)

        // The cable brings another value.
        document.graph.update(source) { $0.inputs["a"] = .number(0.8) }
        runtime.update(document: document)
        runtime.tick(dt: 1 / 60)
        let second = try #require(runtime.resolved.find(layer.id)?.drawing)
        #expect(second.stamp != first.stamp)
        #expect(fills(second) == [[0, 0, 80, 20]])

        // The view gets wider.
        document.screen.update(layer.id) { $0.set(.size, .size(Size2(width: 200, height: 20))) }
        runtime.update(document: document)
        runtime.tick(dt: 1 / 60)
        #expect(fills(runtime.resolved.find(layer.id)?.drawing) == [[0, 0, 160, 20]])
    }

    @Test func aRepeatedViewIsDrawnOncePerItem() throws {
        var document = Document(screen: Layer(kind: .screen, children: [bar()]))
        let layer = document.screen.children[0].id
        let patch = document.graph.viewNode(layer: layer)!.id
        let loop = document.graph.add(PatchNode(kind: "loop", inputs: ["count": .number(3)]))
        let scaled = document.graph.add(PatchNode(kind: "multiply", inputs: ["b": .number(0.25)]))
        document.graph.connect(from: PortRef(node: loop, port: "index"), to: PortRef(node: scaled, port: "a"))
        document.graph.connect(from: PortRef(node: scaled, port: "result"), to: PortRef(node: patch, port: "ext.amount"))
        // As with a shader's inputs, it is a loop on one of the view's own inputs that
        // repeats it; each copy then reads its own value of the extension's.
        document.graph.connect(from: PortRef(node: loop, port: "index"), to: PortRef(node: patch, port: "y"))
        let runtime = Runtime(document: document, registry: registry(try Self.package()))
        runtime.tick(dt: 1 / 60)
        let copies = runtime.resolved.children.filter { $0.id == layer }
        #expect(copies.count == 3)
        #expect(copies.map { fills($0.drawing).first?[2] } == [0, 25, 50])
        #expect(Set(copies.compactMap(\.drawing?.stamp)).count == 3)
    }

    @Test func aViewThatAsksToIsDrawnEveryFrame() throws {
        let script = """
        everyFrame = true;
        function draw(canvas, inputs, size, time) { canvas.fillRect(0, 0, time * 100, 1); }
        """
        let layer = bar()
        let runtime = Runtime(document: Document(screen: Layer(kind: .screen, children: [layer])), registry: registry(try Self.package(script: script)))
        runtime.tick(dt: 0.5)
        #expect(runtime.needsAnotherFrame)
        #expect(fills(runtime.resolved.find(layer.id)?.drawing).first?[2] == 50)
        runtime.tick(dt: 0.5)
        #expect(fills(runtime.resolved.find(layer.id)?.drawing).first?[2] == 100)
    }

    @Test func insideAComponentEvenAsItsRoot() throws {
        // A component whose root is the drawn view, with an input cabled to its amount.
        var root = bar(size: Size2(width: 50, height: 10))
        root.name = "Meter"
        var definition = ComponentDefinition(name: "Meter", root: root, graph: Graph())
        var inner = Document(screen: root)
        let rootPatch = inner.graph.viewNode(layer: root.id)!.id
        let input = inner.graph.add(PatchNode(kind: PatchKind.componentInput, name: "Level", inputs: ["value": .number(0.5)], valueType: .number))
        inner.graph.connect(from: PortRef(node: input, port: "value"), to: PortRef(node: rootPatch, port: "ext.amount"))
        definition.graph = inner.graph

        var first = definition.instance(name: "A")
        first.component?.inputs[input.uuidString] = .number(0.2)
        var second = definition.instance(name: "B")
        second.component?.inputs[input.uuidString] = .number(1)
        var document = Document(screen: Layer(kind: .screen, children: [first, second]))
        document.components = [definition]
        document.normalize()
        let runtime = Runtime(document: document, registry: registry(try Self.package()))
        runtime.tick(dt: 1 / 60)
        runtime.tick(dt: 1 / 60)
        #expect(fills(runtime.resolved.find(first.id)?.drawing) == [[0, 0, 10, 10]])
        #expect(fills(runtime.resolved.find(second.id)?.drawing) == [[0, 0, 50, 10]])
    }

    // MARK: When things go wrong

    @Test func withoutTheExtensionTheViewIsLeftEmptyAndKeepsItsCables() throws {
        var document = Document(screen: Layer(kind: .screen, children: [bar(["amount": .number(0.4)])]))
        let layer = document.screen.children[0].id
        let patch = document.graph.viewNode(layer: layer)!.id
        let source = document.graph.add(PatchNode(kind: "add"))
        document.graph.connect(from: PortRef(node: source, port: "result"), to: PortRef(node: patch, port: "ext.amount"))
        document.graph.connect(from: PortRef(node: source, port: "result"), to: PortRef(node: patch, port: "opacity"))
        let package = try Self.package()

        for registry in [PatchRegistry.standard, registry(package, available: false)] {
            var copy = document
            copy.normalize(measure: registry.height)
            registry.settlePublished(in: &copy)
            #expect(copy.graph.connections.count == 2)
            #expect(copy.screen.children[0].custom?.inputs["amount"] == .number(0.4))
            let runtime = Runtime(document: copy, registry: registry)
            runtime.tick(dt: 1 / 60)
            #expect(runtime.resolved.find(layer)?.drawing == nil)
            #expect(!runtime.needsAnotherFrame)
        }

        // With the extension, a cable into an input it no longer declares goes, as on any patch.
        var copy = document
        copy.graph.connect(from: PortRef(node: source, port: "result"), to: PortRef(node: patch, port: "ext.gone"))
        #expect(copy.graph.connections.count == 3)
        registry(package).settlePublished(in: &copy)
        #expect(copy.graph.connections.map(\.to.port).sorted() == ["ext.amount", "opacity"])
    }

    @Test func aDrawScriptThatNeverEndsIsStoppedAndNotRunAgain() throws {
        let layer = bar()
        let runtime = Runtime(
            document: Document(screen: Layer(kind: .screen, children: [layer])),
            registry: registry(try Self.package(script: "everyFrame = true; function draw() { while (true) {} }"))
        )
        let started = Date()
        for _ in 0..<5 { runtime.tick(dt: 1 / 60) }
        #expect(Date().timeIntervalSince(started) < 1.5)
        #expect(runtime.resolved.find(layer.id)?.drawing == nil)
        // It no longer asks for frames either.
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func whatAScriptDrawsIsMadeSafeToDraw() throws {
        let script = """
        function draw(canvas, inputs, size) {
          canvas.fillRect(0 / 0, 1 / 0, -1 / 0, "wide");
          canvas.globalAlpha = 7;
          canvas.fillStyle = "rgba(255, 0, 0, 0.5)";
          canvas.fillRect(1, 2, 3, 4);
          canvas.fillStyle = "#0f0";
          canvas.fillRect(5, 6, 7, 8);
          canvas.fillStyle = "not a color";
          canvas.fillRect(9, 9, 9, 9);
          canvas.drawImage("assets/logo.png", 0, 0, 10, 10);
          canvas.drawImage("../../secret.png", 0, 0, 10, 10);
          canvas.drawImage("/etc/passwd", 0, 0, 10, 10);
          for (var i = 0; i < 100000; i++) canvas.lineTo(i, i);
        }
        """
        let layer = bar()
        let runtime = Runtime(document: Document(screen: Layer(kind: .screen, children: [layer])), registry: registry(try Self.package(script: script)))
        runtime.tick(dt: 1 / 60)
        let drawing = try #require(runtime.resolved.find(layer.id)?.drawing)
        #expect(drawing.commands.count <= Drawing.limit)
        #expect(fills(drawing).first == [0, 0, 0, 0])
        let styles: [DrawCommand.Style] = drawing.commands.compactMap { if case let .fillRect(_, _, _, _, style) = $0 { style } else { nil } }
        #expect(styles.allSatisfy { (0...1).contains($0.alpha) })
        #expect(styles[1].paint == .color(ColorValue(red: 1, green: 0, blue: 0, alpha: 128.0 / 255)))
        #expect(styles[2].paint == .color(ColorValue(hex: "#00FF00")!))
        #expect(styles[3].paint == .color(.black))
        // A picture is one of the extension's own files, and nothing else.
        let images: [String] = drawing.commands.compactMap { if case let .image(name, _, _, _, _, _) = $0 { name } else { nil } }
        #expect(images == ["ext:com.example.charts/assets/logo.png"])
    }

    @Test func theCanvasKeepsItsStyleAcrossSaveAndRestoreAndMeasuresText() throws {
        let script = """
        function draw(canvas, inputs, size) {
          canvas.fillStyle = "blue";
          canvas.save();
          canvas.fillStyle = "red";
          canvas.translate(10, 0);
          canvas.fillRect(0, 0, 1, 1);
          canvas.restore();
          canvas.fillRect(0, 0, canvas.measureText("Hello").width, 1);
          var gradient = canvas.createLinearGradient(0, 0, size.width, 0);
          gradient.addColorStop(0, "white");
          gradient.addColorStop(1, inputs.tint);
          canvas.fillStyle = gradient;
          canvas.beginPath();
          canvas.arc(10, 10, 5, 0, Math.PI * 2);
          canvas.fill();
          canvas.lineWidth = 3;
          canvas.setLineDash([2, 1]);
          canvas.stroke();
        }
        """
        let layer = bar()
        let runtime = Runtime(document: Document(screen: Layer(kind: .screen, children: [layer])), registry: registry(try Self.package(script: script)))
        runtime.tick(dt: 1 / 60)
        let commands = try #require(runtime.resolved.find(layer.id)?.drawing).commands
        let styles: [DrawCommand.Style] = commands.compactMap { if case let .fillRect(_, _, _, _, style) = $0 { style } else { nil } }
        #expect(styles.map(\.paint) == [.color(ColorValue(hex: "#FF3B30")!), .color(ColorValue(hex: "#007AFF")!)])
        let measured = fills(runtime.resolved.find(layer.id)?.drawing)[1][2]
        #expect(measured == TextMeasurer.measure("Hello", fontSize: 13, weight: 400, maxWidth: nil).width)
        #expect(commands.contains(.save) && commands.contains(.restore) && commands.contains(.translate(10, 0)))
        guard case let .fill(style)? = commands.first(where: { if case .fill = $0 { true } else { false } }),
              case let .linear(from, to, stops) = style.paint else {
            Issue.record("expected a fill with a gradient")
            return
        }
        #expect([from.x, to.x] == [0, 100])
        #expect(stops.map(\.color) == [.white, ColorValue(hex: "#FF0000")!])
        guard case let .stroke(_, line)? = commands.last else {
            Issue.record("expected a stroke last")
            return
        }
        #expect(line.width == 3)
        #expect(line.dash == [2, 1])
    }

    @Test func anUpdatedExtensionDrawsWithItsNewScript() throws {
        let layer = bar()
        let runtime = Runtime(document: Document(screen: Layer(kind: .screen, children: [layer])), registry: registry(try Self.package()))
        runtime.tick(dt: 1 / 60)
        #expect(fills(runtime.resolved.find(layer.id)?.drawing) == [[0, 0, 50, 20]])
        runtime.update(registry: registry(try Self.package(script: "function draw(canvas) { canvas.fillRect(1, 1, 1, 1); }", version: "1.1.0")))
        runtime.tick(dt: 1 / 60)
        #expect(fills(runtime.resolved.find(layer.id)?.drawing) == [[1, 1, 1, 1]])
        // Switched off: nothing is drawn, and nothing is run.
        runtime.update(registry: registry(try Self.package(), available: false))
        runtime.tick(dt: 1 / 60)
        #expect(runtime.resolved.find(layer.id)?.drawing == nil)
    }
}
