import Foundation
import PaperModel

extension ComponentLibrary {
    // MARK: Navigation Bar

    /// A round button of glass with a symbol on it, as a bar has on iOS 26.
    static func glassButton(_ name: String, _ glyph: Layer, _ more: [Layer] = [], extra: [LayerProperty: Value] = [:]) -> Layer {
        var properties: [LayerProperty: Value] = [
            .size: size(44, 44), .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .distribution: .text("Center"),
            .shadowColor: .color(ColorValue(white: 0, alpha: 0.08)), .shadowRadius: .number(10), .shadowOffset: .point(Point2(x: 0, y: 3)),
        ]
        properties.merge(extra) { _, new in new }
        let side = properties[.size]?.sizeValue.height ?? 44
        return glass(name, properties, radius: side / 2, [glyph] + more)
    }

    static let navigationBar: ComponentDefinition = {
        // Measured on the real one (iOS 26): no bar is drawn. The title is in the middle of
        // a row 44 high, and the buttons are glass: a circle of 44 for Back, and a capsule
        // 44 high for the action, 16 from the edge, with its words the color of text.
        let chevron = symbol("Chevron", "chevron.left", width: 13, height: 22, color: .black, weight: 500)
        // Back has no words on iOS 26. The view stays, hidden, for the input that names it.
        let backLabel = text("Back Title", "Back", [.visible: .bool(false)])
        let back = glassButton("Back", chevron, [backLabel])
        let title = text("Title", "Title", weight: 600)
        let titleRow = group("Title Row", [
            .size: size(402, 44), .absolute: .bool(true), .layout: .text("Stack"), .axis: .text("Horizontal"),
            .alignment: .text("Center"), .distribution: .text("Center"),
        ], [title])
        let space = group("Space", [.size: size(10, 44), .widthMode: .text("Grow")])
        let actionLabel = text("Action Label", "")
        let action = glassButton("Action", actionLabel, extra: [
            .widthMode: .text("Auto"), .paddingHorizontal: .number(15.5), .paddingVertical: .number(0), .visible: .bool(false),
        ])
        let root = group("Navigation Bar", [
            .size: size(402, 44), .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
            .paddingHorizontal: .number(16), .paddingVertical: .number(0),
        ], [titleRow, back, space, action])

        return make("Navigation Bar", "A title in the middle with glass buttons at its ends, as on iOS 26: Back, and a button at the other end when Action names one. Both report taps. No bar is drawn behind them; Tint and Back Title are kept for documents that set them and change nothing.", root: root, placement: .top, shippedViews: 6) { b in
            let titleText = b.input("Title", .text, .text("Title"), at: at(0, 0))
            let backText = b.input("Back Title", .text, .text("Back"), at: at(0, 1))
            let showsBack = b.input("Shows Back", .bool, .bool(true), at: at(0, 2))
            _ = b.input("Tint", .color, .color(blue), at: at(0, 3.2))
            let touch = b.interaction(on: back.id, at: at(0, 4.4))
            b.connect(titleText, "value", to: b.property(.text, of: title.id, at: at(2, 0)), "value")
            b.connect(backText, "value", to: b.property(.text, of: backLabel.id, at: at(2, 0.8)), "value")
            b.connect(showsBack, "value", to: b.property(.opacity, of: back.id, at: at(2, 1.6)), "value")
            b.connect(showsBack, "value", to: b.property(.enabled, of: back.id, at: at(2, 2.4)), "value")
            b.connect(touch, "tap", to: b.output("Back", .pulse, at: at(2, 4.8)), "value")
            var look = Look(&b, row: 5.8)
            look.paint(&b, SystemStyle.label, "Text Color", .textColor, of: title, actionLabel)
            look.paint(&b, SystemStyle.label, "Glyph Color", .fill, of: chevron)
            // The button at the trailing end: there when Action has a name.
            let actionText = b.input("Action", .text, .text(""), at: at(0, 9))
            let actionTouch = b.interaction(on: action.id, at: at(0, 10))
            let length = b.add("textLength", at: at(1, 9))
            let hasAction = b.add("not", at: at(2, 9), name: "Has Action")
            b.connect(actionText, "value", to: length, "text")
            b.connect(length, "empty", to: hasAction, "value")
            b.connect(actionText, "value", to: b.property(.text, of: actionLabel.id, at: at(3, 9)), "value")
            b.connect(hasAction, "result", to: b.property(.visible, of: action.id, at: at(3, 10)), "value")
            b.connect(actionTouch, "tap", to: b.output("Action", .pulse, at: at(3, 11)), "value")
            // The title's row is as wide as the bar, so the title is in the middle of it
            // whatever stands at either end; and the glass takes the appearance's tint.
            let measured = b.bound("layerSize", to: root.id, at: at(0, 12))
            let rowSize = b.add("makePoint", at: at(1, 12), name: "Title Row Size", inputs: ["y": .number(SystemStyle.barHeight)])
            b.connect(measured, "width", to: rowSize, "x")
            b.connect(rowSize, "point", to: b.property(.size, of: titleRow.id, at: at(2, 12)), "value")
            let tint = look.color(&b, SystemStyle.glassTint, "Glass Tint")
            b.connect(tint, "value", to: b.view(back.id), ShaderUse.portID("tint"))
            b.connect(tint, "value", to: b.view(action.id), ShaderUse.portID("tint"))
        }
    }()

