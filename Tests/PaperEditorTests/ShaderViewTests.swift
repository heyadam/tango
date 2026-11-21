import AppKit
import Foundation
import PaperEngine
import PaperModel
import PaperRender
import Testing
@testable import PaperEditor

/// Shader views: a view drawn through Metal source, with the views inside it as a picture
/// the shader can read.
@MainActor
@Suite struct ShaderViewTests {
    /// A 200 × 200 screen with one shader view at 20, 20, 100 × 100.
    static func document(_ source: String, fill: ColorValue? = nil, inputs: [String: Value] = [:], children: [Layer] = []) -> PaperModel.Document {
        var view = Layer.new(.shader, name: "Effect")
        view.shader = ShaderUse(source: source, inputs: inputs)
        view.properties[.position] = .point(Point2(x: 20, y: 20))
        view.properties[.size] = .size(Size2(width: 100, height: 100))
        if let fill { view.properties[.fill] = .color(fill) }
        view.children = children
        var screen = Layer.new(.screen)
        screen.properties[.size] = .size(Size2(width: 200, height: 200))
        screen.children = [view]
        return PaperModel.Document(screen: screen)
    }

    static func color(_ bitmap: NSBitmapImageRep?, _ x: Int, _ y: Int) -> [Int] {
        guard let color = bitmap?.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return [] }
        return [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
    }

    static func near(_ a: [Int], _ b: [Int]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= 6 }
    }

    @Test func aShaderDecidesEveryPixelOfItsView() throws {
        try #require(ShaderCompiler.shared != nil)
        let picture = ViewerSnapshot.bitmap(of: Self.document("float4 shader(Frame frame, Inputs in) { return float4(1, 0, 0, 1); }"))
        #expect(Self.near(Self.color(picture, 70, 70), [255, 0, 0]))
        #expect(Self.near(Self.color(picture, 10, 10), [255, 255, 255]))
        #expect(Self.near(Self.color(picture, 150, 150), [255, 255, 255]))
    }

    @Test func aShaderReadsTheViewsInsideIt() throws {
        try #require(ShaderCompiler.shared != nil)
        var square = Layer.new(.view, name: "Square")
        square.properties[.fill] = .color(ColorValue(red: 1, green: 0, blue: 0))
        square.properties[.size] = .size(Size2(width: 50, height: 50))
        let passThrough = "float4 shader(Frame frame, Inputs in) { return content(frame, frame.position); }"
        let picture = ViewerSnapshot.bitmap(of: Self.document(passThrough, fill: ColorValue(red: 0, green: 0, blue: 1), children: [square]))
        // The square is at the view's top left; the rest is the view's fill.
        #expect(Self.near(Self.color(picture, 35, 35), [255, 0, 0]))
        #expect(Self.near(Self.color(picture, 100, 100), [0, 0, 255]))
        #expect(Self.near(Self.color(picture, 35, 100), [0, 0, 255]))

        // A shader can move what it reads: here the picture is mirrored left to right.
        let mirrored = "float4 shader(Frame frame, Inputs in) { return content(frame, float2(frame.size.x - frame.position.x, frame.position.y)); }"
        let flipped = ViewerSnapshot.bitmap(of: Self.document(mirrored, fill: ColorValue(red: 0, green: 0, blue: 1), children: [square]))
        #expect(Self.near(Self.color(flipped, 100, 35), [255, 0, 0]))
        #expect(Self.near(Self.color(flipped, 35, 35), [0, 0, 255]))
    }

    @Test func whatAShaderLeavesClearShowsWhatIsBehindIt() throws {
        try #require(ShaderCompiler.shared != nil)
        let half = "float4 shader(Frame frame, Inputs in) { return frame.uv.y < 0.5 ? float4(0, 1, 0, 1) : content(frame, frame.position); }"
        let picture = ViewerSnapshot.bitmap(of: Self.document(half))
        #expect(Self.near(Self.color(picture, 70, 40), [0, 255, 0]))
        #expect(Self.near(Self.color(picture, 70, 100), [255, 255, 255]))
    }

    @Test func aShaderDrawsWithItsInputs() throws {
        try #require(ShaderCompiler.shared != nil)
        let source = """
        struct Inputs {
            float4 tint = float4(0, 0, 1, 1);
            float level = 1;
            bool on = true;
            float2 spot = float2(50, 50);
        };
        float4 shader(Frame frame, Inputs in) {
            if (!in.on) { return float4(0, 0, 0, 1); }
            return distance(frame.position, in.spot) < 20 ? float4(1, 1, 1, 1) : float4(in.tint.rgb * in.level, 1);
        }
        """
        let standard = ViewerSnapshot.bitmap(of: Self.document(source))
        #expect(Self.near(Self.color(standard, 25, 25), [0, 0, 255]))
        #expect(Self.near(Self.color(standard, 70, 70), [255, 255, 255]))

        let changed = ViewerSnapshot.bitmap(of: Self.document(source, inputs: [
            "tint": .color(ColorValue(red: 1, green: 0, blue: 0)), "level": .number(0.5), "spot": .point(Point2(x: 80, y: 80)),
        ]))
        #expect(Self.near(Self.color(changed, 25, 25), [128, 0, 0]))
        #expect(Self.near(Self.color(changed, 100, 100), [255, 255, 255]))
        #expect(Self.near(Self.color(changed, 60, 60), [128, 0, 0]))

        let off = ViewerSnapshot.bitmap(of: Self.document(source, inputs: ["on": .bool(false)]))
        #expect(Self.near(Self.color(off, 70, 70), [0, 0, 0]))
    }
}

