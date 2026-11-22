import Foundation
import Testing
import PaperModel
@testable import PaperEngine

/// Four gaps On-Device Chat had to work round: each now holds as a person would expect.
@Suite struct EngineGapTests {
    let frame = 1.0 / 60.0

    /// Rows from a loop, the first of them hidden: a tap on the second is the second's.
    @Test func aTapOnACopyAfterAHiddenOneIsItsOwn() {
        let row = Layer(name: "Row", kind: .view, properties: [
            .size: .size(Size2(width: 300, height: 50)), .fill: .color(ColorValue(white: 0.9)),
        ])
        let list = Layer(name: "List", kind: .view, properties: [
            .position: .point(.zero), .size: .size(Size2(width: 300, height: 400)),
            .layout: .text("Stack"), .spacing: .number(10), .paddingHorizontal: .number(0), .paddingVertical: .number(0),
        ], children: [row])
        var screen = Layer(name: "Screen", kind: .screen)
        screen.children = [list]
        var b = SampleDocuments.Builder(screen: screen)
        let shown = b.add("splitText", at: Point2(x: 48, y: 96), inputs: ["text": .text("0,1,1")])
        let each = b.add("loopOverArray", at: Point2(x: 336, y: 96), type: .number)
        let touch = b.interaction(on: row.id, at: Point2(x: 48, y: 312))
        let chosen = b.add("loopOptionSwitch", at: Point2(x: 336, y: 312), inputs: ["start": .number(-1)])
        let rowView = b.view(row.id, at: Point2(x: 624, y: 96))
        b.connect(shown, "array", to: each, "array")
        b.connect(each, "value", to: rowView, LayerProperty.visible.rawValue)
        b.connect(touch, "tap", to: chosen, "set")
        let runtime = Runtime(document: b.document)
        runtime.tick(dt: frame)
        runtime.tick(dt: frame)
        // Copy 0 is left out, so copy 1 is at the top and copy 2 under it.
        #expect(runtime.outputValues(PortRef(node: touch, port: "tap")).count == 3)
        for (y, copy) in [(25.0, 1.0), (85.0, 2.0)] {
            runtime.send(.touchDown(Point2(x: 100, y: y)))
            runtime.tick(dt: frame)
            runtime.send(.touchUp(Point2(x: 100, y: y)))
            runtime.tick(dt: frame)
            runtime.tick(dt: frame)
            #expect(runtime.number(chosen, "option") == copy)
        }
    }

    /// Return sends what was typed and empties the field, through a pulse that goes back
    /// into the field's own Clear.
    @Test(arguments: [false, true]) func aFieldEmptiesItselfOnReturn(throughAnotherPatch: Bool) {
        let field = Layer(name: "Field", kind: .textField, properties: [
            .position: .point(.zero), .size: .size(Size2(width: 300, height: 50)),
        ])
        var screen = Layer(name: "Screen", kind: .screen)
        screen.children = [field]
        var b = SampleDocuments.Builder(screen: screen)
        let input = b.attach("textInput", to: field.id, at: Point2(x: 48, y: 96))
        let chat = b.add("aiText", at: Point2(x: 624, y: 96), inputs: ["model": .text(AIRequest.onDevice)])
        b.connect(input, "text", to: chat, "prompt")
        if throughAnotherPatch {
            let either = b.add("eitherPulse", at: Point2(x: 336, y: 312))
            b.connect(input, "submitted", to: either, "a")
            b.connect(either, "pulse", to: chat, "send")
            b.connect(either, "pulse", to: input, "clear")
        } else {
            b.connect(input, "submitted", to: chat, "send")
            b.connect(input, "submitted", to: input, "clear")
        }
        let runtime = Runtime(document: b.document)
        var sent: [AIRequest] = []
        runtime.aiHandler = { sent.append($0) }
        runtime.tick(dt: frame)
        runtime.send(.touchDown(Point2(x: 10, y: 10)))
        runtime.tick(dt: frame)
        runtime.send(.touchUp(Point2(x: 10, y: 10)))
        runtime.tick(dt: frame)
        runtime.send(.text("Hello"))
        runtime.tick(dt: frame)
        runtime.send(.submit)
        for _ in 0..<3 { runtime.tick(dt: frame) }
        #expect(sent.map(\.prompt) == ["Hello"])
        #expect(runtime.outputValues(PortRef(node: input, port: "text")) == [.text("")])
        // And the next one too (Return took the focus away, so a tap gives it back).
        runtime.send(.touchDown(Point2(x: 10, y: 10)))
        runtime.tick(dt: frame)
        runtime.send(.touchUp(Point2(x: 10, y: 10)))
        runtime.tick(dt: frame)
        runtime.send(.text("Again"))
        runtime.tick(dt: frame)
        runtime.send(.submit)
        for _ in 0..<3 { runtime.tick(dt: frame) }
        #expect(sent.filter { $0.phase == .send }.map(\.prompt) == ["Hello", "Again"])
        #expect(runtime.outputValues(PortRef(node: input, port: "text")) == [.text("")])
    }

    /// A loop of JSON objects, as Loop Over Array makes from an array, can be picked from.
    @Test func loopSelectPicksJSON() {
        var b = SampleDocuments.Builder(screen: Layer(name: "Screen", kind: .screen))
        let script = b.document.graph.add(PatchNode(
            kind: PatchKind.javascript, position: PatchGrid.snap(Point2(x: 48, y: 96)), name: "Messages",
            script: """
            inputs = {};
            outputs = { list: [] };
            function evaluate(inputs, outputs) { outputs.list = [{ text: "first" }, { text: "second" }]; }
            """
        ))
        let each = b.add("loopOverArray", at: Point2(x: 336, y: 96), type: .json)
        let pick = b.add("loopSelect", at: Point2(x: 624, y: 96), type: .json, inputs: ["index": .number(1)])
        let count = b.add("loopCount", at: Point2(x: 624, y: 312), type: .json)
        let words = b.add("jsonValue", at: Point2(x: 912, y: 96), type: .text, inputs: ["path": .text("text")])
        b.connect(script, "list", to: each, "array")
        b.connect(each, "value", to: pick, "loop")
        b.connect(each, "value", to: count, "loop")
        b.connect(pick, "value", to: words, "json")
        let runtime = Runtime(document: b.document)
        runtime.tick(dt: frame)
        runtime.tick(dt: frame)
        #expect(runtime.outputValue(PortRef(node: pick, port: "value")) == .object(["text": .text("second")]))
        #expect(runtime.outputValue(PortRef(node: words, port: "value")) == .text("second"))
        #expect(runtime.number(count, "count") == 2)
    }
}
