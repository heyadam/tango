import Foundation
import PaperModel

// Smaller prototypes that each show one reusable solution (spec 7.11): typing, swipe
// menus, pinching, hovering and a collapsing header. Built in code like the examples.

extension SampleDocuments.Builder {
    /// Adds a patch that attaches to a layer, such as Text Input, Swipe, Pinch or Scroll.
    @discardableResult
    public mutating func attach(
        _ kind: String, to layer: LayerID, at position: Point2, inputs: [String: Value] = [:]
    ) -> NodeID {
        document.graph.add(PatchNode(kind: kind, position: PatchGrid.snap(position), inputs: inputs, layerID: layer))
    }
}

extension SampleDocuments {
    private static func label(
        _ name: String, _ string: String, at point: Point2, size: Double = 17, weight: Double = 400,
        color: ColorValue = .black
    ) -> Layer {
        Layer(name: name, kind: .text, properties: [
            .position: .point(point), .text: .text(string), .fontSize: .number(size), .fontWeight: .number(weight),
            .textColor: .color(color), .widthMode: .text("Auto"), .heightMode: .text("Auto"),
        ])
    }

    public struct SignIn {
        public let document: Document
        public let field: LayerID
        public let greeting: LayerID
        public let button: LayerID
        public let input: NodeID
    }

    /// Typing drives the interface: the greeting follows the name as it is typed, and the
    /// button wakes up once there is something to send.
    public static func signIn() -> SignIn {
        typealias S = ExampleStyle
        let badge = Layer(name: "Badge", kind: .view, properties: [
            .position: .point(Point2(x: S.margin, y: 112)), .size: .size(Size2(width: 64, height: 64)),
            .cornerRadius: .number(20), .fill: .color(S.accent),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .distribution: .text("Center"),
        ], children: [S.symbol("Wave", "hand.wave.fill", side: 30, color: .white)])
        let title = S.text("Title", "What should\nwe call you?", at: Point2(x: S.margin, y: 200), size: 32, weight: 700,
                           width: S.column, height: 84)
        let subtitle = S.text("Subtitle", "We'll only use it to say hello.", at: Point2(x: S.margin, y: 292), color: S.secondary)
        let field = Layer(name: "Name", kind: .textField, properties: [
            .position: .point(Point2(x: S.margin, y: 344)), .size: .size(Size2(width: S.column, height: 56)),
            .placeholder: .text("Your name"), .fill: .color(S.surface), .cornerRadius: .number(16), .padding: .number(18),
            .strokeColor: .color(S.hairline), .strokeWidth: .number(1), .fontSize: .number(18),
        ])
        let greeting = S.text("Greeting", "Hello", at: Point2(x: S.margin, y: 432), size: 26, weight: 600, color: S.accent)
        var button = S.button("Continue", "Continue", at: Point2(x: S.margin, y: S.device.height - S.bottom - 70))
        button.properties[.opacity] = .number(0.35)
        let screen = Layer(name: "Screen", kind: .screen, properties: [
            .fill: .color(S.paper),
        ], children: [badge, title, subtitle, field, greeting, S.hint("Click the field and type a name", symbol: "keyboard", y: 704), button])

        var b = Builder(screen: screen)
        let input = b.attach("textInput", to: field.id, at: Point2(x: 48, y: 96))
        let join = b.add("joinText", at: Point2(x: 336, y: 96), name: "Greeting", inputs: ["a": .text("Hello, ")])
        let text = b.property(.text, of: greeting.id, at: Point2(x: 624, y: 96))
        let length = b.add("textLength", at: Point2(x: 336, y: 312))
        let dimmed = b.add("if", at: Point2(x: 624, y: 312), name: "Ready", type: .number, inputs: [
            "then": .number(0.35), "else": .number(1),
        ])
        let spring = b.add("spring", at: Point2(x: 912, y: 312), inputs: ["target": .number(0.35)])
        let opacity = b.property(.opacity, of: button.id, at: Point2(x: 1200, y: 312))
        b.connect(input, "text", to: join, "b")
        b.connect(join, "text", to: text, "value")
        b.connect(input, "text", to: length, "text")
        b.connect(length, "empty", to: dimmed, "condition")
        b.connect(dimmed, "value", to: spring, "target")
        b.connect(spring, "value", to: opacity, "value")
        b.note("Text · As it is typed", around: [input])
        b.note("Greet · Hello and the name", around: [join, text])
        b.note("Wake · Empty keeps the button dim", around: [length, dimmed, spring])
        return SignIn(document: b.document, field: field.id, greeting: greeting.id, button: button.id, input: input)
    }

    public struct SearchList {
        public let document: Document
        public let field: LayerID
        public let row: LayerID
        public let filter: NodeID
        public static let names = [
            "Ada Lovelace", "Alan Turing", "Barbara Liskov", "Grace Hopper", "Katherine Johnson",
            "Linus Torvalds", "Margaret Hamilton", "Tim Berners-Lee",
        ]
    }

