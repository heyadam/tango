import Foundation
import PaperModel

extension ComponentLibrary {
    /// What every presentation has: whether it is there to begin with, a pulse that brings
    /// it, the switch that remembers, and a spring from 0 (away) to 1 (there).
    struct Presenting {
        let shown: NodeID
        let spring: NodeID
        /// On while any of it can be seen.
        let visible: NodeID

        init(_ b: inout Builder, row: Double, response: Double = 0.32) {
            let presented = b.input("Presented", .bool, .bool(true), at: at(0, row))
            let present = b.input("Present", .pulse, .pulse(false), at: at(0, row + 1))
            shown = b.add("switch", at: at(1, row), name: "Shown")
            spring = b.add("spring", at: at(2, row), inputs: ["response": .number(response), "damping": .number(0.9)])
            visible = b.add("greater", at: at(3, row + 1), name: "Visible", inputs: ["b": .number(0.01)])
            b.connect(presented, "value", to: shown, "start")
            b.connect(present, "value", to: shown, "turnOn")
            b.connect(shown, "on", to: spring, "target")
            b.connect(spring, "value", to: visible, "a")
        }
    }

    /// A view as large as the component, kept that size whatever size the component is given.
    static func cover(_ b: inout Builder, _ layer: Layer, of root: Layer, column: Double, row: Double) {
        let measured = b.bound("layerSize", to: root.id, at: at(column, row))
        let whole = b.add("makePoint", at: at(column + 1, row), name: "Whole Size")
        b.connect(measured, "width", to: whole, "x")
        b.connect(measured, "height", to: whole, "y")
        b.connect(whole, "point", to: b.property(.size, of: layer.id, at: at(column + 2, row)), "value")
    }

    // MARK: Alert

