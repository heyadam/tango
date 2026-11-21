import Foundation
import Testing
import PaperModel
@testable import PaperEngine

/// Web requests from an extension's script: asked for with `paper.fetch`, made by the
/// runtime's host, answered on a later frame.
@Suite struct ExtensionRequestTests {
    static let manifest = """
    {
      "format": 1, "id": "com.example.net", "name": "Net", "version": "1.0.0",
      "network": ["api.example.com"],
      "secrets": [{ "id": "apiKey", "name": "API Key", "hosts": ["api.example.com"] }],
      "patches": [{
        "id": "ask", "name": "Ask", "script": "patches/count.js",
        "inputs": [ { "id": "send", "type": "pulse" }, { "id": "query", "type": "text", "default": "hello" }, { "id": "index", "type": "number" } ],
        "outputs": [
          { "id": "loading", "type": "bool" }, { "id": "text", "type": "text" }, { "id": "done", "type": "pulse" },
          { "id": "error", "type": "text" }, { "id": "count", "type": "number" }
        ]
      }]
    }
    """
    static let kind = "com.example.net/ask"

    static let ask = """
    async function load(query) {
      outputs.loading = true;
      const reply = await paper.fetch("https://api.example.com/v1/ask?q=" + encodeURIComponent(query), {
        headers: { "X-Api-Key": paper.secret("apiKey") }
      });
      outputs.loading = false;
      if (reply.ok) { outputs.text = reply.json.answer; outputs.done = true; }
      else outputs.error = reply.error;
    }
    function evaluate(inputs, outputs) { if (inputs.send) load(inputs.query); }
    """

    /// A runtime with one Ask patch, whose Send is pulsed by `send()`, and the requests it made.
    final class Rig {
        let runtime: Runtime
        let node: NodeID
        let trigger: NodeID
        var sent: [NetworkRequest] = []

        init(script: String, handler: Bool = true, loop: Int? = nil) throws {
            let package = try TestExtension.package(manifest: ExtensionRequestTests.manifest, files: ["patches/count.js": script])
            var graph = Graph()
            let button = Layer(kind: .view, properties: [.size: .size(Size2(width: 100, height: 100))])
            trigger = graph.add(.interaction(on: button.id))
            node = graph.add(PatchNode(kind: ExtensionRequestTests.kind))
            graph.connect(from: PortRef(node: trigger, port: "tap"), to: PortRef(node: node, port: "send"))
            if let loop {
                let source = graph.add(PatchNode(kind: "loop", inputs: ["count": .number(Double(loop))]))
                graph.connect(from: PortRef(node: source, port: "index"), to: PortRef(node: node, port: "index"))
            }
            let document = Document(screen: Layer(kind: .screen, children: [button]), graph: graph)
            runtime = Runtime(document: document, registry: PatchRegistry.standard.adding(ExtensionSet([package])))
            if handler { runtime.requestHandler = { [unowned self] in self.sent.append($0) } }
            runtime.tick(dt: 1 / 60)
        }

        func send() {
            runtime.send(.touchDown(Point2(x: 50, y: 50)))
            runtime.tick(dt: 1 / 60)
            runtime.send(.touchUp(Point2(x: 50, y: 50)))
            runtime.tick(dt: 1 / 60)
            // The tap is told from a double tap only after a moment.
            runtime.advance(seconds: 0.5)
        }

        func answer(_ index: Int = 0, _ body: String, status: Int = 200) {
            runtime.complete(sent[index].id, with: NetworkResponse(status: status, body: Data(body.utf8)))
        }

        func out(_ port: String) -> Value? { runtime.outputValue(PortRef(node: node, port: port)) }
        func outs(_ port: String) -> [Value] { runtime.outputValues(PortRef(node: node, port: port)) }
    }