    /// A search field that narrows a list as you type: the typed text filters an array, and
    /// one row is repeated for whatever is left.
    public static func searchList() -> SearchList {
        typealias S = ExampleStyle
        let field = Layer(name: "Search", kind: .textField, properties: [
            .position: .point(Point2(x: S.margin, y: 144)), .size: .size(Size2(width: S.column, height: 44)),
            .placeholder: .text("Search"), .fill: .color(ColorValue(hex: "#E8E5DE")!), .cornerRadius: .number(12),
            .padding: .number(40),
        ])
        let glass = S.symbol("Glass", "magnifyingglass", at: Point2(x: S.margin + 14, y: 157), side: 17, color: S.secondary, weight: 600)
        let name = Layer(name: "Name", kind: .text, properties: [
            .fontWeight: .number(600), .textColor: .color(S.ink), .widthMode: .text("Grow"), .heightMode: .text("Auto"),
        ])
        let avatar = Layer(name: "Avatar", kind: .view, properties: [
            .size: .size(Size2(width: 36, height: 36)), .cornerRadius: .number(18), .fill: .color(ColorValue(hex: "#E4E7FD")!),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .distribution: .text("Center"),
        ], children: [S.symbol("Person", "person.fill", side: 17, color: S.accent)])
        let row = Layer(name: "Row", kind: .view, properties: [
            .size: .size(Size2(width: S.column, height: 60)), .fill: .color(S.surface), .cornerRadius: .number(18),
            .widthMode: .text("Grow"), .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
            .spacing: .number(12), .paddingHorizontal: .number(12), .paddingVertical: .number(12), .paddingRight: .number(18),
        ], children: [avatar, name, S.symbol("Chevron", "chevron.right", side: 13, color: S.tertiary, weight: 700)])
        let list = Layer(name: "List", kind: .view, properties: [
            .position: .point(Point2(x: S.margin, y: 204)), .size: .size(Size2(width: S.column, height: 100)),
            .layout: .text("Stack"), .spacing: .number(8), .heightMode: .text("Auto"),
        ], children: [row])
        let screen = Layer(name: "Screen", kind: .screen, properties: [
            .fill: .color(S.paper),
        ], children: S.header("8 people", "Contacts") + [field, glass, list, S.hint("Click Search and type, say, “ra”", symbol: "keyboard")])

        var b = Builder(screen: screen)
        let names = b.add("splitText", at: Point2(x: 48, y: 96), name: "Names", inputs: [
            "text": .text(SearchList.names.joined(separator: ", ")),
        ])
        let input = b.attach("textInput", to: field.id, at: Point2(x: 48, y: 312))
        let filter = b.add("filterArray", at: Point2(x: 336, y: 96))
        let each = b.add("loopOverArray", at: Point2(x: 624, y: 96), type: .text)
        let text = b.property(.text, of: name.id, at: Point2(x: 912, y: 96))
        // The loop has to reach the row itself for the whole row to repeat.
        let always = b.add("greaterEqual", at: Point2(x: 912, y: 264), name: "Every Row")
        let shown = b.property(.opacity, of: row.id, at: Point2(x: 1200, y: 264))
        b.connect(names, "array", to: filter, "array")
        b.connect(input, "text", to: filter, "search")
        b.connect(filter, "array", to: each, "array")
        b.connect(each, "value", to: text, "value")
        b.connect(each, "index", to: always, "a")
        b.connect(always, "result", to: shown, "value")
        b.note("Filter · Keep the names that match", around: [names, input, filter])
        b.note("Repeat · One row per match", around: [each, always])
        return SearchList(document: b.document, field: field.id, row: row.id, filter: filter)
    }

    public struct SwipeMenu {
        public let document: Document
        public let row: LayerID
        public let revealed: NodeID
        public static let restX: Double = 20
        public static let openX: Double = -76
    }

    /// A row that slides aside on a swipe to show an action behind it, and back again.
    public static func swipeMenu() -> SwipeMenu {
        typealias S = ExampleStyle
        let rowY = 150.0, height = 84.0
        func message(_ name: String, _ sender: String, _ preview: String, _ time: String, _ color: ColorValue, initials: String) -> [Layer] {
            [
                { var a = S.avatar(initials: initials, color: color, side: 44); a.properties[.position] = .point(Point2(x: 16, y: 20)); return a }(),
                S.text("Sender", sender, at: Point2(x: 74, y: 20), weight: 600),
                S.text("Preview", preview, at: Point2(x: 74, y: 44), size: 15, color: S.secondary),
                S.text("Time", time, at: Point2(x: S.column - 56, y: 22), size: 13, color: S.tertiary, width: 40, align: "Right"),
            ]
        }
        let action = Layer(name: "Delete", kind: .view, properties: [
            .position: .point(Point2(x: S.margin, y: rowY)), .size: .size(Size2(width: S.column, height: height)),
            .fill: .color(ColorValue(hex: "#FF4D3D")!), .cornerRadius: .number(22),
        ], children: [
            S.symbol("Trash", "trash.fill", at: Point2(x: S.column - 58, y: 18), side: 24, color: .white),
            S.text("Label", "Delete", at: Point2(x: S.column - 78, y: 48), size: 13, weight: 600, color: .white, width: 64, align: "Center"),
        ])
        let row = Layer(name: "Row", kind: .view, properties: [
            .position: .point(Point2(x: SwipeMenu.restX, y: rowY)), .size: .size(Size2(width: S.column, height: height)),
            .fill: .color(S.surface), .cornerRadius: .number(22),
            .shadowRadius: .number(10), .shadowColor: .color(S.shadow), .shadowOffset: .point(Point2(x: 0, y: 2)),
        ], children: message("Row", "Mika Ito", "Photos from Kyoto", "9:41", S.coral, initials: "MI"))
        let others: [Layer] = [
            ("Sam Okafor", "Re: Friday's plan", "9:12", S.sky, "SO"), ("Lena Park", "The deck, with your notes", "8:55", S.sage, "LP"),
            ("Theo Grant", "Lunch?", "8:30", S.plum, "TG"),
        ].enumerated().map { index, m in
            Layer(name: "Message \(index + 2)", kind: .view, properties: [
                .position: .point(Point2(x: S.margin, y: rowY + Double(index + 1) * (height + 10))),
                .size: .size(Size2(width: S.column, height: height)), .fill: .color(S.surface), .cornerRadius: .number(22),
                .opacity: .number(0.55),
            ], children: message("Message", m.0, m.1, m.2, m.3, initials: m.4))
        }
        let screen = Layer(name: "Screen", kind: .screen, properties: [
            .fill: .color(S.paper),
        ], children: S.header("4 unread", "Inbox") + others + [action, row, S.hint("Swipe the top message left, then right", symbol: "hand.draw.fill")])

        var b = Builder(screen: screen)
        let swipe = b.attach("swipe", to: row.id, at: Point2(x: 48, y: 96))
        let revealed = b.add("switch", at: Point2(x: 336, y: 96), name: "Revealed")
        let spring = b.add("spring", at: Point2(x: 624, y: 96), inputs: ["response": .number(0.35), "damping": .number(0.85)])
        let slide = b.add("transition", at: Point2(x: 912, y: 96), name: "Slide", type: .point, inputs: [
            "start": .point(Point2(x: SwipeMenu.restX, y: rowY)), "end": .point(Point2(x: SwipeMenu.openX, y: rowY)),
        ])
        let position = b.property(.position, of: row.id, at: Point2(x: 1200, y: 96))
        b.connect(swipe, "left", to: revealed, "turnOn")
        b.connect(swipe, "right", to: revealed, "turnOff")
        b.connect(revealed, "on", to: spring, "target")
        b.connect(spring, "value", to: slide, "progress")
        b.connect(slide, "value", to: position, "value")
        b.note("Swipe · Left opens, right closes", around: [swipe, revealed])
        b.note("Slide · The row springs aside", around: [spring, slide])
        return SwipeMenu(document: b.document, row: row.id, revealed: revealed)
    }