    static let alert: ComponentDefinition = {
        // Measured on the real one (iOS 26, 402 points wide): a gray card 320 wide with
        // corners of 36, its middle 14 points under the screen's; the title 22 from its top
        // and 30 from its side, the message 8 under it in gray; then 19 to two gray capsules
        // 48 high, 8 apart, 15 from the sides and 16 from the bottom. Neither is tinted.
        let dim = Layer(name: "Dim", kind: .view, properties: [
            .size: size(402, 874), .fill: .color(SystemStyle.dim.light), .absolute: .bool(true),
        ])
        let title = text("Title", "Title", weight: SystemStyle.headline.weight, [.size: size(260, 21), .widthMode: .text("Grow"), .singleLine: .bool(false)])
        let message = text("Message", "A message that says what happened.", size: SystemStyle.subheadline.size, color: SystemStyle.alertMessage.light, [
            .size: size(260, 18), .widthMode: .text("Grow"), .singleLine: .bool(false),
        ])
        let texts = group("Texts", [
            .widthMode: .text("Grow"), .heightMode: .text("Auto"), .layout: .text("Stack"), .axis: .text("Vertical"), .spacing: .number(7.7),
            .paddingHorizontal: .number(14.7), .paddingVertical: .number(0),
        ], [title, message])
        let buttonLabel = text("Button Label", "OK", weight: 500, [.widthMode: .text("Grow"), .textAlignment: .text("Center")])
        let button = group("Button", [
            .size: size(120, 48), .widthMode: .text("Grow"), .cornerRadius: .number(24), .fill: .color(SystemStyle.alertButton.light),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
        ], [buttonLabel])
        let buttons = group("Buttons", [
            .size: size(288, 48), .widthMode: .text("Grow"), .layout: .text("Stack"), .axis: .text("Horizontal"), .spacing: .number(8),
        ], [button])
        let card = group("Card", [
            .size: size(320, 152), .heightMode: .text("Auto"), .fill: .color(SystemStyle.alertSurface.light), .cornerRadius: .number(36),
            .layout: .text("Stack"), .axis: .text("Vertical"), .spacing: .number(19.4),
            .paddingHorizontal: .number(15), .paddingVertical: .number(16), .paddingTop: .number(22),
            .shadowColor: .color(ColorValue(white: 0, alpha: 0.14)), .shadowRadius: .number(24), .shadowOffset: .point(Point2(x: 0, y: 8)),
        ], [texts, buttons])
        let root = group("Alert", [
            .size: size(402, 874), .layout: .text("Stack"), .axis: .text("Vertical"), .alignment: .text("Center"), .distribution: .text("Center"),
            .paddingHorizontal: .number(0), .paddingVertical: .number(0), .paddingTop: .number(28),
        ], [dim, card])

        return make(
            "Alert", "An alert over the whole screen: a title, a message and buttons from a comma-separated list. A tap on a button dismisses it and says which. Pulse Present to show it again.",
            root: root, placement: .fill
        ) { b in
            let titleText = b.input("Title", .text, .text("Title"), at: at(0, 0))
            let messageText = b.input("Message", .text, .text("A message that says what happened."), at: at(0, 1))
            let names = b.input("Buttons", .text, .text("Cancel, OK"), at: at(0, 2))
            let split = b.add("splitText", at: at(1, 2))
            let each = b.add("loopOverArray", at: at(2, 2), type: .text)
            let everyButton = b.add("greaterEqual", at: at(3, 3), name: "Every Button")
            let touch = b.interaction(on: button.id, at: at(0, 5.2))
            _ = b.interaction(on: dim.id, at: at(0, 12))
            let chosen = b.add("loopOptionSwitch", at: at(2, 5.2), name: "Chosen Button", inputs: ["start": .number(-1)])
            let press = b.add("transition", at: at(4, 6.4), name: "Dim", type: .number, inputs: ["start": .number(1), "end": .number(0.6)])
            let presenting = Presenting(&b, row: 8)
            let settle = b.add("transition", at: at(3, 8), name: "Card Scale", type: .number, inputs: ["start": .number(1.08), "end": .number(1)])
            b.connect(titleText, "value", to: b.property(.text, of: title.id, at: at(6, 0)), "value")
            b.connect(messageText, "value", to: b.property(.text, of: message.id, at: at(6, 1)), "value")
            b.connect(names, "value", to: split, "text")
            b.connect(split, "array", to: each, "array")
            b.connect(each, "value", to: b.property(.text, of: buttonLabel.id, at: at(6, 2)), "value")
            b.connect(each, "index", to: everyButton, "a")
            b.connect(everyButton, "result", to: b.property(.enabled, of: button.id, at: at(6, 3)), "value")
            b.connect(touch, "down", to: press, "progress")
            b.connect(press, "value", to: b.property(.opacity, of: button.id, at: at(6, 3)), "value")
            b.connect(touch, "tap", to: chosen, "set")
            b.connect(chosen, "picked", to: presenting.shown, "turnOff")
            b.connect(presenting.spring, "value", to: settle, "progress")
            b.connect(presenting.spring, "value", to: b.property(.opacity, of: dim.id, at: at(6, 8)), "value")
            b.connect(presenting.spring, "value", to: b.property(.opacity, of: card.id, at: at(6, 9)), "value")
            b.connect(settle, "value", to: b.property(.scale, of: card.id, at: at(6, 9)), "value")
            b.connect(presenting.visible, "result", to: b.property(.visible, of: root.id, at: at(6, 10)), "value")
            cover(&b, dim, of: root, column: 3, row: 11)
            b.connect(chosen, "option", to: b.output("Chosen", .number, at: at(6, 12)), "value")
            b.connect(chosen, "picked", to: b.output("Dismissed", .pulse, at: at(6, 13)), "value")
            b.connect(presenting.shown, "on", to: b.output("Showing", .bool, at: at(6, 14)), "value")
            var look = Look(&b, row: 13)
            look.paint(&b, SystemStyle.alertSurface, "Card Color", .fill, of: card)
            look.paint(&b, SystemStyle.label, "Text Color", .textColor, of: title, buttonLabel)
            look.paint(&b, SystemStyle.alertMessage, "Message Color", .textColor, of: message)
            look.paint(&b, SystemStyle.alertButton, "Button Color", .fill, of: button)
            look.paint(&b, SystemStyle.dim, "Dim Color", .fill, of: dim)
        }
    }()

    // MARK: Action Sheet

