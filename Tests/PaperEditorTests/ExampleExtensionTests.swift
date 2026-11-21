import AppKit
import Foundation
import Testing
import PaperEngine
import PaperModel
import PaperRender
@testable import PaperEditor

/// The extensions that come with the repository, in `Extensions/`. Each is read as it is
/// on disk and used the way a person would use it. Nothing here reaches the network.
@MainActor
@Suite struct ExampleExtensionTests {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Extensions")

    static func package(_ name: String) throws -> PaperExtension {
        try PaperExtension(contentsOf: folder.appendingPathComponent("\(name).\(PaperExtension.fileExtension)"))
    }

    static var all: [PaperExtension] {
        get throws {
            try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == PaperExtension.fileExtension }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { try PaperExtension(contentsOf: $0) }
        }
    }

    @Test func everyExampleIsWholeAndHasNoProblems() throws {
        let packages = try Self.all
        #expect(packages.map(\.id) == ["com.tango.claude", "com.tango.charts", "com.tango.sampler"])
        for package in packages {
            #expect(package.problems().isEmpty, "\(package.name): \(package.problems())")
            #expect(package.text("README.md")?.isEmpty == false, "\(package.name) has no README")
            #expect(package.manifest.summary?.isEmpty == false)
            for patch in package.manifest.patches { #expect(!patch.summary.isEmpty, "\(patch.name)") }
            for view in package.manifest.views { #expect(!view.summary.isEmpty, "\(view.name)") }
        }
        // Together they install side by side and show up where things are picked.
        let folder = Fixture.Folder()
        let store = ExtensionStore(directory: folder.url)
        for package in packages { #expect(try store.install(package).isUsable) }
        let registry = store.registry()
        #expect(registry.viewLibrary.map(\.name) == ["Line Chart", "Bar Chart", "Progress Ring", "Stripes"])
        #expect(registry.library.filter { $0.origin != nil }.map(\.name) == ["Ask Claude", "Format Number"])
        #expect(registry.shelves.map(\.name) == ["Sampler"])
        let reference = AssistantPrompt.reference(registry: registry, components: [])
        for kind in ["com.tango.claude/ask", "com.tango.charts/line", "com.tango.sampler/ring"] {
            #expect(reference.contains(kind), "\(kind) is not in what agents are told")
        }
    }

    @Test func everyDrawnViewDrawsSomethingAsItComes() throws {
        for package in try Self.all {
            let registry = Fixture.registry(package)
            for view in registry.viewLibrary where view.script != nil {
                let (store, undo) = Fixture.store(registry: registry)
                var id: LayerID!
                undo.step { id = store.addExtensionView(view) }
                let runtime = Runtime(document: store.runtimeDocument, registry: store.runtimeRegistry)
                runtime.tick(dt: 1 / 60)
                let drawing = runtime.resolved.find(id)?.drawing
                #expect((drawing?.commands.count ?? 0) > 2, "\(view.name) drew nothing")
                #expect(!runtime.needsAnotherFrame, "\(view.name) keeps the prototype running")
                #expect(ExtensionLog.shared.entries(for: package.id).filter(\.isError).isEmpty, "\(view.name) reported an error")
            }
        }
    }

    @Test func everyShaderInAnExampleCompiles() throws {
        try #require(ShaderCompiler.shared != nil)
        for package in try Self.all {
            for view in Fixture.registry(package).viewLibrary {
                guard let source = view.shader else { continue }
                #expect(ShaderCompiler.error(in: source) == nil, "\(view.name): \(ShaderCompiler.error(in: source) ?? "")")
            }
        }
    }

    @Test func chartsFollowTheirValues() throws {
        let registry = Fixture.registry(try Self.package("Charts"))
        let (store, undo) = Fixture.store(registry: registry)
        var bars: LayerID!
        undo.step { bars = store.addExtensionView(registry.view("com.tango.charts/bars")!) }
        undo.step {
            store.setCustomInput("values", of: bars, to: .array([.number(1), .number(2), .number(4)]))
            store.setCustomInput("gap", of: bars, to: .number(0))
            store.setInput(ViewInput(id: "width")!, of: bars, to: .number(300))
            store.setInput(ViewInput(id: "height")!, of: bars, to: .number(100))
        }
        let runtime = Runtime(document: store.runtimeDocument, registry: store.runtimeRegistry)
        runtime.tick(dt: 1 / 60)
        let heights: [Double] = (runtime.resolved.find(bars)?.drawing?.commands ?? []).compactMap {
            if case let .roundRect(_, _, _, height, _) = $0 { height } else { nil }
        }
        #expect(heights == [25, 50, 100])
        // Values that are not numbers, or none at all, draw nothing and break nothing.
        undo.step { store.setCustomInput("values", of: bars, to: .array([.text("x")])) }
        runtime.update(document: store.runtimeDocument)
        runtime.tick(dt: 1 / 60)
        #expect(runtime.resolved.find(bars)?.drawing?.commands.isEmpty == true)
    }

    @Test func formatNumberWritesNumbersAsText() throws {
        let registry = Fixture.registry(try Self.package("Sampler"))
        func format(_ inputs: [String: Value]) -> Value? {
            var graph = Graph()
            let node = graph.add(PatchNode(kind: "com.tango.sampler/format-number", inputs: inputs))
            let runtime = Runtime(document: PaperModel.Document(graph: graph), registry: registry)
            runtime.tick(dt: 1 / 60)
            return runtime.outputValue(PortRef(node: node, port: "text"))
        }
        #expect(format(["value": .number(1234567.891)]) == .text("1,234,568"))
        #expect(format(["value": .number(-1234.5), "decimals": .number(2), "prefix": .text("$")]) == .text("$-1,234.50"))
        #expect(format(["value": .number(0.5), "decimals": .number(1), "thousands": .bool(false), "suffix": .text("%")]) == .text("0.5%"))
    }

    @Test func theSamplersComponentIsAddedAndDrawsItsRing() throws {
        let package = try Self.package("Sampler")
        let (store, undo) = Fixture.store(registry: Fixture.registry(package))
        let stat = try #require(store.libraryComponents.first { $0.name == "Stat Ring" })
        #expect(stat.inputs.map(\.name) == ["Progress", "Color", "Title"])
        var id: LayerID?
        undo.step { id = store.insertComponent(stat) }
        let instance = try #require(id)
        undo.step { store.setComponentInput(stat.inputs[0].id, of: instance, to: .number(0.25)) }
        let runtime = Runtime(document: store.runtimeDocument, registry: store.runtimeRegistry)
        runtime.tick(dt: 1 / 60)
        runtime.tick(dt: 1 / 60)
        // The ring is somewhere inside the instance, however the component nests it.
        func drawn(_ layer: ResolvedLayer) -> ResolvedLayer? {
            layer.drawing != nil ? layer : layer.children.lazy.compactMap(drawn).first
        }
        let ring = runtime.resolved.find(instance).flatMap(drawn)
        let texts: [String] = (ring?.drawing?.commands ?? []).compactMap { if case let .text(text, _, _, _, _) = $0 { text } else { nil } }
        #expect(texts == ["25%"])
        #expect(store.package.carried == [package])
    }

    // MARK: Ask Claude

    /// A Viewer with one Ask Claude patch whose Ask is pulsed by a tap, and a stand-in for
    /// the network that answers with `reply`.
    func asking(model: String? = nil, reply: @escaping @Sendable (URLRequest) -> NetworkResponse) throws -> (ViewerView, NodeID, Shared<[URLRequest]>) {
        let folder = Fixture.Folder()
        let installed = ExtensionStore(directory: folder.url)
        let package = try installed.install(try Self.package("AskClaude")).package
        try installed.keys.set("sk-ant-test-Sup3rSecret", for: package.manifest.secrets[0], of: package.id)
        let (store, undo) = Fixture.store(registry: installed.registry())
        var node: NodeID!, button: LayerID!
        undo.step { button = store.addView(.view, name: "Button") }
        undo.step {
            store.setInput(ViewInput(id: "x")!, of: button, to: .number(0))
            store.setInput(ViewInput(id: "y")!, of: button, to: .number(0))
        }
        undo.step { node = store.addPatch("com.tango.claude/ask") }
        undo.step { store.setLiteral(.text("Name a color."), node: node, port: "prompt") }
        undo.step { store.setLiteral(.text("Answer in one word."), node: node, port: "system") }
        if let model { undo.step { store.setLiteral(.text(model), node: node, port: "model") } }
        var touch: NodeID!
        undo.step { touch = store.addTouchPatch("interaction", for: button) }
        undo.step { _ = store.connect(from: PortRef(node: touch, port: "tap"), to: PortRef(node: node, port: "ask")) }
        let seen = Shared<[URLRequest]>([])
        let viewer = ViewerView(store: store)
        viewer.keyLookup = installed.keys.lookup
        viewer.extensionTransport = { request in
            seen.withLock { $0.append(request) }
            return reply(request)
        }
        viewer.update(document: store.runtimeDocument, restartToken: store.restartToken)
        viewer.runtime.restart()
        viewer.advance(by: 1.0 / 60)
        viewer.runtime.send(.touchDown(Point2(x: 20, y: 20)))
        viewer.advance(by: 1.0 / 60)
        viewer.runtime.send(.touchUp(Point2(x: 20, y: 20)))
        for _ in 0..<40 { viewer.advance(by: 1.0 / 60) }
        return (viewer, node, seen)
    }

    func settle(_ viewer: ViewerView, _ node: NodeID) async {
        let loading = PortRef(node: node, port: "loading")
        for _ in 0..<300 where viewer.runtime.outputValue(loading) == .bool(true) {
            try? await Task.sleep(for: .milliseconds(5))
            viewer.advance(by: 1.0 / 60)
        }
        viewer.advance(by: 1.0 / 60)
    }

    @Test func askClaudeSendsAMessagesRequestAndReadsTheAnswer() async throws {
        let (viewer, node, seen) = try asking { _ in
            NetworkResponse(status: 200, body: Data("""
            {"id": "msg_1", "type": "message", "role": "assistant", "model": "claude-opus-5-5", "stop_reason": "end_turn",
             "content": [{"type": "thinking", "thinking": "", "signature": "abc"}, {"type": "text", "text": "Blue"}, {"type": "text", "text": "."}],
             "usage": {"input_tokens": 12, "output_tokens": 3}}
            """.utf8))
        }
        await settle(viewer, node)
        let request = try #require(seen.withLock { $0.first })
        #expect(seen.withLock { $0.count } == 1)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test-Sup3rSecret")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.timeoutInterval == 120)
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["max_tokens"] as? Int == 16000)
        #expect(body["system"] as? String == "Answer in one word.")
        #expect(body["fallbacks"] as? String == "default")
        #expect((body["messages"] as? [[String: String]]) == [["role": "user", "content": "Name a color."]])
        // Nothing the API no longer takes.
        for gone in ["temperature", "top_p", "top_k", "thinking"] { #expect(body[gone] == nil, "\(gone)") }
        #expect(!String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("Sup3r"))

        // The answer is the text blocks, not the thinking that comes with them.
        #expect(viewer.runtime.outputValue(PortRef(node: node, port: "text")) == .text("Blue."))
        #expect(viewer.runtime.outputValue(PortRef(node: node, port: "error")) == .text(""))
        #expect(viewer.runtime.outputValue(PortRef(node: node, port: "loading")) == .bool(false))
    }

    @Test func askClaudeSaysWhatWentWrong() async throws {
        // The API's own message for an error.
        var (viewer, node, _) = try asking { _ in
            NetworkResponse(status: 401, body: Data(#"{"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}}"#.utf8))
        }
        await settle(viewer, node)
        #expect(viewer.runtime.outputValue(PortRef(node: node, port: "error")) == .text("invalid x-api-key"))
        #expect(viewer.runtime.outputValue(PortRef(node: node, port: "text")) == .text(""))

        // A request the model declined comes back as a success with a reason to stop.
        (viewer, node, _) = try asking { _ in
            NetworkResponse(status: 200, body: Data(#"{"stop_reason": "refusal", "stop_details": {"type": "refusal", "category": null}, "content": []}"#.utf8))
        }
        await settle(viewer, node)
        #expect(viewer.runtime.outputValue(PortRef(node: node, port: "error")) == .text("Claude declined to answer this."))

        // No connection.
        (viewer, node, _) = try asking { _ in NetworkResponse(status: 0, error: "The Internet connection appears to be offline.") }
        await settle(viewer, node)
        #expect(viewer.runtime.outputValue(PortRef(node: node, port: "error")) == .text("The Internet connection appears to be offline."))
    }

    @Test func aModelWithoutFallbacksIsNotSentThem() async throws {
        let (viewer, node, seen) = try asking(model: "claude-haiku-5-5") { _ in
            NetworkResponse(status: 200, body: Data(#"{"stop_reason": "end_turn", "content": [{"type": "text", "text": "Red"}]}"#.utf8))
        }
        await settle(viewer, node)
        let request = try #require(seen.withLock { $0.first })
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil)
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["fallbacks"] == nil)
        #expect(body["model"] as? String == "claude-haiku-5-5")
        #expect(viewer.runtime.outputValue(PortRef(node: node, port: "text")) == .text("Red"))
    }
}
