import Foundation
import PaperModel

extension ComponentLibrary {
    // MARK: List Row

    static let listRow: ComponentDefinition = {
        let glyph = symbol("Glyph", "wifi", width: 20, height: 20, color: .white, weight: 600)
        let tile = group("Tile", [
            .size: size(SystemStyle.tileSize, SystemStyle.tileSize), .fill: .color(blue), .cornerRadius: .number(7), .layout: .text("Stack"), .axis: .text("Horizontal"),
            .alignment: .text("Center"), .distribution: .text("Center"),
        ], [glyph])
        // The tile with the room after it that brings the text to where it starts.
        let symbolBox = group("Symbol", [
            .size: size(SystemStyle.tileTextInset - SystemStyle.tileInset - SystemStyle.rowSpacing, SystemStyle.tileSize), .visible: .bool(false),
        ], [tile])
        let title = text("Title", "Title", [.widthMode: .text("Grow")])
        let subtitle = text("Subtitle", "", size: SystemStyle.footnote.size, color: secondaryLabel, [.widthMode: .text("Grow"), .visible: .bool(false)])
        let texts = group("Texts", [
            .widthMode: .text("Grow"), .heightMode: .text("Auto"), .layout: .text("Stack"), .axis: .text("Vertical"), .spacing: .number(2),
        ], [title, subtitle])
        let detail = text("Detail", "", color: secondaryLabel)
        let chevron = symbol("Chevron", "chevron.right", width: 11.5, height: 17, color: tertiaryLabel, weight: 700)
        let check = symbol("Checkmark", "checkmark", width: 16, height: 16, color: blue, weight: 600, [.visible: .bool(false)])
        let track = Layer(name: "Track", kind: .view, properties: [
            .size: .size(SystemStyle.switchSize), .cornerRadius: .number(SystemStyle.switchSize.height / 2), .fill: .color(SystemStyle.switchOff.light),
        ])
        let knob = switchKnob()
        let toggle = group("Switch", [.size: .size(SystemStyle.switchSize), .visible: .bool(false)], [track, knob])
        // The line under the row stands apart from what the row arranges.
        let separator = Layer(name: "Separator", kind: .view, properties: [
            .position: .point(Point2(x: SystemStyle.rowInset, y: SystemStyle.rowHeight - 1)), .size: size(330, 1), .fill: .color(SystemStyle.listSeparator.light),
            .absolute: .bool(true), .visible: .bool(false),
        ])
        let root = group("List Row", [
            .size: size(370, SystemStyle.rowHeight), .fill: .color(.white), .layout: .text("Stack"), .axis: .text("Horizontal"),
            .alignment: .text("Center"), .paddingHorizontal: .number(SystemStyle.rowInset), .paddingVertical: .number(0),
            .spacing: .number(SystemStyle.rowSpacing),
        ], [symbolBox, texts, detail, chevron, check, toggle, separator])

        return make(
            "List Row", "A table row: a title, with an optional symbol, subtitle and detail, and a chevron, checkmark or switch at the end. It highlights while pressed and reports taps.",
            root: root, shippedViews: 4
        ) { b in
            let titleText = b.input("Title", .text, .text("Title"), at: at(0, 0))
            let detailText = b.input("Detail", .text, .text(""), at: at(0, 1))
            let showsChevron = b.input("Shows Chevron", .bool, .bool(true), at: at(0, 2))
            let touch = b.interaction(on: root.id, at: at(0, 3.2))
            let highlight = b.add("transition", at: at(1, 3.2), name: "Highlight", type: .color, inputs: [
                "start": .color(.white), "end": .color(pressed),
            ])
            b.connect(titleText, "value", to: b.property(.text, of: title.id, at: at(2, 0)), "value")
            b.connect(detailText, "value", to: b.property(.text, of: detail.id, at: at(2, 0.8)), "value")
            b.connect(touch, "down", to: highlight, "progress")
            b.connect(highlight, "value", to: b.property(.fill, of: root.id, at: at(2, 3.2)), "value")
            b.connect(touch, "tap", to: b.output("Tap", .pulse, at: at(2, 4.2)), "value")
            var look = Look(&b, row: 5.4)
            look.paint(&b, SystemStyle.label, "Title Color", .textColor, of: title)
            look.paint(&b, SystemStyle.secondaryLabel, "Detail Color", .textColor, of: detail, subtitle)
            look.paint(&b, SystemStyle.tertiaryLabel, "Chevron Color", .fill, of: chevron)
            b.connect(look.color(&b, SystemStyle.surface, "Row Color"), "value", to: highlight, "start")
            b.connect(look.color(&b, SystemStyle.pressed, "Pressed Color"), "value", to: highlight, "end")

            // Everything below came after the row first shipped, so it is added after the rest.
            /// On when a text input has something in it.
            func filled(_ input: NodeID, _ name: String, _ row: Double) -> NodeID {
                let length = b.add("textLength", at: at(1, row))
                let has = b.add("not", at: at(2, row), name: name)
                b.connect(input, "value", to: length, "text")
                b.connect(length, "empty", to: has, "value")
                return has
            }
            let subtitleText = b.input("Subtitle", .text, .text(""), at: at(0, 12))
            b.connect(subtitleText, "value", to: b.property(.text, of: subtitle.id, at: at(3, 12)), "value")
            b.connect(filled(subtitleText, "Has Subtitle", 12), "result", to: b.property(.visible, of: subtitle.id, at: at(3, 12)), "value")

            let symbolName = b.input("Symbol", .text, .text(""), at: at(0, 13))
            let symbolColor = b.input("Symbol Color", .color, .color(blue), at: at(0, 14))
            b.connect(symbolName, "value", to: b.property(.symbol, of: glyph.id, at: at(3, 13)), "value")
            b.connect(filled(symbolName, "Has Symbol", 13), "result", to: b.property(.visible, of: symbolBox.id, at: at(3, 13.8)), "value")
            b.connect(symbolColor, "value", to: b.property(.fill, of: tile.id, at: at(3, 13.8)), "value")

            // What stands at the end of the row.
            let accessory = b.input("Accessory", .text, .text("Chevron"), at: at(0, 15), options: ["Chevron", "None", "Checkmark", "Switch"])
            func isAccessory(_ name: String, _ row: Double) -> NodeID {
                let match = b.add("textContains", at: at(1, row), name: "Is \(name)", inputs: ["search": .text(name)])
                b.connect(accessory, "value", to: match, "text")
                return match
            }
            let isChevron = isAccessory("Chevron", 15), isCheck = isAccessory("Checkmark", 16), isSwitch = isAccessory("Switch", 17)
            let chevronShows = b.add("and", at: at(2, 15), name: "Chevron Shows")
            b.connect(isChevron, "result", to: chevronShows, "a")
            b.connect(showsChevron, "value", to: chevronShows, "b")
            b.connect(chevronShows, "result", to: b.property(.visible, of: chevron.id, at: at(3, 15)), "value")
            b.connect(isCheck, "result", to: b.property(.visible, of: check.id, at: at(3, 16)), "value")
            b.connect(isSwitch, "result", to: b.property(.visible, of: toggle.id, at: at(3, 17)), "value")

            // The switch, as the Toggle is built.
            let startsOn = b.input("On", .bool, .bool(false), at: at(0, 18))
            let tint = b.input("Tint", .color, .color(green), at: at(0, 19))
            let flick = b.interaction(on: toggle.id, at: at(0, 20))
            let flipped = b.add("switch", at: at(1, 20), name: "Flipped")
            let isOn = b.add("notEqual", at: at(2, 18), name: "Is On")
            let spring = b.add("spring", at: at(3, 18), inputs: ["response": .number(0.3), "damping": .number(0.8)])
            let slide = b.add("transition", at: at(4, 18), name: "Knob Position", type: .point, inputs: [
                "start": .point(Point2(x: 2, y: 2)), "end": .point(Point2(x: switchTravel, y: 2)),
            ])
            let trackColor = b.add("transition", at: at(4, 19), name: "Track Color", type: .color)
            b.connect(flick, "tap", to: flipped, "flip")
            b.connect(flipped, "on", to: isOn, "a")
            b.connect(startsOn, "value", to: isOn, "b")
            b.connect(isOn, "result", to: spring, "target")
            b.connect(spring, "value", to: slide, "progress")
            b.connect(spring, "value", to: trackColor, "progress")
            b.connect(look.color(&b, SystemStyle.switchOff, "Off Color"), "value", to: trackColor, "start")
            b.connect(tint, "value", to: trackColor, "end")
            b.connect(tint, "value", to: b.property(.fill, of: check.id, at: at(5, 16)), "value")
            b.connect(slide, "value", to: b.property(.position, of: knob.id, at: at(5, 18)), "value")
            b.connect(trackColor, "value", to: b.property(.fill, of: track.id, at: at(5, 19)), "value")
            b.connect(isOn, "result", to: b.output("On", .bool, at: at(5, 20)), "value")
            b.connect(flick, "tap", to: b.output("Changed", .pulse, at: at(5, 21)), "value")

            // The line under the row, from the text to the trailing edge.
            let showsSeparator = b.input("Separator", .bool, .bool(false), at: at(0, 22))
            let measured = b.bound("layerSize", to: root.id, at: at(0, 23))
            let lineWidth = b.add("subtract", at: at(1, 23), name: "Line Width")
            let lineSize = b.add("makePoint", at: at(2, 23), inputs: ["y": .number(1)])
            let lineY = b.add("subtract", at: at(1, 24), name: "Line Y", inputs: ["b": .number(1)])
            let linePlace = b.add("makePoint", at: at(2, 24))
            b.connect(measured, "width", to: lineWidth, "a")
            b.connect(lineWidth, "result", to: lineSize, "x")
            b.connect(measured, "height", to: lineY, "a")
            b.connect(lineY, "result", to: linePlace, "y")
            b.connect(showsSeparator, "value", to: b.property(.visible, of: separator.id, at: at(3, 22)), "value")
            b.connect(lineSize, "point", to: b.property(.size, of: separator.id, at: at(3, 22)), "value")
            b.connect(linePlace, "point", to: b.property(.position, of: separator.id, at: at(3, 22)), "value")
            look.paint(&b, SystemStyle.listSeparator, "Separator Color", .fill, of: separator)

            // With a symbol, the tile stands a little further out than text would, and the
            // line starts where the text does; a switch stands a little nearer the edge.
            let hasSymbol = filled(symbolName, "Symbol Shows", 26)
            let textAt = SystemStyle.tileTextInset
            func either(_ name: String, _ condition: NodeID, _ then: Double, _ other: Double, _ row: Double) -> NodeID {
                let choice = b.add("if", at: at(3, row), name: name, type: .number, inputs: ["then": .number(then), "else": .number(other)])
                b.connect(condition, "result", to: choice, "condition")
                return choice
            }
            let leading = either("Leading Inset", hasSymbol, SystemStyle.tileInset, SystemStyle.rowInset, 26)
            let trailing = either("Trailing Inset", isSwitch, SystemStyle.switchTrailing, SystemStyle.rowTrailing, 27)
            let lineStart = either("Line Start", hasSymbol, textAt, SystemStyle.rowInset, 28)
            let lineInsets = b.add("add", at: at(4, 28), name: "Line Insets", inputs: ["b": .number(SystemStyle.rowInset)])
            b.connect(leading, "value", to: b.property(.paddingLeft, of: root.id, at: at(5, 26)), "value")
            b.connect(trailing, "value", to: b.property(.paddingRight, of: root.id, at: at(5, 26)), "value")
            b.connect(lineStart, "value", to: linePlace, "x")
            b.connect(lineStart, "value", to: lineInsets, "a")
            b.connect(lineInsets, "result", to: lineWidth, "b")
        }
    }()