    static let actionSheet: ComponentDefinition = {
        // Measured on the real one (iOS 26, a confirmation dialog with nothing to point at):
        // a card of glass 240 wide in the middle of the screen, its middle 13 points under
        // the screen's; the title 23 from its top; then gray capsules 48 high, 8 apart, 16
        // from the sides and the bottom. There is no Cancel: a tap outside is the way out.
        let outside = Layer(name: "Outside", kind: .view, properties: [
            .size: size(402, 874), .fill: .color(ColorValue(white: 0, alpha: 0)), .absolute: .bool(true),
        ])
        let heading = text("Heading", "Title", [.size: size(200, 21), .widthMode: .text("Grow"), .textAlignment: .text("Center"), .singleLine: .bool(false)])
        let headingRow = group("Heading Row", [
            .widthMode: .text("Grow"), .heightMode: .text("Auto"), .layout: .text("Stack"), .axis: .text("Horizontal"),
            .paddingHorizontal: .number(0), .paddingVertical: .number(0), .paddingBottom: .number(10.3),
        ], [heading])
        let actionLabel = text("Action Label", "Action", weight: 500, [.widthMode: .text("Grow"), .textAlignment: .text("Center")])
        let action = group("Action", [
            .size: size(208, 48), .widthMode: .text("Grow"), .cornerRadius: .number(24), .fill: .color(SystemStyle.sheetButton.light),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
        ], [actionLabel])
        let card = group("Card", [
            .size: size(240, 180), .heightMode: .text("Auto"), .fill: .color(SystemStyle.sheetSurface.light), .cornerRadius: .number(36),
            .layout: .text("Stack"), .axis: .text("Vertical"), .spacing: .number(8),
            .paddingHorizontal: .number(16), .paddingVertical: .number(16), .paddingTop: .number(21.7),
            .shadowColor: .color(ColorValue(white: 0, alpha: 0.14)), .shadowRadius: .number(28), .shadowOffset: .point(Point2(x: 0, y: 10)),
        ], [headingRow, action])
        let root = group("Action Sheet", [
            .size: size(402, 874), .layout: .text("Stack"), .axis: .text("Vertical"), .alignment: .text("Center"), .distribution: .text("Center"),
            .paddingHorizontal: .number(0), .paddingVertical: .number(0), .paddingTop: .number(26),
        ], [outside, card])

        return make(
            "Action Sheet", "Choices on a card of glass in the middle of the screen, as a confirmation dialog is on iOS 26. Give it a comma-separated list; a tap on a choice or outside dismisses it.",
            root: root, placement: .fill
        ) { b in
            let titleText = b.input("Title", .text, .text("Title"), at: at(0, 0))
            let names = b.input("Actions", .text, .text("Duplicate, Delete"), at: at(0, 1))
            let destructive = b.input("Destructive", .number, .number(1), at: at(0, 3))
            let split = b.add("splitText", at: at(1, 1))
            let each = b.add("loopOverArray", at: at(2, 1), type: .text)
            let everyAction = b.add("greaterEqual", at: at(3, 2), name: "Every Action")
            let isDestructive = b.add("equal", at: at(3, 3), name: "Is Destructive")
            let ink = b.add("if", at: at(4, 3), name: "Action Ink", type: .color, inputs: ["then": .color(SystemStyle.red.light)])
            let touch = b.interaction(on: action.id, at: at(0, 6.2))
            let away = b.interaction(on: outside.id, at: at(0, 7.6))
            let chosen = b.add("loopOptionSwitch", at: at(2, 6.2), name: "Chosen Action", inputs: ["start": .number(-1)])
            let done = b.add("eitherPulse", at: at(3, 7.2), name: "Dismissed")
            let press = b.add("transition", at: at(3, 5), name: "Dim", type: .number, inputs: ["start": .number(1), "end": .number(0.6)])
            let length = b.add("textLength", at: at(1, 0))
            let hasTitle = b.add("not", at: at(2, 0), name: "Has Title")
            let presenting = Presenting(&b, row: 10.4, response: 0.3)
            let settle = b.add("transition", at: at(3, 10.4), name: "Card Scale", type: .number, inputs: ["start": .number(0.9), "end": .number(1)])
            b.connect(titleText, "value", to: b.property(.text, of: heading.id, at: at(7, 0)), "value")
            b.connect(titleText, "value", to: length, "text")
            b.connect(length, "empty", to: hasTitle, "value")
            b.connect(hasTitle, "result", to: b.property(.visible, of: headingRow.id, at: at(7, 0.8)), "value")
            b.connect(names, "value", to: split, "text")
            b.connect(split, "array", to: each, "array")
            b.connect(each, "value", to: b.property(.text, of: actionLabel.id, at: at(7, 1.6)), "value")
            b.connect(each, "index", to: everyAction, "a")
            b.connect(everyAction, "result", to: b.property(.enabled, of: action.id, at: at(7, 2.4)), "value")
            b.connect(each, "index", to: isDestructive, "a")
            b.connect(destructive, "value", to: isDestructive, "b")
            b.connect(isDestructive, "result", to: ink, "condition")
            b.connect(ink, "value", to: b.property(.textColor, of: actionLabel.id, at: at(7, 1.6)), "value")
            b.connect(touch, "down", to: press, "progress")
            b.connect(press, "value", to: b.property(.opacity, of: action.id, at: at(7, 2.4)), "value")
            b.connect(touch, "tap", to: chosen, "set")
            b.connect(chosen, "picked", to: done, "a")
            b.connect(away, "tap", to: done, "b")
            b.connect(done, "pulse", to: presenting.shown, "turnOff")
            b.connect(presenting.spring, "value", to: settle, "progress")
            b.connect(presenting.spring, "value", to: b.property(.opacity, of: card.id, at: at(7, 10.4)), "value")
            b.connect(settle, "value", to: b.property(.scale, of: card.id, at: at(7, 10.4)), "value")
            b.connect(presenting.visible, "result", to: b.property(.visible, of: root.id, at: at(7, 11.4)), "value")
            cover(&b, outside, of: root, column: 3, row: 16)
            b.connect(chosen, "option", to: b.output("Chosen", .number, at: at(7, 6.2)), "value")
            b.connect(chosen, "picked", to: b.output("Picked", .pulse, at: at(7, 7.2)), "value")
            b.connect(away, "tap", to: b.output("Cancelled", .pulse, at: at(7, 8.2)), "value")
            b.connect(done, "pulse", to: b.output("Dismissed", .pulse, at: at(7, 9.2)), "value")
            b.connect(presenting.shown, "on", to: b.output("Showing", .bool, at: at(7, 9.8)), "value")
            var look = Look(&b, row: 17.4)
            look.paint(&b, SystemStyle.sheetSurface, "Card Color", .fill, of: card)
            look.paint(&b, SystemStyle.sheetButton, "Button Color", .fill, of: action)
            look.paint(&b, SystemStyle.label, "Heading Color", .textColor, of: heading)
            b.connect(look.color(&b, SystemStyle.label, "Plain Ink"), "value", to: ink, "else")
        }
    }()