    public struct ScreenFlow {
        public let document: Document
        public let inbox: LayerID
        public let message: LayerID
        public let compose: LayerID
        public let row: LayerID
        public let back: LayerID
        public let write: LayerID
        public let close: LayerID
    }

    /// Three screens and the ways between them: a row pushes a message in from the side,
    /// its back button goes back, and a button brings a sheet up from the bottom. Each way
    /// is a Tap cabled into a Navigate patch on the screen it shows.
    public static func screenFlow() -> ScreenFlow {
        typealias S = ExampleStyle
        func page(_ name: String, fill: ColorValue, _ children: [Layer]) -> Layer {
            var layer = Layer.newPage(name: name)
            layer.properties[.fill] = .color(fill)
            layer.children = children
            return layer
        }
        func navButton(_ name: String, _ title: String, symbol: String?, at point: Point2) -> Layer {
            var children: [Layer] = []
            if let symbol { children.append(S.symbol("Chevron", symbol, side: 18, color: S.accent, weight: 700)) }
            children.append(S.text("Title", title, size: 17, weight: 500, color: S.accent))
            return Layer(name: name, kind: .view, properties: [
                .position: .point(point), .size: .size(Size2(width: 100, height: 44)), .widthMode: .text("Auto"),
                .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .spacing: .number(4),
                .paddingHorizontal: .number(8), .paddingVertical: .number(0),
            ], children: children)
        }
        var avatar = S.avatar(initials: "MI", color: S.coral, side: 48)
        avatar.properties[.position] = .point(Point2(x: 16, y: 18))
        let row = Layer(name: "Row", kind: .view, properties: [
            .position: .point(Point2(x: S.margin, y: 150)), .size: .size(Size2(width: S.column, height: 84)),
            .fill: .color(S.surface), .cornerRadius: .number(22),
            .shadowRadius: .number(10), .shadowColor: .color(S.shadow), .shadowOffset: .point(Point2(x: 0, y: 2)),
        ], children: [
            avatar,
            S.text("Sender", "Mika Ito", at: Point2(x: 78, y: 20), weight: 600),
            S.text("Preview", "Photos from Kyoto", at: Point2(x: 78, y: 44), size: 15, color: S.secondary),
            S.symbol("Chevron", "chevron.right", at: Point2(x: S.column - 30, y: 35), side: 13, color: S.tertiary, weight: 700),
        ])
        let write = S.button("Write", "New Message", at: Point2(x: (S.device.width - 200) / 2, y: 720), width: 200)
        let inbox = page("Inbox", fill: S.paper, S.header("1 unread", "Inbox") + [
            row, S.hint("Tap the message, or New Message", y: 660), write,
        ])
        let back = navButton("Back", "Inbox", symbol: "chevron.left", at: Point2(x: 8, y: S.top + 4))
        var big = S.avatar(initials: "MI", color: S.coral, side: 56)
        big.properties[.position] = .point(Point2(x: S.margin, y: 128))
        let message = page("Message", fill: S.surface, [
            back, big,
            S.text("From", "Mika Ito · 9:41", at: Point2(x: 92, y: 146), size: 15, color: S.secondary),
            S.text("Subject", "Photos from Kyoto", at: Point2(x: S.margin, y: 206), size: 28, weight: 700),
            S.text("Body", "The maples were just turning. I've put the best ones in a shared album — the temple at dawn is my favorite.\n\nSwipe from the left edge, or tap Inbox, to go back.",
                   at: Point2(x: S.margin, y: 256), color: ColorValue(hex: "#3A3940")!, width: S.column, height: 200),
        ])
        let close = navButton("Close", "Cancel", symbol: nil, at: Point2(x: 8, y: S.top + 4))
        func line(_ name: String, _ label: String, y: Double) -> Layer {
            Layer(name: name, kind: .view, properties: [
                .position: .point(Point2(x: S.margin, y: y)), .size: .size(Size2(width: S.column, height: 48)),
                .strokeColor: .color(S.hairline), .strokeWidth: .number(0),
            ], children: [
                S.text("Label", label, at: Point2(x: 0, y: 14), color: S.secondary),
                Layer(name: "Rule", kind: .view, properties: [
                    .position: .point(Point2(x: 0, y: 47)), .size: .size(Size2(width: S.column, height: 1)), .fill: .color(S.hairline),
                ]),
            ])
        }
        let compose = page("Compose", fill: S.surface, [
            close,
            S.text("Title", "New Message", at: Point2(x: S.margin, y: 128), size: 28, weight: 700),
            line("To", "To:", y: 176), line("Subject", "Subject:", y: 224),
            S.text("Note", "This screen came up from the bottom, as a sheet does. Cancel sends it back down.",
                   at: Point2(x: S.margin, y: 296), color: S.secondary, width: S.column, height: 50),
        ])
        let screen = Layer(name: "Device", kind: .screen, properties: [
            .fill: .color(.black),
        ], children: [inbox, message, compose])

        var b = Builder(screen: screen)
        // Each screen's taps are with its views; the Navigate patches are beside the screens.
        let tapRow = b.attach(PatchKind.tap, to: row.id, at: Point2(x: 48, y: 96))
        let tapWrite = b.attach(PatchKind.tap, to: write.id, at: Point2(x: 48, y: 336))
        let tapBack = b.attach(PatchKind.tap, to: back.id, at: Point2(x: 48, y: 96))
        let tapClose = b.attach(PatchKind.tap, to: close.id, at: Point2(x: 48, y: 96))
        let goBack = b.add(PatchKind.navigateBack, at: Point2(x: 336, y: 96), name: "Back to Inbox")
        let dismiss = b.add(PatchKind.navigateBack, at: Point2(x: 336, y: 96), name: "Dismiss")
        let push = b.attach(PatchKind.navigate, to: message.id, at: Point2(x: 48, y: 96))
        let present = b.attach(PatchKind.navigate, to: compose.id, at: Point2(x: 48, y: 288), inputs: ["style": .text(Navigation.Style.modal.rawValue)])
        // Each level in two columns: what starts a flow, then the views it is about.
        b.view(inbox.id, at: Point2(x: 336, y: 96))
        b.view(message.id, at: Point2(x: 336, y: 240))
        b.view(compose.id, at: Point2(x: 336, y: 384))
        for views in [inbox.children, message.children, compose.children] {
            for (index, view) in views.enumerated() {
                b.view(view.id, at: Point2(x: 624, y: 96 + Double(index) * 228))
            }
        }
        b.connect(tapRow, "tapped", to: push, "go")
        b.connect(tapWrite, "tapped", to: present, "go")
        b.connect(tapBack, "tapped", to: goBack, "go")
        b.connect(tapClose, "tapped", to: dismiss, "go")
        return ScreenFlow(
            document: b.document, inbox: inbox.id, message: message.id, compose: compose.id,
            row: row.id, back: back.id, write: write.id, close: close.id
        )
    }

