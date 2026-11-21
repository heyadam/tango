import AppKit
import Foundation
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

/// Keys people enter for extensions. Every test keeps them in memory: none touches the
/// Mac's keychain.
@MainActor
@Suite struct ExtensionKeyTests {
    nonisolated static let value = "sk-live-Sup3r/Secret+Key=="

    static func manifest(version: String = "1.0.0", hosts: String = #"["api.example.com"]"#, network: String = #"["api.example.com", "other.example.com"]"#) -> String {
        """
        {
          "format": 1, "id": "com.example.net", "name": "Net", "version": "\(version)",
          "network": \(network),
          "secrets": [{ "id": "apiKey", "name": "API Key", "hosts": \(hosts) }],
          "patches": [{
            "id": "ask", "name": "Ask", "script": "patches/count.js",
            "inputs": [ { "id": "send", "type": "pulse" } ],
            "outputs": [ { "id": "text", "type": "text" }, { "id": "error", "type": "text" } ]
          }]
        }
        """
    }

    static func package(version: String = "1.0.0", hosts: String = #"["api.example.com"]"#, script: String = "function evaluate() {}") throws -> PaperExtension {
        try Fixture.package(manifest: manifest(version: version, hosts: hosts), files: ["patches/count.js": script])
    }

    @Test func aKeyIsKeptForOneExtensionAndTheHostsItDeclared() throws {
        let vault = MemoryVault()
        let keys = ExtensionKeys(vault: vault)
        let package = try Self.package()
        let secret = package.manifest.secrets[0]
        #expect(keys.status(of: secret, in: package.id) == .missing)
        #expect(keys.needed(by: package).map(\.id) == ["apiKey"])
        #expect(keys.lookup(package.id, secret) == nil)

        try keys.set("  \(Self.value)\n", for: secret, of: package.id)
        guard case .saved = keys.status(of: secret, in: package.id) else {
            Issue.record("the key was not saved")
            return
        }
        #expect(keys.needed(by: package).isEmpty)
        #expect(keys.lookup(package.id, secret) == Self.value)
        #expect(keys.entries.map(\.hosts) == [["api.example.com"]])
        // Not for another extension that names its key the same.
        #expect(keys.lookup("com.example.impostor", secret) == nil)
        // Not for a key of another name.
        var other = secret
        other.id = "other"
        #expect(keys.lookup(package.id, other) == nil)

        // Replacing keeps one entry; removing takes the value out of the vault.
        try keys.set("second", for: secret, of: package.id)
        #expect(keys.entries.count == 1)
        #expect(keys.lookup(package.id, secret) == "second")
        keys.remove(keys.entries[0])
        #expect(keys.lookup(package.id, secret) == nil)
        #expect(vault.isEmpty)
    }