    // MARK: Swipe Actions Row

    static let swipeActionsRow: ComponentDefinition = {
        let reveal = 88.0
        let actionLabel = text("Action Label", "Delete", color: .white, [.widthMode: .text("Grow"), .textAlignment: .text("Center")])
        let action = group("Action", [
            .position: .point(Point2(x: 370 - reveal, y: 0)), .size: size(reveal, SystemStyle.rowHeight), .fill: .color(SystemStyle.red.light),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
        ], [actionLabel])
        let title = text("Title", "Swipe me", [.widthMode: .text("Grow")])
        let content = group("Content", [
            .size: size(370, SystemStyle.rowHeight), .fill: .color(.white), .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
            .paddingHorizontal: .number(SystemStyle.rowInset), .paddingVertical: .number(0),
        ], [title])
        let root = group("Swipe Actions Row", [.size: size(370, SystemStyle.rowHeight), .clips: .bool(true)], [action, content])

        return make(
            "Swipe Actions Row", "A row that slides aside under a finger to show an action, such as Delete, and stays open when dragged far enough. It reports a tap on the action.",
            root: root
        ) { b in
            let titleText = b.input("Title", .text, .text("Swipe me"), at: at(0, 0))
            let actionText = b.input("Action", .text, .text("Delete"), at: at(0, 1))
            let actionColor = b.input("Action Color", .color, .color(SystemStyle.red.light), at: at(0, 2))
            let measured = b.bound("layerSize", to: root.id, at: at(0, 3))
            // Sideways only, so the row still scrolls with the list it is in.
            let drag = b.bound("pan", to: content.id, at: at(0, 4.4), inputs: ["direction": .text("Horizontal")])
            let press = b.interaction(on: action.id, at: at(0, 6.4))
            let dragX = b.add("splitPoint", at: at(1, 4.4), name: "Drag X")
            let edges = b.add("pulse", at: at(1, 5.6), name: "Drag Began / Ended")
            let spring = b.add("spring", at: at(3, 4.4), inputs: ["response": .number(0.32), "damping": .number(0.9)])
            let isPast = b.add("less", at: at(4, 5.6), name: "Past Half", inputs: ["b": .number(-reveal / 2)])
            let open = b.add("sampleHold", at: at(5, 5.6), name: "Open", type: .bool)
            let rest = b.add("if", at: at(2, 5.6), name: "Rest", type: .number, inputs: ["then": .number(-reveal), "else": .number(0)])
            let kept = b.add("clamp", at: at(4, 4.4), inputs: ["min": .number(-reveal - 40), "max": .number(0)])
            let place = b.add("makePoint", at: at(5, 4.4))
            let actionX = b.add("subtract", at: at(1, 3), name: "Action X", inputs: ["b": .number(reveal)])
            let actionPlace = b.add("makePoint", at: at(2, 3))
            let actionSize = b.add("makePoint", at: at(2, 2), inputs: ["x": .number(reveal)])
            let rowSize = b.add("makePoint", at: at(2, 1))
            b.connect(drag, "translation", to: dragX, "point")
            b.connect(drag, "panning", to: edges, "value")
            b.connect(drag, "panning", to: spring, "hold")
            b.connect(dragX, "x", to: spring, "held")
            b.connect(spring, "value", to: isPast, "a")
            b.connect(isPast, "result", to: open, "value")
            b.connect(edges, "turnedOff", to: open, "sample")
            b.connect(open, "value", to: rest, "condition")
            b.connect(rest, "value", to: spring, "target")
            b.connect(spring, "value", to: kept, "value")
            b.connect(kept, "result", to: place, "x")
            b.connect(place, "point", to: b.property(.position, of: content.id, at: at(6, 4.4)), "value")
            b.connect(measured, "width", to: actionX, "a")
            b.connect(actionX, "result", to: actionPlace, "x")
            b.connect(measured, "height", to: actionSize, "y")
            b.connect(measured, "width", to: rowSize, "x")
            b.connect(measured, "height", to: rowSize, "y")
            b.connect(actionPlace, "point", to: b.property(.position, of: action.id, at: at(6, 3)), "value")
            b.connect(actionSize, "point", to: b.property(.size, of: action.id, at: at(6, 3)), "value")
            b.connect(rowSize, "point", to: b.property(.size, of: content.id, at: at(6, 4.4)), "value")
            b.connect(titleText, "value", to: b.property(.text, of: title.id, at: at(6, 0)), "value")
            b.connect(actionText, "value", to: b.property(.text, of: actionLabel.id, at: at(6, 1)), "value")
            b.connect(actionColor, "value", to: b.property(.fill, of: action.id, at: at(6, 3)), "value")
            b.connect(press, "tap", to: b.output("Action", .pulse, at: at(6, 6.4)), "value")
            b.connect(open, "value", to: b.output("Open", .bool, at: at(6, 7.4)), "value")
            var look = Look(&b, row: 8.4)
            look.paint(&b, SystemStyle.surface, "Row Color", .fill, of: content)
            look.paint(&b, SystemStyle.label, "Title Color", .textColor, of: title)
        }
    }()