    // MARK: Context Menu

    static let contextMenu: ComponentDefinition = {
        let label = text("Item Label", "Copy", [.widthMode: .text("Grow")])
        let glyph = symbol("Glyph", "doc.on.doc", width: 20, height: 20, color: .black, weight: 400)
        let item = group("Item", [
            .size: size(250, SystemStyle.menuRowHeight), .widthMode: .text("Grow"), .layout: .text("Stack"), .axis: .text("Horizontal"),
            .alignment: .text("Center"), .paddingHorizontal: .number(SystemStyle.margin), .paddingVertical: .number(0), .spacing: .number(10),
        ], [label, glyph])
        let root = group("Context Menu", [
            .size: size(250, 144), .heightMode: .text("Auto"), .fill: .color(.white), .cornerRadius: .number(SystemStyle.alertRadius + 4),
            .layout: .text("Stack"), .axis: .text("Vertical"), .paddingHorizontal: .number(0), .paddingVertical: .number(6),
            .shadowColor: .color(ColorValue(white: 0, alpha: 0.2)), .shadowRadius: .number(28), .shadowOffset: .point(Point2(x: 0, y: 10)),
        ], [item])

        return make(
            "Context Menu", "A menu of actions with a symbol each, as a long press brings up. Give it comma-separated titles and symbol names; a tap on one dismisses it and says which. Pulse Present to show it again.",
            root: root
        ) { b in
            let titles = b.input("Items", .text, .text("Copy, Share, Delete"), at: at(0, 0))
            let symbols = b.input("Symbols", .text, .text("doc.on.doc, square.and.arrow.up, trash"), at: at(0, 1))
            let destructive = b.input("Destructive", .number, .number(2), at: at(0, 3.4))
            let splitTitles = b.add("splitText", at: at(1, 0))
            let splitSymbols = b.add("splitText", at: at(1, 1))
            let eachTitle = b.add("loopOverArray", at: at(2, 0), type: .text)
            let eachSymbol = b.add("loopOverArray", at: at(2, 1), type: .text)
            let everyItem = b.add("greaterEqual", at: at(3, 2), name: "Every Item")
            let isDestructive = b.add("equal", at: at(3, 3.4), name: "Is Destructive")
            let ink = b.add("if", at: at(4, 3.4), name: "Ink", type: .color, inputs: ["then": .color(SystemStyle.red.light)])
            let touch = b.interaction(on: item.id, at: at(0, 4.8))
            let chosen = b.add("loopOptionSwitch", at: at(2, 4.8), name: "Chosen Item", inputs: ["start": .number(-1)])
            let press = b.add("transition", at: at(3, 4.8), name: "Highlight", type: .color, inputs: ["start": .color(ColorValue(white: 0.5, alpha: 0))])
            let presenting = Presenting(&b, row: 6.4, response: 0.26)
            let grow = b.add("transition", at: at(3, 6.4), name: "Scale", type: .number, inputs: ["start": .number(0.8), "end": .number(1)])
            b.connect(titles, "value", to: splitTitles, "text")
            b.connect(symbols, "value", to: splitSymbols, "text")
            b.connect(splitTitles, "array", to: eachTitle, "array")
            b.connect(splitSymbols, "array", to: eachSymbol, "array")
            b.connect(eachTitle, "value", to: b.property(.text, of: label.id, at: at(6, 0)), "value")
            b.connect(eachSymbol, "value", to: b.property(.symbol, of: glyph.id, at: at(6, 1)), "value")
            b.connect(eachTitle, "index", to: everyItem, "a")
            b.connect(everyItem, "result", to: b.property(.enabled, of: item.id, at: at(6, 2)), "value")
            b.connect(eachTitle, "index", to: isDestructive, "a")
            b.connect(destructive, "value", to: isDestructive, "b")
            b.connect(isDestructive, "result", to: ink, "condition")
            b.connect(ink, "value", to: b.property(.textColor, of: label.id, at: at(6, 0)), "value")
            b.connect(ink, "value", to: b.property(.fill, of: glyph.id, at: at(6, 1)), "value")
            b.connect(touch, "tap", to: chosen, "set")
            b.connect(touch, "down", to: press, "progress")
            b.connect(press, "value", to: b.property(.fill, of: item.id, at: at(6, 2)), "value")
            b.connect(chosen, "picked", to: presenting.shown, "turnOff")
            b.connect(presenting.spring, "value", to: grow, "progress")
            b.connect(presenting.spring, "value", to: b.property(.opacity, of: root.id, at: at(6, 6.4)), "value")
            b.connect(grow, "value", to: b.property(.scale, of: root.id, at: at(6, 6.4)), "value")
            b.connect(presenting.visible, "result", to: b.property(.visible, of: root.id, at: at(6, 6.4)), "value")
            b.connect(chosen, "option", to: b.output("Chosen", .number, at: at(6, 8)), "value")
            b.connect(chosen, "picked", to: b.output("Picked", .pulse, at: at(6, 9)), "value")
            b.connect(presenting.shown, "on", to: b.output("Showing", .bool, at: at(6, 10)), "value")
            var look = Look(&b, row: 9)
            look.paint(&b, SystemStyle.elevated, "Menu Color", .fill, of: root)
            b.connect(look.color(&b, SystemStyle.label, "Plain Ink"), "value", to: ink, "else")
            b.connect(look.color(&b, SystemStyle.pressed, "Pressed Color"), "value", to: press, "end")
        }
    }()