    // MARK: Large Title Bar

    static let largeTitleBar: ComponentDefinition = {
        let full = 96.0, travel = 52.0, titleTop = 14.0
        let chevron = symbol("Chevron", "chevron.left", width: 12, height: 20, color: blue, weight: 600)
        let backLabel = text("Back Title", "Back", color: blue)
        let back = group("Back", [
            .size: size(84, 28), .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .spacing: .number(4),
        ], [chevron, backLabel])
        let inline = text("Inline Title", "Title", weight: SystemStyle.headline.weight, [
            .widthMode: .text("Grow"), .textAlignment: .text("Center"), .opacity: .number(0),
        ])
        let balance = group("Balance", [.size: size(84, 28)])
        let row = group("Row", [
            .size: size(402, SystemStyle.barHeight), .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
            .paddingHorizontal: .number(8), .paddingVertical: .number(8),
        ], [back, inline, balance])
        let large = text("Large Title", "Title", size: SystemStyle.largeTitle.size, weight: SystemStyle.largeTitle.weight, [
            .position: .point(Point2(x: SystemStyle.margin, y: titleTop)),
        ])
        // The large title has the room under the row to itself, and leaves by sliding up
        // out of it: it is never seen in the row.
        let titleArea = group("Title Area", [
            .position: .point(Point2(x: 0, y: SystemStyle.barHeight)), .size: size(402, travel), .clips: .bool(true),
        ], [large])
        // Nothing is drawn behind a large title. The material comes in as the title goes
        // into the row, when there is content under the bar to soften.
        let material = Layer(name: "Material", kind: .view, properties: [
            .size: size(402, full), .fill: .color(bar), .backgroundBlur: .number(SystemStyle.barBlur), .opacity: .number(0),
        ])
        let background = group("Background", [.size: size(402, full), .clips: .bool(true)], [material, titleArea, row])
        let root = group("Large Title Bar", [.size: size(402, full)], [background])

        return make(
            "Large Title Bar", "A navigation bar with a large title. Cable a scroll view's Offset into Scroll Offset (it goes below zero as the content moves up): the bar shrinks as the content scrolls and the title moves into the bar.",
            root: root, placement: .top
        ) { b in
            let titleText = b.input("Title", .text, .text("Title"), at: at(0, 0))
            let offset = b.input("Scroll Offset", .number, .number(0), at: at(0, 1))
            let backText = b.input("Back Title", .text, .text("Back"), at: at(0, 5))
            let showsBack = b.input("Shows Back", .bool, .bool(false), at: at(0, 6))
            let tint = b.input("Tint", .color, .color(blue), at: at(0, 7))
            let touch = b.interaction(on: back.id, at: at(0, 8))
            let measured = b.bound("layerSize", to: root.id, at: at(0, 2.4))
            let collapse = b.add("clamp", at: at(1, 1), name: "Collapse", inputs: ["min": .number(0), "max": .number(travel)])
            let height = b.add("subtract", at: at(2, 1), name: "Height", inputs: ["a": .number(full)])
            let frame = b.add("makePoint", at: at(3, 1), name: "Bar Size")
            let rowFrame = b.add("makePoint", at: at(3, 2.4), name: "Row Size", inputs: ["y": .number(SystemStyle.barHeight)])
            let titleY = b.add("subtract", at: at(2, 3.4), name: "Title Y", inputs: ["a": .number(titleTop)])
            let areaHeight = b.add("subtract", at: at(2, 11.4), name: "Title Room", inputs: ["a": .number(travel)])
            let areaSize = b.add("makePoint", at: at(3, 11.4), name: "Title Area Size")
            let titlePlace = b.add("makePoint", at: at(3, 3.4), name: "Title Place", inputs: ["x": .number(SystemStyle.margin)])
            // The title in the bar comes in over the last part of the way.
            let arrival = b.add("progress", at: at(2, 4.4), name: "Arrival", inputs: ["start": .number(travel - 16), "end": .number(travel)])
            let shown = b.add("clamp", at: at(3, 4.4), inputs: ["min": .number(0), "max": .number(1)])
            // A scroll view's offset goes below zero as its content moves up.
            let scrolled = b.add("multiply", at: at(1, 0), name: "Scrolled", inputs: ["b": .number(-1)])
            b.connect(offset, "value", to: scrolled, "a")
            b.connect(scrolled, "result", to: collapse, "value")
            b.connect(collapse, "result", to: height, "b")
            b.connect(measured, "width", to: frame, "x")
            b.connect(height, "result", to: frame, "y")
            b.connect(measured, "width", to: rowFrame, "x")
            b.connect(collapse, "result", to: titleY, "b")
            b.connect(collapse, "result", to: areaHeight, "b")
            b.connect(measured, "width", to: areaSize, "x")
            b.connect(areaHeight, "result", to: areaSize, "y")
            b.connect(areaSize, "point", to: b.property(.size, of: titleArea.id, at: at(4, 11.4)), "value")
            b.connect(titleY, "result", to: titlePlace, "y")
            b.connect(collapse, "result", to: arrival, "value")
            b.connect(arrival, "progress", to: shown, "value")
            b.connect(frame, "point", to: b.property(.size, of: background.id, at: at(4, 1)), "value")
            b.connect(frame, "point", to: b.property(.size, of: material.id, at: at(4, 0)), "value")
            b.connect(shown, "result", to: b.property(.opacity, of: material.id, at: at(4, 0)), "value")
            b.connect(rowFrame, "point", to: b.property(.size, of: row.id, at: at(4, 2.4)), "value")
            b.connect(titlePlace, "point", to: b.property(.position, of: large.id, at: at(4, 3.4)), "value")
            b.connect(shown, "result", to: b.property(.opacity, of: inline.id, at: at(4, 4.4)), "value")
            b.connect(titleText, "value", to: b.property(.text, of: large.id, at: at(4, 3.4)), "value")
            b.connect(titleText, "value", to: b.property(.text, of: inline.id, at: at(4, 4.4)), "value")
            b.connect(backText, "value", to: b.property(.text, of: backLabel.id, at: at(4, 5)), "value")
            b.connect(showsBack, "value", to: b.property(.opacity, of: back.id, at: at(4, 6)), "value")
            b.connect(showsBack, "value", to: b.property(.enabled, of: back.id, at: at(4, 6)), "value")
            b.connect(tint, "value", to: b.property(.fill, of: chevron.id, at: at(4, 7)), "value")
            b.connect(tint, "value", to: b.property(.textColor, of: backLabel.id, at: at(4, 5)), "value")
            b.connect(touch, "tap", to: b.output("Back", .pulse, at: at(4, 8)), "value")
            b.connect(height, "result", to: b.output("Height", .number, at: at(4, 9)), "value")
            var look = Look(&b, row: 10)
            look.paint(&b, SystemStyle.bar, "Bar Color", .fill, of: material)
            look.paint(&b, SystemStyle.label, "Title Color", .textColor, of: large, inline)
        }
    }()