    // MARK: List Section

    /// The views of an inset grouped section, as in Settings: a header, rows on a rounded
    /// surface, a footer.
    struct Section {
        let root: Layer
        let rows: Layer
        let captions: [(name: String, row: Layer, text: Layer)]

        /// A caption that is given no words is there and hidden, to be shown later.
        init(name: String = "List Section", header: String = "Section", footer: String = "", grows: Bool = false) {
            func caption(_ name: String, _ string: String, height: Double?) -> (name: String, row: Layer, text: Layer) {
                // As wide as it will be, so it is measured on the lines it will have.
                let label = ComponentLibrary.text(name, string.isEmpty ? name : string, size: SystemStyle.footnote.size, color: secondaryLabel, [
                    .size: size(330, 16), .widthMode: .text("Grow"), .singleLine: .bool(false),
                ])
                var properties: [LayerProperty: Value] = [
                    .widthMode: .text("Grow"), .heightMode: .text("Auto"), .layout: .text("Stack"), .axis: .text("Horizontal"),
                    .paddingHorizontal: .number(SystemStyle.rowInset), .paddingVertical: .number(0), .visible: .bool(!string.isEmpty),
                ]
                // The footer takes less room than its words: the space after a section is
                // 35 points with no footer and 46 with one line of it, and this is how a
                // footer that is only shown or hidden gets both right.
                if let height {
                    properties[.heightMode] = .text("Fixed")
                    properties[.size] = size(370, height)
                }
                return (name, group("\(name) Row", properties, [label]), label)
            }
            captions = [caption("Header", header, height: nil), caption("Footer", footer, height: 5)]
            rows = group("Rows", [
                .widthMode: .text("Grow"), .heightMode: .text("Auto"), .layout: .text("Stack"), .axis: .text("Vertical"),
                .fill: .color(.white), .cornerRadius: .number(SystemStyle.groupRadius), .clips: .bool(true),
            ])
            var properties: [LayerProperty: Value] = [
                .size: size(370, 150), .heightMode: .text("Auto"), .layout: .text("Stack"), .axis: .text("Vertical"), .spacing: .number(7),
            ]
            if grows { properties[.widthMode] = .text("Grow") }
            root = group(name, properties, [captions[0].row, rows, captions[1].row])
        }