    @Test func aRequestGoesOutAndItsAnswerComesBack() throws {
        let rig = try Rig(script: Self.ask)
        #expect(rig.sent.isEmpty)
        rig.send()
        #expect(rig.sent.count == 1)
        let request = rig.sent[0]
        #expect(request.url == "https://api.example.com/v1/ask?q=hello")
        #expect(request.method == "GET")
        #expect(request.origin == "com.example.net")
        // The script holds a placeholder, never a key.
        #expect(request.headers["X-Api-Key"] == Script.secretOpen + "apiKey" + Script.secretClose)
        #expect(rig.out("loading") == .bool(true))
        // Waiting costs no frames.
        #expect(!rig.runtime.needsAnotherFrame)

        rig.answer(0, #"{"answer": "hi there"}"#)
        #expect(rig.runtime.needsAnotherFrame)
        rig.runtime.tick(dt: 1 / 60)
        #expect(rig.out("loading") == .bool(false))
        #expect(rig.out("text") == .text("hi there"))
        // A pulse set after the answer lasts one frame, like any other.
        #expect(rig.out("done") == .pulse(true))
        rig.runtime.tick(dt: 1 / 60)
        #expect(rig.out("done") == .pulse(false))
        #expect(rig.out("text") == .text("hi there"))
        rig.runtime.advance(seconds: 0.2)
        #expect(!rig.runtime.needsAnotherFrame)
    }

    @Test func anAnswerThatIsNotASuccessIsAnErrorNotAnException() throws {
        let rig = try Rig(script: Self.ask)
        rig.send()
        rig.answer(0, "nope", status: 500)
        rig.runtime.tick(dt: 1 / 60)
        #expect(rig.out("error") == .text("The server answered 500."))
        #expect(rig.out("loading") == .bool(false))

        rig.send()
        rig.runtime.complete(rig.sent[1].id, with: NetworkResponse(status: 0, error: "The request timed out."))
        rig.runtime.tick(dt: 1 / 60)
        #expect(rig.out("error") == .text("The request timed out."))
    }

    @Test func oneRequestCanFollowAnother() throws {
        let rig = try Rig(script: """
        async function chain() {
          const first = await paper.fetch("https://api.example.com/first");
          const second = await paper.fetch("https://api.example.com/second", { method: "post", body: { id: first.json.id } });
          outputs.text = second.text;
          outputs.count = second.status;
        }
        function evaluate(inputs, outputs) { if (inputs.send) chain(); }
        """)
        rig.send()
        #expect(rig.sent.map(\.url) == ["https://api.example.com/first"])
        rig.answer(0, #"{"id": 7}"#)
        rig.runtime.tick(dt: 1 / 60)
        #expect(rig.sent.count == 2)
        #expect(rig.sent[1].method == "POST")
        #expect(rig.sent[1].body == #"{"id":7}"#)
        #expect(rig.sent[1].headers["Content-Type"] == "application/json")
        rig.answer(1, "done", status: 201)
        rig.runtime.tick(dt: 1 / 60)
        #expect(rig.out("text") == .text("done"))
        #expect(rig.out("count") == .number(201))
    }

    @Test func withNobodyToMakeItARequestFailsOnTheNextFrame() throws {
        let rig = try Rig(script: Self.ask, handler: false)
        rig.send()
        rig.runtime.advance(seconds: 0.1)
        #expect(rig.out("error") == .text("This player cannot make network requests."))
        #expect(rig.out("loading") == .bool(false))
        #expect(!rig.runtime.needsAnotherFrame)
    }

    @Test func aHostThatAnswersAtOnceIsHeardToo() throws {
        let rig = try Rig(script: Self.ask, handler: false)
        rig.runtime.requestHandler = { [unowned rig] request in
            rig.runtime.complete(request.id, with: NetworkResponse(body: Data(#"{"answer": "now"}"#.utf8)))
        }
        rig.send()
        rig.runtime.advance(seconds: 0.1)
        #expect(rig.out("text") == .text("now"))
    }

    @Test func whatWasAwaitingAnAnswerAndNeverEndsIsCutOffForGood() throws {
        ExtensionLog.shared.clear("com.example.net")
        let rig = try Rig(script: """
        var runs = 0;
        async function load() {
          await paper.fetch("https://api.example.com/slow");
          while (true) {}
        }
        function evaluate(inputs, outputs) { runs += 1; outputs.count = runs; if (inputs.send) load(); }
        """)
        rig.send()
        let before = rig.out("count")
        rig.answer(0, "{}")
        let started = Date()
        rig.runtime.tick(dt: 1 / 60)
        #expect(Date().timeIntervalSince(started) < 1)
        // It is not entered again: taps and frames cost nothing and change nothing.
        let after = Date()
        rig.send()
        rig.runtime.advance(seconds: 0.5)
        #expect(Date().timeIntervalSince(after) < 0.2)
        #expect(rig.out("count") == before)
        #expect(rig.sent.count == 1)
        #expect(ExtensionLog.shared.entries(for: "com.example.net").contains { $0.message == Script.tooLong })
    }

    @Test func anEndlessChainOfAwaitsIsCutOffToo() throws {
        let rig = try Rig(script: """
        async function spin() { while (true) { await null; } }
        function evaluate(inputs, outputs) { if (inputs.send) spin(); outputs.count = 1; }
        """)
        let started = Date()
        rig.send()
        #expect(Date().timeIntervalSince(started) < 1.5)
        rig.runtime.advance(seconds: 0.2)
        #expect(Date().timeIntervalSince(started) < 1.5)
    }

    @Test func onlySoManyRequestsWaitAtOnce() throws {
        let rig = try Rig(script: """
        function evaluate(inputs, outputs) {
          if (!inputs.send) return;
          for (var i = 0; i < 20; i++) {
            paper.fetch("https://api.example.com/" + i).then(function (reply) { if (!reply.ok) outputs.count += 1; });
          }
        }
        """)
        rig.send()
        #expect(rig.sent.count == Script.mostRequests)
        // The rest were refused at once.
        #expect(rig.out("count") == .number(Double(20 - Script.mostRequests)))
    }

    @Test func anAnswerThatComesAfterARestartIsIgnored() throws {
        let rig = try Rig(script: Self.ask)
        rig.send()
        rig.runtime.restart()
        rig.runtime.tick(dt: 1 / 60)
        rig.answer(0, #"{"answer": "late"}"#)
        rig.runtime.advance(seconds: 0.1)
        #expect(rig.out("text") == .text(""))
        #expect(rig.out("loading") == .bool(false))
    }

    @Test func anEditKeepsWaitingAndANewScriptDoesNot() throws {
        let rig = try Rig(script: Self.ask)
        rig.send()
        // The document changes elsewhere: the patch still gets its answer.
        var document = rig.runtime.document
        document.graph.add(PatchNode(kind: "add"))
        rig.runtime.update(document: document)
        rig.runtime.tick(dt: 1 / 60)
        rig.answer(0, #"{"answer": "kept"}"#)
        rig.runtime.advance(seconds: 0.1)
        #expect(rig.out("text") == .text("kept"))

        // The extension is updated while a request is out: the new script did not ask.
        rig.send()
        let changed = try TestExtension.package(manifest: Self.manifest, files: ["patches/count.js": Self.ask + "\n// 1.1"])
        rig.runtime.update(registry: PatchRegistry.standard.adding(ExtensionSet([changed])))
        rig.runtime.tick(dt: 1 / 60)
        rig.answer(1, #"{"answer": "stale"}"#)
        rig.runtime.advance(seconds: 0.1)
        #expect(rig.out("text") != .text("stale"))
    }

    @Test func eachItemOfALoopAsksAndIsAnsweredForItself() throws {
        let rig = try Rig(script: """
        async function load(query) {
          const reply = await paper.fetch("https://api.example.com/item/" + query);
          outputs.text = reply.text;
        }
        var asked = false;
        function evaluate(inputs, outputs) { if (!asked) { asked = true; load(inputs.index); } }
        """, loop: 3)
        #expect(rig.sent.map(\.url).sorted() == (0..<3).map { "https://api.example.com/item/\($0)" })
        // Answered out of order, each lands in its own row.
        for request in rig.sent.reversed() {
            rig.runtime.complete(request.id, with: NetworkResponse(body: Data(("for " + request.url.suffix(1)).utf8)))
        }
        rig.runtime.tick(dt: 1 / 60)
        #expect(rig.outs("text") == [.text("for 0"), .text("for 1"), .text("for 2")])

        // The loop gets shorter while a request of its last item is out.
        var document = rig.runtime.document
        let loop = document.graph.nodes.first { $0.kind == "loop" }!.id
        document.graph.update(loop) { $0.inputs["count"] = .number(4) }
        rig.runtime.update(document: document)
        rig.runtime.tick(dt: 1 / 60)
        #expect(rig.sent.count == 4)
        document.graph.update(loop) { $0.inputs["count"] = .number(2) }
        rig.runtime.update(document: document)
        rig.runtime.tick(dt: 1 / 60)
        rig.runtime.complete(rig.sent[3].id, with: NetworkResponse(body: Data("gone".utf8)))
        rig.runtime.advance(seconds: 0.1)
        #expect(rig.outs("text") == [.text("for 0"), .text("for 1")])
    }

    @Test func aScriptCanLogAndAJavaScriptPatchHasNoWayOut() throws {
        ExtensionLog.shared.clear("com.example.net")
        let rig = try Rig(script: """
        function evaluate(inputs, outputs) { if (inputs.send) paper.log("asked", { query: inputs.query }, 3); }
        """)
        rig.send()
        let said = ExtensionLog.shared.entries(for: "com.example.net")
        #expect(said.map(\.message) == [#"asked {"query":"hello"} 3"#])
        #expect(said.first?.isError == false)

        // A JavaScript patch travels inside a document, so it is given nothing to reach out with.
        let plain = Script.Instance(source: """
        inputs = {}; outputs = { has: "" };
        function evaluate(inputs, outputs) { outputs.has = typeof paper + " " + typeof fetch + " " + typeof XMLHttpRequest; }
        """)
        #expect(plain.run(inputs: [], outputs: [.text("")], time: 0) == [.text("undefined undefined undefined")])

        // And `paper` cannot be swapped for something else by the script.
        let fixed = try Rig(script: """
        function evaluate(inputs, outputs) { try { paper = null; paper.fetch = null; } catch (e) {} outputs.text = typeof paper.fetch; }
        """)
        #expect(fixed.out("text") == .text("function"))
    }
}