    // MARK: Tab Bar

    static let tabBar: ComponentDefinition = {
        // Measured on the real one (iOS 26, 402 points wide): a capsule 62 high that ends 21
        // above the bottom of the screen and is as wide as its tabs, 86 points each with 8
        // at either end; the chosen tab on a pill 94 by 54; symbols about 23 high with their
        // middle 24 from the top, and 10-point titles under them.
        let icon = symbol("Icon", "house.fill", width: 34, height: 28, color: .black)
        let label = text("Label", "Tab", size: 10, weight: 500, color: .black)
        let pill = Layer(name: "Pill", kind: .view, properties: [
            .position: .point(Point2(x: -4, y: 4)), .size: size(94, 54), .cornerRadius: .number(27),
            .fill: .color(ColorValue(white: 0.5, alpha: 0)), .absolute: .bool(true),
        ])
        let tab = group("Tab", [
            .size: size(86, 62), .heightMode: .text("Grow"), .layout: .text("Stack"), .alignment: .text("Center"),
            .paddingHorizontal: .number(0), .paddingVertical: .number(0), .paddingTop: .number(10), .spacing: .number(1),
        ], [pill, icon, label])
        // The bar itself is a view inside the root, so it can be as wide as its tabs and float.
        // It is glass: its rim bends what is behind it and catches the light. With Floating
        // off it is a flat bar from edge to edge that only softens and tints what is under it.
        // The chosen tab's pill is one view that slides from tab to tab (`Sliding`).
        let selection = Layer(name: "Selection", kind: .view, properties: [
            .size: size(94, 54), .cornerRadius: .number(27), .fill: .color(ColorValue(white: 0.5, alpha: 0)), .absolute: .bool(true),
        ])
        let background = glass("Background", [
            .size: size(274, 62), .widthMode: .text("Auto"), .layout: .text("Stack"), .axis: .text("Horizontal"),
            .paddingHorizontal: .number(8), .paddingVertical: .number(0),
            // A hairline round it and a faint shadow, as the real one has.
            .strokeColor: .color(ColorValue(white: 0, alpha: 0.12)), .strokeWidth: .number(0.5),
            .shadowColor: .color(ColorValue(white: 0, alpha: 0.06)), .shadowRadius: .number(18), .shadowOffset: .point(Point2(x: 0, y: 6)),
        ], radius: 31, inputs: ["tint": .color(SystemStyle.glassTint.light)], [selection, tab])
        let root = group("Tab Bar", [
            .size: size(402, 83), .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Start"), .distribution: .text("Center"),
        ], [background])

        return make("Tab Bar", "Tabs with a symbol and a title each; tapping one selects it. Give it comma-separated titles and symbol names. It is a capsule of glass as wide as its tabs, floating above the bottom of the screen, as on iOS 26; with Floating off it is a flat bar from edge to edge.", root: root, placement: .bottom, shippedViews: 4) { b in
            let titles = b.input("Titles", .text, .text("Home, Search, Profile"), at: at(0, 0))
            let symbols = b.input("Symbols", .text, .text("house.fill, magnifyingglass, person.fill"), at: at(0, 1))
            let initial = b.input("Selected", .number, .number(0), at: at(0, 3.4))
            let tint = b.input("Tint", .color, .color(blue), at: at(0, 4.6))
            let splitTitles = b.add("splitText", at: at(1, 0))
            let splitSymbols = b.add("splitText", at: at(1, 1))
            let eachTitle = b.add("loopOverArray", at: at(2, 0), type: .text)
            let eachSymbol = b.add("loopOverArray", at: at(2, 1), type: .text)
            // Driving a property of the Tab group with the loop is what repeats the tab.
            let everyTab = b.add("greaterEqual", at: at(3, 1.8), name: "Every Tab")
            let touch = b.interaction(on: tab.id, at: at(0, 2.2))
            let chosen = b.add("loopOptionSwitch", at: at(2, 2.8), name: "Selected Tab")
            let isSelected = b.add("equal", at: at(3, 2.8), name: "Is Selected")
            let color = b.add("transition", at: at(4, 2.8), name: "Tab Color", type: .color, inputs: ["start": .color(.black)])
            b.connect(titles, "value", to: splitTitles, "text")
            b.connect(symbols, "value", to: splitSymbols, "text")
            b.connect(splitTitles, "array", to: eachTitle, "array")
            b.connect(splitSymbols, "array", to: eachSymbol, "array")
            b.connect(eachTitle, "value", to: b.property(.text, of: label.id, at: at(5, 0)), "value")
            b.connect(eachSymbol, "value", to: b.property(.symbol, of: icon.id, at: at(5, 0.8)), "value")
            b.connect(eachTitle, "index", to: everyTab, "a")
            b.connect(everyTab, "result", to: b.property(.enabled, of: tab.id, at: at(5, 1.6)), "value")
            b.connect(touch, "tap", to: chosen, "set")
            b.connect(initial, "value", to: chosen, "start")
            b.connect(eachTitle, "index", to: isSelected, "a")
            b.connect(chosen, "option", to: isSelected, "b")
            b.connect(tint, "value", to: color, "end")
            b.connect(color, "value", to: b.property(.fill, of: icon.id, at: at(5, 2.4)), "value")
            b.connect(color, "value", to: b.property(.textColor, of: label.id, at: at(5, 3.2)), "value")
            b.connect(chosen, "option", to: b.output("Selected", .number, at: at(5, 4)), "value")
            b.connect(chosen, "changed", to: b.output("Changed", .pulse, at: at(5, 4.8)), "value")
            var look = Look(&b, row: 5.8)
            let barColor = look.color(&b, SystemStyle.bar, "Bar Color")
            let floating = b.input("Floating", .bool, .bool(true), at: at(0, 9))
            // A tab that is not chosen is the color of text when the bar floats, gray when it is flat.
            let quiet = b.add("if", at: at(3, 6.8), name: "Unselected Color", type: .color)
            b.connect(floating, "value", to: quiet, "condition")
            b.connect(look.color(&b, SystemStyle.label, "Text Color"), "value", to: quiet, "then")
            b.connect(look.color(&b, SystemStyle.secondaryLabel, "Gray"), "value", to: quiet, "else")
            b.connect(quiet, "value", to: color, "start")
            // Floating or flat: the capsule's corners, shadow and room, and whether the bar
            // and its tabs take their own width or all there is.
            for (index, change) in [
                ("Roundness", LayerProperty.cornerRadius, background, 31.0), ("Shadow", .shadowRadius, background, 18), ("Room", .paddingHorizontal, background, 8),
            ].enumerated() {
                let choice = b.add("if", at: at(1, 9 + Double(index)), name: change.0, type: .number, inputs: ["then": .number(change.3), "else": .number(0)])
                b.connect(floating, "value", to: choice, "condition")
                b.connect(choice, "value", to: b.property(change.1, of: change.2.id, at: at(2, 9 + Double(index))), "value")
            }
            for (index, change) in [
                ("Bar Width", LayerProperty.widthMode, background, "Auto"), ("Bar Height", .heightMode, background, "Fixed"), ("Tab Width", .widthMode, tab, "Fixed"),
            ].enumerated() {
                let choice = b.add("if", at: at(1, 12 + Double(index)), name: change.0, type: .text, inputs: ["then": .text(change.3), "else": .text("Grow")])
                b.connect(floating, "value", to: choice, "condition")
                b.connect(choice, "value", to: b.property(change.1, of: change.2.id, at: at(2, 12 + Double(index))), "value")
            }
            let onPill = b.add("and", at: at(4, 9), name: "On the Pill")
            let pillColor = b.add("transition", at: at(5, 9), name: "Pill Color", type: .color, inputs: ["start": .color(ColorValue(white: 0.5, alpha: 0))])
            b.connect(isSelected, "result", to: onPill, "a")
            b.connect(floating, "value", to: onPill, "b")
            b.connect(onPill, "result", to: pillColor, "progress")
            let pillTint = look.color(&b, SystemStyle.tabPill, "Pill")
            b.connect(pillTint, "value", to: pillColor, "end")
            // The glass: its corners follow the bar's, and floating gives it a lens for a
            // rim, light on its edge, and a tint that is mostly clear.
            let pane = b.view(background.id)
            for (index, change) in [("Glass Radius", "radius", 31.0, 0.0), ("Refraction", "refraction", SystemStyle.glassRefraction, 0), ("Shine", "shine", SystemStyle.glassShine, 0)].enumerated() {
                let choice = b.add("if", at: at(1, 16 + Double(index)), name: change.0, type: .number, inputs: ["then": .number(change.2), "else": .number(change.3)])
                b.connect(floating, "value", to: choice, "condition")
                b.connect(choice, "value", to: pane, ShaderUse.portID(change.1))
            }
            let glassTint = b.add("if", at: at(2, 19), name: "Glass Tint", type: .color)
            b.connect(floating, "value", to: glassTint, "condition")
            b.connect(look.color(&b, SystemStyle.glassTint, "Clear Tint"), "value", to: glassTint, "then")
            b.connect(barColor, "value", to: glassTint, "else")
            b.connect(glassTint, "value", to: pane, ShaderUse.portID("tint"))
            // Measured on iOS 26 (`motion-tab-bar`): the pill slides, stretching toward the new
            // tab, and each tab takes the tint as the pill comes over it. (Each tab's own Pill,
            // and the Pill Color above, are no longer shown; they are kept so the ids stay
            // where they were.)
            let sliding = Sliding(&b, repeated: tab.id, pill: selection.id, chosen: chosen, outset: (4, -4, 4, -4),
                                  quick: 0.18, slow: 0.28, damping: 0.9, column: 7, row: 0)
            b.connect(sliding.coverage, "result", to: color, "progress")
            let shownPill = b.add("if", at: at(6, 10), name: "Shown Pill", type: .color, inputs: ["else": .color(ColorValue(white: 0.5, alpha: 0))])
            b.connect(floating, "value", to: shownPill, "condition")
            b.connect(pillTint, "value", to: shownPill, "then")
            b.connect(shownPill, "value", to: b.property(.fill, of: selection.id, at: at(7, 10)), "value")
        }
    }()

