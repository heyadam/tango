import Foundation
import Testing
import PaperModel
@testable import PaperEngine

/// Text fields and the gestures beyond a single finger (spec 7.2).
@Suite struct InputTests {
    let frame = 1.0 / 60.0

    func tap(_ runtime: Runtime, _ x: Double, _ y: Double) {
        runtime.send(.touchDown(Point2(x: x, y: y)))
        runtime.tick(dt: frame)
        runtime.send(.touchUp(Point2(x: x, y: y)))
        runtime.tick(dt: frame)
    }

    func drag(_ runtime: Runtime, from: Point2, to: Point2, frames: Int) {
        runtime.send(.touchDown(from))
        runtime.tick(dt: frame)
        for step in 1...frames {
            let t = Double(step) / Double(frames)
            runtime.send(.touchMoved(Point2(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)))
            runtime.tick(dt: frame)
        }
        runtime.send(.touchUp(to))
        runtime.tick(dt: frame)
    }

    /// A text field at the top, a second one below it, and a plain box at the bottom.
    func form() -> (Runtime, name: Layer, email: Layer, input: NodeID) {
        let name = Layer(name: "Name", kind: .textField, properties: [.position: .point(Point2(x: 20, y: 100))])
        let email = Layer(name: "Email", kind: .textField, properties: [
            .position: .point(Point2(x: 20, y: 200)), .text: .text("a@b.co"),
        ])
        let box = Layer(name: "Box", kind: .view, properties: [.position: .point(Point2(x: 20, y: 600))])
        let input = PatchNode(kind: "textInput", position: .zero, layerID: name.id)
        var screen = Layer(name: "Screen", kind: .screen)
        screen.children = [name, email, box]
        let runtime = Runtime(document: Document(screen: screen, graph: Graph(nodes: [input])))
        runtime.tick(dt: frame)
        return (runtime, name, email, input.id)
    }

    func out(_ runtime: Runtime, _ node: NodeID, _ port: String) -> Value {
        runtime.outputValue(PortRef(node: node, port: port))!
    }

