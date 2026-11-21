import AppKit
import Foundation
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

/// Components an extension ships, and making one from a document.
@MainActor
@Suite struct ExtensionComponentTests {
    static let manifest = """
    {
      "format": 1, "id": "com.example.kit", "name": "Kit", "version": "1.0.0",
      "patches": [{ "id": "count", "name": "Count", "script": "patches/count.js",
        "inputs": [ { "id": "add", "type": "pulse" }, { "id": "step", "type": "number", "default": 2 } ],
        "outputs": [ { "id": "total", "type": "number" } ] }],
      "components": ["components/Badge.json", "components/Card.json"]
    }
    """

    /// A document with two components of its own: a Badge with a picture, and a Card
    /// that holds a Badge, an iOS Button and a Count patch of the extension.
    func source() throws -> (DocumentPackage, PaperExtension) {
        let base = try Fixture.package(manifest: Fixture.manifest(id: "com.example.kit"))
        let (store, undo) = Fixture.store(registry: Fixture.registry(base))
        store.assets["dot.png"] = Data([1, 2, 3])
        var picture: LayerID!, card: LayerID!
        undo.step { picture = store.addView(.image, name: "Picture") }
        undo.step { store.setInput(ViewInput(id: "image")!, of: picture, to: .text("dot.png")) }
        store.selectedLayers = [picture]
        undo.step { _ = store.createComponentFromSelection(named: "Badge") }
        let badge = try #require(store.fullDocument.components.first)

        undo.step { card = store.addView(.view, name: "Body") }
        store.selectedLayers = [card]
        undo.step { _ = store.createComponentFromSelection(named: "Card") }
        let made = try #require(store.fullDocument.components.first { $0.id != badge.id })
        store.enterComponent(made.id)
        undo.step { _ = store.insertComponent(store.fullDocument.component(badge.id)!) }
        undo.step { _ = store.insertComponent(ComponentLibrary.iOS("Button")) }
        undo.step { _ = store.addPatch("com.example.kit/count") }
        store.exitComponent()
        return (store.package, base)
    }

    @Test func aComponentIsWrittenForAnExtensionAndComesBackWhole() throws {
        let (document, base) = try source()
        let folder = Fixture.Folder()
        let extensionFolder = folder.url.appendingPathComponent("Kit.paperextension")
        try base.write(to: extensionFolder)
        let paths = try ExtensionStore.export(component: "card", of: document, to: extensionFolder)
        // The component, and the document's own component it is made of. Not the iOS Button.
        #expect(paths == ["components/Card.json", "components/Badge.json"])
        #expect(FileManager.default.fileExists(atPath: extensionFolder.appendingPathComponent("assets/dot.png").path))
        try Data(Self.manifest.utf8).write(to: extensionFolder.appendingPathComponent(ExtensionManifest.fileName))
        #expect(throws: ExtensionProblem.self) { try ExtensionStore.export(component: "nothing", of: document, to: extensionFolder) }

        let package = try PaperExtension(contentsOf: extensionFolder)
        #expect(package.problems().isEmpty)
        let registry = Fixture.registry(package)
        #expect(registry.shelves.map(\.name) == ["Kit"])
        #expect(registry.shelves[0].components.map(\.name) == ["Badge", "Card"])
        #expect(registry.shelves[0].components.allSatisfy { $0.library == "Kit" })

        // In a new document: on the shelf, and inserted with everything it is made of.
        let (store, undo) = Fixture.store(registry: registry)
        #expect(store.componentShelves.map(\.name) == ["iOS", "Kit"])
        let card = try #require(store.libraryComponents.first { $0.name == "Card" })
        var instance: LayerID?
        undo.step { instance = store.insertComponent(card) }
        #expect(instance != nil)
        #expect(Set(store.fullDocument.components.map(\.name)) == ["Card", "Badge", "Button"])
        // Its picture came along, and the component now names it as the document has it.
        #expect(store.assets["dot.png"] == Data([1, 2, 3]))
        let badge = try #require(store.fullDocument.components.first { $0.name == "Badge" })
        #expect(badge.root.flattened.contains { $0.properties[.image] == .text("dot.png") })
        // The extension's patch inside it runs, and the document carries the extension.
        #expect(store.usedExtensionIDs == ["com.example.kit"])
        #expect(store.package.carried == [package])
        let runtime = Runtime(document: store.runtimeDocument, registry: store.runtimeRegistry)
        runtime.tick(dt: 1 / 60)
        #expect(runtime.resolved.find(instance!)?.children.isEmpty == false)

        // A second one adds no second copy; undo takes the first away again.
        undo.step { _ = store.insertComponent(card) }
        #expect(store.fullDocument.components.count == 3)
        // An agent finds it by name, and is told of it.
        var result: AssistantToolResult!
        undo.step {
            result = AssistantToolbox(store: store).call("edit_document", input: ["operations": [["op": "insert_component", "component": "badge"]]])
        }
        #expect(!result.isError && !result.text.contains("No component"))
        #expect(AssistantPrompt.reference(registry: store.registry, components: store.fullDocument.components).contains("- Card"))
        #expect(AssistantPrompt.reference(registry: store.registry, components: []).contains("- Card"))
    }

