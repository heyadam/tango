import Foundation
import Testing
import PaperModel
@testable import PaperEngine

/// A small extension made in memory, for tests.
enum TestExtension {
    static let counterScript = """
    var total = 0;
    function evaluate(inputs, outputs) {
      if (inputs.add) total += inputs.step;
      outputs.total = total;
      outputs.label = inputs.prefix + " " + total;
    }
    """

    static func manifest(
        id: String = "com.example.counter", version: String = "1.0.0", extra: String = ""
    ) -> String {
        """
        {
          "format": 1, "id": "\(id)", "name": "Counter", "version": "\(version)", "author": "Example",
          "patches": [{
            "id": "count", "name": "Count", "summary": "Adds a step each time it is told to.", "category": "Math",
            "script": "patches/count.js",
            "inputs": [
              { "id": "add", "type": "pulse" },
              { "id": "step", "type": "number", "default": 2 },
              { "id": "prefix", "name": "Label Prefix", "type": "text", "default": "Total" }
            ],
            "outputs": [ { "id": "total", "type": "number" }, { "id": "label", "type": "text" } ]
          }]\(extra)
        }
        """
    }

    static func package(
        id: String = "com.example.counter", version: String = "1.0.0", script: String = counterScript,
        manifest: String? = nil, files: [String: String] = [:]
    ) throws -> PaperExtension {
        var all = files.mapValues { Data($0.utf8) }
        all[ExtensionManifest.fileName] = Data((manifest ?? self.manifest(id: id, version: version)).utf8)
        if all["patches/count.js"] == nil { all["patches/count.js"] = Data(script.utf8) }
        return try PaperExtension(files: all)
    }

    static let kind = "com.example.counter/count"
}