    public struct MorphingCard {
        public let document: Document
        public let feed: LayerID
        public let detail: LayerID
        public let card: LayerID
        public let bigCard: LayerID
        public let close: LayerID
    }

    /// A card that opens into its own screen: the card and its title have the same names
    /// on both screens, so the Morph style moves them from one place to the other while
    /// the rest crossfades. Close goes back the same way.
    public static func morphingCard() -> MorphingCard {
        typealias S = ExampleStyle
        let size = S.device
        func page(_ name: String, _ children: [Layer]) -> Layer {
            var layer = Layer.newPage(name: name)
            layer.properties[.fill] = .color(S.paper)
            layer.children = children
            return layer
        }
        func picture() -> Layer {
            var scene = S.scene("Picture", size: Size2(width: 442, height: 460), sky: S.night,
                                hills: (ColorValue(hex: "#24315E")!, ColorValue(hex: "#111830")!),
                                sun: ColorValue(hex: "#E9F4FF")!, subject: "sparkles")
            scene.properties[.position] = .point(Point2(x: -20, y: 0))
            return scene
        }
        let card = Layer(name: "Card", kind: .view, properties: [
            .position: .point(Point2(x: S.margin, y: 150)), .size: .size(Size2(width: S.column, height: 280)),
            .fill: .color(S.night), .cornerRadius: .number(28), .clips: .bool(true),
            .shadowRadius: .number(20), .shadowColor: .color(S.shadow), .shadowOffset: .point(Point2(x: 0, y: 10)),
        ], children: [picture()])
        let feed = page("Feed", [
            S.text("Date", "TONIGHT", at: Point2(x: S.margin, y: S.top + 14), size: 13, weight: 600, color: S.secondary),
            S.text("Heading", "Discover", at: Point2(x: S.margin, y: S.top + 34), size: 34, weight: 700),
            card,
            S.text("Title", "Northern Lights", at: Point2(x: S.margin, y: 446), size: 24, weight: 700),
            S.text("Teaser", "Where to see them this winter", at: Point2(x: S.margin, y: 480), size: 15, color: S.secondary),
            S.hint("Tap the card; Close goes back"),
        ])
        let bigCard = Layer(name: "Card", kind: .view, properties: [
            .position: .point(.zero), .size: .size(Size2(width: size.width, height: 440)),
            .fill: .color(S.night), .cornerRadius: .number(0), .clips: .bool(true),
        ], children: [picture()])
        let close = S.roundButton("Close", symbol: "xmark", at: Point2(x: size.width - 56, y: S.top + 10))
        let detail = page("Detail", [
            bigCard, close,
            S.text("Title", "Northern Lights", at: Point2(x: S.margin, y: 464), size: 34, weight: 700),
            S.text("Body", "The card grew into this screen. It is called Card on both screens, and so is the title, so the flow's Morph style moves each from its place on one to its place on the other while the rest fades.",
                   at: Point2(x: S.margin, y: 516), color: ColorValue(hex: "#3A3940")!, width: S.column, height: 160),
        ])
        let screen = Layer(name: "Device", kind: .screen, properties: [.fill: .color(.black)], children: [feed, detail])

        var b = Builder(screen: screen)
        let tapCard = b.attach(PatchKind.tap, to: card.id, at: Point2(x: 48, y: 96))
        let tapClose = b.attach(PatchKind.tap, to: close.id, at: Point2(x: 48, y: 96))
        let back = b.add(PatchKind.navigateBack, at: Point2(x: 336, y: 96), name: "Close")
        let open = b.attach(PatchKind.navigate, to: detail.id, at: Point2(x: 48, y: 96),
                            inputs: ["style": .text(Navigation.Style.morph.rawValue), "response": .number(0.5)])
        b.view(feed.id, at: Point2(x: 336, y: 96))
        b.view(detail.id, at: Point2(x: 336, y: 240))
        for views in [feed.children, detail.children] {
            for (index, view) in views.enumerated() {
                b.view(view.id, at: Point2(x: 624, y: 96 + Double(index) * 228))
            }
        }
        b.connect(tapCard, "tapped", to: open, "go")
        b.connect(tapClose, "tapped", to: back, "go")
        return MorphingCard(document: b.document, feed: feed.id, detail: detail.id, card: card.id, bigCard: bigCard.id, close: close.id)
    }

    public struct PinchZoom {
        public let document: Document
        public let photo: LayerID
        public let pan: NodeID
        public let pinch: NodeID
        public let rotation: NodeID
    }