/// Editing shader views: the store's commands and what an agent may send.
@MainActor
@Suite struct ShaderEditingTests {
    static let twoInputs = "struct Inputs { float amount = 0.5; float4 tint = float4(1, 1, 1, 1); };\nfloat4 shader(Frame frame, Inputs in) { return in.tint * in.amount; }"

    private func edit(_ store: DocumentStore, _ operations: [[String: Any]]) -> (errors: [String], created: [String: String]) {
        let result = AssistantToolbox(store: store).call("edit_document", input: ["operations": operations])
        let answer = (try? JSONSerialization.jsonObject(with: Data(result.text.utf8))) as? [String: Any] ?? [:]
        return ((answer["errors"] as? [[String: Any]] ?? []).compactMap { $0["error"] as? String }, answer["created"] as? [String: String] ?? [:])
    }

    @Test func editingAShaderKeepsWhatStillFitsAndUndoes() throws {
        let store = DocumentStore()
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        func step(_ body: () -> Void) {
            undo.beginUndoGrouping()
            body()
            undo.endUndoGrouping()
        }
        var id = LayerID()
        var source = NodeID()
        step { id = store.addView(.shader) }
        #expect(store.document.layer(id)?.shader?.source == ShaderUse.template)
        step { store.setShader(Self.twoInputs, of: id) }
        step { store.setShaderInput("amount", of: id, to: .number(0.25)) }
        step { store.setShaderInput("tint", of: id, to: .color(ColorValue(red: 1, green: 0, blue: 0))) }
        let patch = try #require(store.viewNode(for: id))
        step { source = store.addPatch("value") }
        step { #expect(store.connect(from: PortRef(node: source, port: "value"), to: PortRef(node: patch.id, port: "shader.amount"))) }
        // The patch shows the shader's inputs, and reads their values from the view.
        let ports = store.visiblePorts(for: try #require(store.viewNode(for: id)))
        #expect(ports.inputs.map(\.id).suffix(3) == [ShaderUse.codePort, "shader.amount", "shader.tint"])
        // The code is an input of the patch too: its value is the source, and setting it edits the shader.
        #expect(store.literal(for: try #require(ports.input(ShaderUse.codePort)), of: patch) == .text(Self.twoInputs))
        #expect(store.literal(for: try #require(ports.input("shader.tint")), of: patch) == .color(ColorValue(red: 1, green: 0, blue: 0)))

        // `amount` becomes a color and `tint` goes: the number, its cable and tint's value go too.
        step { store.setShader("struct Inputs { float4 amount = float4(0, 0, 0, 1); };\nfloat4 shader(Frame frame, Inputs in) { return in.amount; }", of: id) }
        #expect(store.document.layer(id)?.shader?.inputs.isEmpty == true)
        #expect(store.document.graph.connections.isEmpty)

        undo.undo()
        #expect(store.document.layer(id)?.shader?.source == Self.twoInputs)
        #expect(store.document.layer(id)?.shader?.inputs["amount"] == .number(0.25))
        #expect(store.document.graph.connections.count == 1)
    }

    @Test func theCodeInputEditsTheShaderAndTakesATextCable() throws {
        try #require(ShaderCompiler.shared != nil)
        let store = DocumentStore()
        let id = store.addView(.shader)
        let patch = try #require(store.viewNode(for: id))
        let red = "float4 shader(Frame frame, Inputs in) { return float4(1, 0, 0, 1); }"
        store.setLiteral(.text(red), node: patch.id, port: ShaderUse.codePort)
        #expect(store.document.layer(id)?.shader?.source == red)

        // An agent cables text into it by the port's name; what arrives is what is drawn.
        let green = "float4 shader(Frame frame, Inputs in) { return float4(0, 1, 0, 1); }"
        #expect(edit(store, [
            ["op": "add_patch", "kind": "value", "type": "text", "ref": "code", "inputs": ["value": green]],
            ["op": "connect", "from": "code", "output": "value", "to": store.document.layer(id)?.name ?? "", "input": "code"],
        ]).errors == [])
        #expect(store.document.graph.connections.first?.to == PortRef(node: patch.id, port: ShaderUse.codePort))
        let layer = try #require(store.document.layer(id))
        let origin = layer.value(.position).pointValue
        let picture = ViewerSnapshot.bitmap(of: store.document)
        #expect(ShaderViewTests.near(ShaderViewTests.color(picture, Int(origin.x) + 20, Int(origin.y) + 20), [0, 255, 0]))