    // MARK: Toolbar

    static let toolbar: ComponentDefinition = {
        // Measured on the real one (iOS 26): no bar is drawn. Each button is a circle of
        // glass 48 across with its symbol the color of text, the first and last 28 from
        // the sides, ending 28 above the bottom of the screen.
        let glyph = symbol("Glyph", "square.and.arrow.up", width: 28, height: 28, color: .black, weight: 500)
        let item = glassButton("Item", glyph, extra: [.size: size(48, 48)])
        let root = group("Toolbar", [
            .size: size(402, 76), .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Start"),
            .distribution: .text("Space Between"), .paddingHorizontal: .number(28), .paddingVertical: .number(0),
        ], [item])

        return make("Toolbar", "Round glass buttons with a symbol each along the bottom of the screen, as on iOS 26. Give it comma-separated symbol names; it says which one was tapped.", root: root, placement: .bottom) { b in
            let symbols = b.input("Symbols", .text, .text("square.and.arrow.up, heart, trash"), at: at(0, 0))
            let split = b.add("splitText", at: at(1, 0))
            let each = b.add("loopOverArray", at: at(2, 0), type: .text)
            let everyItem = b.add("greaterEqual", at: at(3, 1), name: "Every Item")
            let touch = b.interaction(on: item.id, at: at(0, 1.2))
            let chosen = b.add("loopOptionSwitch", at: at(2, 2.4), name: "Tapped Item", inputs: ["start": .number(-1)])
            let dim = b.add("transition", at: at(2, 3.6), name: "Dim", type: .number, inputs: ["start": .number(1), "end": .number(0.4)])
            b.connect(symbols, "value", to: split, "text")
            b.connect(split, "array", to: each, "array")
            b.connect(each, "value", to: b.property(.symbol, of: glyph.id, at: at(4, 0)), "value")
            b.connect(each, "index", to: everyItem, "a")
            b.connect(everyItem, "result", to: b.property(.enabled, of: item.id, at: at(4, 1)), "value")
            b.connect(touch, "tap", to: chosen, "set")
            b.connect(touch, "down", to: dim, "progress")
            b.connect(dim, "value", to: b.property(.opacity, of: glyph.id, at: at(4, 0)), "value")
            b.connect(chosen, "option", to: b.output("Tapped", .number, at: at(4, 2.4)), "value")
            b.connect(chosen, "picked", to: b.output("Tap", .pulse, at: at(4, 3.4)), "value")
            var look = Look(&b, row: 4.8)
            look.paint(&b, SystemStyle.label, "Glyph Color", .fill, of: glyph)
            b.connect(look.color(&b, SystemStyle.glassTint, "Glass Tint"), "value", to: b.view(item.id), ShaderUse.portID("tint"))
        }
    }()

