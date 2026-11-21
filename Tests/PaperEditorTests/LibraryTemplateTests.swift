import AppKit
import Foundation
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

/// Templates from the library: containers that are copied into the document as plain views.
@MainActor
@Suite struct LibraryTemplateTests {
    func makeStore() -> (DocumentStore, UndoManager) {
        let store = DocumentStore()
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        return (store, undo)
    }

    func step(_ undo: UndoManager, _ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    @Test func aTemplateIsCopiedInAsPlainViewsWithItsPorts() throws {
        let (store, undo) = makeStore()
        let template = try #require(ComponentLibrary.template("List Section"))
        var first: LayerID?, second: LayerID?
        step(undo) { first = store.insertTemplate(template) }
        let firstID = try #require(first)
        let section = try #require(store.document.layer(firstID))
        #expect(section.name == "List Section")
        #expect(section.kind == .view)
        #expect(section.id != template.root.id)
        #expect(section.children.map(\.name) == ["Header Row", "Rows", "Footer Row"])
        #expect(section.children[1].children.map(\.kind) == [.component, .component])
        #expect(store.fullDocument.components.map(\.name) == ["List Row"])

        // What the root publishes is on its patch, and setting it reaches the text inside.
        let patch = try #require(store.viewNode(for: section.id))
        let ports = store.visiblePorts(for: patch)
        #expect(ports.inputs.map(\.name).suffix(5) == ["Header", "Shows Header", "Footer", "Shows Footer", "Dark"])
        let header = try #require(ports.inputs.first { $0.name == "Header" })
        step(undo) { store.setLiteral(.text("Network"), node: patch.id, port: header.id) }
        #expect(store.document.layer(section.children[0].children[0].id)?.value(.text) == .text("Network"))

        // A second copy shares nothing with the first but the component.
        step(undo) { second = store.insertTemplate(template) }
        let secondID = try #require(second)
        let other = try #require(store.document.layer(secondID))
        #expect(other.name == "List Section 2")
        #expect(Set(other.flattened.map(\.id)).isDisjoint(with: section.flattened.map(\.id)))
        #expect(store.document.layer(other.children[0].children[0].id)?.value(.text) == .text("Section"))
        #expect(store.fullDocument.components.count == 1)

        // Each insert is one undo step.
        undo.undo()
        #expect(store.document.layer(other.id) == nil)
        undo.undo()
        undo.undo()
        #expect(store.document.screen.children.isEmpty)
        #expect(store.fullDocument.components.isEmpty)
    }

    @Test func everyTemplateInsertsAndRuns() throws {
        for template in ComponentLibrary.templates {
            let (store, undo) = makeStore()
            var made: LayerID?
            step(undo) { made = store.insertTemplate(template) }
            let madeID = try #require(made, "\(template.name)")
            let layer = try #require(store.document.layer(madeID), "\(template.name)")
            // Nothing it published was dropped on the way in.
            let published = store.viewNode(for: layer.id)?.published ?? []
            #expect(Set(published.map(\.name)) == Set((template.publishedInputs + template.publishedOutputs).map(\.name)), "\(template.name)")
            if let content = template.contentName {
                #expect(layer.flattened.contains { $0.name == content && $0.kind.canHaveChildren }, "\(template.name)")
            }
            let runtime = Runtime(document: store.fullDocument, registry: store.runtimeRegistry)
            runtime.advance(seconds: 0.5)
            #expect(!runtime.needsAnotherFrame, "\(template.name) never comes to rest")
        }
    }

    @Test func anAgentAddsATemplateAndFillsIt() throws {
        let store = DocumentStore()
        let result = AssistantToolbox(store: store).call("edit_document", input: ["operations": [
            ["op": "insert_template", "template": "list section", "name": "Network", "ref": "section", "properties": ["x": 16, "y": 120]],
            ["op": "set_inputs", "patch": "section", "inputs": ["Header": "Network", "Footer": "Known networks are joined automatically.", "Shows Footer": true]],
            ["op": "insert_component", "component": "List Row", "parent": "Rows", "name": "Third Row", "inputs": ["Title": "Other…"],
             "properties": ["widthMode": "Grow"]],
        ] as [[String: Any]]])
        let answer = (try? JSONSerialization.jsonObject(with: Data(result.text.utf8))) as? [String: Any] ?? [:]
        #expect(!result.isError)
        #expect(answer["errors"] == nil, "\(answer["errors"] ?? "")")

        let section = try #require(store.document.screen.children.first)
        #expect(section.name == "Network")
        #expect(section.value(.position) == .point(Point2(x: 16, y: 120)))
        #expect(section.children[0].children[0].value(.text) == .text("Network"))
        #expect(section.children[2].children[0].value(.text) == .text("Known networks are joined automatically."))
        // The footer is there once it is shown; until then it takes no room.
        #expect(section.children[2].value(.visible) == .bool(true))
        #expect(ComponentLibrary.template("List Section")!.root.children[2].value(.visible) == .bool(false))
        #expect(section.children[1].children.map(\.name) == ["First Row", "Second Row", "Third Row"])

        // An input it does not publish is said to be missing, with what it does publish.
        let wrong = AssistantToolbox(store: store).call("edit_document", input: ["operations": [
            ["op": "set_inputs", "patch": "Network", "inputs": ["Title": "x"]],
        ] as [[String: Any]]])
        #expect(wrong.text.contains("Header, Shows Header, Footer, Shows Footer, Dark"))
        // The prompt lists every template.
        for template in ComponentLibrary.templates {
            #expect(AssistantPrompt.reference(registry: store.runtimeRegistry, components: []).contains("- \(template.name) ("))
        }
    }

    @Test func everyShelfItemHasAPictureForThePatchLibrary() {
        let items = ComponentLibrary.iOS.map { LibraryItem.component($0, shelf: "iOS") } + ComponentLibrary.templates.map(LibraryItem.template)
        for item in items {
            let picture = LibraryPreview.shared.picture(of: item)
            #expect((picture?.size.width ?? 0) > 40, "\(item.name)")
            // `TANGO_LIBRARY_PICTURES_OUT=<folder>` keeps them, to look at the shelf.
            if let folder = ProcessInfo.processInfo.environment["TANGO_LIBRARY_PICTURES_OUT"],
               let data = picture?.representations.compactMap({ $0 as? NSBitmapImageRep }).first?.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(item.name).png"))
            }
        }
    }