        // The cable goes when the view stops being a shader view.
        store.convert(id, to: .view)
        #expect(store.document.graph.connections.isEmpty)
    }

    @Test func codeThatArrivesByCableAddsItsInputsToThePatch() throws {
        let store = DocumentStore()
        let id = store.addView(.shader)
        store.setShader(Self.twoInputs, of: id)
        let patch = try #require(store.viewNode(for: id))
        let other = "struct Inputs { float radius = 10; float amount = 1; };\nfloat4 shader(Frame frame, Inputs in) { return float4(in.radius * in.amount); }"
        let code = store.addPatch("value")
        store.setValueType(.text, node: code)
        store.setLiteral(.text(other), node: code, port: "value")
        #expect(store.connect(from: PortRef(node: code, port: "value"), to: PortRef(node: patch.id, port: ShaderUse.codePort)))
        func inputs() -> [String] {
            store.visiblePorts(for: store.viewNode(for: id)!).inputs.map(\.id).filter { $0.hasPrefix("shader.") }
        }
        // What the cable brings is only known once the prototype runs.
        #expect(inputs() == ["shader.amount", "shader.tint"])
        let viewer = ViewerView(store: store, sendsRequests: false)
        viewer.advance(by: 1.0 / 60)
        // The patch keeps the inputs of the view's own code and gains the arriving code's.
        #expect(inputs() == ["shader.amount", "shader.tint", "shader.radius"])
        #expect(store.document.layer(id)?.shader?.arriving == other)
        #expect(store.document.layer(id)?.shader?.source == Self.twoInputs)

        // The new input takes a value and a cable, and both stay.
        store.setShaderInput("radius", of: id, to: .number(42))
        let level = store.addPatch("value")
        #expect(store.connect(from: PortRef(node: level, port: "value"), to: PortRef(node: patch.id, port: "shader.amount")))
        let size = store.addPatch("value")
        #expect(store.connect(from: PortRef(node: size, port: "value"), to: PortRef(node: patch.id, port: "shader.radius")))
        viewer.update(document: store.runtimeDocument, restartToken: store.restartToken)
        viewer.advance(by: 1.0 / 60)
        #expect(store.document.graph.connections.count == 3)
        #expect(store.document.layer(id)?.shader?.inputs["radius"] == .number(42))
        // The code that is drawn gets the values of the inputs it declares.
        let running = try #require(store.runtime?.resolved.find(id)?.shader)
        #expect(running.source == other && running.values["radius"] == .number(0))

        // Without the cable the patch goes back to the inputs of the view's own code.
        store.disconnect(input: PortRef(node: patch.id, port: ShaderUse.codePort))
        #expect(inputs() == ["shader.amount", "shader.tint"])
        #expect(store.document.layer(id)?.shader?.arriving == nil)
        #expect(store.document.graph.connections.map(\.to.port) == ["shader.amount"])
    }

    @Test func anAgentCablesCodeAndThenItsInputsInOneBatch() throws {
        try #require(ShaderCompiler.shared != nil)
        let store = DocumentStore()
        let other = "struct Inputs { float radius = 10; };\nfloat4 shader(Frame frame, Inputs in) { return float4(in.radius / 100.0, 0, 0, 1); }"
        let made = edit(store, [
            ["op": "add_view", "kind": "shader", "name": "Look", "ref": "look", "shader": Self.twoInputs],
            ["op": "add_patch", "kind": "value", "type": "text", "ref": "code", "inputs": ["value": other]],
            ["op": "connect", "from": "code", "output": "value", "to": "look", "input": "code"],
            // No Viewer has run: the arriving code's input is there for the next step anyway.
            ["op": "add_patch", "kind": "value", "ref": "size", "inputs": ["value": 50]],
            ["op": "connect", "from": "size", "output": "value", "to": "look", "input": "radius"],
            ["op": "set_shader", "view": "look", "inputs": ["amount": 0.3]],
        ])
        #expect(made.errors == [])
        #expect(Set(store.document.graph.connections.map(\.to.port)) == [ShaderUse.codePort, "shader.radius"])
        let described = AssistantToolbox(store: store).call("get_document", input: [:]).text
        #expect(described.contains("shader_arriving") && described.contains("code: text") && described.contains("radius: number"))
    }

    @Test func anAgentLooksWhileAFingerIsHeld() throws {
        try #require(ShaderCompiler.shared != nil)
        let store = DocumentStore(package: DocumentPackage(document: SampleDocuments.shaderLens().document))
        let result = AssistantToolbox(store: store).call("interact_prototype", input: ["steps": [
            ["do": "look"],
            ["do": "down", "at": ["x": 195, "y": 300]], ["do": "wait", "seconds": 1], ["do": "look"],
            ["do": "move", "to": ["x": 195, "y": 500], "seconds": 0.3], ["do": "look"],
            ["do": "up"], ["do": "wait", "seconds": 2],
        ]])
        #expect(!result.isError && result.images.count == 4)
        let pictures = result.images.compactMap { NSBitmapImageRep(data: $0) }
        // The lens shows under the held finger, follows it, and goes when it lifts.
        #expect(ShaderViewTests.color(pictures[0], 195, 406) != ShaderViewTests.color(pictures[1], 195, 406))
        #expect(ShaderViewTests.color(pictures[1], 195, 606) != ShaderViewTests.color(pictures[2], 195, 606))
        #expect(ShaderViewTests.near(ShaderViewTests.color(pictures[0], 195, 406), ShaderViewTests.color(pictures[3], 195, 406)))
        #expect(AssistantToolbox(store: store).call("interact_prototype", input: ["steps": [["do": "move", "to": ["x": 1, "y": 1]]]]).isError)
    }

    @Test func aViewBecomesAShaderViewAndBackWithWhatIsInIt() throws {
        let store = DocumentStore()
        let box = store.addView(.stack)
        store.open(box)
        let inner = store.addView(.text)
        store.closeView()
        #expect(store.document.screen.parent(of: inner)?.id == box)
        store.convert(box, to: .shader)
        let shader = try #require(store.document.layer(box))
        #expect(shader.type == .shader && shader.arrangement == .stack && shader.children.map(\.id) == [inner])
        #expect(shader.applicable.contains(.spacing))
        let patch = try #require(store.viewNode(for: box))
        let value = store.addPatch("value")
        #expect(store.connect(from: PortRef(node: value, port: "value"), to: PortRef(node: patch.id, port: "shader.speed")))

        store.convert(box, to: .stack)
        #expect(store.document.layer(box)?.shader == nil)
        #expect(store.document.layer(box)?.type == .stack)
        #expect(store.document.layer(box)?.children.map(\.id) == [inner])
        #expect(store.document.graph.connections.isEmpty)
    }

    @Test func aDuplicatedShaderViewKeepsItsCodeAndValues() throws {
        let store = DocumentStore()
        let id = store.addView(.shader)
        store.setShader(Self.twoInputs, of: id)
        store.setShaderInput("amount", of: id, to: .number(0.9))
        store.selectedLayers = [id]
        store.duplicateSelectedLayers()
        let copies = store.document.screen.children.filter { $0.shader != nil }
        #expect(copies.count == 2)
        #expect(copies.allSatisfy { $0.shader?.inputs["amount"] == .number(0.9) })
        for copy in copies {
            #expect(store.registry.ports(for: try #require(store.viewNode(for: copy.id))).input("shader.amount") != nil)
        }
    }

    @Test func anAgentWritesShadersAndHearsWhenOneDoesNotCompile() throws {
        try #require(ShaderCompiler.shared != nil)
        let store = DocumentStore()
        let made = edit(store, [
            ["op": "add_view", "kind": "shader", "name": "Glow", "ref": "glow", "shader": Self.twoInputs, "inputs": ["amount": 0.75, "Tint": "#FF0000"]],
            ["op": "add_patch", "kind": "value", "ref": "level", "inputs": ["value": 0.2]],
            ["op": "connect", "from": "level", "output": "value", "to": "glow", "input": "amount"],
        ])
        #expect(made.errors == [])
        let glow = try #require(store.document.screen.children.first { $0.name == "Glow" })
        #expect(glow.shader?.inputs == ["amount": .number(0.75), "tint": .color(ColorValue(red: 1, green: 0, blue: 0))])
        #expect(store.document.graph.connections.first?.to.port == "shader.amount")

        // The agent reads back the code, the inputs and their values.
        let described = AssistantToolbox(store: store).call("get_document", input: [:]).text
        #expect(described.contains("float4 shader(Frame frame, Inputs in)"))
        #expect(described.contains("amount: number") && described.contains("shader.amount"))

        // Code Metal refuses is an error with its line, and the view keeps what it had.
        let broken = edit(store, [["op": "set_shader", "view": "Glow", "shader": "float4 shader(Frame frame, Inputs in) {\n    return vec4(1.0);\n}"]])
        #expect(broken.errors.count == 1)
        #expect(broken.errors.first?.contains("does not compile") == true && broken.errors.first?.contains("Line 2") == true)
        #expect(store.document.layer(glow.id)?.shader?.source == Self.twoInputs)
        #expect(store.document.graph.connections.count == 1)

        let wrong = edit(store, [
            ["op": "set_shader", "view": "Glow", "inputs": ["missing": 1]],
            ["op": "add_view", "kind": "view", "shader": Self.twoInputs],
            ["op": "add_view", "kind": "view", "name": "Plain", "ref": "plain"],
            ["op": "set_shader", "view": "plain", "shader": Self.twoInputs],
            ["op": "add_view", "kind": "shader", "name": "Bad", "shader": "float4 shader(Frame frame) { return float4(1); }"],
        ])
        #expect(wrong.errors.count == 4)
        #expect(wrong.errors[0].contains("no input \"missing\""))
        #expect(wrong.errors[2].contains("change_view"))
        #expect(wrong.errors[3].contains("float4 shader(Frame frame, Inputs in)"))
        // A view whose shader failed is not left behind.
        #expect(!store.document.screen.children.contains { $0.name == "Bad" })

        // A plain view becomes a shader view, then takes code.
        #expect(edit(store, [
            ["op": "change_view", "view": "Plain", "kind": "shader"],
            ["op": "set_shader", "view": "Plain", "shader": "float4 shader(Frame frame, Inputs in) { return float4(0, 1, 0, 1); }"],
        ]).errors == [])
        #expect(store.document.screen.children.first { $0.name == "Plain" }?.type == .shader)
    }

    @Test func aShaderViewInsideAnotherIsDrawnFirst() throws {
        try #require(ShaderCompiler.shared != nil)
        var inner = Layer.new(.shader, name: "Inner")
        inner.shader = ShaderUse(source: "float4 shader(Frame frame, Inputs in) { return float4(1, 0, 0, 1); }")
        inner.properties[.size] = .size(Size2(width: 50, height: 50))
        // The outer one swaps red and blue of what is in it.
        let swap = "float4 shader(Frame frame, Inputs in) { float4 c = content(frame, frame.position); return float4(c.b, c.g, c.r, c.a); }"
        let picture = ViewerSnapshot.bitmap(of: ShaderViewTests.document(swap, fill: ColorValue(red: 0, green: 1, blue: 0), children: [inner]))
        #expect(ShaderViewTests.near(ShaderViewTests.color(picture, 35, 35), [0, 0, 255]))
        #expect(ShaderViewTests.near(ShaderViewTests.color(picture, 100, 100), [0, 255, 0]))
    }

    @Test func theLensBendsWhatIsUnderIt() throws {
        try #require(ShaderCompiler.shared != nil)
        var document = SampleDocuments.shaderLens().document
        let lens = try #require(document.screen.children.first)
        let flat = ViewerSnapshot.bitmap(of: document)
        // With the lens shown at rest, without the cables that drive it.
        document.graph.connections.filter { $0.to.port.hasPrefix("shader.") }.forEach { document.graph.disconnect(input: $0.to) }
        document.screen.update(lens.id) { $0.shader?.inputs = ["amount": .number(1), "touch": .point(Point2(x: 195, y: 300))] }
        let bent = ViewerSnapshot.bitmap(of: document)
        // Far from the lens nothing changes; at its rim there is a highlight.
        #expect(ShaderViewTests.color(flat, 30, 800) == ShaderViewTests.color(bent, 30, 800))
        #expect(ShaderViewTests.color(flat, 195, 406) != ShaderViewTests.color(bent, 195, 406))
        if let data = bent?.representation(using: .png, properties: [:]), let path = ProcessInfo.processInfo.environment["SHADER_TEST_PICTURES"] {
            try data.write(to: URL(fileURLWithPath: path).appendingPathComponent("lens-bent.png"))
        }
    }

    @Test func everyShaderInTheGalleryCompiles() throws {
        try #require(ShaderCompiler.shared != nil)
        var count = 0
        for item in Gallery.items {
            for layer in item.make().screen.flattened {
                guard let shader = layer.shader else { continue }
                count += 1
                #expect(ShaderCompiler.error(in: shader.source) == nil, "\(item.id): \(ShaderCompiler.error(in: shader.source) ?? "")")
            }
        }
        #expect(count >= 2)
        #expect(ShaderCompiler.error(in: ShaderUse.template) == nil)
        // The shaders the agent reference shows whole are held to the same.
        for recipe in AssistantPrompt.shaderRecipes {
            #expect(ShaderCompiler.error(in: recipe.source) == nil, "\(recipe.title): \(ShaderCompiler.error(in: recipe.source) ?? "")")
        }
        let reference = AssistantPrompt.reference(registry: .standard, components: [])
        for word in ["set_shader", "content(frame, point)", "shader_error", "interact_prototype", "max(x, 1.0)", "A blur of the views inside"] {
            #expect(reference.contains(word), "\(word)")
        }
    }

    @Test func aBrokenShaderKeepsDrawingWhatIsInsideIt() throws {
        try #require(ShaderCompiler.shared != nil)
        #expect(ShaderCompiler.error(in: "float4 shader(Frame frame, Inputs in) { return nothing; }")?.hasPrefix("Line 1:") == true)
        #expect(ShaderCompiler.error(in: ShaderUse.template) == nil)
        let picture = ViewerSnapshot.bitmap(of: ShaderViewTests.document(
            "float4 shader(Frame frame, Inputs in) { return nothing; }", fill: ColorValue(red: 0, green: 0, blue: 1)
        ))
        #expect(ShaderViewTests.near(ShaderViewTests.color(picture, 70, 70), [0, 0, 255]))
    }
}

