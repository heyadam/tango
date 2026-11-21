import AppKit
import Foundation
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

/// Things found by reviewing and by trying to break extensions: each test is a way one
/// went wrong, or a thing a hostile or careless extension might do.
@MainActor
@Suite struct ExtensionQATests {
    static let kind = "com.example.charts/bar"

    func registry(_ script: String) throws -> PatchRegistry {
        Fixture.registry(try ExtensionViewStoreTests.package(script: script))
    }

    /// A 200 × 200 screen with one drawn view on it.
    func document(size: Size2) -> PaperModel.Document {
        var view = Layer.new(.custom, name: "Drawn")
        view.custom = CustomViewUse(kind: Self.kind)
        view.properties[.size] = .size(size)
        var screen = Layer.new(.screen)
        screen.properties[.size] = .size(Size2(width: 200, height: 200))
        screen.children = [view]
        return PaperModel.Document(screen: screen)
    }

    // MARK: Found in review

    @Test func aViewOfAnySizeIsDrawnOrLeftOutButNeverStopsTheApp() throws {
        let registry = try registry("function draw(canvas, inputs, size) { canvas.fillRect(0, 0, size.width, size.height); }")
        for size in [
            Size2(width: 1e20, height: 20), Size2(width: 20, height: 1e300), Size2(width: 0, height: 0),
            Size2(width: -50, height: 30), Size2(width: 0.2, height: 0.2), Size2(width: 5000, height: 5000),
        ] {
            #expect(ViewerSnapshot.bitmap(of: document(size: size), registry: registry) != nil, "\(size)")
        }
        // A size that arrives by cable is as unbounded as one that is stored.
        var driven = document(size: Size2(width: 50, height: 50))
        let patch = driven.graph.viewNode(layer: driven.screen.children[0].id)!.id
        let huge = driven.graph.add(PatchNode(kind: "multiply", inputs: ["a": .number(1e15), "b": .number(1e15)]))
        driven.graph.connect(from: PortRef(node: huge, port: "result"), to: PortRef(node: patch, port: "width"))
        #expect(ViewerSnapshot.bitmap(of: driven, registry: registry) != nil)
    }