    @Test func aPictureOfTheSameNameIsNotOverwritten() throws {
        let (document, base) = try source()
        let folder = Fixture.Folder()
        let extensionFolder = folder.url.appendingPathComponent("Kit.paperextension")
        try base.write(to: extensionFolder)
        _ = try ExtensionStore.export(component: "Badge", of: document, to: extensionFolder)
        try Data(Self.manifest.replacingOccurrences(of: #", "components/Card.json""#, with: "").utf8)
            .write(to: extensionFolder.appendingPathComponent(ExtensionManifest.fileName))
        let package = try PaperExtension(contentsOf: extensionFolder)
        let (store, undo) = Fixture.store(registry: Fixture.registry(package))
        store.assets["dot.png"] = Data([9, 9])
        undo.step { _ = store.insertComponent(store.libraryComponents.first { $0.name == "Badge" }!) }
        #expect(store.assets["dot.png"] == Data([9, 9]))
        #expect(store.assets["dot 2.png"] == Data([1, 2, 3]))
        #expect(store.fullDocument.components[0].root.flattened.contains { $0.properties[.image] == .text("dot 2.png") })
    }

    @Test func aComponentFileThatCannotBeReadIsAProblemNotACrash() throws {
        let broken = try Fixture.package(
            manifest: Fixture.manifest(id: "com.example.kit", extra: #", "components": ["components/Bad.json"]"#),
            files: ["components/Bad.json": "{ \"name\": 4 }"]
        )
        #expect(broken.problems().contains { $0.contains("components/Bad.json") })
        #expect(Fixture.registry(broken).shelves.isEmpty)
        let folder = Fixture.Folder()
        let entry = try ExtensionStore(directory: folder.url).install(broken)
        #expect(!entry.isUsable)
    }

    @Test func aComponentWhoseRootIsAShaderKeepsItWhenUsed() throws {
        var root = Layer.new(.shader, name: "Glow")
        root.shader = ShaderUse(source: "float4 shader(Frame frame, Inputs in) { return float4(1, 0, 0, 1); }")
        let definition = ComponentDefinition(name: "Glow", root: root, graph: PaperModel.Document(screen: root).graph)
        var document = PaperModel.Document(screen: Layer(kind: .screen, children: [definition.instance(name: "One")]))
        document.components = [definition]
        document.normalize()
        let instance = document.screen.children[0].id
        let runtime = Runtime(document: document)
        runtime.tick(dt: 1 / 60)
        #expect(runtime.resolved.find(instance)?.shader?.source == root.shader?.source)
    }
}
