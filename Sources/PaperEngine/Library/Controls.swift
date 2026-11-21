import Foundation
import PaperModel

extension ComponentLibrary {
    // MARK: Button

    static let button: ComponentDefinition = {
        let label = text("Label", "Button", weight: 400, color: .white, [
            .widthMode: .text("Grow"), .textAlignment: .text("Center"),
        ])
        let body = group("Background", [
            .fill: .color(blue), .cornerRadius: .number(100), .widthMode: .text("Grow"), .heightMode: .text("Grow"),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .paddingHorizontal: .number(16), .paddingVertical: .number(16),
        ], [label])
        let root = group("Button", [.size: size(200, 50), .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center")], [body])

        return make("Button", "A button that dims while pressed and reports taps: Filled, Tinted, Gray or Plain. A large corner radius makes it a capsule.", root: root, shippedViews: 3) { b in
            let title = b.input("Title", .text, .text("Button"), at: at(0, 0))
            let tint = b.input("Tint", .color, .color(blue), at: at(0, 1))
            let touch = b.interaction(on: root.id, at: at(0, 2))
            let spring = b.add("spring", at: at(1, 2), inputs: ["response": .number(0.18), "damping": .number(1)])
            let dim = b.add("transition", at: at(2, 2), name: "Dim", type: .number, inputs: ["start": .number(1), "end": .number(0.55)])
            b.connect(title, "value", to: b.property(.text, of: label.id, at: at(3, 0)), "value")
            let bodyFill = b.property(.fill, of: body.id, at: at(3, 1))
            b.connect(touch, "down", to: spring, "target")
            b.connect(spring, "value", to: dim, "progress")
            b.connect(dim, "value", to: b.property(.opacity, of: body.id, at: at(3, 2)), "value")
            b.connect(touch, "tap", to: b.output("Tap", .pulse, at: at(3, 3)), "value")
            // Added after the rest, so the ids of the patches above stay what documents stored.
            let radius = b.input("Corner Radius", .number, .number(100), at: at(0, 4))
            let weight = b.input("Weight", .number, .number(400), at: at(0, 5))
            b.connect(radius, "value", to: b.property(.cornerRadius, of: body.id, at: at(3, 4)), "value")
            b.connect(weight, "value", to: b.property(.fontWeight, of: label.id, at: at(3, 5)), "value")
            // Style: what the body is filled with and what color the title is.
            let style = b.input("Style", .text, .text("Filled"), at: at(0, 6), options: ["Filled", "Tinted", "Gray", "Plain"])
            func isStyle(_ name: String, _ row: Double) -> NodeID {
                let match = b.add("textContains", at: at(1, row), name: "Is \(name)", inputs: ["search": .text(name)])
                b.connect(style, "value", to: match, "text")
                return match
            }
            let isTinted = isStyle("Tinted", 6), isGray = isStyle("Gray", 7), isPlain = isStyle("Plain", 8)
            var look = Look(&b, row: 9)
            let wash = b.add("transition", at: at(2, 6), name: "Tinted Fill", type: .color, inputs: ["progress": .number(0.15)])
            b.connect(look.color(&b, SystemStyle.surface, "Surface"), "value", to: wash, "start")
            b.connect(tint, "value", to: wash, "end")
            func choose(_ name: String, _ condition: NodeID, _ then: NodeID?, _ thenValue: ColorValue = .clear, else other: NodeID, _ column: Double, _ row: Double) -> NodeID {
                let choice = b.add("if", at: at(column, row), name: name, type: .color, inputs: ["then": .color(thenValue)])
                b.connect(condition, "result", to: choice, "condition")
                if let then { b.connect(then, "value", to: choice, "then") }
                b.connect(other, "value", to: choice, "else")
                return choice
            }
            let tintedOrFilled = choose("Tinted or Filled", isTinted, wash, else: tint, 3, 6)
            let grayOrThat = choose("Gray or That", isGray, look.color(&b, SystemStyle.fieldFill, "Gray Fill"), else: tintedOrFilled, 4, 6)
            let fill = choose("Fill", isPlain, nil, ColorValue(white: 1, alpha: 0), else: grayOrThat, 5, 6)
            b.connect(fill, "value", to: bodyFill, "value")
            let quiet = b.add("or", at: at(2, 7.4), name: "Tinted or Gray")
            let notFilled = b.add("or", at: at(3, 7.4), name: "Not Filled")
            b.connect(isTinted, "result", to: quiet, "a")
            b.connect(isGray, "result", to: quiet, "b")
            b.connect(quiet, "result", to: notFilled, "a")
            b.connect(isPlain, "result", to: notFilled, "b")
            let titleColor = b.add("if", at: at(4, 7.4), name: "Title Color", type: .color, inputs: ["else": .color(.white)])
            b.connect(notFilled, "result", to: titleColor, "condition")
            b.connect(tint, "value", to: titleColor, "then")
            b.connect(titleColor, "value", to: b.property(.textColor, of: label.id, at: at(6, 7.4)), "value")
        }
    }()

    // MARK: Toggle

    static let toggle: ComponentDefinition = {
        let track = Layer(name: "Track", kind: .view, properties: [
            .size: .size(SystemStyle.switchSize), .cornerRadius: .number(SystemStyle.switchSize.height / 2), .fill: .color(SystemStyle.switchOff.light),
        ])
        let knob = switchKnob()
        let root = group("Toggle", [.size: .size(SystemStyle.switchSize)], [track, knob])

        return make("Toggle", "A switch: tap to turn it on or off. The knob slides and the track fills with the tint.", root: root, shippedViews: 3) { b in
            let startsOn = b.input("On", .bool, .bool(false), at: at(0, 0))
            let tint = b.input("Tint", .color, .color(green), at: at(0, 3))
            let touch = b.interaction(on: root.id, at: at(0, 1))
            let flipped = b.add("switch", at: at(1, 1), name: "Flipped")
            // On when the starting value and the taps disagree: each tap flips it.
            let isOn = b.add("notEqual", at: at(2, 0), name: "Is On")
            let spring = b.add("spring", at: at(3, 0), inputs: ["response": .number(0.3), "damping": .number(0.8)])
            let slide = b.add("transition", at: at(4, 0), name: "Knob Position", type: .point, inputs: [
                "start": .point(Point2(x: 2, y: 2)), "end": .point(Point2(x: switchTravel, y: 2)),
            ])
            let color = b.add("transition", at: at(4, 2), name: "Track Color", type: .color, inputs: ["start": .color(SystemStyle.switchOff.light)])
            b.connect(touch, "tap", to: flipped, "flip")
            b.connect(flipped, "on", to: isOn, "a")
            b.connect(startsOn, "value", to: isOn, "b")
            b.connect(isOn, "result", to: spring, "target")
            b.connect(spring, "value", to: slide, "progress")
            b.connect(tint, "value", to: color, "end")
            b.connect(slide, "value", to: b.property(.position, of: knob.id, at: at(5, 0)), "value")
            b.connect(color, "value", to: b.property(.fill, of: track.id, at: at(5, 2)), "value")
            b.connect(isOn, "result", to: b.output("On", .bool, at: at(5, 3)), "value")
            b.connect(touch, "tap", to: b.output("Changed", .pulse, at: at(5, 4)), "value")
            var look = Look(&b, row: 4.4)
            b.connect(look.color(&b, SystemStyle.switchOff, "Off Color"), "value", to: color, "start")
            // Measured on iOS 26 (`motion-toggle`): the track fills more slowly than the knob
            // slides, so its color follows a spring of its own.
            let fill = b.add("spring", at: at(3, 2), name: "Track Fill", inputs: ["response": .number(0.45), "damping": .number(1)])
            b.connect(isOn, "result", to: fill, "target")
            b.connect(fill, "value", to: color, "progress")
        }
    }()

    // MARK: Slider

    static let slider: ComponentDefinition = {
        // As the real one measures: a track 6 points thick with the same pill for a knob
        // as a switch has, 37 by 24, which travels the width less its own.
        let knobSize = SystemStyle.knobSize
        let track = Layer(name: "Track", kind: .view, properties: [
            .position: .point(Point2(x: 0, y: 12.5)), .size: size(280, 6), .cornerRadius: .number(3), .fill: .color(SystemStyle.sliderTrack.light),
        ])
        let fill = Layer(name: "Fill", kind: .view, properties: [
            .position: .point(Point2(x: 0, y: 12.5)), .size: size(140, 6), .cornerRadius: .number(3), .fill: .color(blue),
        ])
        var knob = switchKnob()
        knob.set(.position, .point(Point2(x: (280 - knobSize.width) / 2, y: 4)))
        // The knob stands four points down in a frame of 32, with the track through its middle.
        let root = group("Slider", [.size: size(280, 32)], [track, fill, knob])

        return make("Slider", "Drag to choose a value between Minimum and Maximum, 0 to 1 unless you say otherwise. It stretches to whatever width you give it.", root: root, shippedViews: 4) { b in
            let start = b.input("Value", .number, .number(0.5), at: at(0, 0))
            let tint = b.input("Tint", .color, .color(blue), at: at(0, 4))
            let touch = b.interaction(on: root.id, at: at(0, 1))
            let measured = b.bound("layerSize", to: root.id, at: at(0, 2.6))
            let travel = b.add("subtract", at: at(1, 2.6), name: "Travel", inputs: ["b": .number(knobSize.width)])
            let dragX = b.add("splitPoint", at: at(1, 1.4))
            let value = b.add("dragValue", at: at(2, 0.6))
            let knobX = b.add("multiply", at: at(3, 0.6), name: "Knob X")
            let knobPoint = b.add("makePoint", at: at(4, 0), inputs: ["y": .number(4)])
            let fillWidth = b.add("add", at: at(4, 1.2), name: "Fill Width", inputs: ["b": .number(knobSize.width / 2)])
            let fillSize = b.add("makePoint", at: at(5, 1.2), inputs: ["y": .number(6)])
            let trackSize = b.add("makePoint", at: at(2, 3), inputs: ["y": .number(6)])
            b.connect(measured, "width", to: travel, "a")
            b.connect(touch, "drag", to: dragX, "point")
            b.connect(touch, "down", to: value, "down")
            b.connect(dragX, "x", to: value, "drag")
            b.connect(travel, "result", to: value, "range")
            b.connect(value, "value", to: knobX, "a")
            b.connect(travel, "result", to: knobX, "b")
            b.connect(knobX, "result", to: knobPoint, "x")
            b.connect(knobX, "result", to: fillWidth, "a")
            b.connect(fillWidth, "result", to: fillSize, "x")
            b.connect(measured, "width", to: trackSize, "x")
            b.connect(knobPoint, "point", to: b.property(.position, of: knob.id, at: at(6, 0)), "value")
            b.connect(fillSize, "point", to: b.property(.size, of: fill.id, at: at(6, 1.2)), "value")
            b.connect(trackSize, "point", to: b.property(.size, of: track.id, at: at(6, 3)), "value")
            b.connect(tint, "value", to: b.property(.fill, of: fill.id, at: at(6, 4)), "value")
            let reported = b.output("Value", .number, at: at(6, 2.2))
            var look = Look(&b, row: 5.4)
            look.paint(&b, SystemStyle.sliderTrack, "Track Color", .fill, of: track)
            // The range: Value comes in and goes out between Minimum and Maximum.
            let low = b.input("Minimum", .number, .number(0), at: at(0, 7.6))
            let high = b.input("Maximum", .number, .number(1), at: at(0, 8.6))
            let fraction = b.add("progress", at: at(1, 7.6), name: "Start Fraction")
            let scaled = b.add("transition", at: at(5, 2.2), name: "In Range", type: .number)
            b.connect(start, "value", to: fraction, "value")
            b.connect(low, "value", to: fraction, "start")
            b.connect(high, "value", to: fraction, "end")
            b.connect(fraction, "progress", to: value, "start")
            b.connect(value, "value", to: scaled, "progress")
            b.connect(low, "value", to: scaled, "start")
            b.connect(high, "value", to: scaled, "end")
            b.connect(scaled, "value", to: reported, "value")
        }
    }()

    // MARK: Stepper

    static let stepper: ComponentDefinition = {
        func half(_ name: String, _ glyph: String) -> Layer {
            group(name, [
                .widthMode: .text("Grow"), .heightMode: .text("Grow"), .layout: .text("Stack"), .axis: .text("Horizontal"),
                .alignment: .text("Center"), .distribution: .text("Center"),
            ], [symbol("Glyph", glyph, width: 20, height: 20, color: .black, weight: 500)])
        }
        let minus = half("Minus", "minus")
        let plus = half("Plus", "plus")
        let glyphs = [minus.children[0], plus.children[0]]
        let divider = Layer(name: "Divider", kind: .view, properties: [.size: size(1, 20), .fill: .color(tertiaryLabel)])
        let root = group("Stepper", [
            .size: size(94, 32), .fill: .color(SystemStyle.stepperFill.light), .cornerRadius: .number(16), .clips: .bool(true),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
        ], [minus, divider, plus])

        return make("Stepper", "Minus and plus buttons that count down and up by Step, from Value, between Minimum and Maximum.", root: root, shippedViews: 6) { b in
            let less = b.interaction(on: minus.id, at: at(0, 0))
            let more = b.interaction(on: plus.id, at: at(0, 1.6))
            let count = b.add("counter", at: at(1, 0.8))
            b.connect(less, "tap", to: count, "decrease")
            b.connect(more, "tap", to: count, "increase")
            for (index, pair) in [(less, minus), (more, plus)].enumerated() {
                let dim = b.add("transition", at: at(1, 2.4 + Double(index) * 1.3), name: "Dim", type: .number, inputs: [
                    "start": .number(1), "end": .number(0.3),
                ])
                b.connect(pair.0, "down", to: dim, "progress")
                b.connect(dim, "value", to: b.property(.opacity, of: pair.1.id, at: at(2, 2.4 + Double(index) * 1.3)), "value")
            }
            b.connect(count, "value", to: b.output("Value", .number, at: at(2, 0.8)), "value")
            var look = Look(&b, row: 5.2)
            look.paint(&b, SystemStyle.stepperFill, "Body Color", .fill, of: root)
            look.paint(&b, SystemStyle.label, "Glyph Color", .fill, of: glyphs[0], glyphs[1])
            look.paint(&b, SystemStyle.tertiaryLabel, "Divider Color", .fill, of: divider)
            for (index, port) in [("Value", "start", 0.0), ("Minimum", "min", 0), ("Maximum", "max", 100), ("Step", "step", 1)].enumerated() {
                b.connect(b.input(port.0, .number, .number(port.2), at: at(0, 9.4 + Double(index))), "value", to: count, port.1)
            }
        }
    }()

    // MARK: Segmented Control

    static let segmentedControl: ComponentDefinition = {
        // As the real one: a capsule, the chosen segment a capsule in it with its label bolder.
        let label = text("Label", "Segment", size: 13, weight: 500, [.widthMode: .text("Grow"), .textAlignment: .text("Center")])
        let segment = group("Segment", [
            .cornerRadius: .number(14), .widthMode: .text("Grow"), .heightMode: .text("Grow"),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
        ], [label])
        // The chosen segment's capsule is one view that slides from segment to segment.
        let selection = Layer(name: "Selection", kind: .view, properties: [
            .size: size(98, 28), .cornerRadius: .number(14), .fill: .color(SystemStyle.selectedSegment.light), .absolute: .bool(true),
        ])
        let root = group("Segmented Control", [
            .size: size(300, 32), .fill: .color(SystemStyle.fieldFill.light), .cornerRadius: .number(16),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .paddingHorizontal: .number(2), .paddingVertical: .number(2),
        ], [selection, segment])

        return make("Segmented Control", "A row of choices, one selected. Give it a comma-separated list; it makes a segment for each.", root: root, shippedViews: 3) { b in
            let names = b.input("Segments", .text, .text("First, Second, Third"), at: at(0, 0))
            let initial = b.input("Selected", .number, .number(0), at: at(0, 2.6))
            let split = b.add("splitText", at: at(1, 0))
            let each = b.add("loopOverArray", at: at(2, 0), type: .text)
            let touch = b.interaction(on: segment.id, at: at(0, 1.3))
            let chosen = b.add("loopOptionSwitch", at: at(2, 1.6), name: "Selected Segment")
            let isSelected = b.add("equal", at: at(3, 1), name: "Is Selected")
            let spring = b.add("spring", at: at(4, 1), inputs: ["response": .number(0.25), "damping": .number(0.9)])
            // Each segment stays clear (the Selection is what shows the choice), but the loop
            // into its fill is what repeats the segment.
            let color = b.add("transition", at: at(5, 1), name: "Segment Color", type: .color, inputs: [
                "start": .color(ColorValue(white: 1, alpha: 0)), "end": .color(ColorValue(white: 1, alpha: 0)),
            ])
            b.connect(names, "value", to: split, "text")
            b.connect(split, "array", to: each, "array")
            b.connect(each, "value", to: b.property(.text, of: label.id, at: at(3, 0)), "value")
            b.connect(touch, "tap", to: chosen, "set")
            b.connect(initial, "value", to: chosen, "start")
            b.connect(each, "index", to: isSelected, "a")
            b.connect(chosen, "option", to: isSelected, "b")
            b.connect(isSelected, "result", to: spring, "target")
            b.connect(spring, "value", to: color, "progress")
            b.connect(color, "value", to: b.property(.fill, of: segment.id, at: at(6, 1)), "value")
            b.connect(chosen, "option", to: b.output("Selected", .number, at: at(3, 2.4)), "value")
            b.connect(chosen, "changed", to: b.output("Changed", .pulse, at: at(3, 3.4)), "value")
            var look = Look(&b, row: 4.6)
            look.paint(&b, SystemStyle.fieldFill, "Body Color", .fill, of: root)
            look.paint(&b, SystemStyle.label, "Label Color", .textColor, of: label)
            let selectedColor = look.color(&b, SystemStyle.selectedSegment, "Selected Color")
            b.connect(selectedColor, "value", to: b.property(.fill, of: selection.id, at: at(6, 1)), "value")
            let weight = b.add("if", at: at(4, 2.2), name: "Label Weight", type: .number, inputs: ["then": .number(600), "else": .number(500)])
            b.connect(weight, "value", to: b.property(.fontWeight, of: label.id, at: at(6, 2.2)), "value")
            // Measured on iOS 26 (`motion-segmented`): the capsule slides, stretching toward the
            // new segment, and a label turns bold as it arrives.
            let sliding = Sliding(&b, repeated: segment.id, pill: selection.id, chosen: chosen, quick: 0.24, slow: 0.36, damping: 0.9, column: 0, row: 9)
            let covered = b.add("greater", at: at(3, 6.6), name: "Mostly Covered", inputs: ["b": .number(0.5)])
            b.connect(sliding.coverage, "result", to: covered, "a")
            b.connect(covered, "result", to: weight, "condition")
        }
    }()

    // MARK: Text Field and Search Field

    /// A box to type in, with a button that clears it while it is being edited.
    /// `bordered` is the white box with a hairline round it that a text field is; without
    /// it the box is filled, as a search field is.
    static func field(_ name: String, _ summary: String, height: Double, radius: Double, glyph: String?, placeholder: String, bordered: Bool = false) -> ComponentDefinition {
        let fillColor = bordered ? SystemStyle.surface : SystemStyle.fieldFill
        let typed = Layer(name: "Field", kind: .textField, properties: [
            .widthMode: .text("Grow"), .heightMode: .text("Grow"), .fill: .color(.clear), .cornerRadius: .number(0),
            .padding: .number(0), .placeholder: .text(placeholder),
        ])
        let clear = symbol("Clear", "xmark.circle.fill", width: 17, height: 17, color: secondaryLabel, [.visible: .bool(false)])
        let lens = glyph.map { symbol("Glyph", $0, width: 20, height: 20, color: SystemStyle.label.light, weight: 500) }
        let root = group(name, [
            .size: size(300, height), .fill: .color(fillColor.light), .cornerRadius: .number(radius),
            .strokeColor: .color(SystemStyle.fieldBorder.light), .strokeWidth: .number(bordered ? 0.5 : 0),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
            .paddingHorizontal: .number(bordered ? 7 : 12), .paddingVertical: .number(0), .spacing: .number(bordered ? 6 : 7),
        ], (lens.map { [$0] } ?? []) + [typed, clear])

        return make(name, summary, root: root) { b in
            let hint = b.input("Placeholder", .text, .text(placeholder), at: at(0, 0))
            let typing = b.bound("textInput", to: typed.id, at: at(0, 1))
            let wipe = b.interaction(on: clear.id, at: at(0, 3))
            let length = b.add("textLength", at: at(1, 1))
            let hasText = b.add("not", at: at(2, 1), name: "Has Text")
            let showsClear = b.add("and", at: at(3, 1), name: "Shows Clear")
            b.connect(hint, "value", to: b.property(.placeholder, of: typed.id, at: at(4, 0)), "value")
            b.connect(typing, "text", to: length, "text")
            b.connect(length, "empty", to: hasText, "value")
            b.connect(hasText, "result", to: showsClear, "a")
            b.connect(typing, "editing", to: showsClear, "b")
            b.connect(showsClear, "result", to: b.property(.visible, of: clear.id, at: at(4, 1)), "value")
            b.connect(wipe, "tap", to: typing, "clear")
            b.connect(typing, "text", to: b.output("Text", .text, at: at(4, 2)), "value")
            b.connect(typing, "editing", to: b.output("Editing", .bool, at: at(4, 3)), "value")
            b.connect(typing, "changed", to: b.output("Changed", .pulse, at: at(4, 4)), "value")
            b.connect(typing, "submitted", to: b.output("Submitted", .pulse, at: at(4, 5)), "value")
            var look = Look(&b, row: 6)
            look.paint(&b, fillColor, "Field Color", .fill, of: root)
            if bordered { look.paint(&b, SystemStyle.fieldBorder, "Border Color", .strokeColor, of: root) }
            look.paint(&b, SystemStyle.label, "Text Color", .textColor, of: typed)
            if let lens { look.paint(&b, SystemStyle.label, "Glyph Color", .fill, of: lens) }
        }
    }

    static let textField = field(
        "Text Field", "A box to type in. It reports what is typed, whether it is being edited, and Return. A button clears it.",
        height: 34, radius: 6, glyph: nil, placeholder: "Placeholder", bordered: true
    )

    static let searchField = field(
        "Search Field", "A search box with a magnifying glass. Cable Text into a Filter Array to search a list.",
        // As .searchable draws it under a large title on iOS 26: 44 high, the glyph the color of text.
        height: 44, radius: 22, glyph: "magnifyingglass", placeholder: "Search"
    )

    // MARK: Menu Button

    static let menuButton: ComponentDefinition = {
        let label = text("Label", "One", color: blue)
        let chevrons = symbol("Chevrons", "chevron.up.chevron.down", width: 11, height: 15, color: blue, weight: 600)
        let face = group("Face", [
            .size: size(160, 34), .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .spacing: .number(5),
            // A menu picker's words stand in from its edge, as a button's do.
            .paddingHorizontal: .number(12), .paddingVertical: .number(0),
        ], [label, chevrons])
        let check = symbol("Check", "checkmark", width: 15, height: 15, color: .black, weight: 600)
        let choiceLabel = text("Choice Label", "One", [.widthMode: .text("Grow")])
        let choice = group("Choice", [
            .size: size(220, SystemStyle.menuRowHeight), .widthMode: .text("Grow"), .layout: .text("Stack"), .axis: .text("Horizontal"),
            .alignment: .text("Center"), .paddingHorizontal: .number(SystemStyle.margin), .paddingVertical: .number(0), .spacing: .number(10),
        ], [check, choiceLabel])
        let menu = group("Menu", [
            .position: .point(Point2(x: 0, y: 40)), .size: size(220, 44), .heightMode: .text("Auto"), .anchor: .point(.zero),
            .fill: .color(.white), .cornerRadius: .number(SystemStyle.alertRadius), .layout: .text("Stack"), .axis: .text("Vertical"),
            .paddingHorizontal: .number(0), .paddingVertical: .number(6),
            .shadowColor: .color(ColorValue(white: 0, alpha: 0.2)), .shadowRadius: .number(24), .shadowOffset: .point(Point2(x: 0, y: 8)),
            .visible: .bool(false),
        ], [choice])
        let root = group("Menu Button", [.size: size(160, 34)], [face, menu])

        return make("Menu Button", "A pop-up button: it shows one of a comma-separated list of choices, and a tap opens a menu to pick another.", root: root) { b in
            let options = b.input("Options", .text, .text("One, Two, Three"), at: at(0, 0))
            let initial = b.input("Selected", .number, .number(0), at: at(0, 2.4))
            let tint = b.input("Tint", .color, .color(blue), at: at(0, 6))
            let split = b.add("splitText", at: at(1, 0))
            let each = b.add("loopOverArray", at: at(2, 0), type: .text)
            let everyChoice = b.add("greaterEqual", at: at(3, 1), name: "Every Choice")
            let opens = b.interaction(on: face.id, at: at(0, 3.6))
            let picks = b.interaction(on: choice.id, at: at(0, 1.2))
            let chosen = b.add("loopOptionSwitch", at: at(2, 2.4), name: "Selected Choice")
            let open = b.add("switch", at: at(3, 3.6), name: "Open")
            let spring = b.add("spring", at: at(4, 3.6), inputs: ["response": .number(0.25), "damping": .number(0.85)])
            let showing = b.add("greater", at: at(5, 4.6), name: "Showing", inputs: ["b": .number(0.01)])
            let grow = b.add("transition", at: at(5, 3.6), name: "Menu Scale", type: .number, inputs: ["start": .number(0.85), "end": .number(1)])
            let current = b.add("loopSelect", at: at(3, 0), name: "Current Choice", type: .text)
            let isCurrent = b.add("equal", at: at(3, 2.4), name: "Is Current")
            b.connect(options, "value", to: split, "text")
            b.connect(split, "array", to: each, "array")
            b.connect(each, "value", to: b.property(.text, of: choiceLabel.id, at: at(6, 0)), "value")
            b.connect(each, "index", to: everyChoice, "a")
            b.connect(everyChoice, "result", to: b.property(.enabled, of: choice.id, at: at(6, 1)), "value")
            b.connect(picks, "tap", to: chosen, "set")
            b.connect(initial, "value", to: chosen, "start")
            b.connect(each, "value", to: current, "loop")
            b.connect(chosen, "option", to: current, "index")
            b.connect(current, "value", to: b.property(.text, of: label.id, at: at(6, 1.8)), "value")
            b.connect(each, "index", to: isCurrent, "a")
            b.connect(chosen, "option", to: isCurrent, "b")
            b.connect(isCurrent, "result", to: b.property(.opacity, of: check.id, at: at(6, 2.6)), "value")
            b.connect(opens, "tap", to: open, "flip")
            b.connect(chosen, "picked", to: open, "turnOff")
            b.connect(open, "on", to: spring, "target")
            b.connect(spring, "value", to: grow, "progress")
            b.connect(spring, "value", to: showing, "a")
            b.connect(spring, "value", to: b.property(.opacity, of: menu.id, at: at(6, 3.6)), "value")
            b.connect(grow, "value", to: b.property(.scale, of: menu.id, at: at(6, 3.6)), "value")
            b.connect(showing, "result", to: b.property(.visible, of: menu.id, at: at(6, 3.6)), "value")
            b.connect(tint, "value", to: b.property(.textColor, of: label.id, at: at(6, 1.8)), "value")
            b.connect(tint, "value", to: b.property(.fill, of: chevrons.id, at: at(6, 5.4)), "value")
            b.connect(chosen, "option", to: b.output("Selected", .number, at: at(6, 6.4)), "value")
            b.connect(chosen, "changed", to: b.output("Changed", .pulse, at: at(6, 7.2)), "value")
            b.connect(open, "on", to: b.output("Open", .bool, at: at(6, 8)), "value")
            var look = Look(&b, row: 7)
            look.paint(&b, SystemStyle.elevated, "Menu Color", .fill, of: menu)
            look.paint(&b, SystemStyle.label, "Choice Color", .textColor, of: choiceLabel)
            look.paint(&b, SystemStyle.label, "Check Color", .fill, of: check)
        }
    }()

    // MARK: Progress Bar

    static let progressBar: ComponentDefinition = {
        let fill = Layer(name: "Fill", kind: .view, properties: [.size: size(140, 4), .cornerRadius: .number(2), .fill: .color(blue)])
        let root = group("Progress Bar", [.size: size(280, 4), .cornerRadius: .number(2), .fill: .color(controlFill), .clips: .bool(true)], [fill])

        return make("Progress Bar", "A bar that fills from the left as Value goes from 0 to 1.", root: root) { b in
            let value = b.input("Value", .number, .number(0.5), at: at(0, 0))
            let tint = b.input("Tint", .color, .color(blue), at: at(0, 2.4))
            let measured = b.bound("layerSize", to: root.id, at: at(0, 1))
            let kept = b.add("clamp", at: at(1, 0), inputs: ["min": .number(0), "max": .number(1)])
            let width = b.add("multiply", at: at(2, 0), name: "Fill Width")
            let size = b.add("makePoint", at: at(3, 0))
            b.connect(value, "value", to: kept, "value")
            b.connect(kept, "result", to: width, "a")
            b.connect(measured, "width", to: width, "b")
            b.connect(width, "result", to: size, "x")
            b.connect(measured, "height", to: size, "y")
            b.connect(size, "point", to: b.property(.size, of: fill.id, at: at(4, 0)), "value")
            b.connect(tint, "value", to: b.property(.fill, of: fill.id, at: at(4, 2.4)), "value")
            var look = Look(&b, row: 3.6)
            look.paint(&b, SystemStyle.controlFill, "Track Color", .fill, of: root)
        }
    }()

    // MARK: Activity Indicator

    static let activityIndicator: ComponentDefinition = {
        let mark = Layer(name: "Mark", kind: .view, properties: [
            .position: .point(Point2(x: 8.8, y: 0)), .size: size(2.4, 6.6), .cornerRadius: .number(1.2), .fill: .color(secondaryLabel),
        ])
        // Each tick turns about the middle of the indicator, so the marks stand in a ring.
        // 20 points across, as UIKit's medium indicator (SwiftUI's ProgressView) is.
        let tick = group("Tick", [.size: size(20, 20)], [mark])
        let root = group("Activity Indicator", [.size: size(20, 20)], [tick])

        return make("Activity Indicator", "A spinner that turns while something is loading. It is hidden when Animating is off.", root: root) { b in
            let animating = b.input("Animating", .bool, .bool(true), at: at(0, 0))
            let ticks = b.add("loop", at: at(0, 1), inputs: ["count": .number(8)])
            let angle = b.add("multiply", at: at(1, 1), name: "Angle", inputs: ["b": .number(45)])
            let time = b.add("time", at: at(0, 2.4))
            let steps = b.add("multiply", at: at(1, 2.4), name: "Steps", inputs: ["b": .number(10)])
            let whole = b.add("round", at: at(2, 2.4))
            let behind = b.add("subtract", at: at(3, 2.4), name: "Behind the Lead")
            let around = b.add("mod", at: at(4, 2.4), inputs: ["b": .number(8)])
            let share = b.add("divide", at: at(5, 2.4), inputs: ["b": .number(7)])
            let fade = b.add("transition", at: at(6, 2.4), name: "Fade", type: .number, inputs: ["start": .number(0.25), "end": .number(1)])
            b.connect(ticks, "index", to: angle, "a")
            b.connect(angle, "result", to: b.property(.rotation, of: tick.id, at: at(7, 1)), "value")
            b.connect(time, "time", to: steps, "a")
            b.connect(steps, "result", to: whole, "value")
            b.connect(ticks, "index", to: behind, "a")
            b.connect(whole, "result", to: behind, "b")
            b.connect(behind, "result", to: around, "a")
            b.connect(around, "result", to: share, "a")
            b.connect(share, "result", to: fade, "progress")
            b.connect(fade, "value", to: b.property(.opacity, of: tick.id, at: at(7, 1)), "value")
            b.connect(animating, "value", to: b.property(.visible, of: root.id, at: at(7, 0)), "value")
            // Stopped, it asks for no frames: a spinner that is not there costs nothing.
            b.connect(animating, "value", to: time, "running")
            var look = Look(&b, row: 4)
            look.paint(&b, SystemStyle.secondaryLabel, "Mark Color", .fill, of: mark)
        }
    }()

    // MARK: Page Control

    static let pageControl: ComponentDefinition = {
        let quiet = SystemStyle.Dynamic(light: ColorValue(white: 0, alpha: 0.25), dark: ColorValue(white: 1, alpha: 0.3))
        let dot = Layer(name: "Dot", kind: .ellipse, properties: [.size: size(8, 8), .fill: .color(quiet.light)])
        let root = group("Page Control", [
            .size: size(120, 26), .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
            .distribution: .text("Center"), .spacing: .number(9.7),
        ], [dot])

        return make("Page Control", "A row of dots, one for each page, with the current one marked.", root: root) { b in
            let count = b.input("Pages", .number, .number(3), at: at(0, 0))
            let selected = b.input("Selected", .number, .number(0), at: at(0, 1.2))
            let pages = b.add("loop", at: at(1, 0))
            let nearest = b.add("round", at: at(1, 1.2))
            let isCurrent = b.add("equal", at: at(2, 0.6), name: "Is Current")
            let color = b.add("transition", at: at(3, 0.6), name: "Dot Color", type: .color)
            // No screen has room for more dots than this, and a count gone wrong should not
            // make a thousand of them.
            let room = b.add("clamp", at: at(1, -1), name: "Pages That Fit", inputs: ["min": .number(0), "max": .number(30)])
            b.connect(count, "value", to: room, "value")
            b.connect(room, "result", to: pages, "count")
            b.connect(selected, "value", to: nearest, "value")
            b.connect(pages, "index", to: isCurrent, "a")
            b.connect(nearest, "result", to: isCurrent, "b")
            b.connect(isCurrent, "result", to: color, "progress")
            b.connect(color, "value", to: b.property(.fill, of: dot.id, at: at(4, 0.6)), "value")
            var look = Look(&b, row: 2.4)
            b.connect(look.color(&b, quiet, "Other Pages"), "value", to: color, "start")
            b.connect(look.color(&b, SystemStyle.label, "This Page"), "value", to: color, "end")
        }
    }()
}