        /// The rows it starts with, each by its inputs, and what the section publishes: the
        /// words of its header and footer and whether each shows, and Dark, which turns its
        /// surface. Returns the rows.
        @discardableResult
        func wire(
            _ b: inout Builder, column: Double = 0, row: Double = 0,
            rows starting: [[String: Value]] = [["Title": .text("First")], ["Title": .text("Second")]], patchesAt: ((Int) -> Point2?)? = nil
        ) -> [(layer: LayerID, node: NodeID?)] {
            let placed = starting.enumerated().map { index, inputs in
                var inputs = inputs
                // Every row but the last has a line under it.
                if inputs["Separator"] == nil { inputs["Separator"] = .bool(index < starting.count - 1) }
                let title = inputs["Title"]?.textValue ?? "Row"
                // A row with a second line is taller.
                let height = (inputs["Subtitle"]?.textValue ?? "").isEmpty ? SystemStyle.rowHeight : 64
                return b.place(
                    listRow, name: "\(title) Row", in: rows.id, inputs: inputs,
                    properties: [.widthMode: .text("Grow"), .size: size(370, height)], patchAt: patchesAt.flatMap { $0(index) }
                )
            }
            // The words are the text views' own, so the Canvas shows them as the Viewer does.
            for caption in captions {
                b.publish(caption.name, PortRef(node: b.view(caption.text.id), port: LayerProperty.text.rawValue), on: caption.row.id, output: false, type: .text)
                let outer = b.document.graph.viewNode(layer: caption.row.id)!
                b.publish(caption.name, PortRef(node: outer.id, port: outer.published!.last!.id), on: root.id, output: false, type: .text)
                b.publish("Shows \(caption.name)", PortRef(node: outer.id, port: LayerProperty.visible.rawValue), on: root.id, output: false, type: .bool)
            }
            let dark = b.add("value", at: at(column, row), name: "Dark", type: .bool, inputs: ["value": .bool(false)])
            let surface = b.add("if", at: at(column + 1, row), name: "Surface", type: .color, inputs: [
                "then": .color(SystemStyle.surface.dark), "else": .color(SystemStyle.surface.light),
            ])
            b.connect(dark, "value", to: surface, "condition")
            b.connect(surface, "value", to: b.property(.fill, of: rows.id, at: at(column + 2, row)), "value")
            b.publish("Dark", PortRef(node: dark, port: "value"), on: root.id, output: false, type: .bool)
            return placed
        }
    }

    static let listSection: ViewTemplate = {
        let section = Section()
        return template(
            "List Section", "An inset grouped section, as in Settings: rows on a rounded surface, with a header over them and a footer under them that each show when Shows Header and Shows Footer are on. Put List Rows in Rows.",
            root: section.root, content: "Rows"
        ) { b in section.wire(&b) }
    }()

    // MARK: Form

    /// A screen of grouped sections that scrolls, as Settings is.
    static let form: ViewTemplate = {
        let section = Section(name: "Section", grows: true)
        let root = group("Form", [
            .size: size(402, 640), .fill: .color(SystemStyle.groupedBackground.light), .clips: .bool(true),
            .layout: .text("Stack"), .axis: .text("Vertical"), .scrolls: .bool(true), .spacing: .number(SystemStyle.sectionGap),
            .paddingHorizontal: .number(SystemStyle.margin), .paddingVertical: .number(SystemStyle.margin),
        ], [section.root])
        return template(
            "Form", "A scrolling screen of grouped sections on the gray of Settings. It is a scroll view: its patch reports Offset, which a Large Title Bar takes. Add List Sections to it.",
            root: root, content: "Form"
        ) { b in section.wire(&b) }
    }()
}
