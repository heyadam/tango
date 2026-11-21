import AppKit
import Foundation
import Testing
import PaperEngine
import PaperModel
import PaperRender
@testable import PaperEditor

@MainActor
@Suite struct TextAndGalleryTests {
    private func call(_ store: DocumentStore, _ name: String, _ input: [String: Any]) -> AssistantToolResult {
        AssistantToolbox(store: store).call(name, input: input)
    }

    @Test func anAgentCanBuildAFieldAndTypeInIt() throws {
        let store = DocumentStore()
        let built = call(store, "edit_document", ["operations": [
            ["op": "add_view", "kind": "textField", "name": "Search", "ref": "field", "properties": [
                "position": ["x": 24, "y": 100], "size": ["width": 342, "height": 44], "placeholder": "Search",
            ]],
            ["op": "add_view", "kind": "text", "name": "Echo", "ref": "echo", "properties": ["position": ["x": 24, "y": 200]]],
            ["op": "add_patch", "kind": "textInput", "view": "field", "ref": "input"],
            ["op": "connect", "from": "input", "output": "text", "to": "echo", "input": "text"],
            // A Text Input only fits a text field.
            ["op": "add_patch", "kind": "textInput", "view": "echo"],
        ] as [[String: Any]]])
        #expect(built.text.contains("attaches to a view of kind textField"))
        let field = try #require(store.document.screen.children.first)
        #expect(field.kind == .textField)
        #expect(field.value(.placeholder).textValue == "Search")
        #expect(store.document.graph.nodes.count { $0.kind == "textInput" } == 1)

        let used = call(store, "interact_prototype", ["steps": [
            ["do": "look"],
            ["do": "tap", "at": ["x": 100, "y": 120]],
            ["do": "type", "text": "cats"],
            ["do": "press", "key": "delete"],
            ["do": "look"],
            ["do": "press", "key": "return"],
        ] as [[String: Any]]])
        #expect(!used.isError)
        #expect(used.images.count == 3)
        #expect(used.images[0] != used.images[1])
        #expect(used.text.contains("typed \"cats\""))
        #expect(call(store, "interact_prototype", ["steps": [["do": "press", "key": "tab"]]]).isError)
    }

    @Test func aFieldShowsItsPlaceholderUntilTypedInAndACaretWhileEdited() throws {
        let field = Layer(name: "Field", kind: .textField, properties: [.placeholder: .text("Your name")])
        var screen = Layer(name: "Screen", kind: .screen)
        screen.children = [field]
        let runtime = Runtime(document: PaperModel.Document(screen: screen))
        let renderer = LayerRenderer()
        runtime.tick(dt: 1 / 60)
        renderer.render(runtime.resolved)
        let layer = try #require(renderer.layer(for: field.id))
        let text = try #require(layer.sublayers?.first?.sublayers?.first as? CATextLayer)
        let caret = try #require(layer.sublayers?.last)
        #expect(text.string as? String == "Your name")
        #expect(caret.isHidden)

        runtime.send(.touchDown(Point2(x: 50, y: 20)))
        runtime.tick(dt: 1 / 60)
        runtime.send(.touchUp(Point2(x: 50, y: 20)))
        runtime.tick(dt: 1 / 60)
        renderer.render(runtime.resolved)
        #expect(!caret.isHidden)
        #expect(caret.animation(forKey: "blink") != nil)
        let emptyCaret = caret.position.x

        runtime.send(.text("Ada"))
        runtime.tick(dt: 1 / 60)
        renderer.render(runtime.resolved)
        #expect(text.string as? String == "Ada")
        #expect(caret.position.x > emptyCaret + 10)
        // The same layers are reused from frame to frame.
        #expect(renderer.layer(for: field.id) === layer)
        #expect(layer.sublayers?.count == 2)
    }

    @Test func gesturesReachASnapshot() throws {
        let pinch = SampleDocuments.pinchZoom().document
        let pictures = ViewerSnapshot.bitmaps(of: pinch, steps: [
            .look, .pinch(at: Point2(x: 195, y: 400), scale: 1.2, rotation: 25, seconds: 0.3), .look,
        ]).compactMap { $0.representation(using: .png, properties: [:]) }
        #expect(pictures.count == 2)
        #expect(pictures[0] != pictures[1])

        let hover = SampleDocuments.hoverButton().document
        let hovered = ViewerSnapshot.bitmaps(of: hover, steps: [.look, .hover(Point2(x: 195, y: 410)), .wait(1), .look])
            .compactMap { $0.representation(using: .png, properties: [:]) }
        #expect(hovered[0] != hovered[1])
    }

    @Test func everyGalleryCardGetsAPictureAndThePromptKnowsTheNewPieces() {
        for item in Gallery.items {
            // As wide as the device it was built for.
            let document = item.make()
            let bitmap = ViewerSnapshot.bitmap(of: document)
            #expect(bitmap?.pixelsWide == Int(document.screen.value(.size).sizeValue.width), "\(item.id)")
        }
        let reference = AssistantPrompt.reference(registry: .standard, components: [])
        for word in ["textField", "`textInput`", "`swipe`", "`pinch`", "`hover`", "placeholder", "`joinText`"] {
            #expect(reference.contains(word), "\(word)")
        }
    }
}