    /// A picture that fingers move, zoom and turn, all at once, and that springs back when
    /// they lift. Pan, Pinch and Rotation on one view go together; each drives a spring
    /// that follows it while it is under way (Hold) and settles when it ends.
    public static func pinchZoom() -> PinchZoom {
        typealias S = ExampleStyle
        let side = 322.0
        let rest = Point2(x: (S.device.width - side) / 2, y: 180)
        var photo = S.scene("Photo", size: Size2(width: side, height: side), sky: ColorValue(hex: "#8FD3E8")!,
                            hills: (ColorValue(hex: "#4FB39B")!, ColorValue(hex: "#2E7F72")!),
                            sun: ColorValue(hex: "#FFF6D8")!, subject: "mountain.2.fill", radius: 32)
        photo.properties[.position] = .point(rest)
        photo.properties[.shadowColor] = .color(S.shadow)
        photo.properties[.shadowRadius] = .number(24)
        photo.properties[.shadowOffset] = .point(Point2(x: 0, y: 12))
        let screen = Layer(name: "Screen", kind: .screen, properties: [
            .fill: .color(S.paper),
        ], children: S.header("Gestures", "Look Closer") + [
            photo,
            S.text("Caption", "Fingers move, zoom and turn the picture at once. Let go and it springs back.",
                   at: Point2(x: 40, y: 540), size: 15, color: S.secondary, width: S.device.width - 80, height: 44, align: "Center"),
            S.hint("Drag it; hold Option to pinch and twist", symbol: "hand.pinch.fill"),
        ])

        var b = Builder(screen: screen)
        func spring(_ name: String, target: Double, at position: Point2) -> NodeID {
            b.add("spring", at: position, name: name, inputs: [
                "target": .number(target), "response": .number(0.3), "damping": .number(0.7),
            ])
        }
        let pan = b.attach(PatchKind.pan, to: photo.id, at: Point2(x: 48, y: 96))
        let travel = b.add("splitPoint", at: Point2(x: 336, y: 96))
        let x = spring("X", target: rest.x, at: Point2(x: 624, y: 96))
        let y = spring("Y", target: rest.y, at: Point2(x: 624, y: 312))
        let pinch = b.attach(PatchKind.pinch, to: photo.id, at: Point2(x: 48, y: 648))
        let size = spring("Scale", target: 1, at: Point2(x: 624, y: 648))
        let rotation = b.attach(PatchKind.rotation, to: photo.id, at: Point2(x: 48, y: 960))
        let turn = spring("Turn", target: 0, at: Point2(x: 624, y: 960))
        let view = b.view(photo.id, at: Point2(x: 912, y: 96))

        b.connect(pan, "translation", to: travel, "point")
        b.connect(pan, "panning", to: x, "hold")
        b.connect(travel, "x", to: x, "held")
        b.connect(pan, "panning", to: y, "hold")
        b.connect(travel, "y", to: y, "held")
        b.connect(pinch, "pinching", to: size, "hold")
        b.connect(pinch, "scale", to: size, "held")
        b.connect(rotation, "rotating", to: turn, "hold")
        b.connect(rotation, "rotation", to: turn, "held")
        b.connect(x, "value", to: view, "x")
        b.connect(y, "value", to: view, "y")
        b.connect(size, "value", to: view, LayerProperty.scale.rawValue)
        b.connect(turn, "value", to: view, LayerProperty.rotation.rawValue)
        b.note("Move · Held, the springs follow the drag", around: [pan, travel, x, y])
        b.note("Zoom · Held, Scale follows the pinch", around: [pinch, size])
        b.note("Turn · Held, Turn follows the twist", around: [rotation, turn])
        return PinchZoom(document: b.document, photo: photo.id, pan: pan, pinch: pinch, rotation: rotation)
    }

    public struct HoverButton {
        public let document: Document
        public let button: LayerID
        public let hover: NodeID
    }

    /// A button that lifts when a pointer rests on it, as on iPad or the web.
    public static func hoverButton() -> HoverButton {
        typealias S = ExampleStyle
        func feature(_ words: String) -> Layer {
            Layer(name: "Feature", kind: .view, properties: [
                .size: .size(Size2(width: 100, height: 24)), .widthMode: .text("Grow"),
                .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .spacing: .number(10),
            ], children: [
                S.symbol("Check", "checkmark", side: 16, color: S.sage, weight: 700),
                S.text("Words", words, color: ColorValue(hex: "#3A3940")!),
            ])
        }
        let plan = Layer(name: "Plan", kind: .view, properties: [
            .position: .point(Point2(x: S.margin, y: 150)), .size: .size(Size2(width: S.column, height: 330)), .heightMode: .text("Auto"),
            .fill: .color(S.surface), .cornerRadius: .number(28),
            .shadowColor: .color(S.shadow), .shadowRadius: .number(20), .shadowOffset: .point(Point2(x: 0, y: 8)),
            .layout: .text("Stack"), .spacing: .number(14), .paddingHorizontal: .number(24), .paddingVertical: .number(26),
        ], children: [
            S.text("Tier", "STUDIO", size: 13, weight: 700, color: S.accent),
            S.text("Price", "$12 a month", size: 34, weight: 700),
            S.text("Pitch", "Everything you need to share prototypes with your team.", size: 15, color: S.secondary,
                   width: S.column - 48, height: 40),
            feature("Unlimited prototypes"), feature("Shared libraries"), feature("Recordings with touches"),
        ])
        let buttonLabel = Layer(name: "Label", kind: .text, properties: [
            .size: .size(Size2(width: 240, height: 22)), .position: .point(Point2(x: 0, y: 19)),
            .text: .text("Start Free Trial"), .fontWeight: .number(600), .textColor: .color(.white),
            .textAlignment: .text("Center"),
        ])
        let button = Layer(name: "Button", kind: .view, properties: [
            .position: .point(Point2(x: (S.device.width - 240) / 2, y: 488)), .size: .size(Size2(width: 240, height: 60)),
            .fill: .color(S.accent), .cornerRadius: .number(30),
            .shadowColor: .color(S.accent.withAlpha(0.45)), .shadowOffset: .point(Point2(x: 0, y: 8)),
        ], children: [buttonLabel])
        let screen = Layer(name: "Screen", kind: .screen, properties: [
            .fill: .color(S.paper),
        ], children: S.header("Pricing", "Go Further") + [plan, button, S.hint("Point at the button without clicking", symbol: "cursorarrow")])

        var b = Builder(screen: screen)
        let hover = b.attach("hover", to: button.id, at: Point2(x: 48, y: 96))
        let spring = b.add("spring", at: Point2(x: 336, y: 96), inputs: ["response": .number(0.3), "damping": .number(0.65)])
        let grow = b.add("transition", at: Point2(x: 624, y: 96), name: "Lift", type: .number, inputs: [
            "start": .number(1), "end": .number(1.08),
        ])
        let glow = b.add("transition", at: Point2(x: 624, y: 264), name: "Glow", type: .number, inputs: [
            "start": .number(0), "end": .number(18),
        ])
        let scale = b.property(.scale, of: button.id, at: Point2(x: 912, y: 96))
        let shadow = b.property(.shadowRadius, of: button.id, at: Point2(x: 912, y: 96))
        b.connect(hover, "hovering", to: spring, "target")
        b.connect(spring, "value", to: grow, "progress")
        b.connect(spring, "value", to: glow, "progress")
        b.connect(grow, "value", to: scale, "value")
        b.connect(glow, "value", to: shadow, "value")
        b.note("Hover · On while the pointer rests", around: [hover, spring])
        b.note("Lift · Bigger, with a glow", around: [grow, glow])
        return HoverButton(document: b.document, button: button.id, hover: hover)
    }