    // MARK: Keyboard

    static let keyboard: ComponentDefinition = {
        // As iOS 26 draws it, measured in the simulator (Reference/run.sh): a panel 336 high
        // with corners of 26, a strip of suggestions 53 high with two lines in it, then rows
        // of white keys 43 high and 11 apart, 7.3 in from the sides and 7.3 apart, capitals
        // on them, and the emoji and dictation buttons under the last row.
        let board = SystemStyle.Dynamic("#E0E1E8", "#202020")
        let keyFill = SystemStyle.Dynamic("#FFFFFF", "#444444")
        let quietFill = SystemStyle.Dynamic("#FFFFFF", "#444444")
        let gap = 7.3, keyHeight = 43.0
        func key(_ name: String, _ label: Layer, width: Double? = nil, quiet: Bool = false) -> Layer {
            var properties: [LayerProperty: Value] = [
                .size: size(width ?? 32, keyHeight), .cornerRadius: .number(8), .fill: .color((quiet ? quietFill : keyFill).light),
                .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .distribution: .text("Center"),
            ]
            if width == nil { properties[.widthMode] = .text("Grow") }
            // Words on a key stand a little above its middle.
            if label.kind == .text { properties[.paddingVertical] = .number(0); properties[.paddingBottom] = .number(2.6) }
            return group(name, properties, [label])
        }
        func letter(_ name: String) -> Layer { text(name, "Q", size: 22, [.widthMode: .text("Grow"), .textAlignment: .text("Center")]) }
        func glyph(_ name: String, _ symbol: String) -> Layer { ComponentLibrary.symbol(name, symbol, width: 24.5, height: 21, color: .black, weight: 400) }
        func row(_ name: String, _ children: [Layer], inset: Double = 0) -> Layer {
            group(name, [
                .size: size(387, keyHeight), .widthMode: .text("Grow"), .layout: .text("Stack"), .axis: .text("Horizontal"), .spacing: .number(gap),
                .paddingHorizontal: .number(inset), .paddingVertical: .number(0),
            ], children)
        }
        let letters = [letter("Top Letter"), letter("Middle Letter"), letter("Bottom Letter")]
        let keys = [key("Top Key", letters[0]), key("Middle Key", letters[1]), key("Bottom Key", letters[2])]
        let shiftGlyph = glyph("Shift Glyph", "shift.fill"), deleteGlyph = glyph("Delete Glyph", "delete.left")
        let shift = key("Shift", shiftGlyph, width: 44, quiet: true), delete = key("Delete", deleteGlyph, width: 44, quiet: true)
        // The space bar has no word on it and Return is a glyph; the labels stay, empty, so
        // documents that cabled them keep their cables.
        let numbersLabel = text("Numbers Label", "123", size: 18), spaceLabel = text("Space Label", "", size: 16), returnLabel = text("Return Label", "", size: 16)
        let returnGlyph = glyph("Return Glyph", "return.left")
        let numbers = key("Numbers", numbersLabel, width: 91.4, quiet: true), space = key("Space", spaceLabel)
        let enter = key("Return", returnLabel, width: 91.4, quiet: true)
        var returnKey = enter
        returnKey.children.append(returnGlyph)
        // Shift and Delete stand 15 from the letters.
        let bottomSpacers = [group("Left Gap", [.size: size(15 - 2 * gap, keyHeight)]), group("Right Gap", [.size: size(15 - 2 * gap, keyHeight)])]
        let rows = [
            row("Top Row", [keys[0]]), row("Middle Row", [keys[1]], inset: 19.7),
            row("Bottom Row", [shift, bottomSpacers[0], keys[2], bottomSpacers[1], delete]), row("Last Row", [numbers, space, returnKey]),
        ]
        func line(_ name: String, x: Double) -> Layer {
            Layer(name: name, kind: .view, properties: [
                .position: .point(Point2(x: x, y: 13.7)), .size: size(1, 24), .fill: .color(ColorValue(white: 0, alpha: 0.12)),
            ])
        }
        let strip = group("Suggestions", [
            .size: size(402, 41.7), .absolute: .bool(true), .position: .point(.zero),
        ], [line("First Line", x: 133), line("Second Line", x: 267)])
        let emoji = ComponentLibrary.symbol("Emoji", "face.smiling.inverse", width: 31.5, height: 31.5, color: .black, weight: 400)
        let dictation = ComponentLibrary.symbol("Dictation", "mic", width: 27, height: 37, color: .black, weight: 400)
        let lower = group("Lower Buttons", [
            .size: size(402, 30), .absolute: .bool(true), .position: .point(Point2(x: 0, y: 280.5)),
        ], [
            { var l = emoji; l.set(.position, .point(Point2(x: 26.7, y: -0.6))); return l }(),
            { var l = dictation; l.set(.position, .point(Point2(x: 345.8, y: -4))); return l }(),
        ])
        let panel = group("Board", [
            .size: size(402, 336), .fill: .color(board.light), .cornerRadius: .number(26), .layout: .text("Stack"), .axis: .text("Vertical"),
            .spacing: .number(11), .paddingHorizontal: .number(gap), .paddingVertical: .number(0), .paddingTop: .number(52.7),
        ], rows + [strip, lower])
        let root = group("Keyboard", [.size: size(402, 336), .clips: .bool(true)], [panel])

        return make(
            "Keyboard", "The keyboard, as a picture: it slides up while Presented is on. Cable a Text Field's Editing into Presented. Typing still comes from the Mac's keyboard.",
            root: root, placement: .bottom
        ) { b in
            let presenting = Presenting(&b, row: 0, response: 0.36)
            let measured = b.bound("layerSize", to: root.id, at: at(0, 2.4))
            let frame = b.add("makePoint", at: at(1, 2.4), name: "Board Size")
            let fall = b.add("transition", at: at(3, 0), name: "Fall", type: .number, inputs: ["end": .number(0)])
            let place = b.add("makePoint", at: at(4, 0))
            b.connect(measured, "width", to: frame, "x")
            b.connect(measured, "height", to: frame, "y")
            b.connect(measured, "height", to: fall, "start")
            b.connect(presenting.spring, "value", to: fall, "progress")
            b.connect(fall, "value", to: place, "y")
            b.connect(frame, "point", to: b.property(.size, of: panel.id, at: at(5, 2.4)), "value")
            b.connect(place, "point", to: b.property(.position, of: panel.id, at: at(5, 2.4)), "value")
            b.connect(presenting.visible, "result", to: b.property(.visible, of: root.id, at: at(5, 1.2)), "value")
            // Nothing behind the keyboard is touched through it.
            _ = b.interaction(on: panel.id, at: at(0, 3.6))
            // Capitals, as at the start of a field.
            for (index, line) in ["Q, W, E, R, T, Y, U, I, O, P", "A, S, D, F, G, H, J, K, L", "Z, X, C, V, B, N, M"].enumerated() {
                let rowAt = 5 + Double(index) * 1.4
                let split = b.add("splitText", at: at(0, rowAt), inputs: ["text": .text(line)])
                let each = b.add("loopOverArray", at: at(1, rowAt), type: .text)
                let every = b.add("greaterEqual", at: at(2, rowAt), name: "Every Key")
                b.connect(split, "array", to: each, "array")
                b.connect(each, "value", to: b.property(.text, of: letters[index].id, at: at(4, rowAt)), "value")
                b.connect(each, "index", to: every, "a")
                b.connect(every, "result", to: b.property(.enabled, of: keys[index].id, at: at(4, rowAt)), "value")
            }
            b.connect(presenting.shown, "on", to: b.output("Showing", .bool, at: at(5, 0)), "value")
            var look = Look(&b, row: 10)
            look.paint(&b, board, "Board Color", .fill, of: panel)
            look.paint(&b, keyFill, "Key Color", .fill, of: keys[0], keys[1], keys[2], space)
            look.paint(&b, quietFill, "Quiet Key Color", .fill, of: shift, delete, numbers, returnKey)
            look.paint(&b, SystemStyle.label, "Letter Color", .textColor, of: letters[0], letters[1], letters[2], numbersLabel, spaceLabel, returnLabel)
            look.paint(&b, SystemStyle.label, "Glyph Color", .fill, of: shiftGlyph, deleteGlyph)
            // Added after the rest, so the ids of the patches above stay what documents stored.
            look.paint(&b, SystemStyle.label, "Button Color", .fill, of: returnGlyph, emoji, dictation)
        }
    }()