    @Test func aPatchThatWasStoppedNoLongerAsksForFrames() throws {
        let package = try Fixture.package(script: "everyFrame = true; var runs = 0; function evaluate(i, o) { runs += 1; if (runs > 2) while (true) {} }")
        var graph = Graph()
        graph.add(PatchNode(kind: Fixture.kind))
        let runtime = Runtime(document: PaperModel.Document(graph: graph), registry: Fixture.registry(package))
        runtime.tick(dt: 1 / 60)
        #expect(runtime.needsAnotherFrame)
        for _ in 0..<4 { runtime.tick(dt: 1 / 60) }
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func aFolderWithAnEnormousFileIsRefusedWithoutReadingIt() throws {
        let folder = Fixture.Folder()
        let source = folder.url.appendingPathComponent("Big.paperextension")
        try Fixture.package().write(to: source)
        // A file that says it is 8 GB and takes no room on disk.
        let big = source.appendingPathComponent("movie.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: 8_000_000_000)
        try handle.close()
        let started = Date()
        #expect(throws: ExtensionProblem.self) { try PaperExtension(contentsOf: source) }
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test func whatCannotBeReadCanBeClearedAway() throws {
        let folder = Fixture.Folder()
        let source = folder.url.appendingPathComponent("Counter.paperextension")
        try Fixture.package().write(to: source)
        let store = ExtensionStore(directory: folder.url.appendingPathComponent("Installed"))
        try store.link(source)
        try store.keys.set("value", for: try ExtensionKeyTests.package().manifest.secrets[0], of: "com.example.counter")

        // The linked folder is moved away.
        let moved = folder.url.appendingPathComponent("Elsewhere.paperextension")
        try FileManager.default.moveItem(at: source, to: moved)
        store.reload()
        #expect(store.installed.isEmpty)
        let link = try #require(store.broken.first)
        #expect(link.linkedID == "com.example.counter")
        try store.remove(link)
        #expect(store.broken.isEmpty)
        #expect(ExtensionStore(directory: store.directory).broken.isEmpty)
        #expect(store.keys.entries.isEmpty)
        // Removing a link never touches someone's folder.
        #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("extension.json").path))

        // A folder among the installed ones that is not an extension: the folder goes.
        let odd = store.directory.appendingPathComponent("odd.paperextension")
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: odd.appendingPathComponent("extension.json"))
        store.reload()
        let item = try #require(store.broken.first)
        #expect(item.linkedID == nil)
        try store.remove(item)
        #expect(store.broken.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: odd.path))
    }

    @Test func aLongAnswerDoesNotGetTheScriptStopped() throws {
        ExtensionLog.shared.clear("com.example.net")
        let package = try Fixture.package(manifest: ExtensionNetworkTests.manifestText, files: ["patches/count.js": """
        var asked = false;
        function evaluate(inputs, outputs) {
          if (asked) return;
          asked = true;
          paper.fetch("https://api.example.com/list").then(function (reply) {
            outputs.text = String(reply.text.length) + " " + reply.json.items.length;
          });
        }
        """])
        var graph = Graph()
        let node = graph.add(PatchNode(kind: "com.example.net/ask"))
        let runtime = Runtime(document: PaperModel.Document(graph: graph), registry: Fixture.registry(package))
        var sent: [NetworkRequest] = []
        runtime.requestHandler = { sent.append($0) }
        runtime.tick(dt: 1 / 60)
        // Six megabytes of JSON.
        let items = (0..<120_000).map { #"{"id": \#($0), "name": "item number \#($0)", "tags": ["a", "b"]}"# }.joined(separator: ",")
        let body = Data(("{\"items\": [" + items + "]}").utf8)
        #expect(body.count > 6_000_000)
        runtime.complete(sent[0].id, with: NetworkResponse(body: body))
        runtime.tick(dt: 1 / 60)
        #expect(runtime.outputValue(PortRef(node: node, port: "text")) == .text("\(body.count) 120000"))
        #expect(!ExtensionLog.shared.entries(for: "com.example.net").contains { $0.isError })
    }

    @Test func anAgentAndAPersonMakeTheSameView() throws {
        let registry = try registry(ExtensionViewStoreTests.bar)
        let (byHand, undoA) = Fixture.store(registry: registry)
        var first: LayerID!
        undoA.step { first = byHand.addExtensionView(registry.view(Self.kind)!) }
        let (byAgent, undoB) = Fixture.store(registry: registry)
        var result: AssistantToolResult!
        undoB.step {
            result = AssistantToolbox(store: byAgent).call("edit_document", input: ["operations": [
                ["op": "add_view", "kind": Self.kind, "ref": "bar", "inputs": ["amount": 0.25, "Tint": "#00FF00"]],
                ["op": "add_patch", "kind": "add", "ref": "sum"],
                ["op": "connect", "from": "sum", "output": "result", "to": "bar", "input": "amount"],
                ["op": "set_inputs", "patch": "bar", "inputs": ["tint": "#0000FF"]],
            ]])
        }
        #expect(!result.text.contains("error"), "\(result.text)")
        let made = try #require(byAgent.document.screen.children.first)
        let hand = try #require(byHand.document.layer(first))
        #expect(made.custom?.kind == hand.custom?.kind)
        #expect(made.custom?.inputCount == hand.custom?.inputCount)
        #expect(made.value(.size) == hand.value(.size))
        #expect(made.custom?.inputs == ["amount": .number(0.25), "tint": .color(ColorValue(hex: "#0000FF")!)])
        #expect(byAgent.document.graph.connections.map(\.to.port) == ["ext.amount"])
        // What an agent reads back is what it would ask for.
        let read = AssistantToolbox(store: byAgent).call("get_document", input: [:]).text
        #expect(read.replacingOccurrences(of: "\\/", with: "/").contains("com.example.charts/bar"))
        #expect(read.contains("extension_view"))

        // An input the view does not have is refused, and the view is not left behind.
        undoB.step {
            result = AssistantToolbox(store: byAgent).call("edit_document", input: ["operations": [
                ["op": "add_view", "kind": Self.kind, "inputs": ["nothing": 1]],
            ]])
        }
        #expect(result.text.contains("has no input"))
        #expect(byAgent.document.screen.children.count == 1)
    }

    // MARK: Trying to break it

    @Test func aScriptThatMisusesItsPortsBreaksOnlyItself() throws {
        let scripts = [
            "function evaluate(i, o) { o.total = { not: 'a number' }; }",
            "function evaluate(i, o) { o.total = undefined; o.extra = 5; delete o.total; }",
            "function evaluate(i, o) { Object.defineProperty(o, 'total', { get: function () { throw new Error('no'); } }); }",
            "function evaluate(i, o) { outputs = 5; inputs = null; o.total = NaN; }",
            "function evaluate(i, o) { function deep(n) { return deep(n + 1); } deep(0); }",
            "function evaluate(i, o) { o.total = 1 / 0; paper.fetch(); paper.fetch({}, 5); paper.secret(); paper.log(); }",
            "function evaluate(i, o) { var a = {}; a.self = a; paper.fetch('https://x.example.com', { body: a }); }",
            "function evaluate(i, o) { paper.fetch('https://x.example.com', { headers: new Proxy({}, { ownKeys: function () { throw 1; } }) }); }",
            "function evaluate(i, o) { o.total = 'x'.repeat(5000000).length; }",
            "var evaluate = 7;",
            "throw new Error('at load');",
        ]
        for script in scripts {
            let package = try Fixture.package(script: script)
            var graph = Graph()
            let node = graph.add(PatchNode(kind: Fixture.kind))
            let runtime = Runtime(document: PaperModel.Document(graph: graph), registry: Fixture.registry(package))
            runtime.requestHandler = { _ in }
            for _ in 0..<3 { runtime.tick(dt: 1 / 60) }
            let total = runtime.outputValue(PortRef(node: node, port: "total"))
            // Whatever it did, its output is still a finite number.
            #expect(total?.type == .number, "\(script)")
            #expect(total?.numberValue.isFinite == true, "\(script)")
        }
    }

    @Test func aDrawingMeantToTakeForeverIsCutShort() throws {
        let scripts = [
            // Twenty thousand long lines of text.
            "function draw(c, i, s) { var t = 'word '.repeat(4000); for (var n = 0; n < 30000; n++) c.fillText(t, 0, n % 100); }",
            // Blurred shadows over the whole view, again and again.
            "function draw(c, i, s) { c.shadowColor = 'black'; c.shadowBlur = 500; for (var n = 0; n < 30000; n++) c.fillRect(0, 0, s.width, s.height); }",
            // A font no one can read, saves without end, a gradient with too many stops.
            "function draw(c, i, s) { c.font = 'bold 1e12px x'; c.fillText('A', 0, 0); for (var n = 0; n < 1e5; n++) c.save(); var g = c.createLinearGradient(0, 0, 1, 1); for (var k = 0; k < 1e4; k++) g.addColorStop(k / 1e4, 'red'); c.fillStyle = g; c.fillRect(0, 0, 9, 9); }",
            // Paths with numbers that are not numbers.
            "function draw(c, i, s) { c.beginPath(); c.arc(NaN, 1/0, -5, 'a', {}, 7); c.roundRect(0, 0, -1e9, 1e9, 1e9); c.scale(0, 0); c.rotate(1e308); c.fill(); c.stroke(); c.clip(); c.fillRect(0, 0, 5, 5); }",
        ]
        for script in scripts {
            let started = Date()
            let picture = ViewerSnapshot.bitmap(of: document(size: Size2(width: 150, height: 150)), registry: try registry(script))
            #expect(picture != nil)
            #expect(Date().timeIntervalSince(started) < 3, "took \(Date().timeIntervalSince(started)) s: \(script.prefix(60))")
        }
    }

    @Test func addressesWrittenToConfuse() throws {
        let manifest = try ExtensionNetworkTests.package().manifest
        func sent(_ url: String, headers: [String: String] = [:]) -> URLRequest? {
            try? ExtensionNetwork.prepare(
                NetworkRequest(url: url, headers: headers, origin: manifest.id), for: manifest, key: { _ in "secret-key-value" }
            ).get().request
        }
        let key = Script.secretOpen + "apiKey" + Script.secretClose
        // Allowed, however it is spelled.
        #expect(sent("HTTPS://API.Example.COM/v1")?.url?.host?.lowercased() == "api.example.com")
        #expect(sent("https://api.example.com:8443/v1")?.url?.port == 8443)
        // Not the host it looks like.
        for url in [
            "https://api.example.com./", "https://api.example.com%2eevil.net/", "https://api.example.com%00.evil.net/",
            "https://api.example.com\u{202E}ten.live/", "https://аpi.example.com/", "https://api.example.com:443@evil.net/",
            "https://evil.net/api.example.com", "https://api.example.com.evil.net:443/", "https:///api.example.com",
            "https:/api.example.com", "https:api.example.com", "data:text/plain,api.example.com", " https://api.example.com/",
        ] {
            let request = sent(url)
            #expect(request == nil || request?.url?.host?.lowercased() == "api.example.com", "\(url) went to \(request?.url?.host ?? "?")")
        }
        // A key rides only to its own host, wherever in the address it is put.
        for url in [
            "https://other.example.com/?k=" + key, "https://api.example.com/#" + key + "@evil.net",
            "https://api.example.com/?next=https://evil.net/&k=" + key,
        ] {
            let request = sent(url)
            if let request {
                #expect(request.url?.host == "api.example.com", "\(url)")
            }
        }
        // Two keys in one request, and a tab in a header, are fine; the key lands once per mention.
        let twice = sent("https://api.example.com/?a=" + key + "&b=" + key, headers: ["X-A": "a\tb " + key])
        #expect(twice?.url?.query == "a=secret-key-value&b=secret-key-value")
        #expect(twice?.value(forHTTPHeaderField: "X-A") == "a\tb secret-key-value")
        // A very long address is refused, not truncated.
        #expect(sent("https://api.example.com/?q=" + String(repeating: "a", count: 20_000)) == nil)
    }

    @Test func manifestsWrittenToConfuse() throws {
        func problem(_ manifest: String, files: [String: String] = [:]) -> String {
            do {
                _ = try Fixture.package(manifest: manifest, files: files)
                return ""
            } catch { return error.localizedDescription }
        }
        func with(_ field: String, _ value: String) -> String {
            Fixture.manifest().replacingOccurrences(of: "\"\(field)\": \"", with: "\"\(field)\": \"\(value)")
        }
        // An id that would be a path, a kind, or someone else's.
        for id in ["a/b", "a b", "A.B", ".hidden", "a..b", "a.", "", String(repeating: "a", count: 200), "view/x", "a\\b", "a\u{0000}b"] {
            let escaped = id.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\u{0000}", with: "\\u0000")
            #expect(!problem(Fixture.manifest(id: escaped)).isEmpty, "\(id.debugDescription) was taken as an id")
        }
        // Files outside the folder, by any spelling.
        for path in ["/etc/passwd", "../x.js", "a/../../x.js", "./x.js", "a//x.js", ".git/config", "~/x.js", "a\\..\\x.js", ""] {
            let manifest = Fixture.manifest().replacingOccurrences(of: "patches/count.js", with: path.replacingOccurrences(of: "\\", with: "\\\\"))
            #expect(!problem(manifest, files: [path: "function evaluate() {}"]).isEmpty, "\(path.debugDescription) was taken as a path")
        }
        // Hosts that are not hosts.
        for host in ["*", "*.com.", "*.*", "a.com/path", "a.com:80", "http://a.com", "a..com", "-a.com", "user@a.com", "*.a.*.com", " a.com", "a.com,b.com"] {
            #expect(!problem(Fixture.manifest(extra: #", "network": ["\#(host)"]"#)).isEmpty, "\(host.debugDescription) was taken as a host")
        }
        // The same id for a patch and a view, and a view that is both drawn and a shader.
        let clash = Fixture.manifest(extra: #", "views": [{"id": "count", "draw": "patches/count.js"}]"#)
        #expect(problem(clash).contains("more than one"))
        let both = Fixture.manifest(extra: #", "views": [{"id": "v", "draw": "patches/count.js", "shader": "patches/count.js"}]"#)
        #expect(problem(both).contains("either"))
        // A manifest that is enormous, or nested without end, is refused rather than hanging.
        let deep = String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)
        let started = Date()
        _ = problem(Fixture.manifest().replacingOccurrences(of: #""default": 2"#, with: "\"default\": \(deep)"))
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func kindsInADocumentThatAreNotWhatTheySeem() throws {
        // A document can say anything in a kind. None of it reaches the file system or a script.
        var graph = Graph()
        for kind in ["../../etc/x", "/abs/x", "a/", "/x", "a/b/c", "com.example.counter/missing", "com.example.counter/count/extra", "/", ""] {
            graph.add(PatchNode(kind: kind))
        }
        var document = PaperModel.Document(graph: graph)
        var odd = Layer.new(.custom, name: "Odd")
        odd.custom = CustomViewUse(kind: "../../x/y")
        document.screen.children = [odd]
        document.normalize()
        let (store, undo) = Fixture.store(DocumentPackage(document: document), registry: Fixture.registry(try Fixture.package()))
        undo.step { _ = store.addView(.view) }
        let saved = store.package
        // Only ids that are ids are carried, and only those the registry has a copy of.
        #expect(saved.extensions.keys.allSatisfy(ExtensionManifest.isExtensionID))
        let folder = Fixture.Folder()
        try saved.write(to: folder.url.appendingPathComponent("Doc.tango"))
        let written = try FileManager.default.subpathsOfDirectory(atPath: folder.url.path)
        #expect(written.allSatisfy { !$0.contains("..") })
        #expect(ViewerSnapshot.bitmap(of: store.runtimeDocument, registry: store.runtimeRegistry) != nil)
        let offers = ExtensionStore(directory: folder.url.appendingPathComponent("Installed")).offers(used: store.usedExtensionIDs, carried: store.carriedExtensions)
        #expect(offers.allSatisfy { if case .install = $0.action { false } else { true } } || offers.contains { $0.id == "com.example.counter" })
    }
}