    @Test func tappingAFieldFocusesItAndTypingFillsIt() {
        let (runtime, name, _, input) = form()
        #expect(!runtime.isEditingText)
        #expect(out(runtime, input, "text").textValue == "")

        // Typing with no field in focus goes nowhere.
        runtime.send(.text("x"))
        runtime.tick(dt: frame)
        #expect(out(runtime, input, "text").textValue == "")

        tap(runtime, 100, 120)
        #expect(runtime.isEditingText)
        #expect(out(runtime, input, "editing").boolValue)
        #expect(runtime.resolved.find(name.id)?.isEditing == true)

        runtime.send(.text("Ad"))
        runtime.send(.text("a"))
        runtime.tick(dt: frame)
        #expect(out(runtime, input, "text").textValue == "Ada")
        #expect(out(runtime, input, "changed").pulseValue)
        #expect(runtime.resolved.find(name.id)?.value(.text).textValue == "Ada")
        runtime.tick(dt: frame)
        #expect(!out(runtime, input, "changed").pulseValue)

        runtime.send(.deleteBackward)
        runtime.tick(dt: frame)
        #expect(out(runtime, input, "text").textValue == "Ad")

        // Nothing moves while the caret blinks: the blink is not the runtime's work.
        runtime.advance(seconds: 0.2)
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func returnSubmitsAndATapElsewhereTakesFocusAway() {
        let (runtime, name, email, input) = form()
        tap(runtime, 100, 120)
        runtime.send(.text("Ada"))
        runtime.send(.submit)
        runtime.tick(dt: frame)
        #expect(out(runtime, input, "submitted").pulseValue)
        #expect(!out(runtime, input, "editing").boolValue)
        #expect(!runtime.isEditingText)
        #expect(out(runtime, input, "text").textValue == "Ada")

        // Each field keeps its own text; a field with no patch still takes typing.
        tap(runtime, 100, 220)
        #expect(runtime.resolved.find(email.id)?.isEditing == true)
        runtime.send(.text("m"))
        runtime.tick(dt: frame)
        #expect(runtime.resolved.find(email.id)?.value(.text).textValue == "a@b.com")
        #expect(runtime.resolved.find(name.id)?.value(.text).textValue == "Ada")

        tap(runtime, 60, 650)
        #expect(!runtime.isEditingText)
        #expect(runtime.resolved.find(email.id)?.isEditing == false)

        // Dragging across a field is not a tap on it.
        drag(runtime, from: Point2(x: 100, y: 120), to: Point2(x: 100, y: 320), frames: 6)
        #expect(!runtime.isEditingText)

        runtime.restart()
        runtime.tick(dt: frame)
        #expect(out(runtime, input, "text").textValue == "")
    }

    @Test func theGraphCanFocusDismissAndClearAField() {
        let field = Layer(name: "Search", kind: .textField, properties: [.text: .text("cats")])
        let button = Layer(name: "Clear", kind: .view, properties: [.position: .point(Point2(x: 20, y: 400))])
        let touch = PatchNode.interaction(on: button.id, position: .zero)
        let input = PatchNode(kind: "textInput", position: .zero, layerID: field.id)
        let length = PatchNode(kind: "textLength", position: .zero)
        var screen = Layer(name: "Screen", kind: .screen)
        screen.children = [field, button]
        let graph = Graph(nodes: [touch, input, length], connections: [
            Connection(from: PortRef(node: touch.id, port: "tap"), to: PortRef(node: input.id, port: "clear")),
            Connection(from: PortRef(node: touch.id, port: "tap"), to: PortRef(node: input.id, port: "focus")),
            Connection(from: PortRef(node: input.id, port: "text"), to: PortRef(node: length.id, port: "text")),
        ])
        let runtime = Runtime(document: Document(screen: screen, graph: graph))
        runtime.tick(dt: frame)
        #expect(out(runtime, input.id, "text").textValue == "cats")
        #expect(out(runtime, length.id, "length").numberValue == 4)

        tap(runtime, 60, 450)
        runtime.advance(seconds: 0.1)
        #expect(out(runtime, input.id, "text").textValue == "")
        #expect(out(runtime, length.id, "empty").boolValue)
        #expect(runtime.isEditingText)
        #expect(runtime.resolved.find(field.id)?.value(.text).textValue == "")
    }

    @Test func textPatchesJoinAndSearch() {
        let join = PatchNode(kind: "joinText", position: .zero, inputs: ["a": .text("Hello, "), "b": .text("Ada")])
        let has = PatchNode(kind: "textContains", position: .zero, inputs: ["text": .text("Grace Hopper"), "search": .text("HOP")])
        let all = PatchNode(kind: "textContains", position: .zero, inputs: ["text": .text("Grace Hopper")])
        let none = PatchNode(kind: "textContains", position: .zero, inputs: ["text": .text("Grace"), "search": .text("z")])
        let runtime = Runtime(document: Document(graph: Graph(nodes: [join, has, all, none])))
        runtime.tick(dt: frame)
        #expect(out(runtime, join.id, "text").textValue == "Hello, Ada")
        #expect(out(runtime, has.id, "result").boolValue)
        #expect(out(runtime, all.id, "result").boolValue)
        #expect(!out(runtime, none.id, "result").boolValue)
    }

    // MARK: Gestures

    func card(_ kind: String) -> (Runtime, NodeID) {
        let card = Layer(name: "Card", kind: .view, properties: [
            .position: .point(Point2(x: 45, y: 300)), .size: .size(Size2(width: 300, height: 200)),
        ])
        let node = PatchNode(kind: kind, position: .zero, layerID: card.id)
        var screen = Layer(name: "Screen", kind: .screen)
        screen.children = [card]
        let runtime = Runtime(document: Document(screen: screen, graph: Graph(nodes: [node])))
        runtime.tick(dt: frame)
        return (runtime, node.id)
    }

    @Test func aFlickIsASwipeInItsDirection() {
        let (runtime, swipe) = card("swipe")
        drag(runtime, from: Point2(x: 300, y: 400), to: Point2(x: 120, y: 410), frames: 6)
        #expect(out(runtime, swipe, "left").pulseValue)
        #expect(!out(runtime, swipe, "right").pulseValue)
        runtime.tick(dt: frame)
        #expect(!out(runtime, swipe, "left").pulseValue)

        drag(runtime, from: Point2(x: 200, y: 320), to: Point2(x: 205, y: 480), frames: 6)
        #expect(out(runtime, swipe, "down").pulseValue)

        // A slow drag that stops before lifting is not a swipe, nor is a short one.
        runtime.tick(dt: frame)
        runtime.send(.touchDown(Point2(x: 100, y: 400)))
        runtime.tick(dt: frame)
        runtime.send(.touchMoved(Point2(x: 300, y: 400)))
        runtime.advance(seconds: 0.4)
        runtime.send(.touchUp(Point2(x: 300, y: 400)))
        runtime.tick(dt: frame)
        #expect(!out(runtime, swipe, "right").pulseValue)
        drag(runtime, from: Point2(x: 200, y: 400), to: Point2(x: 220, y: 400), frames: 2)
        #expect(!out(runtime, swipe, "right").pulseValue)

        // A swipe that starts off the layer belongs to nobody.
        drag(runtime, from: Point2(x: 200, y: 700), to: Point2(x: 20, y: 700), frames: 6)
        #expect(!out(runtime, swipe, "left").pulseValue)
    }

    @Test func twoFingersReportScaleAndRotationAndKeepThemAfterLifting() {
        let (runtime, pinch) = card("pinch")
        #expect(out(runtime, pinch, "scale").numberValue == 1)
        runtime.send(.pinchBegan(Point2(x: 195, y: 400)))
        runtime.send(.pinchChanged(scale: 1.5, rotation: 20))
        runtime.tick(dt: frame)
        #expect(out(runtime, pinch, "scale").numberValue == 1.5)
        #expect(out(runtime, pinch, "rotation").numberValue == 20)
        #expect(out(runtime, pinch, "pinching").boolValue)
        #expect(runtime.needsAnotherFrame)

        runtime.send(.pinchEnded)
        runtime.tick(dt: frame)
        #expect(!out(runtime, pinch, "pinching").boolValue)
        #expect(out(runtime, pinch, "scale").numberValue == 1.5)
        runtime.tick(dt: frame)
        #expect(!runtime.needsAnotherFrame)

        // Fingers that come down beside the layer do nothing to it.
        runtime.send(.pinchBegan(Point2(x: 195, y: 700)))
        runtime.send(.pinchChanged(scale: 3, rotation: 0))
        runtime.tick(dt: frame)
        #expect(out(runtime, pinch, "scale").numberValue == 1.5)
        #expect(!out(runtime, pinch, "pinching").boolValue)
    }

    @Test func aRestingPointerHovers() {
        let (runtime, hover) = card("hover")
        #expect(runtime.usesHover)
        #expect(!out(runtime, hover, "hovering").boolValue)
        runtime.send(.hover(Point2(x: 100, y: 350)))
        runtime.tick(dt: frame)
        #expect(out(runtime, hover, "hovering").boolValue)
        #expect(out(runtime, hover, "position").pointValue == Point2(x: 100, y: 350))
        runtime.tick(dt: frame)
        #expect(!runtime.needsAnotherFrame)

        runtime.send(.hover(Point2(x: 100, y: 700)))
        runtime.tick(dt: frame)
        #expect(!out(runtime, hover, "hovering").boolValue)
        runtime.send(.hover(Point2(x: 100, y: 350)))
        runtime.tick(dt: frame)
        runtime.send(.hover(nil))
        runtime.tick(dt: frame)
        #expect(!out(runtime, hover, "hovering").boolValue)
        #expect(!Runtime(document: Document()).usesHover)
    }
}

extension InputTests {
    /// Found in QA: typed text used to be fed in as a loop, which then decided how often
    /// the field repeats and never let the count go down.
    @Test func aRepeatedFieldStillFollowsItsLoopAfterTyping() {
        let field = Layer(name: "Field", kind: .textField)
        var screen = Layer(name: "Screen", kind: .screen, properties: [.layout: .text("Stack")])
        screen.children = [field]
        let loop = PatchNode(kind: "loop", position: .zero, inputs: ["count": .number(3)])
        let fill = PatchNode.view(of: field.id)
        let input = PatchNode(kind: "textInput", position: .zero, layerID: field.id)
        var graph = Graph(nodes: [loop, fill, input], connections: [
            Connection(from: PortRef(node: loop.id, port: "index"), to: PortRef(node: fill.id, port: "opacity")),
        ])
        var document = Document(screen: screen, graph: graph)
        let runtime = Runtime(document: document)
        runtime.advance(seconds: 0.1)
        func count() -> Int { runtime.resolved.children.count }
        #expect(count() == 3)

        // Type in the second one (it is the only one with any opacity to hit besides the third).
        runtime.send(.touchDown(Point2(x: 50, y: 66)))
        runtime.tick(dt: frame)
        runtime.send(.touchUp(Point2(x: 50, y: 66)))
        runtime.tick(dt: frame)
        runtime.send(.text("hi"))
        runtime.advance(seconds: 0.1)
        #expect(runtime.resolved.children.map { $0.value(.text).textValue } == ["", "hi", ""])
        #expect(runtime.outputValues(PortRef(node: input.id, port: "text")).map(\.textValue) == ["", "hi", ""])

        for smaller in [2.0, 1.0] {
            graph.update(loop.id) { $0.inputs["count"] = .number(smaller) }
            document.graph = graph
            runtime.update(document: document)
            runtime.advance(seconds: 0.1)
            #expect(count() == Int(smaller))
        }
    }
}

extension InputTests {
    @Test func filteringAnArrayKeepsWhatTheSearchMatches() {
        let people: Value = .array([.text("Ada Lovelace"), .text("Grace Hopper"), .text("Alan Turing")])
        let objects: Value = .array([
            .object(["name": .text("Ada"), "city": .text("London")]),
            .object(["name": .text("Grace"), "city": .text("New York")]),
        ])
        func run(_ array: Value, _ search: String, key: String = "") -> (Int, Double) {
            let node = PatchNode(kind: "filterArray", position: .zero, inputs: [
                "array": array, "search": .text(search), "key": .text(key),
            ])
            let runtime = Runtime(document: Document(graph: Graph(nodes: [node])))
            runtime.tick(dt: frame)
            return (out(runtime, node.id, "array").arrayValue.count, out(runtime, node.id, "count").numberValue)
        }
        #expect(run(people, "") == (3, 3))
        #expect(run(people, " HO ") == (1, 1))
        #expect(run(people, "a") == (3, 3))
        #expect(run(people, "zz") == (0, 0))
        #expect(run(objects, "york") == (1, 1))
        #expect(run(objects, "york", key: "name") == (0, 0))
        #expect(run(objects, "gra", key: "name") == (1, 1))
        #expect(run(.array([]), "x") == (0, 0))
    }
}