    @Test func aKeyIsNotHandedToAVersionThatWouldSendItFurther() throws {
        let keys = ExtensionKeys()
        let first = try Self.package()
        try keys.set(Self.value, for: first.manifest.secrets[0], of: first.id)

        // What goes by the same id now declares another host for the key.
        let wider = try Self.package(version: "2.0.0", hosts: #"["api.example.com", "other.example.com"]"#)
        let secret = wider.manifest.secrets[0]
        #expect(keys.lookup(wider.id, secret) == nil)
        #expect(keys.status(of: secret, in: wider.id) == .outgrown(added: ["other.example.com"]))
        #expect(keys.needed(by: wider).map(\.id) == ["apiKey"])
        // The version it was entered for still gets it.
        #expect(keys.lookup(first.id, first.manifest.secrets[0]) == Self.value)

        // Entered again, it is agreed to for both.
        try keys.set(Self.value, for: secret, of: wider.id)
        #expect(keys.lookup(wider.id, secret) == Self.value)
        // A version that asks for less is covered by what was agreed to.
        #expect(keys.lookup(first.id, first.manifest.secrets[0]) == Self.value)
    }

    @Test func installingAndRemovingSettleTheKeys() throws {
        let folder = Fixture.Folder()
        let vault = MemoryVault()
        let store = ExtensionStore(directory: folder.url, vault: vault)
        let first = try store.install(try Self.package()).package
        try store.keys.set(Self.value, for: first.manifest.secrets[0], of: first.id)

        // What is known of the keys is written down; the value is not.
        let written = try String(contentsOf: folder.url.appendingPathComponent("keys.json"), encoding: .utf8)
        #expect(written.contains("api.example.com"))
        #expect(!written.contains("Sup3r"))
        // The next launch knows the key is there without opening the vault.
        let again = ExtensionStore(directory: folder.url, vault: vault)
        #expect(again.keys.needed(by: first).isEmpty)
        #expect(again.keys.lookup(first.id, first.manifest.secrets[0]) == Self.value)

        // An update that asks for no more keeps the key.
        try store.install(try Self.package(version: "1.1.0"))
        #expect(store.keys.entries.count == 1)
        // One that would send it further does not inherit it.
        let wider = try store.install(try Self.package(version: "2.0.0", hosts: #"["api.example.com", "other.example.com"]"#)).package
        #expect(store.keys.entries.isEmpty)
        #expect(vault.isEmpty)
        #expect(store.keys.lookup(wider.id, wider.manifest.secrets[0]) == nil)

        // Uninstalling takes its keys with it.
        try store.keys.set(Self.value, for: wider.manifest.secrets[0], of: wider.id)
        #expect(!vault.isEmpty)
        try store.uninstall(wider.id)
        #expect(store.keys.entries.isEmpty)
        #expect(vault.isEmpty)
    }

    @Test func aDocumentIsToldWhichKeysAreMissing() throws {
        let folder = Fixture.Folder()
        let store = ExtensionStore(directory: folder.url)
        let package = try store.install(try Self.package()).package
        #expect(store.offers(used: [package.id], carried: []).map(\.action) == [.needsKeys(["API Key"])])
        try store.keys.set(Self.value, for: package.manifest.secrets[0], of: package.id)
        #expect(store.offers(used: [package.id], carried: []).isEmpty)
        // An extension the document does not use is none of its business.
        #expect(store.offers(used: [], carried: []).isEmpty)
    }

    @Test func theKeyReachesTheRequestAndNothingElse() async throws {
        let folder = Fixture.Folder()
        let installed = ExtensionStore(directory: folder.url)
        let package = try installed.install(try Self.package(script: """
        var asked = false;
        function evaluate(inputs, outputs) {
          if (asked) return;
          asked = true;
          paper.fetch("https://api.example.com/echo", { headers: { "Authorization": "Bearer " + paper.secret("apiKey") } }).then(function (reply) {
            outputs.text = reply.text;
            outputs.error = reply.error;
            paper.log("got", reply.text, reply.headers);
          });
        }
        """)).package
        try installed.keys.set(Self.value, for: package.manifest.secrets[0], of: package.id)
        ExtensionLog.shared.clear(package.id)

        let (store, undo) = Fixture.store(registry: installed.registry())
        var node: NodeID!
        undo.step { node = store.addPatch("com.example.net/ask") }
        let seen = Shared<[URLRequest]>([])
        let viewer = ViewerView(store: store)
        viewer.keyLookup = installed.keys.lookup
        viewer.extensionTransport = { request in
            seen.withLock { $0.append(request) }
            let sent = request.value(forHTTPHeaderField: "Authorization") ?? ""
            return NetworkResponse(status: 200, body: Data("you sent: \(sent)".utf8), headers: ["x-echo": sent])
        }
        viewer.update(document: store.runtimeDocument, restartToken: store.restartToken)
        viewer.runtime.restart()
        viewer.advance(by: 1.0 / 60)
        let text = PortRef(node: node, port: "text")
        for _ in 0..<200 where viewer.runtime.outputValue(text)?.textValue.isEmpty != false {
            try? await Task.sleep(for: .milliseconds(5))
            viewer.advance(by: 1.0 / 60)
        }

        // The request carried it.
        #expect(seen.withLock { $0.first }?.value(forHTTPHeaderField: "Authorization") == "Bearer " + Self.value)
        #expect(viewer.runtime.outputValue(text) == .text("you sent: Bearer [key]"))

        // Nowhere a script, a document, an agent or a picture's maker could read it.
        func clean(_ text: String, _ place: String) {
            #expect(!text.contains("Sup3r"), "the key is in \(place)")
        }
        clean(String(decoding: try store.fullDocument.encoded(), as: UTF8.self), "the document")
        for (id, files) in store.package.extensions {
            for (path, data) in files { clean(String(decoding: data, as: UTF8.self), "the carried copy \(id)/\(path)") }
        }
        var answer: AssistantToolResult!
        undo.step { answer = AssistantToolbox(store: store).call("get_document", input: [:]) }
        clean(answer.text, "what an agent reads")
        clean(AssistantPrompt.reference(registry: store.registry, components: []), "the agent reference")
        for entry in ExtensionLog.shared.entries(for: package.id) { clean(entry.message, "the extension's log") }
        #expect(ExtensionLog.shared.entries(for: package.id).contains { $0.message.contains("[key]") })
        for (_, values) in [("text", viewer.runtime.outputValues(text)), ("error", viewer.runtime.outputValues(PortRef(node: node, port: "error")))] {
            for value in values { clean(value.textValue, "an output") }
        }
        clean((try? String(contentsOf: folder.url.appendingPathComponent("keys.json"), encoding: .utf8)) ?? "", "keys.json")
        clean((try? String(contentsOf: folder.url.appendingPathComponent("state.json"), encoding: .utf8)) ?? "", "state.json")
    }

    @Test func aViewerWithNoKeysRefusesRatherThanSendingWithoutOne() async throws {
        let package = try Self.package(script: """
        var asked = false;
        function evaluate(inputs, outputs) {
          if (asked) return;
          asked = true;
          paper.fetch("https://api.example.com/", { headers: { "X-Key": paper.secret("apiKey") } }).then(function (reply) { outputs.error = reply.error; });
        }
        """)
        let (store, undo) = Fixture.store(registry: Fixture.registry(package))
        var node: NodeID!
        undo.step { node = store.addPatch("com.example.net/ask") }
        let calls = Shared(0)
        let viewer = ViewerView(store: store)
        viewer.extensionTransport = { _ in calls.withLock { $0 += 1 }; return NetworkResponse() }
        viewer.update(document: store.runtimeDocument, restartToken: store.restartToken)
        viewer.runtime.restart()
        viewer.advance(by: 1.0 / 60)
        let error = PortRef(node: node, port: "error")
        for _ in 0..<200 where viewer.runtime.outputValue(error)?.textValue.isEmpty != false {
            try? await Task.sleep(for: .milliseconds(5))
            viewer.advance(by: 1.0 / 60)
        }
        #expect(viewer.runtime.outputValue(error)?.textValue.contains("needs the key API Key") == true)
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func theLookupIsSafeFromOtherThreads() async throws {
        let keys = ExtensionKeys()
        let package = try Self.package()
        let secret = package.manifest.secrets[0]
        try keys.set(Self.value, for: secret, of: package.id)
        let lookup = keys.lookup
        let found = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<50 { group.addTask { lookup("com.example.net", secret) } }
            var all: [String?] = []
            for await value in group { all.append(value) }
            return all
        }
        #expect(found.count == 50)
        #expect(found.allSatisfy { $0 == Self.value })
    }
}
