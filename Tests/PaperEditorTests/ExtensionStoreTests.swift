import AppKit
import Foundation
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

/// An extension made in memory, and a folder to install it in.
enum Fixture {
    static let counterScript = """
    var total = 0;
    function evaluate(inputs, outputs) {
      if (inputs.add) total += inputs.step;
      outputs.total = total;
    }
    """

    static func manifest(id: String = "com.example.counter", version: String = "1.0.0", extra: String = "") -> String {
        """
        {
          "format": 1, "id": "\(id)", "name": "Counter", "version": "\(version)",
          "patches": [{
            "id": "count", "name": "Count", "summary": "Adds a step each time it is told to.", "category": "Math",
            "script": "patches/count.js",
            "inputs": [ { "id": "add", "type": "pulse" }, { "id": "step", "type": "number", "default": 2 } ],
            "outputs": [ { "id": "total", "type": "number" } ]
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

    /// A folder that is removed when the test is over.
    final class Folder {
        let url: URL
        init() {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("paper-extension-tests-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    @MainActor static func registry(_ packages: PaperExtension..., unavailable: [PaperExtension] = []) -> PatchRegistry {
        PatchRegistry.standard.adding(ExtensionSet(packages, unavailable: unavailable))
    }

    /// A store whose edits are undo steps, as in the app.
    @MainActor static func store(_ package: DocumentPackage = DocumentPackage(), registry: PatchRegistry) -> (DocumentStore, UndoManager) {
        let store = DocumentStore(package: package, registry: registry)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        return (store, undo)
    }
}

extension UndoManager {
    func step(_ body: () -> Void) {
        beginUndoGrouping()
        body()
        endUndoGrouping()
    }
}

@MainActor
@Suite struct ExtensionStoreTests {
    // MARK: Installing

    @Test func installingUpdatingAndRemoving() throws {
        let folder = Fixture.Folder()
        let store = ExtensionStore(directory: folder.url.appendingPathComponent("Installed"))
        #expect(store.installed.isEmpty)

        let entry = try store.install(try Fixture.package())
        #expect(entry.isUsable)
        #expect(store.installed.map(\.id) == ["com.example.counter"])
        #expect(store.registry().library.contains { $0.kind == Fixture.kind })

        // Read again from disk, as on the next launch.
        let again = ExtensionStore(directory: store.directory)
        #expect(again.installed.map(\.package.version.description) == ["1.0.0"])
        #expect(again.installed.first?.package == entry.package)

        // An update replaces it, and one that was switched off stays off.
        store.setEnabled("com.example.counter", false)
        #expect(store.installed.first?.isUsable == false)
        #expect(!store.registry().library.contains { $0.kind == Fixture.kind })
        #expect(store.registry().definition(Fixture.kind)?.isAvailable == false)
        try store.install(try Fixture.package(version: "1.2.0"))
        #expect(store.installed.count == 1)
        #expect(store.installed.first?.package.version.description == "1.2.0")
        #expect(store.installed.first?.isEnabled == false)
        #expect(ExtensionStore(directory: store.directory).installed.first?.isEnabled == false)

        let before = store.revision
        try store.uninstall("com.example.counter")
        #expect(store.installed.isEmpty)
        #expect(store.revision > before)
        #expect(store.registry().definition(Fixture.kind) == nil)
        #expect(ExtensionStore(directory: store.directory).installed.isEmpty)
    }

    @Test func installingFromAFolderRemembersWhereItCameFrom() throws {
        let folder = Fixture.Folder()
        let source = folder.url.appendingPathComponent("Counter.paperextension")
        try Fixture.package(files: ["README.md": "# Counter", "assets/icon.txt": "x"]).write(to: source)
        // What Finder leaves behind is not part of the extension.
        try Data().write(to: source.appendingPathComponent(".DS_Store"))

        let store = ExtensionStore(directory: folder.url.appendingPathComponent("Installed"))
        let entry = try store.install(contentsOf: source)
        #expect(entry.source?.lastPathComponent == "Counter.paperextension")
        #expect(entry.package.files.keys.sorted() == ["README.md", "assets/icon.txt", "extension.json", "patches/count.js"])
        #expect(ExtensionStore(directory: store.directory).installed.first?.source?.path == source.standardizedFileURL.path)
    }

    @Test func aLinkOutOfTheFolderIsRefused() throws {
        let folder = Fixture.Folder()
        let source = folder.url.appendingPathComponent("Counter.paperextension")
        try Fixture.package().write(to: source)
        let outside = folder.url.appendingPathComponent("private.txt")
        try Data("private".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("assets"), withDestinationURL: outside)
        #expect(throws: ExtensionProblem.self) { try PaperExtension(contentsOf: source) }
    }

    @Test func whatCannotBeReadIsListedAsBrokenAndAScriptProblemIsShown() throws {
        let folder = Fixture.Folder()
        let directory = folder.url.appendingPathComponent("Installed")
        let odd = directory.appendingPathComponent("odd.paperextension")
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: odd.appendingPathComponent("extension.json"))
        let store = ExtensionStore(directory: directory)
        #expect(store.installed.isEmpty)
        #expect(store.broken.map(\.name) == ["odd.paperextension"])

        // A script that does not load: installed, but it does not run and says why.
        let entry = try store.install(try Fixture.package(script: "function evaluate( {"))
        #expect(!entry.isUsable)
        #expect(entry.problems.contains { $0.contains("patches/count.js") })
        #expect(store.registry().definition(Fixture.kind)?.isAvailable == false)
    }

    @Test func aLinkedFolderIsUsedWhereItIsAndFollowsItsFiles() throws {
        let folder = Fixture.Folder()
        let source = folder.url.appendingPathComponent("Counter.paperextension")
        try Fixture.package(script: "function evaluate(i, o) { o.total = 1; }").write(to: source)
        let store = ExtensionStore(directory: folder.url.appendingPathComponent("Installed"))
        let entry = try store.link(source)
        #expect(entry.isLinked && entry.isUsable)
        // Nothing was copied.
        #expect(!FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("com.example.counter.paperextension").path))
        #expect(ExtensionStore(directory: store.directory).installed.first?.isLinked == true)

        // Nothing changed: nothing is read again.
        var revision = store.revision
        store.refreshLinked()
        #expect(store.revision == revision)

        // The script is saved with a change, and what runs is the new script.
        try Data("function evaluate(i, o) { o.total = 22; } // edited".utf8).write(to: source.appendingPathComponent("patches/count.js"))
        store.refreshLinked()
        #expect(store.revision == revision + 1)
        var graph = Graph()
        let node = graph.add(PatchNode(kind: Fixture.kind))
        let runtime = Runtime(document: PaperModel.Document(graph: graph), registry: store.registry())
        runtime.tick(dt: 1 / 60)
        #expect(runtime.outputValue(PortRef(node: node, port: "total")) == .number(22))

        // A mistake while writing shows as a problem, and goes when it is fixed.
        try Data("function evaluate( {".utf8).write(to: source.appendingPathComponent("patches/count.js"))
        store.refreshLinked()
        #expect(store.installed.first?.isUsable == false)
        try Data("{".utf8).write(to: source.appendingPathComponent("extension.json"))
        store.refreshLinked()
        #expect(store.installed.isEmpty)
        #expect(store.broken.map(\.name) == ["Counter.paperextension"])
        try Fixture.package().write(to: source)
        store.refreshLinked()
        #expect(store.installed.first?.isUsable == true)

        // Removing the link leaves the folder alone.
        revision = store.revision
        try store.uninstall("com.example.counter")
        #expect(store.installed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("extension.json").path))
        store.refreshLinked()
        #expect(store.installed.isEmpty)

        // Installing a copy ends a link.
        try store.link(source)
        try store.install(contentsOf: source)
        #expect(store.installed.first?.isLinked == false)
        #expect(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("com.example.counter.paperextension").path))
    }

    @Test func aLinkedExtensionThatStartsAskingForMoreLosesItsKey() throws {
        let folder = Fixture.Folder()
        let source = folder.url.appendingPathComponent("Net.paperextension")
        func write(hosts: String) throws {
            try Fixture.package(manifest: Fixture.manifest(
                extra: ##", "network": ["api.example.com", "other.example.com"], "secrets": [{"id": "key", "name": "Key", "hosts": \##(hosts)}]"##
            )).write(to: source)
        }
        try write(hosts: #"["api.example.com"]"#)
        let store = ExtensionStore(directory: folder.url.appendingPathComponent("Installed"))
        let package = try store.link(source).package
        try store.keys.set("secret-value", for: package.manifest.secrets[0], of: package.id)
        #expect(store.keys.entries.count == 1)
        try write(hosts: #"["api.example.com", "other.example.com"]"#)
        store.refreshLinked()
        #expect(store.keys.entries.isEmpty)
        #expect(store.keys.lookup(package.id, store.installed[0].package.manifest.secrets[0]) == nil)
    }

    // MARK: Documents

    @Test func anExtensionPatchIsAddedLikeAnyOther() throws {
        let (store, undo) = Fixture.store(registry: Fixture.registry(try Fixture.package()))
        var node: NodeID!
        undo.step { node = store.addPatch(Fixture.kind) }
        #expect(store.registry.ports(for: store.document.graph.node(node)!).inputs.map(\.id) == ["add", "step"])
        #expect(store.registry.defaultTitle(for: store.document.graph.node(node)!) == "Count")
        undo.step { store.setLiteral(.number(7), node: node, port: "step") }
        #expect(store.document.graph.node(node)?.inputs["step"] == .number(7))

        // An agent adds one by its kind, and reads it back.
        let toolbox = AssistantToolbox(store: store)
        var result: AssistantToolResult!
        undo.step {
            result = toolbox.call("edit_document", input: ["operations": [
                ["op": "add_patch", "kind": Fixture.kind, "ref": "c", "inputs": ["step": 3]],
            ]])
        }
        #expect(!result.isError)
        #expect(store.document.graph.nodes.filter { $0.kind == Fixture.kind }.count == 2)
        #expect(toolbox.call("get_document", input: [:]).text.contains(Fixture.kind))
        #expect(AssistantPrompt.reference(registry: store.registry, components: []).contains(Fixture.kind))
    }

    /// A card holding a Count patch whose Step and Total are published, with cables from
    /// outside on both and one from the patch to a view inside.
    func build(in store: DocumentStore, _ undo: UndoManager) -> (card: LayerID, count: NodeID) {
        var card: LayerID!, dot: LayerID!, count: NodeID!
        undo.step { card = store.addView(.view, name: "Card") }
        store.open(card)
        undo.step { dot = store.addView(.view, name: "Dot") }
        undo.step { count = store.addPatch(Fixture.kind) }
        undo.step { store.setLiteral(.number(9), node: count, port: "step") }
        undo.step { _ = store.connect(from: PortRef(node: count, port: "total"), to: PortRef(node: store.viewNode(for: dot)!.id, port: "opacity")) }
        var step: String!, total: String!
        undo.step { step = store.publish(PortRef(node: count, port: "step"), output: false) }
        undo.step { total = store.publish(PortRef(node: count, port: "total"), output: true) }
        store.closeView()
        var source: NodeID!, sink: NodeID!
        undo.step { source = store.addPatch("add") }
        undo.step { sink = store.addPatch("add") }
        let cardPatch = store.viewNode(for: card)!.id
        undo.step { _ = store.connect(from: PortRef(node: source, port: "result"), to: PortRef(node: cardPatch, port: step)) }
        undo.step { _ = store.connect(from: PortRef(node: cardPatch, port: total), to: PortRef(node: sink, port: "a")) }
        return (card, count)
    }

    @Test func aDocumentEditedWithoutItsExtensionLosesNothing() throws {
        let package = try Fixture.package()
        let (first, undo) = Fixture.store(registry: Fixture.registry(package))
        let made = build(in: first, undo)
        #expect(first.fullDocument.graph.connections.count == 3)
        #expect(first.viewNode(for: made.card)?.published?.count == 2)
        let saved = try DocumentPackage(fileWrapper: first.package.fileWrapper())

        // Opened where the extension is not installed, with and without a carried copy.
        for registry in [PatchRegistry.standard, Fixture.registry(unavailable: [package])] {
            let (store, undo) = Fixture.store(saved, registry: registry)
            #expect(store.fullDocument.graph.connections.count == 3)
            // Edits of every kind: a view, a value, a patch, a move, an undo and a redo.
            var extra: LayerID!
            undo.step { extra = store.addView(.text, name: "Note") }
            undo.step { store.setInput(ViewInput(id: "opacity")!, of: made.card, to: .number(0.5)) }
            undo.step { _ = store.addPatch("switch") }
            undo.step { store.setLiteral(.number(4), node: made.count, port: "step") }
            undo.undo()
            undo.redo()
            store.open(made.card)
            undo.step { _ = store.addView(.view, name: "Another") }
            store.closeView()
            #expect(store.document.layer(extra) != nil)
            #expect(store.fullDocument.graph.connections.count == 3)
            #expect(store.viewNode(for: made.card)?.published?.map(\.name).count == 2)
            #expect(store.fullDocument.graph.node(made.count)?.inputs["step"] == .number(4))

            // Saved there and opened again where the extension is: all of it works.
            let returned = try DocumentPackage(fileWrapper: store.package.fileWrapper())
            let (back, _) = Fixture.store(returned, registry: Fixture.registry(package))
            #expect(back.fullDocument.graph.connections.count == 3)
            #expect(back.viewNode(for: made.card)?.published?.count == 2)
            let runtime = Runtime(document: back.runtimeDocument, registry: back.runtimeRegistry)
            runtime.tick(dt: 1 / 60)
            #expect(runtime.outputValue(PortRef(node: made.count, port: "total")) == .number(0))
        }
    }

    @Test func withoutTheExtensionAnAgentIsToldThePatchCannotBeAdded() throws {
        let (store, undo) = Fixture.store(registry: Fixture.registry(unavailable: [try Fixture.package()]))
        var result: AssistantToolResult!
        undo.step {
            result = AssistantToolbox(store: store).call("edit_document", input: ["operations": [
                ["op": "add_patch", "kind": Fixture.kind],
            ]])
        }
        #expect(result.text.contains("not installed") || result.text.contains("switched off"))
        #expect(store.document.graph.nodes.allSatisfy { $0.kind != Fixture.kind })
        // And it is not in what agents are told they can use.
        #expect(!AssistantPrompt.reference(registry: store.registry, components: []).contains(Fixture.kind))
    }

    // MARK: A running prototype

    @Test func theViewerFollowsWhatIsInstalled() throws {
        let (store, undo) = Fixture.store(registry: Fixture.registry(try Fixture.package(script: "function evaluate(i, o) { o.total = 1; }")))
        var node: NodeID!
        undo.step { node = store.addPatch(Fixture.kind) }
        let viewer = ViewerView(store: store, sendsRequests: false)
        viewer.update(document: store.runtimeDocument, restartToken: store.restartToken)
        viewer.advance(by: 1.0 / 60)
        #expect(viewer.runtime.outputValue(PortRef(node: node, port: "total")) == .number(1))

        let revision = store.registryRevision
        store.setRegistry(Fixture.registry(try Fixture.package(version: "1.1.0", script: "function evaluate(i, o) { o.total = 2; }")))
        #expect(store.registryRevision == revision + 1)
        viewer.advance(by: 1.0 / 60)
        #expect(viewer.runtime.outputValue(PortRef(node: node, port: "total")) == .number(2))

        // The same extensions again change nothing.
        store.setRegistry(Fixture.registry(try Fixture.package(version: "1.1.0", script: "function evaluate(i, o) { o.total = 2; }")))
        #expect(store.registryRevision == revision + 1)

        // A picture is taken with the same definitions.
        #expect(ViewerSnapshot.bitmap(of: store.runtimeDocument, registry: store.runtimeRegistry) != nil)
    }
}

/// Documents that carry a copy of the extensions they use, and what a Mac without one
/// is offered.
@MainActor
@Suite struct ExtensionDocumentTests {
    /// A document with one Count patch, saved where the extension is installed.
    func saved(_ package: PaperExtension) throws -> (DocumentPackage, NodeID) {
        let (store, undo) = Fixture.store(registry: Fixture.registry(package))
        var node: NodeID!
        undo.step { node = store.addPatch(ExtensionKind.make(package.id, "count")) }
        return (store.package, node)
    }

    @Test func aDocumentCarriesACopyOfWhatItUsesAndOnlyThat() throws {
        let counter = try Fixture.package(files: ["README.md": "# Counter", "assets/deep/icon.txt": "x"])
        let other = try Fixture.package(id: "com.example.other")
        let (store, undo) = Fixture.store(registry: Fixture.registry(counter, other))
        #expect(store.package.extensions.isEmpty)
        var node: NodeID!
        undo.step { node = store.addPatch(Fixture.kind) }
        #expect(store.package.extensions.keys.sorted() == ["com.example.counter"])
        #expect(store.package.carried == [counter])

        // To disk and back, folders and all.
        let folder = Fixture.Folder()
        let url = folder.url.appendingPathComponent("Doc.tango")
        try store.package.write(to: url)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("extensions/com.example.counter/assets/deep/icon.txt").path))
        let read = try DocumentPackage(contentsOf: url)
        #expect(read.carried == [counter])
        #expect(read.document == store.fullDocument)

        // The patch goes, and so does the copy; undo brings both back.
        undo.step { store.selectedNodes = [node]; store.deleteSelectedPatches() }
        #expect(store.package.extensions.isEmpty)
        undo.undo()
        #expect(store.package.carried == [counter])

        // The extension is removed from this Mac while the document is open: it still
        // carries what it had.
        store.setRegistry(Fixture.registry(other))
        #expect(store.package.carried == [counter])
        #expect(store.carriedExtensions == [counter])
    }

    @Test func whatADocumentCarriesIsNeverRun() throws {
        let id = "com.example.loud"
        ExtensionLog.shared.clear(id)
        let loud = try Fixture.package(id: id, script: """
        paper.log("loaded");
        paper.fetch("https://example.com/");
        function evaluate(inputs, outputs) { paper.log("ran"); outputs.total = 42; }
        """)
        var (package, node) = try saved(loud)
        // Saving where it was installed did run it; from here on it is only carried.
        ExtensionLog.shared.clear(id)
        package = try DocumentPackage(fileWrapper: package.fileWrapper())

        let folder = Fixture.Folder()
        let installed = ExtensionStore(directory: folder.url)
        let (store, undo) = Fixture.store(package, registry: installed.registry(carrying: package.carried))
        _ = installed.offers(used: store.usedExtensionIDs, carried: store.carriedExtensions)
        undo.step { _ = store.addView(.view) }
        let viewer = ViewerView(store: store, sendsRequests: false)
        for _ in 0..<5 { viewer.advance(by: 1.0 / 60) }
        _ = ViewerSnapshot.bitmap(of: store.runtimeDocument, registry: store.runtimeRegistry)
        _ = AssistantToolbox(store: store).call("get_document", input: [:])
        #expect(viewer.runtime.outputValue(PortRef(node: node, port: "total")) == .number(0))
        #expect(ExtensionLog.shared.entries(for: id).isEmpty)
    }

    @Test func aMacWithoutTheExtensionIsOfferedTheCopy() throws {
        let package = try Fixture.package(version: "1.2.0")
        let (document, node) = try saved(package)
        let folder = Fixture.Folder()
        let installed = ExtensionStore(directory: folder.url)

        let (store, _) = Fixture.store(document, registry: installed.registry(carrying: document.carried))
        #expect(store.registry.definition(Fixture.kind)?.isAvailable == false)
        #expect(store.missingExtension(for: store.document.graph.node(node)!) == "Counter")
        var offers = installed.offers(used: store.usedExtensionIDs, carried: store.carriedExtensions)
        #expect(offers.map(\.id) == ["com.example.counter"])
        guard case let .install(offered) = offers[0].action else {
            Issue.record("expected an offer to install")
            return
        }
        #expect(offered == package)

        // Accepted: it is installed here, and the open document starts using it.
        try installed.install(offered)
        store.setRegistry(installed.registry(carrying: store.carriedExtensions))
        #expect(store.registry.definition(Fixture.kind)?.isAvailable == true)
        #expect(store.missingExtension(for: store.document.graph.node(node)!) == nil)
        #expect(installed.offers(used: store.usedExtensionIDs, carried: store.carriedExtensions).isEmpty)

        // Switched off, it is offered to be switched on.
        installed.setEnabled("com.example.counter", false)
        offers = installed.offers(used: store.usedExtensionIDs, carried: store.carriedExtensions)
        #expect(offers.map(\.action) == [.switchOn])
        installed.setEnabled("com.example.counter", true)

        // An older version installed than the document was made with: the newer is offered.
        try installed.install(try Fixture.package(version: "1.0.0"))
        let (older, _) = Fixture.store(document, registry: installed.registry(carrying: document.carried))
        offers = installed.offers(used: older.usedExtensionIDs, carried: older.carriedExtensions)
        #expect(offers.map(\.action) == [.update(package, from: ExtensionVersion("1.0.0")!)])
        // And the document runs with what is installed, never with its own copy.
        #expect(older.runtimeRegistry.extensions.member("com.example.counter")?.package.version.description == "1.0.0")
        // Saved here, it goes on carrying the newer copy it came with.
        #expect(older.package.carried.first?.version.description == "1.2.0")
    }

    @Test func aDocumentWithNoCopySaysWhatItIsMissing() throws {
        let (document, node) = try saved(try Fixture.package())
        var bare = document
        bare.extensions = [:]
        let folder = Fixture.Folder()
        let installed = ExtensionStore(directory: folder.url)
        let (store, _) = Fixture.store(bare, registry: installed.registry(carrying: bare.carried))
        #expect(installed.offers(used: store.usedExtensionIDs, carried: store.carriedExtensions).map(\.action) == [.missing])
        let patch = store.document.graph.node(node)!
        #expect(store.missingExtension(for: patch) == "com.example.counter")
        #expect(store.title(for: patch) == "Count")
        #expect(store.missingExtension(for: PatchNode(kind: "add")) == nil)
    }

    @Test func aCopyThatIsNotAnExtensionIsKeptButNotOffered() throws {
        let (document, _) = try saved(try Fixture.package())
        var odd = document
        odd.extensions["com.example.counter"] = ["extension.json": Data("{".utf8), "x.js": Data()]
        // A copy filed under another extension's id is not taken for it.
        odd.extensions["com.example.other"] = document.extensions["com.example.counter"]
        #expect(odd.carried.isEmpty)
        let read = try DocumentPackage(fileWrapper: odd.fileWrapper())
        #expect(read.extensions["com.example.counter"]?.keys.sorted() == ["extension.json", "x.js"])
        let folder = Fixture.Folder()
        let (store, _) = Fixture.store(read, registry: ExtensionStore(directory: folder.url).registry(carrying: read.carried))
        #expect(store.carriedExtensions.isEmpty)
        // Saved again, what it had for the extension it uses is still there.
        #expect(store.package.extensions.keys.sorted() == ["com.example.counter"])
    }

    @Test func anUpdateSaysWhatItChanges() throws {
        let old = try Fixture.package(manifest: Fixture.manifest(
            extra: #", "network": ["api.example.com"], "secrets": [{"id": "key", "name": "API Key", "hosts": ["api.example.com"]}]"#
        ))
        let wider = try Fixture.package(manifest: Fixture.manifest(
            version: "2.0.0",
            extra: #", "network": ["api.example.com", "collect.example.net"], "secrets": [{"id": "key", "name": "API Key", "hosts": ["api.example.com", "collect.example.net"]}, {"id": "other", "name": "Other Key", "hosts": ["api.example.com"]}]"#
        ))
        let changes = wider.changes(from: old)
        #expect(changes.filter(\.widens).map(\.text) == [
            "Can now contact collect.example.net",
            "Would also send the key API Key to collect.example.net",
            "Asks for a new key: Other Key",
        ])
        #expect(old.changes(from: wider).allSatisfy { !$0.widens })
        #expect(old.changes(from: old).isEmpty)
    }

    @Test func updatesAreFoundWhereAnExtensionWasInstalledFrom() throws {
        let folder = Fixture.Folder()
        let source = folder.url.appendingPathComponent("Counter.paperextension")
        try Fixture.package().write(to: source)
        let store = ExtensionStore(directory: folder.url.appendingPathComponent("Installed"))
        try store.install(contentsOf: source)
        store.checkForUpdates()
        #expect(store.updates.isEmpty)
        try Fixture.package(version: "1.3.0").write(to: source)
        store.checkForUpdates()
        #expect(store.updates["com.example.counter"]?.version.description == "1.3.0")
        try store.install(store.updates["com.example.counter"]!, from: source)
        #expect(store.updates.isEmpty)
        #expect(store.installed.first?.package.version.description == "1.3.0")
    }
}
