import Foundation
import Testing
import PaperModel
@testable import PaperEngine

/// Shader views (spec 7.8): what the source declares, and how values reach it.
@Suite struct ShaderTests {
    let frame = 1.0 / 60.0

    @Test func aShaderDeclaresItsInputs() {
        let interface = ShaderSource.interface(of: """
        struct Inputs {
            float speed = 1.5;        // how fast
            float2 center = float2(0.5, 20);
            float3 base = float3(1, 0, 0);
            float4 tintColor = float4(0, 0.5, 1, 0.25);
            int steps = 4;
            bool on = true;
            float plain;
            /* float hidden = 2; */
        };
        float4 shader(Frame frame, Inputs in) { return in.tintColor; }
        """)
        #expect(interface.error == nil)
        #expect(interface.declaresInputs)
        #expect(interface.uniforms.map(\.name) == ["speed", "center", "base", "tintColor", "steps", "on", "plain"])
        #expect(interface.ports.map(\.type) == [.number, .point, .color, .color, .number, .bool, .number])
        #expect(interface.ports.map(\.id).allSatisfy { $0.hasPrefix("shader.") })
        #expect(interface.ports[3].name == "Tint Color")
        #expect(interface.uniforms.map(\.defaultValue) == [
            .number(1.5), .point(Point2(x: 0.5, y: 20)), .color(ColorValue(red: 1, green: 0, blue: 0)),
            .color(ColorValue(red: 0, green: 0.5, blue: 1, alpha: 0.25)), .number(4), .bool(true), .number(0),
        ])
        #expect(ShaderUse(source: "struct Inputs { float a = 1; /* float b; */ float2 c; // float d;\n };").inputCount == 2)
        // It does not read the time, so it is drawn only when something changes.
        #expect(!interface.animates)
    }

    @Test func whatTheCompilerGetsKeepsEveryLineWhereItWas() {
        let source = """
        // A comment with struct Inputs { in it
        struct Inputs {
            float speed = 1;
            float4 tint = float4(1,
                                 0, 0, 1);
        };
        float4 shader(Frame frame, Inputs in) { return in.tint * frame.time; }
        """
        let interface = ShaderSource.interface(of: source)
        #expect(interface.error == nil)
        #expect(interface.uniforms.map(\.name) == ["speed", "tint"])
        #expect(interface.animates)
        #expect(interface.compilable.split(separator: "\n", omittingEmptySubsequences: false).count
            == source.split(separator: "\n", omittingEmptySubsequences: false).count)
        #expect(!interface.compilable.contains("="))
        #expect(!interface.compilable.contains("comment"))
        #expect(interface.compilable.contains("float speed"))
    }

    @Test func aShaderThatCannotBeReadSaysWhy() {
        #expect(ShaderSource.interface(of: "float4 colour(Frame frame) { return float4(1); }").error?.contains("float4 shader(Frame frame, Inputs in)") == true)
        #expect(ShaderSource.interface(of: "struct Inputs { texture2d<float> picture; };\nfloat4 shader(Frame frame, Inputs in) { return float4(1); }").error?.contains("Inputs cannot hold") == true)
        #expect(ShaderSource.interface(of: "struct Inputs { float a = 1; float a = 2; };\nfloat4 shader(Frame frame, Inputs in) { return float4(1); }").error?.contains("two members") == true)
        // No inputs at all is fine.
        let bare = ShaderSource.interface(of: "float4 shader(Frame frame, Inputs in) { return float4(1); }")
        #expect(bare.error == nil && bare.uniforms.isEmpty && !bare.declaresInputs)
    }

    func shaderView(_ source: String, inputs: [String: Value] = [:]) -> Layer {
        var view = Layer.new(.shader, name: "Effect")
        view.shader = ShaderUse(source: source, inputs: inputs)
        return view
    }

    @Test func aShaderViewIsAViewWhosePatchHasItsInputs() throws {
        let view = shaderView("struct Inputs { float amount = 0.5; float opacity = 1; };\nfloat4 shader(Frame frame, Inputs in) { return float4(in.amount); }")
        #expect(view.kind == .view && view.type == .shader && view.kind.canHaveChildren)
        var screen = Layer.new(.screen)
        screen.children = [view]
        let document = Document(screen: screen)
        let node = try #require(document.graph.viewNode(layer: view.id))
        let ports = PatchRegistry.standard.ports(for: node)
        #expect(ports.input("shader.amount")?.type == .number)
        #expect(ports.input("shader.amount")?.defaultValue == .number(0.5))
        // An input named like a property of the view is still its own port.
        #expect(ports.input("shader.opacity") != nil && ports.input("opacity") != nil)

        // It is stored with the view and comes back from a file.
        let copy = try Document.decode(from: try document.encoded())
        #expect(copy.screen.children.first?.shader == view.shader)
        #expect(copy.graph.viewNode(layer: view.id)?.script == view.shader?.source)

        // A view that stops being a shader view loses the inputs on its patch.
        var plain = document
        plain.screen.update(view.id) { $0.shader = nil }
        plain.normalize()
        #expect(PatchRegistry.standard.ports(for: try #require(plain.graph.viewNode(layer: view.id))).input("shader.amount") == nil)
        #expect(plain.screen.children.first?.type == .view)
    }

    @Test func cablesAndStoredValuesReachTheShader() throws {
        let view = shaderView(
            "struct Inputs { float amount = 0.5; float4 tint = float4(1, 1, 1, 1); };\nfloat4 shader(Frame frame, Inputs in) { return in.tint * in.amount; }",
            inputs: ["tint": .color(ColorValue(red: 1, green: 0, blue: 0))]
        )
        var screen = Layer.new(.screen)
        screen.children = [view]
        var document = Document(screen: screen)
        let value = document.graph.add(PatchNode(kind: "value", inputs: ["value": .number(0.8)]))
        let node = try #require(document.graph.viewNode(layer: view.id))
        #expect(PatchRegistry.standard.canConnect(
            from: PortRef(node: value, port: "value"), to: PortRef(node: node.id, port: "shader.amount"), in: document.graph
        ))
        document.graph.connect(from: PortRef(node: value, port: "value"), to: PortRef(node: node.id, port: "shader.amount"))

        let runtime = Runtime(document: document)
        runtime.tick(dt: frame)
        let shader = try #require(runtime.resolved.find(view.id)?.shader)
        #expect(shader.values["amount"] == .number(0.8))
        #expect(shader.values["tint"] == .color(ColorValue(red: 1, green: 0, blue: 0)))
        // Nothing moves, so nothing asks for another frame.
        runtime.tick(dt: frame)
        #expect(!runtime.needsAnotherFrame)
        #expect(shader.time == 0)
    }

    @Test func aCableIntoTheCodeReplacesItWhileThePrototypeRuns() throws {
        let view = shaderView("float4 shader(Frame frame, Inputs in) { return float4(1); }")
        var screen = Layer.new(.screen)
        screen.children = [view]
        var document = Document(screen: screen)
        let node = try #require(document.graph.viewNode(layer: view.id))
        let code = try #require(PatchRegistry.standard.ports(for: node).input(ShaderUse.codePort))
        #expect(code.type == .text && code.name == "Code")
        let moving = "float4 shader(Frame frame, Inputs in) { return float4(fract(frame.time)); }"
        let text = document.graph.add(PatchNode(kind: "value", inputs: ["value": .text(moving)], valueType: .text))
        document.graph.connect(from: PortRef(node: text, port: "value"), to: PortRef(node: node.id, port: ShaderUse.codePort))
        #expect(document.graph.connections.count == 1)

        let runtime = Runtime(document: document)
        runtime.advance(seconds: 0.25)
        #expect(runtime.resolved.find(view.id)?.shader?.source == moving)
        // The code that arrived reads the time, so the prototype keeps drawing.
        #expect(runtime.needsAnotherFrame)

        // With nothing arriving, the view's own code draws.
        var empty = document
        empty.graph.update(text) { $0.inputs["value"] = .text("") }
        let quiet = Runtime(document: empty)
        quiet.advance(seconds: 0.25)
        #expect(quiet.resolved.find(view.id)?.shader?.source == view.shader?.source)
        #expect(!quiet.needsAnotherFrame)
    }

    @Test func aShaderThatReadsTheTimeIsDrawnEveryFrame() throws {
        var screen = Layer.new(.screen)
        let view = shaderView("float4 shader(Frame frame, Inputs in) { return float4(fract(frame.time)); }")
        screen.children = [view]
        let runtime = Runtime(document: Document(screen: screen))
        runtime.advance(seconds: 0.5)
        #expect(runtime.needsAnotherFrame)
        #expect(abs((runtime.resolved.find(view.id)?.shader?.time ?? 0) - 0.5) < 0.02)
    }

    @Test func theLensFollowsAFinger() throws {
        let example = SampleDocuments.shaderLens()
        let runtime = Runtime(document: example.document)
        runtime.tick(dt: frame)
        #expect(runtime.resolved.find(example.lens)?.shader?.values["amount"]?.numberValue == 0)
        runtime.send(.touchDown(Point2(x: 120, y: 300)))
        runtime.advance(seconds: 1)
        let held = try #require(runtime.resolved.find(example.lens)?.shader)
        #expect(held.values["touch"] == .point(Point2(x: 120, y: 300)))
        #expect((held.values["amount"]?.numberValue ?? 0) > 0.9)
        runtime.send(.touchUp(Point2(x: 120, y: 300)))
        runtime.advance(seconds: 2)
        #expect((runtime.resolved.find(example.lens)?.shader?.values["amount"]?.numberValue ?? 1) < 0.05)
        // The lens does not read the time: once it has gone, the prototype is idle.
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func theAuroraFlaresWhenItsCardIsTapped() throws {
        let example = SampleDocuments.shaderBackground()
        let runtime = Runtime(document: example.document)
        runtime.tick(dt: frame)
        runtime.send(.touchDown(Point2(x: 195, y: 700)))
        runtime.tick(dt: frame)
        runtime.send(.touchUp(Point2(x: 195, y: 700)))
        runtime.advance(seconds: 3)
        #expect((runtime.resolved.find(example.background)?.shader?.values["energy"]?.numberValue ?? 0) > 0.9)
        #expect(runtime.needsAnotherFrame)
    }
}