    @Test func aSheetIsDraggedAwayAndBroughtBack() throws {
        let (store, undo) = makeStore()
        let template = try #require(ComponentLibrary.template("Sheet"))
        var made: LayerID?
        step(undo) { made = store.insertTemplate(template) }
        let id = try #require(made)
        let board = store.document.screen.value(.size).sizeValue
        // It covers the screen, whatever device the template was drawn for.
        #expect(store.document.layer(id)?.value(.size) == .size(board))
        #expect(store.document.layer(id)?.value(.position) == .point(.zero))
        let patch = try #require(store.viewNode(for: id))
        let ports = store.visiblePorts(for: patch)
        #expect(ports.inputs.map(\.name).suffix(4) == ["Presented", "Present", "Sheet Height", "Dark"])
        #expect(ports.outputs.map(\.name) == ["Showing", "Progress", "Dismissed"])

        let runtime = Runtime(document: store.fullDocument, registry: store.runtimeRegistry)
        runtime.advance(seconds: 1)
        func find(_ name: String) -> ResolvedLayer? {
            func walk(_ layer: ResolvedLayer) -> ResolvedLayer? { layer.name == name ? layer : layer.children.lazy.compactMap(walk).first }
            return walk(runtime.resolved)
        }
        func output(_ name: String) -> Value? {
            ports.outputs.first { $0.name == name }.flatMap { runtime.outputValue(PortRef(node: patch.id, port: $0.id)) }
        }
        #expect(abs(find("Panel")!.position.y - (board.height - 520)) < 0.5)
        // It floats in from the sides and the bottom, as iOS 26 shows a sheet that is not full height.
        let inset = SystemStyle.sheetInset
        #expect(abs(find("Panel")!.position.x - inset) < 0.5)
        #expect(find("Content")!.size == Size2(width: board.width - 2 * inset, height: 520 - inset - 28))
        #expect(output("Showing") == .bool(true))
        #expect(abs((output("Progress")?.numberValue ?? 0) - 1) < 0.01)
        #expect(!runtime.needsAnotherFrame)

        // A short pull springs back; a long one sends it away.
        func pull(by distance: Double) {
            let start = Point2(x: 200, y: board.height - 500)
            runtime.send(.touchDown(start))
            runtime.tick(dt: 1 / 60)
            for step in 1...10 {
                runtime.send(.touchMoved(Point2(x: start.x, y: start.y + distance * Double(step) / 10)))
                runtime.tick(dt: 1 / 60)
            }
            runtime.send(.touchUp(Point2(x: start.x, y: start.y + distance)))
            runtime.advance(seconds: 2)
        }
        pull(by: 80)
        #expect(output("Showing") == .bool(true))
        #expect(abs(find("Panel")!.position.y - (board.height - 520)) < 0.5)
        pull(by: 300)
        #expect(output("Showing") == .bool(false))
        #expect(abs(find("Panel")!.position.y - board.height) < 0.5)
        #expect(find("Dim") == nil)
        #expect(!runtime.needsAnotherFrame)

        // Its height is an input: a taller sheet rests higher.
        let height = try #require(ports.inputs.first { $0.name == "Sheet Height" })
        step(undo) { store.setLiteral(.number(700), node: patch.id, port: height.id) }
        let taller = Runtime(document: store.fullDocument, registry: store.runtimeRegistry)
        taller.advance(seconds: 1)
        let panel = taller.resolved.find(id)?.children.last
        #expect(abs((panel?.position.y ?? 0) - (board.height - 700)) < 0.5)
    }

    /// A port a template's root publishes is beside the view's own inputs on one patch, and
    /// is found by name: a second "Height" there would never be the one that is meant. (A
    /// component's ports are looked up in its definition, so they may share a name.)
    @Test func noShelfPortIsNamedLikeAViewsOwnInput() {
        let own = Set(ViewInput.all.map { $0.name.lowercased() } + ViewInput.all.map { $0.id.lowercased() })
        for template in ComponentLibrary.templates {
            for port in template.publishedInputs + template.publishedOutputs {
                #expect(!own.contains(port.name.lowercased()), "\(template.name): \(port.name)")
            }
        }
    }
}