    // MARK: Sheet

    /// A sheet that comes up over the screen and is dragged down to dismiss, with a view
    /// for a person's own content.
    static let sheet: ViewTemplate = {
        let height = 520.0, screen = Size2(width: 402, height: 874)
        let dim = Layer(name: "Dim", kind: .view, properties: [.size: .size(screen), .fill: .color(SystemStyle.dim.light)])
        let grabber = Layer(name: "Grabber", kind: .view, properties: [
            .position: .point(Point2(x: (screen.width - 2 * SystemStyle.sheetInset - 56) / 2, y: 5)), .size: size(56, 4), .cornerRadius: .number(2),
            .fill: .color(ColorValue(white: 0, alpha: 0.27)),
        ])
        // As iOS 26 shows a sheet that is not full height: a pane of glass that floats
        // `sheetInset` in from the sides and the bottom, Sheet Height from its top to the
        // bottom of the screen.
        let inset = SystemStyle.sheetInset, wide = screen.width - 2 * inset
        let content = group("Content", [.position: .point(Point2(x: 0, y: 28)), .size: size(wide, height - inset - 28)])
        let panel = group("Panel", [
            .position: .point(Point2(x: inset, y: screen.height - height)), .size: size(wide, height - inset),
            .fill: .color(SystemStyle.sheetGlass.light), .backgroundBlur: .number(20), .cornerRadius: .number(SystemStyle.sheetRadius),
            .strokeColor: .color(ColorValue(white: 0, alpha: 0.18)), .strokeWidth: .number(0.5),
            .shadowColor: .color(ColorValue(white: 0, alpha: 0.12)), .shadowRadius: .number(24), .shadowOffset: .point(Point2(x: 0, y: -4)),
        ], [grabber, content])
        let root = group("Sheet", [.size: .size(screen)], [dim, panel])

        return template(
            "Sheet", "A sheet that comes up over the screen, with a grabber: drag it down or tap outside to dismiss it. Put your views in Content. Pulse Present to bring it up.",
            root: root, placement: .fill, content: "Content"
        ) { b in
            let tall = b.add("value", at: at(0, 0), name: "Sheet Height", type: .number, inputs: ["value": .number(height)])
            let dark = b.add("value", at: at(0, 1), name: "Dark", type: .bool, inputs: ["value": .bool(false)])
            let shown = b.add("switch", at: at(1, 3), name: "Shown", inputs: ["start": .bool(true)])
            let measured = b.bound("layerSize", to: root.id, at: at(0, 5))
            let touch = b.interaction(on: panel.id, at: at(0, 6.4))
            let outside = b.interaction(on: dim.id, at: at(0, 8.4))
            let openY = b.add("subtract", at: at(1, 5), name: "Open Y")
            let rest = b.add("if", at: at(2, 4), name: "Rest", type: .number)
            let dragY = b.add("splitPoint", at: at(1, 6.4), name: "Drag Y")
            let spring = b.add("spring", at: at(3, 5), inputs: ["response": .number(0.4), "damping": .number(0.88)])
            let ceiling = b.add("subtract", at: at(2, 6), name: "Highest", inputs: ["b": .number(24)])
            let kept = b.add("max", at: at(4, 5), name: "Not Above")
            let place = b.add("makePoint", at: at(5, 5), inputs: ["x": .number(inset)])
            // Let go more than a third of the way down, it goes away.
            let third = b.add("multiply", at: at(1, 7.6), name: "A Third", inputs: ["b": .number(0.35)])
            let line = b.add("add", at: at(2, 7.6), name: "Threshold")
            let isLow = b.add("greater", at: at(4, 7.6), name: "Low Enough")
            let edges = b.add("pulse", at: at(1, 8.8), name: "Touch Began / Ended")
            let letGoLow = b.add("pulseGate", at: at(5, 7.6), name: "Let Go Low")
            let away = b.add("eitherPulse", at: at(6, 8.4), name: "Dismissed")
            let travelled = b.add("progress", at: at(4, 9.6), name: "Progress")
            let seen = b.add("clamp", at: at(5, 9.6), inputs: ["min": .number(0), "max": .number(1)])
            let isSeen = b.add("greater", at: at(6, 9.6), name: "Dim Shows", inputs: ["b": .number(0.01)])
            let panelSize = b.add("makePoint", at: at(2, 11))
            let longer = b.add("subtract", at: at(1, 11), name: "Panel Height", inputs: ["b": .number(inset)])
            let contentHeight = b.add("subtract", at: at(1, 12), name: "Content Height", inputs: ["b": .number(28 + inset)])
            let contentSize = b.add("makePoint", at: at(2, 12))
            let grabberX = b.add("subtract", at: at(1, 13), name: "Grabber Room", inputs: ["b": .number(56)])
            let grabberHalf = b.add("divide", at: at(2, 13), inputs: ["b": .number(2)])
            let grabberPlace = b.add("makePoint", at: at(3, 13), inputs: ["y": .number(5)])
            let wide = b.add("subtract", at: at(1, 14), name: "Panel Width", inputs: ["b": .number(2 * inset)])
            let surface = b.add("if", at: at(1, 1), name: "Surface", type: .color, inputs: [
                "then": .color(SystemStyle.sheetGlass.dark), "else": .color(SystemStyle.sheetGlass.light),
            ])
            b.connect(measured, "height", to: openY, "a")
            b.connect(tall, "value", to: openY, "b")
            b.connect(shown, "on", to: rest, "condition")
            b.connect(openY, "result", to: rest, "then")
            b.connect(measured, "height", to: rest, "else")
            b.connect(rest, "value", to: spring, "target")
            b.connect(touch, "down", to: spring, "hold")
            b.connect(touch, "drag", to: dragY, "point")
            b.connect(dragY, "y", to: spring, "held")
            b.connect(openY, "result", to: ceiling, "a")
            b.connect(spring, "value", to: kept, "a")
            b.connect(ceiling, "result", to: kept, "b")
            b.connect(kept, "result", to: place, "y")
            b.connect(place, "point", to: b.property(.position, of: panel.id, at: at(7, 5)), "value")
            b.connect(tall, "value", to: third, "a")
            b.connect(openY, "result", to: line, "a")
            b.connect(third, "result", to: line, "b")
            b.connect(spring, "value", to: isLow, "a")
            b.connect(line, "result", to: isLow, "b")
            b.connect(touch, "down", to: edges, "value")
            b.connect(edges, "turnedOff", to: letGoLow, "pulse")
            b.connect(isLow, "result", to: letGoLow, "open")
            b.connect(letGoLow, "pulse", to: away, "a")
            b.connect(outside, "tap", to: away, "b")
            b.connect(away, "pulse", to: shown, "turnOff")
            b.connect(spring, "value", to: travelled, "value")
            b.connect(measured, "height", to: travelled, "start")
            b.connect(openY, "result", to: travelled, "end")
            b.connect(travelled, "progress", to: seen, "value")
            b.connect(seen, "result", to: isSeen, "a")
            b.connect(seen, "result", to: b.property(.opacity, of: dim.id, at: at(7, 9.6)), "value")
            b.connect(isSeen, "result", to: b.property(.visible, of: dim.id, at: at(7, 9.6)), "value")
            cover(&b, dim, of: root, column: 4, row: 14.4)
            b.connect(tall, "value", to: longer, "a")
            b.connect(wide, "result", to: panelSize, "x")
            b.connect(longer, "result", to: panelSize, "y")
            b.connect(panelSize, "point", to: b.property(.size, of: panel.id, at: at(7, 5)), "value")
            b.connect(tall, "value", to: contentHeight, "a")
            b.connect(wide, "result", to: contentSize, "x")
            b.connect(contentHeight, "result", to: contentSize, "y")
            b.connect(contentSize, "point", to: b.property(.size, of: content.id, at: at(7, 12)), "value")
            b.connect(wide, "result", to: grabberX, "a")
            b.connect(grabberX, "result", to: grabberHalf, "a")
            b.connect(grabberHalf, "result", to: grabberPlace, "x")
            b.connect(grabberPlace, "point", to: b.property(.position, of: grabber.id, at: at(7, 13)), "value")
            b.connect(measured, "width", to: wide, "a")
            b.connect(dark, "value", to: surface, "condition")
            b.connect(surface, "value", to: b.property(.fill, of: panel.id, at: at(7, 5)), "value")

            b.publish("Presented", PortRef(node: shown, port: "start"), on: root.id, output: false, type: .bool)
            b.publish("Present", PortRef(node: shown, port: "turnOn"), on: root.id, output: false, type: .pulse)
            b.publish("Sheet Height", PortRef(node: tall, port: "value"), on: root.id, output: false, type: .number)
            b.publish("Dark", PortRef(node: dark, port: "value"), on: root.id, output: false, type: .bool)
            b.publish("Showing", PortRef(node: shown, port: "on"), on: root.id, output: true, type: .bool)
            b.publish("Progress", PortRef(node: seen, port: "result"), on: root.id, output: true, type: .number)
            b.publish("Dismissed", PortRef(node: away, port: "pulse"), on: root.id, output: true, type: .pulse)
        }
    }()
}