    public struct StickyHeader {
        public let document: Document
        public let header: LayerID
        public let title: LayerID
        public let list: LayerID
        public static let tall: Double = 200
        public static let short: Double = 106
        public static let rowCount = 12
    }

    /// A tall header that shrinks to a bar as the list scrolls under it, then stays put.
    public static func stickyHeader() -> StickyHeader {
        typealias Header = StickyHeader
        typealias S = ExampleStyle
        let trips: [(String, String, String, ColorValue)] = [
            ("Kyoto", "Nov 21 – 28", "leaf.fill", S.coral), ("Lisbon", "Dec 3 – 9", "tram.fill", S.amber),
            ("Reykjavík", "Jan 12 – 16", "snowflake", S.sky), ("Marrakech", "Feb 2 – 8", "sun.max.fill", S.rose),
            ("Patagonia", "Mar 1 – 14", "mountain.2.fill", S.teal), ("Oaxaca", "Apr 5 – 11", "fork.knife", S.plum),
            ("Hokkaido", "May 2 – 9", "fish.fill", S.sage), ("Lofoten", "Jun 14 – 21", "sailboat.fill", S.sky),
            ("Tuscany", "Jul 7 – 13", "wineglass.fill", S.coral), ("Bali", "Aug 3 – 12", "water.waves", S.teal),
            ("Cappadocia", "Sep 9 – 14", "balloon.fill", S.amber), ("Seoul", "Oct 18 – 25", "building.2.fill", S.plum),
        ]
        let rows: [Layer] = (0..<Header.rowCount).map { index in
            let trip = trips[index % trips.count]
            return Layer(name: "Row \(index + 1)", kind: .view, properties: [
                .size: .size(Size2(width: 100, height: 72)), .fill: .color(S.surface), .cornerRadius: .number(20),
                .widthMode: .text("Grow"), .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
                .spacing: .number(14), .paddingHorizontal: .number(14), .paddingVertical: .number(14),
            ], children: [
                Layer(name: "Icon", kind: .view, properties: [
                    .size: .size(Size2(width: 44, height: 44)), .cornerRadius: .number(14), .fill: .color(trip.3),
                    .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .distribution: .text("Center"),
                ], children: [S.symbol("Glyph", trip.2, side: 21, color: .white)]),
                Layer(name: "Title", kind: .text, properties: [
                    .text: .text(trip.0), .fontWeight: .number(600), .textColor: .color(S.ink),
                    .widthMode: .text("Grow"), .heightMode: .text("Auto"),
                ]),
                S.text("Dates", trip.1, size: 15, color: S.secondary),
            ])
        }
        // The list is a scroll view the size of the screen. An empty first row holds the
        // place of the tall header, so the rows start below it and can scroll up under it.
        let space = Layer(name: "Header Space", kind: .view, properties: [
            .size: .size(Size2(width: 100, height: Header.tall - 10)), .widthMode: .text("Grow"),
        ])
        var list = Layer.new(.scrollView, name: "List")
        list.set(.size, .size(S.device))
        list.set(.spacing, .number(10))
        list.set(.paddingHorizontal, .number(16))
        list.set(.paddingVertical, .number(16))
        list.children = [space] + rows
        let header = Layer(name: "Header", kind: .view, properties: [
            .size: .size(Size2(width: S.device.width, height: Header.tall)), .fill: .color(S.night), .clips: .bool(true),
        ], children: [
            Layer(name: "Glow", kind: .ellipse, properties: [
                .position: .point(Point2(x: 230, y: -150)), .size: .size(Size2(width: 300, height: 300)),
                .fill: .color(S.plum.withAlpha(0.22)),
            ]),
        ])
        let titleStart = Point2(x: S.margin, y: 140), titleEnd = Point2(x: S.margin, y: 72)
        let title = S.text("Title", "Journeys", at: titleStart, size: 36, weight: 700, color: .white)
        let screen = Layer(name: "Screen", kind: .screen, properties: [
            .fill: .color(S.paper),
        ], children: [list, header, title, S.hint("Drag the list up", symbol: "hand.draw.fill")])

        var b = Builder(screen: screen)
        let scroll = b.view(list.id, at: Point2(x: 48, y: 96))
        let collapse = b.add("progress", at: Point2(x: 336, y: 96), name: "Collapse", inputs: [
            "start": .number(0), "end": .number(Header.short - Header.tall),
        ])
        let clamp = b.add("clamp", at: Point2(x: 624, y: 96))
        let height = b.add("transition", at: Point2(x: 912, y: 96), name: "Header Height", type: .size, inputs: [
            "start": .size(Size2(width: S.device.width, height: Header.tall)), "end": .size(Size2(width: S.device.width, height: Header.short)),
        ])
        let fontSize = b.add("transition", at: Point2(x: 912, y: 264), name: "Title Size", type: .number, inputs: [
            "start": .number(36), "end": .number(20),
        ])
        let place = b.add("transition", at: Point2(x: 912, y: 432), name: "Title Position", type: .point, inputs: [
            "start": .point(titleStart), "end": .point(titleEnd),
        ])
        let headerSize = b.property(.size, of: header.id, at: Point2(x: 1200, y: 96))
        let titleSize = b.property(.fontSize, of: title.id, at: Point2(x: 1200, y: 264))
        let titlePosition = b.property(.position, of: title.id, at: Point2(x: 1200, y: 264))
        b.connect(scroll, "offset", to: collapse, "value")
        b.connect(collapse, "progress", to: clamp, "value")
        b.connect(clamp, "result", to: height, "progress")
        b.connect(clamp, "result", to: fontSize, "progress")
        b.connect(clamp, "result", to: place, "progress")
        b.connect(height, "value", to: headerSize, "value")
        b.connect(fontSize, "value", to: titleSize, "value")
        b.connect(place, "value", to: titlePosition, "value")
        b.note("Collapse · Scrolled 0 to 94 points is 0 to 1", around: [scroll, collapse, clamp])
        b.note("Shrink · Header and title follow", around: [height, fontSize, place])
        return StickyHeader(document: b.document, header: header.id, title: title.id, list: list.id)
    }
}