/// The colors of shader code in its editor.
@MainActor
@Suite struct ShaderHighlighterTests {
    @Test func codeIsColoredByWhatItIs() {
        let text = "// tint it\nstruct Inputs { float4 tint = float4(1, 0.5, 0, 1); };\nfloat4 shader(Frame frame, Inputs in) { return mix(in.tint, frame.size.xyxy, 2.0f); /* done */ }"
        let string = text as NSString
        let found = ShaderHighlighter.tokens(in: text).map { "\(string.substring(with: $0.range)):\($0.kind)" }
        #expect(found.contains("// tint it:comment") && found.contains("/* done */:comment"))
        #expect(found.contains("struct:keyword") && found.contains("return:keyword"))
        #expect(found.contains("float4:type") && found.contains("Frame:type") && found.contains("Inputs:type"))
        #expect(found.contains("mix:function") && found.contains("shader:function"))
        #expect(found.contains("0.5:number") && found.contains("2.0f:number"))
        // Names of the person's own, members and digits inside a name are left plain.
        for plain in ["tint", "frame", "size", "xyxy", "in", "4"] {
            #expect(!found.contains { $0.hasPrefix("\(plain):") }, "\(plain)")
        }
        // Words inside a comment are not colored on their own.
        #expect(ShaderHighlighter.tokens(in: "// return float4").count == 1)
    }

    @Test func theLineWithAProblemIsMarked() throws {
        let text = "one\ntwo\nthree"
        #expect(ShaderHighlighter.line(in: "Line 2: use of undeclared identifier") == 2)
        #expect(ShaderHighlighter.line(in: "The shader needs a function") == nil)
        #expect(ShaderHighlighter.range(ofLine: 2, in: text) == NSRange(location: 4, length: 4))
        #expect(ShaderHighlighter.range(ofLine: 3, in: text) == NSRange(location: 8, length: 5))
        #expect(ShaderHighlighter.range(ofLine: 4, in: text) == nil)

        let storage = NSTextStorage(string: text)
        ShaderHighlighter.apply(to: storage, errorLine: 2)
        #expect(storage.attribute(.backgroundColor, at: 5, effectiveRange: nil) != nil)
        #expect(storage.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
        #expect(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == ShaderHighlighter.font)
    }
}