    // MARK: Status Bar

    static let statusBar: ComponentDefinition = {
        let time = text("Time", "9:41", weight: SystemStyle.headline.weight, [.widthMode: .text("Grow")])
        let signal = symbol("Signal", "cellularbars", width: 24, height: 17, color: .black, weight: 500)
        let wifi = symbol("Wi-Fi", "wifi", width: 20, height: 18, color: .black, weight: 600)
        let battery = symbol("Battery", "battery.100percent", width: 32, height: 20, color: .black, weight: 400)
        let root = group("Status Bar", [
            .size: size(402, SystemStyle.statusBarHeight), .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
            // The time stands further in than the battery, and both a little above the middle.
            // Placed against the simulator's own status bar (Reference/run.sh).
            .paddingHorizontal: .number(33), .paddingLeft: .number(55.7), .paddingVertical: .number(0), .paddingTop: .number(2), .spacing: .number(3.3),
        ], [time, signal, wifi, battery])

        return make("Status Bar", "The time, signal, Wi-Fi and battery along the top of the screen.", root: root, placement: .top) { b in
            let clock = b.input("Time", .text, .text("9:41"), at: at(0, 0))
            b.connect(clock, "value", to: b.property(.text, of: time.id, at: at(2, 0)), "value")
            var look = Look(&b, row: 1.2)
            look.paint(&b, SystemStyle.label, "Time Color", .textColor, of: time)
            look.paint(&b, SystemStyle.label, "Symbol Color", .fill, of: signal, wifi, battery)
        }
    }()

    // MARK: Home Indicator

    static let homeIndicator: ComponentDefinition = {
        let line = Layer(name: "Bar", kind: .view, properties: [.size: size(144, 5), .cornerRadius: .number(2.5), .fill: .color(.black)])
        let root = group("Home Indicator", [
            .size: size(402, 34), .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("End"),
            .distribution: .text("Center"), .paddingHorizontal: .number(0), .paddingVertical: .number(0), .paddingBottom: .number(8),
        ], [line])

        return make("Home Indicator", "The bar at the bottom of the screen that a swipe up starts from. It lies over whatever is there, a tab bar included.", root: root, placement: .bottomOverlay) { b in
            var look = Look(&b, row: 0)
            look.paint(&b, SystemStyle.label, "Bar Color", .fill, of: line)
        }
    }()
}