extension SampleDocuments {
    public struct VideoScrubbing {
        public let document: Document
        public let clip: LayerID
        public let scrubber: LayerID
        public let knob: LayerID
        public let time: NodeID

        /// The clip it plays, written by `papertool sample-video`: four seconds.
        public static let clipName = "Sunset.mov"
        public static var assets: [String: Data] {
            guard let url = Bundle.module.url(forResource: "Sunset", withExtension: "mov", subdirectory: "Media"),
                  let data = try? Data(contentsOf: url) else { return [:] }
            return [clipName: data]
        }

        public static let track = (x: 20.0, y: 372.0, width: 362.0)
    }

    /// A video that plays and loops by itself. A finger on the bar under it pauses it and
    /// moves its time; let go and it plays on from there. The knob follows the video.
    public static func videoScrubbing() -> VideoScrubbing {
        typealias S = ExampleStyle
        let track = VideoScrubbing.track
        let clip = Layer(name: "Clip", kind: .video, properties: [
            .position: .point(Point2(x: S.margin, y: 150)), .size: .size(Size2(width: S.column, height: 204)),
            .video: .text(VideoScrubbing.clipName), .cornerRadius: .number(24),
        ])
        let rail = Layer(name: "Track", kind: .view, properties: [
            .position: .point(Point2(x: track.x, y: track.y + 21)), .size: .size(Size2(width: track.width, height: 6)),
            .fill: .color(S.hairline), .cornerRadius: .number(3),
        ])
        let played = Layer(name: "Played", kind: .view, properties: [
            .position: .point(Point2(x: track.x, y: track.y + 21)), .size: .size(Size2(width: 0, height: 6)),
            .fill: .color(S.accent), .cornerRadius: .number(3),
        ])
        let knob = Layer(name: "Knob", kind: .ellipse, properties: [
            .position: .point(Point2(x: track.x - 12, y: track.y + 12)), .size: .size(Size2(width: 24, height: 24)),
            .fill: .color(.white), .shadowRadius: .number(4), .shadowColor: .color(ColorValue(white: 0, alpha: 0.3)),
            .shadowOffset: .point(Point2(x: 0, y: 1)),
        ])
        // What the finger touches: the whole height around the thin track.
        let scrubber = Layer(name: "Scrubber", kind: .view, properties: [
            .position: .point(Point2(x: track.x, y: track.y)), .size: .size(Size2(width: track.width, height: 48)),
        ])
        let screen = Layer(name: "Screen", kind: .screen, properties: [
            .fill: .color(S.paper),
        ], children: S.header("Golden Hour", "Sunset") + [
            clip, rail, played, knob, scrubber,
            S.text("Caption", "It plays and loops on its own. Under a finger it stops and follows; let go and it plays on.",
                   at: Point2(x: S.margin, y: 436), size: 15, color: S.secondary, width: S.column, height: 44),
            S.hint("Drag along the bar", symbol: "hand.draw.fill"),
        ])

        var b = Builder(screen: screen)
        // The finger's place along the track, as seconds of the clip.
        let touch = b.interaction(on: scrubber.id, at: Point2(x: 48, y: 96))
        let split = b.add("splitPoint", at: Point2(x: 336, y: 96))
        let along = b.add("progress", at: Point2(x: 624, y: 96), name: "Along the Track", inputs: [
            "start": .number(track.x), "end": .number(track.x + track.width),
        ])
        let clamp = b.add("clamp", at: Point2(x: 912, y: 96))
        let seconds = b.add("multiply", at: Point2(x: 1200, y: 96), name: "Seconds")
        // It plays except under the finger.
        let still = b.add("not", at: Point2(x: 912, y: 336), name: "Not Touching")
        let video = b.view(clip.id, at: Point2(x: 1488, y: 96))
        // The bar follows the clip.
        let time = b.attach(PatchKind.videoTime, to: clip.id, at: Point2(x: 48, y: 552))
        let fill = b.add("transition", at: Point2(x: 624, y: 552), name: "Played Width", type: .number, inputs: [
            "start": .number(0), "end": .number(track.width),
        ])
        let slide = b.add("transition", at: Point2(x: 624, y: 720), name: "Knob X", type: .number, inputs: [
            "start": .number(track.x - 12), "end": .number(track.x + track.width - 12),
        ])
        let playedView = b.view(played.id, at: Point2(x: 1488, y: 552))
        let knobView = b.view(knob.id, at: Point2(x: 1488, y: 720))
        b.connect(touch, "position", to: split, "point")
        b.connect(split, "x", to: along, "value")
        b.connect(along, "progress", to: clamp, "value")
        b.connect(clamp, "result", to: seconds, "a")
        b.connect(time, "duration", to: seconds, "b")
        b.connect(seconds, "result", to: video, "time")
        b.connect(touch, "down", to: still, "value")
        b.connect(still, "result", to: video, "playing")
        b.connect(time, "progress", to: fill, "progress")
        b.connect(time, "progress", to: slide, "progress")
        b.connect(fill, "value", to: playedView, "width")
        b.connect(slide, "value", to: knobView, "x")
        b.note("Scrub · The finger's place is a time", around: [touch, split, along, clamp, seconds, still])
        b.note("Follow · The bar shows where the clip is", around: [time, fill, slide])
        return VideoScrubbing(document: b.document, clip: clip.id, scrubber: scrubber.id, knob: knob.id, time: time)
    }
}

/// The prototypes that ship with the app, for the gallery, `papertool` and `Examples/`.
public struct GalleryItem: Identifiable, Sendable {
    public enum Section: String, Sendable, CaseIterable {
        /// Finished-looking prototypes where shaders, glass and motion work together.
        case showcase = "Showcase"
        /// Whole prototypes that show a workflow.
        case examples = "Examples"
        /// One reusable solution each.
        case patterns = "Patterns"
    }

    /// Short and stable: what `papertool` takes as a document name.
    public let id: String
    public let title: String
    public let summary: String
    public let section: Section
    /// The file in `Examples/`, without its extension.
    public let fileName: String
    /// The files the document uses, such as a video, by asset name.
    public var assets: @Sendable () -> [String: Data] = { [:] }
    public let make: @Sendable () -> Document