@Suite struct ExtensionTests {
    func problem(_ make: @autoclosure () throws -> PaperExtension) -> String {
        do {
            _ = try make()
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: The manifest

    @Test func aManifestSaysWhatAnExtensionAdds() throws {
        let package = try TestExtension.package()
        let manifest = package.manifest
        #expect(manifest.id == "com.example.counter")
        #expect(manifest.version.description == "1.0.0")
        #expect(manifest.patches.map { manifest.kind(of: $0) } == [TestExtension.kind])
        let patch = manifest.patches[0]
        #expect(patch.inputs.map(\.type) == [.pulse, .number, .text])
        #expect(patch.inputs[1].defaultValue == .number(2))
        #expect(patch.patchCategory == .math)
        #expect(package.problems().isEmpty)
    }

    @Test func aManifestThatIsWrongSaysWhere() throws {
        #expect(problem(try PaperExtension(files: [:])).contains("extension.json"))
        #expect(problem(try TestExtension.package(id: "Bad ID")).contains("lowercase"))
        #expect(problem(try TestExtension.package(id: "../escape")).contains("lowercase"))
        #expect(problem(try TestExtension.package(version: "one")).contains("version"))
        #expect(problem(try TestExtension.package(manifest: "{ not json")).contains("JSON"))
        #expect(problem(try TestExtension.package(manifest: #"{"format": 1, "id": "a.b", "version": "1"}"#)).contains("\"name\" is missing"))
        #expect(problem(try TestExtension.package(manifest: #"{"format": 9, "id": "a.b", "name": "A", "version": "1"}"#)).contains("newer version"))

        // A script the manifest names must be in the package, and inside it.
        let missing = #"{"format": 1, "id": "a.b", "name": "A", "version": "1", "patches": [{"id": "p", "script": "patches/other.js"}]}"#
        #expect(problem(try TestExtension.package(manifest: missing)).contains("patches/other.js"))
        let outside = #"{"format": 1, "id": "a.b", "name": "A", "version": "1", "patches": [{"id": "p", "script": "../../secret.js"}]}"#
        #expect(problem(try TestExtension.package(manifest: outside)).contains("not a path inside"))
        #expect(problem(try TestExtension.package(files: ["../evil.js": ""])).contains("not a file name"))

        // Ports: one id once, a default that fits.
        let twice = TestExtension.manifest().replacingOccurrences(of: #"{ "id": "add", "type": "pulse" }"#, with: #"{ "id": "step", "type": "pulse" }"#)
        #expect(problem(try TestExtension.package(manifest: twice)).contains("declared twice"))
        let misfit = TestExtension.manifest().replacingOccurrences(of: #""default": 2"#, with: #""default": "two""#)
        #expect(problem(try TestExtension.package(manifest: misfit)).contains("does not fit"))
    }

    @Test func hostsAndKeysAreChecked() throws {
        func with(_ extra: String) -> String { problem(try TestExtension.package(manifest: TestExtension.manifest(extra: extra))) }
        #expect(with(#", "network": ["https://api.example.com/v1"]"#).contains("not a host name"))
        #expect(with(#", "network": ["api.example.com"], "secrets": [{"id": "key", "hosts": ["other.example.com"]}]"#).contains("not in network"))
        #expect(with(#", "network": ["*.example.com"], "secrets": [{"id": "key", "hosts": ["*.example.com"]}]"#).contains("exact host"))
        #expect(with(#", "network": ["localhost"], "secrets": [{"id": "key", "hosts": ["localhost"]}]"#).contains("this Mac"))
        #expect(with(#", "network": ["api.example.com"], "secrets": [{"id": "key", "hosts": []}]"#).contains("hosts"))

        let good = try TestExtension.package(manifest: TestExtension.manifest(
            extra: #", "network": ["API.example.com", "*.cdn.example.com"], "secrets": [{"id": "key", "name": "API Key", "hosts": ["api.example.com"]}]"#
        ))
        #expect(good.manifest.allows(host: "api.example.com"))
        #expect(good.manifest.allows(host: "a.cdn.example.com"))
        #expect(!good.manifest.allows(host: "cdn.example.com"))
        #expect(!good.manifest.allows(host: "evilapi.example.com"))
        #expect(!good.manifest.allows(host: "api.example.com.evil.net"))
        #expect(good.manifest.secret("key")?.hosts == ["api.example.com"])
    }

    @Test func versionsCompareNumberByNumber() {
        func v(_ text: String) -> ExtensionVersion { ExtensionVersion(text)! }
        #expect(v("1.10.0") > v("1.9.3"))
        #expect(v("2") > v("1.99"))
        #expect(v("1.0") == v("1.0.0"))
        #expect(v("1.0").hashValue == v("1.0.0").hashValue)
        #expect(ExtensionVersion("1.x") == nil)
        #expect(ExtensionVersion("") == nil)
        #expect(ExtensionVersion("-1") == nil)
    }

    @Test func aProblemInAScriptIsFoundWithoutInstalling() throws {
        let broken = try TestExtension.package(script: "function evaluate( {")
        #expect(broken.problems().contains { $0.contains("patches/count.js") })
        let nameless = try TestExtension.package(script: "var x = 1;")
        #expect(nameless.problems().contains { $0.contains("evaluate") })
        let filed = TestExtension.manifest().replacingOccurrences(of: #""category": "Math""#, with: #""category": "Wizardry""#)
        #expect(try TestExtension.package(manifest: filed).problems().contains { $0.contains("Wizardry") })
    }

    // MARK: Patches

    func registry(_ package: PaperExtension, available: Bool = true) -> PatchRegistry {
        PatchRegistry.standard.adding(available ? ExtensionSet([package]) : ExtensionSet(unavailable: [package]))
    }

    @Test func itsPatchesAreInTheRegistryWithTheManifestsPorts() throws {
        let registry = registry(try TestExtension.package())
        let definition = try #require(registry.definition(TestExtension.kind))
        #expect(definition.name == "Count")
        #expect(definition.category == .math)
        #expect(definition.origin == PatchOrigin(id: "com.example.counter", name: "Counter"))
        #expect(registry.library.contains { $0.kind == TestExtension.kind })
        let ports = registry.ports(for: PatchNode(kind: TestExtension.kind))
        #expect(ports.inputs.map(\.id) == ["add", "step", "prefix"])
        #expect(ports.inputs.map(\.name) == ["Add", "Step", "Label Prefix"])
        #expect(ports.outputs.map(\.type) == [.number, .text])
        #expect(registry.literal(for: ports.inputs[1], of: PatchNode(kind: TestExtension.kind)) == .number(2))
        // The built-in patches are all still there.
        #expect(registry.library.count == PatchRegistry.standard.library.count + 1)
        #expect(ExtensionKind.extensionID(of: TestExtension.kind) == "com.example.counter")
        #expect(PatchRegistry.standard.library.allSatisfy { ExtensionKind.extensionID(of: $0.kind) == nil })
    }

    /// A button, and a Count patch that adds each time it is tapped.
    func tapScene(inputs: [String: Value] = [:]) -> (document: Document, count: NodeID) {
        var graph = Graph()
        let button = Layer(kind: .view, properties: [.size: .size(Size2(width: 100, height: 100))])
        let touch = graph.add(.interaction(on: button.id))
        let count = graph.add(PatchNode(kind: TestExtension.kind, inputs: inputs))
        graph.connect(from: PortRef(node: touch, port: "tap"), to: PortRef(node: count, port: "add"))
        return (Document(screen: Layer(kind: .screen, children: [button]), graph: graph), count)
    }

    func tap(_ runtime: Runtime) {
        runtime.send(.touchDown(Point2(x: 50, y: 50)))
        runtime.tick(dt: 1 / 60)
        runtime.send(.touchUp(Point2(x: 50, y: 50)))
        runtime.advance(seconds: 0.5)
    }

    @Test func anExtensionPatchRunsItsScript() throws {
        let scene = tapScene(inputs: ["step": .number(5)])
        let runtime = Runtime(document: scene.document, registry: registry(try TestExtension.package()))
        runtime.tick(dt: 1 / 60)
        // Before anything happens the outputs have the manifest's defaults.
        #expect(runtime.outputValue(PortRef(node: scene.count, port: "label")) == .text("Total 0"))
        for _ in 0..<3 { tap(runtime) }
        #expect(runtime.outputValue(PortRef(node: scene.count, port: "total")) == .number(15))
        #expect(runtime.outputValue(PortRef(node: scene.count, port: "label")) == .text("Total 15"))
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func withoutTheExtensionThePatchIsLeftAloneAndDoesNothing() throws {
        let scene = tapScene()
        // Carried by the document but not installed: the ports are known, the code is not run.
        let carried = registry(try TestExtension.package(), available: false)
        #expect(carried.definition(TestExtension.kind)?.isAvailable == false)
        #expect(carried.definition(TestExtension.kind)?.script == nil)
        #expect(!carried.library.contains { $0.kind == TestExtension.kind })
        #expect(carried.ports(for: PatchNode(kind: TestExtension.kind)).inputs.count == 3)
        let runtime = Runtime(document: scene.document, registry: carried)
        tap(runtime)
        #expect(runtime.outputValue(PortRef(node: scene.count, port: "total")) == .number(0))

        // Not known at all: no ports, and still nothing breaks.
        let bare = Runtime(document: scene.document)
        tap(bare)
        #expect(bare.outputValue(PortRef(node: scene.count, port: "total")) == nil)
        #expect(!PatchRegistry.standard.knows(PatchNode(kind: TestExtension.kind)))
    }

    @Test func eachItemOfALoopHasItsOwnScript() throws {
        let script = """
        var runs = 0;
        function evaluate(inputs, outputs) { runs += 1; outputs.total = inputs.step * 10 + runs; }
        """
        var graph = Graph()
        let loop = graph.add(PatchNode(kind: "loop", inputs: ["count": .number(3)]))
        let count = graph.add(PatchNode(kind: TestExtension.kind))
        graph.connect(from: PortRef(node: loop, port: "index"), to: PortRef(node: count, port: "step"))
        let runtime = Runtime(document: Document(graph: graph), registry: registry(try TestExtension.package(script: script)))
        runtime.tick(dt: 1 / 60)
        #expect(runtime.outputValues(PortRef(node: count, port: "total")) == [.number(1), .number(11), .number(21)])
    }

    @Test func aScriptThatNeverEndsIsStoppedAndSaysSo() throws {
        let package = try TestExtension.package(id: "com.example.runaway", script: "function evaluate() { while (true) {} }")
        let kind = "com.example.runaway/count"
        ExtensionLog.shared.clear("com.example.runaway")
        var graph = Graph()
        let node = graph.add(PatchNode(kind: kind))
        let runtime = Runtime(document: Document(graph: graph), registry: registry(package))
        let started = Date()
        runtime.tick(dt: 1 / 60)
        // It is not run again: a second frame costs nothing.
        runtime.tick(dt: 1 / 60)
        runtime.tick(dt: 1 / 60)
        #expect(Date().timeIntervalSince(started) < 1.5)
        #expect(runtime.outputValue(PortRef(node: node, port: "total")) == .number(0))
        let said = ExtensionLog.shared.entries(for: "com.example.runaway")
        #expect(said.contains { $0.message == Script.tooLong && $0.item == "Count" && $0.isError })
    }

    @Test func aScriptThatThrowsIsReportedOnceWithACount() throws {
        let package = try TestExtension.package(id: "com.example.thrower", script: "everyFrame = true; function evaluate() { missing(); }")
        ExtensionLog.shared.clear("com.example.thrower")
        var graph = Graph()
        graph.add(PatchNode(kind: "com.example.thrower/count"))
        let runtime = Runtime(document: Document(graph: graph), registry: registry(package))
        for _ in 0..<5 { runtime.tick(dt: 1 / 60) }
        let said = ExtensionLog.shared.entries(for: "com.example.thrower")
        #expect(said.count == 1)
        #expect(said.first?.count == 5)
        #expect(said.first?.message.contains("missing") == true)
    }

    // MARK: Changing what is installed while a prototype runs

    @Test func changingTheRegistryKeepsWhatDidNotChange() throws {
        var scene = tapScene()
        let toggle = scene.document.graph.add(PatchNode(kind: "switch"))
        let touch = scene.document.graph.nodes.first { $0.kind == PatchKind.interaction }!.id
        scene.document.graph.connect(from: PortRef(node: touch, port: "tap"), to: PortRef(node: toggle, port: "flip"))
        let first = try TestExtension.package()
        let runtime = Runtime(document: scene.document, registry: registry(first))
        runtime.tick(dt: 1 / 60)
        tap(runtime)
        #expect(runtime.outputValue(PortRef(node: toggle, port: "on")) == .bool(true))
        #expect(runtime.outputValue(PortRef(node: scene.count, port: "total")) == .number(2))

        // Another extension arrives: nothing that was running starts over.
        let other = try TestExtension.package(id: "com.example.other")
        runtime.update(registry: PatchRegistry.standard.adding(ExtensionSet([first, other])))
        runtime.tick(dt: 1 / 60)
        #expect(runtime.outputValue(PortRef(node: toggle, port: "on")) == .bool(true))
        #expect(runtime.outputValue(PortRef(node: scene.count, port: "total")) == .number(2))

        // The extension is updated: its own patch starts over with the new script, the Switch stays on.
        let updated = try TestExtension.package(version: "1.1.0", script: "function evaluate(inputs, outputs) { outputs.total = 100; }")
        runtime.update(registry: registry(updated))
        runtime.tick(dt: 1 / 60)
        #expect(runtime.outputValue(PortRef(node: toggle, port: "on")) == .bool(true))
        #expect(runtime.outputValue(PortRef(node: scene.count, port: "total")) == .number(100))

        // It is switched off: the patch stops, and its ports stay.
        runtime.update(registry: registry(updated, available: false))
        tap(runtime)
        #expect(runtime.outputValue(PortRef(node: toggle, port: "on")) == .bool(false))
        #expect(runtime.outputValue(PortRef(node: scene.count, port: "total")) != nil)
    }

    // MARK: A document whose extension is missing

    /// A card that holds a Count patch, publishes its Step input and its Total output, and
    /// has cables on both from outside.
    func published() -> (document: Document, cables: Int) {
        let dot = Layer(name: "Dot", kind: .view)
        let card = Layer(name: "Card", kind: .view, children: [dot])
        var document = Document(screen: Layer(kind: .screen, children: [card]))
        let cardPatch = document.graph.viewNode(layer: card.id)!.id
        var count = PatchNode(kind: TestExtension.kind)
        count.home = card.id
        let inner = document.graph.add(count)
        let step = PublishedPort(name: "Step", inner: PortRef(node: inner, port: "step"), isOutput: false, type: .number)
        let total = PublishedPort(name: "Total", inner: PortRef(node: inner, port: "total"), isOutput: true, type: .number)
        document.graph.update(cardPatch) { $0.published = [step, total] }
        let source = document.graph.add(PatchNode(kind: "add"))
        let sink = document.graph.add(PatchNode(kind: "add"))
        document.graph.connect(from: PortRef(node: source, port: "result"), to: PortRef(node: cardPatch, port: step.id))
        document.graph.connect(from: PortRef(node: cardPatch, port: total.id), to: PortRef(node: sink, port: "a"))
        // And a plain cable from the patch to a view.
        let dotPatch = document.graph.viewNode(layer: dot.id)!.id
        document.graph.connect(from: PortRef(node: inner, port: "total"), to: PortRef(node: dotPatch, port: "opacity"))
        return (document, document.graph.connections.count)
    }

    @Test func settlingNeverPrunesAgainstAPatchItDoesNotKnow() throws {
        let scene = published()
        #expect(scene.cables == 3)
        let package = try TestExtension.package()
        for registry in [registry(package), registry(package, available: false), PatchRegistry.standard] {
            var document = scene.document
            document.normalize(measure: registry.with(components: []).height)
            registry.settlePublished(in: &document)
            #expect(document.graph.connections.count == 3)
            let card = document.graph.nodes.first { $0.published != nil }
            #expect(card?.published?.map(\.name) == ["Step", "Total"])
            // Saved and read again, it is the same.
            let again = try Document.decode(from: document.encoded())
            #expect(again.graph.connections.count == 3)
            #expect(again.graph.nodes.first { $0.published != nil }?.published?.count == 2)
        }

        // With the extension, a port it no longer has does go, as for any patch.
        var document = scene.document
        let trimmed = TestExtension.manifest().replacingOccurrences(of: #"{ "id": "step", "type": "number", "default": 2 },"#, with: "")
        registry(try TestExtension.package(manifest: trimmed)).settlePublished(in: &document)
        #expect(document.graph.nodes.first { $0.published != nil }?.published?.map(\.name) == ["Total"])
        #expect(document.graph.connections.count == 2)
    }
}