    /// The document with its assets, as it is opened or written.
    public func package() -> DocumentPackage { DocumentPackage(document: make(), assets: assets()) }
}

public enum Gallery {
    public static let items: [GalleryItem] = [
        GalleryItem(id: "player", title: "Now Playing", summary: "A music player alive while it plays: a shader mesh of light, a shimmering cover and glass controls, all following one spring.",
                    section: .showcase, fileName: "NowPlaying") { SampleDocuments.nowPlaying().document },
        GalleryItem(id: "weather", title: "Sky Through the Day", summary: "Drag to scrub the hour: one shader paints the sun, golden light, stars and clouds, and a script writes the forecast.",
                    section: .showcase, fileName: "Weather") { SampleDocuments.weather().document },
        GalleryItem(id: "holo", title: "Holographic Card", summary: "Drag the card to tilt it: its foil shader slides a rainbow and moves the glare, and it settles back with a spring.",
                    section: .showcase, fileName: "HoloCard") { SampleDocuments.holoCard().document },
        GalleryItem(id: "plan", title: "Plan a Day", summary: "Apple's on-device model, held to six fields, plans a day in a city: the card fills in as it streams and glows while it thinks. Free and private.",
                    section: .showcase, fileName: "PlanADay") { SampleDocuments.planADay().document },
        GalleryItem(id: "card", title: "Card That Opens", summary: "One tap opens a story: one spring value moves its place, size, corners and the dimming together.",
                    section: .examples, fileName: "Card") { SampleDocuments.card().document },
        GalleryItem(id: "signin", title: "Typing a Name", summary: "What is typed drives a greeting, and wakes the button once there is a name.",
                    section: .examples, fileName: "SignIn") { SampleDocuments.signIn().document },
        GalleryItem(id: "search", title: "Searching a List", summary: "A search field that narrows a list as you type.",
                    section: .examples, fileName: "SearchList") { SampleDocuments.searchList().document },
        GalleryItem(id: "people", title: "List from a Loop", summary: "One row repeated for every name; the graph knows which was tapped.",
                    section: .examples, fileName: "People") { SampleDocuments.people().document },
        GalleryItem(id: "live", title: "List from Live Data", summary: "A network request with loading, success and failure states.",
                    section: .examples, fileName: "LiveList") { SampleDocuments.liveList().document },
        GalleryItem(id: "controls", title: "iOS Controls", summary: "The prebuilt switch, slider, stepper, button and tab bar, wired up.",
                    section: .examples, fileName: "Controls") { SampleDocuments.controls().document },
        GalleryItem(id: "kit", title: "Settings from the Shelf", summary: "A whole screen from the iOS components: bars, grouped rows, a switch, an alert. Three cables.",
                    section: .examples, fileName: "SystemKit") { SampleDocuments.systemKit().document },
        GalleryItem(id: "camera", title: "Camera with Feedback", summary: "A viewfinder with a shutter, a haptic and a sound.",
                    section: .examples, fileName: "Camera") { SampleDocuments.camera().document },
        GalleryItem(id: "sheet", title: "Bottom Sheet", summary: "A sheet over a map that follows a finger, then settles open or closed.",
                    section: .patterns, fileName: "Sheet") { SampleDocuments.sheet().document },
        GalleryItem(id: "list", title: "Scrolling List", summary: "An inbox that scrolls with physics and sends its offset to the title.",
                    section: .patterns, fileName: "List") { SampleDocuments.scrollingList().document },
        GalleryItem(id: "header", title: "Sticky Header", summary: "A tall header that shrinks to a bar as the trips scroll under it.",
                    section: .patterns, fileName: "StickyHeader") { SampleDocuments.stickyHeader().document },
        GalleryItem(id: "swipe", title: "Swipe Menu", summary: "A message that slides aside on a swipe to show Delete.",
                    section: .patterns, fileName: "SwipeMenu") { SampleDocuments.swipeMenu().document },
        GalleryItem(id: "flow", title: "Screens and Flows", summary: "Three screens: a row pushes one in, a button brings one up, and each goes back.",
                    section: .patterns, fileName: "ScreenFlow") { SampleDocuments.screenFlow().document },
        GalleryItem(id: "morph", title: "Card to Screen", summary: "A card grows into its own screen and back: views named the same move between screens.",
                    section: .patterns, fileName: "MorphingCard") { SampleDocuments.morphingCard().document },
        GalleryItem(id: "pinch", title: "Pinch to Zoom", summary: "Fingers move, zoom and turn a picture at once; it springs back.",
                    section: .patterns, fileName: "PinchZoom") { SampleDocuments.pinchZoom().document },
        GalleryItem(id: "hover", title: "Hover Highlight", summary: "A button that lifts and glows while a pointer rests on it.",
                    section: .patterns, fileName: "HoverButton") { SampleDocuments.hoverButton().document },
        GalleryItem(id: "aurora", title: "Shader Background", summary: "A background drawn by Metal code, with an input a tap drives.",
                    section: .patterns, fileName: "ShaderBackground") { SampleDocuments.shaderBackground().document },
        GalleryItem(id: "lens", title: "Shader Lens", summary: "A shader over ordinary views: a lens that magnifies whatever is under a finger.",
                    section: .patterns, fileName: "ShaderLens") { SampleDocuments.shaderLens().document },
        GalleryItem(id: "carousels", title: "Nested Scrolling", summary: "Carousels inside a page: the drag's direction picks which one scrolls.",
                    section: .patterns, fileName: "NestedScroll") { SampleDocuments.nestedScroll().document },
        GalleryItem(id: "photos", title: "Selecting Photos", summary: "A grid from one repeated view, with checkmarks and a count.",
                    section: .examples, fileName: "PhotoSelection") { SampleDocuments.photoSelection().document },
        GalleryItem(id: "video", title: "Video Scrubbing", summary: "A clip that plays on its own and follows a finger along a bar.",
                    section: .patterns, fileName: "VideoScrubbing", assets: { SampleDocuments.VideoScrubbing.assets }) {
            SampleDocuments.videoScrubbing().document
        },
    ]

    public static func item(_ id: String) -> GalleryItem? { items.first { $0.id == id } }
}
