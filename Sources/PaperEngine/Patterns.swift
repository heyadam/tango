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
        let title = label("Title", "What should we call you?", at: Point2(x: 24, y: 120), size: 28, weight: 700)
        let field = Layer(name: "Name", kind: .textField, properties: [
            .position: .point(Point2(x: 24, y: 184)), .size: .size(Size2(width: 342, height: 52)),
            .placeholder: .text("Your name"), .cornerRadius: .number(14), .padding: .number(16),
        ])
        let greeting = label("Greeting", "Hello", at: Point2(x: 24, y: 264), size: 20, color: ColorValue(white: 0.4))
        let buttonLabel = Layer(name: "Label", kind: .text, properties: [
            .size: .size(Size2(width: 342, height: 22)), .position: .point(Point2(x: 0, y: 16)),
            .text: .text("Continue"), .fontWeight: .number(600), .textColor: .color(.white),
            .textAlignment: .text("Center"),
        ])
        let button = Layer(name: "Continue", kind: .view, properties: [
            .position: .point(Point2(x: 24, y: 330)), .size: .size(Size2(width: 342, height: 54)),
            .fill: .color(ColorValue(hex: "#3D7BF7")!), .cornerRadius: .number(16), .opacity: .number(0.35),
        ], children: [buttonLabel])
        let screen = Layer(name: "Screen", kind: .screen, properties: [
            .fill: .color(.white),
        ], children: [title, field, greeting, button])

        var b = Builder(screen: screen)
        let input = b.attach("textInput", to: field.id, at: Point2(x: 40, y: 80))
        let join = b.add("joinText", at: Point2(x: 300, y: 80), name: "Greeting", inputs: ["a": .text("Hello, ")])
        let text = b.property(.text, of: greeting.id, at: Point2(x: 560, y: 80))
        let length = b.add("textLength", at: Point2(x: 300, y: 240))
        let dimmed = b.add("if", at: Point2(x: 560, y: 240), name: "Ready", type: .number, inputs: [
            "then": .number(0.35), "else": .number(1),
        ])
        let spring = b.add("spring", at: Point2(x: 800, y: 240), inputs: ["target": .number(0.35)])
        let opacity = b.property(.opacity, of: button.id, at: Point2(x: 1060, y: 240))
        b.connect(input, "text", to: join, "b")
        b.connect(join, "text", to: text, "value")
        b.connect(input, "text", to: length, "text")
        b.connect(length, "empty", to: dimmed, "condition")
        b.connect(dimmed, "value", to: spring, "target")
        b.connect(spring, "value", to: opacity, "value")
        return SignIn(document: b.document, field: field.id, greeting: greeting.id, button: button.id, input: input)
    }

    public struct SearchList {
        public let document: Document
        public let field: LayerID
        public let row: LayerID
        public let filter: NodeID
        public static let names = ["Ada Lovelace", "Grace Hopper", "Alan Turing", "Linus Torvalds", "Margaret Hamilton", "Barbara Liskov"]
    }

    /// A search field that narrows a list as you type: the typed text filters an array, and
    /// one row is repeated for whatever is left.
    public static func searchList() -> SearchList {
        let title = label("Title", "Contacts", at: Point2(x: 20, y: 70), size: 34, weight: 700)
        let field = Layer(name: "Search", kind: .textField, properties: [
            .position: .point(Point2(x: 16, y: 124)), .size: .size(Size2(width: 358, height: 40)),
            .placeholder: .text("Search"), .fill: .color(ColorValue(hex: "#E3E3E8")!),
        ])
        let name = Layer(name: "Name", kind: .text, properties: [
            .fontWeight: .number(600), .widthMode: .text("Auto"), .heightMode: .text("Auto"),
        ])
        let row = Layer(name: "Row", kind: .view, properties: [
            .size: .size(Size2(width: 358, height: 56)), .fill: .color(.white), .cornerRadius: .number(14),
            .widthMode: .text("Grow"), .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .paddingHorizontal: .number(16), .paddingVertical: .number(16),
        ], children: [name])
        let list = Layer(name: "List", kind: .view, properties: [
            .position: .point(Point2(x: 16, y: 180)), .size: .size(Size2(width: 358, height: 100)),
            .layout: .text("Stack"), .spacing: .number(8), .heightMode: .text("Auto"),
        ], children: [row])
        let screen = Layer(name: "Screen", kind: .screen, properties: [
            .fill: .color(ColorValue(hex: "#F2F2F7")!),
        ], children: [title, field, list])

        var b = Builder(screen: screen)
        let names = b.add("splitText", at: Point2(x: 40, y: 80), name: "Names", inputs: [
            "text": .text(SearchList.names.joined(separator: ", ")),
        ])
        let input = b.attach("textInput", to: field.id, at: Point2(x: 40, y: 240))
        let filter = b.add("filterArray", at: Point2(x: 300, y: 80))
        let each = b.add("loopOverArray", at: Point2(x: 560, y: 80), type: .text)
        let text = b.property(.text, of: name.id, at: Point2(x: 820, y: 80))
        // The loop has to reach the row itself for the whole row to repeat.
        let always = b.add("greaterEqual", at: Point2(x: 820, y: 220), name: "Every Row")
        let shown = b.property(.opacity, of: row.id, at: Point2(x: 1080, y: 220))
        b.connect(names, "array", to: filter, "array")
        b.connect(input, "text", to: filter, "search")
        b.connect(filter, "array", to: each, "array")
        b.connect(each, "value", to: text, "value")
        b.connect(each, "index", to: always, "a")
        b.connect(always, "result", to: shown, "value")
        return SearchList(document: b.document, field: field.id, row: row.id, filter: filter)
    }

    public struct SwipeMenu {
        public let document: Document
        public let row: LayerID
        public let revealed: NodeID
        public static let restX: Double = 16
        public static let openX: Double = -72
    }

    /// A row that slides aside on a swipe to show an action behind it, and back again.
    public static func swipeMenu() -> SwipeMenu {
        let header = label("Header", "Inbox", at: Point2(x: 16, y: 72), size: 34, weight: 700)
        let trash = Layer(name: "Trash", kind: .symbol, properties: [
            .position: .point(Point2(x: 306, y: 26)), .size: .size(Size2(width: 28, height: 28)),
            .symbol: .text("trash.fill"), .fill: .color(.white),
        ])
        let action = Layer(name: "Delete", kind: .view, properties: [
            .position: .point(Point2(x: 16, y: 140)), .size: .size(Size2(width: 358, height: 80)),
            .fill: .color(ColorValue(hex: "#FF3B30")!), .cornerRadius: .number(20),
        ], children: [trash])
        let row = Layer(name: "Row", kind: .view, properties: [
            .position: .point(Point2(x: SwipeMenu.restX, y: 140)), .size: .size(Size2(width: 358, height: 80)),
            .fill: .color(.white), .cornerRadius: .number(20),
            .shadowRadius: .number(10), .shadowColor: .color(ColorValue(white: 0, alpha: 0.08)),
        ], children: [
            label("Sender", "Ada Lovelace", at: Point2(x: 20, y: 16), weight: 600),
            label("Preview", "Swipe me left, then right", at: Point2(x: 20, y: 42), size: 15, color: ColorValue(white: 0.45)),
        ])
        let screen = Layer(name: "Screen", kind: .screen, properties: [
            .fill: .color(ColorValue(white: 0.95)),
        ], children: [header, action, row])

        var b = Builder(screen: screen)
        let swipe = b.attach("swipe", to: row.id, at: Point2(x: 40, y: 80))
        let revealed = b.add("switch", at: Point2(x: 300, y: 80), name: "Revealed")
        let spring = b.add("spring", at: Point2(x: 540, y: 80), inputs: ["response": .number(0.35), "damping": .number(0.85)])
        let slide = b.add("transition", at: Point2(x: 800, y: 80), name: "Slide", type: .point, inputs: [
            "start": .point(Point2(x: SwipeMenu.restX, y: 140)), "end": .point(Point2(x: SwipeMenu.openX, y: 140)),
        ])
        let position = b.property(.position, of: row.id, at: Point2(x: 1060, y: 80))
        b.connect(swipe, "left", to: revealed, "turnOn")
        b.connect(swipe, "right", to: revealed, "turnOff")
        b.connect(revealed, "on", to: spring, "target")
        b.connect(spring, "value", to: slide, "progress")
        b.connect(slide, "value", to: position, "value")
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
        // The size the other examples have.
        let size = LayerProperty.size.defaultValue(for: .screen).sizeValue
        func page(_ name: String, fill: ColorValue, _ children: [Layer]) -> Layer {
            var layer = Layer.newPage(name: name)
            layer.properties[.fill] = .color(fill)
            layer.children = children
            return layer
        }
        func button(_ name: String, _ title: String, at point: Point2, width: Double, fill: ColorValue, text: ColorValue) -> Layer {
            Layer(name: name, kind: .view, properties: [
                .position: .point(point), .size: .size(Size2(width: width, height: 48)),
                .fill: .color(fill), .cornerRadius: .number(24),
            ], children: [label("Title", title, at: Point2(x: 20, y: 13), weight: 600, color: text)])
        }
        let blue = ColorValue(hex: "#007AFF")!
        let row = Layer(name: "Row", kind: .view, properties: [
            .position: .point(Point2(x: 16, y: 150)), .size: .size(Size2(width: size.width - 32, height: 80)),
            .fill: .color(.white), .cornerRadius: .number(20),
        ], children: [
            label("Sender", "Ada Lovelace", at: Point2(x: 20, y: 16), weight: 600),
            label("Preview", "Tap to read the whole message", at: Point2(x: 20, y: 42), size: 15, color: ColorValue(white: 0.45)),
        ])
        let write = button("Write", "New Message", at: Point2(x: (size.width - 170) / 2, y: 760), width: 170, fill: blue, text: .white)
        let inbox = page("Inbox", fill: ColorValue(white: 0.95), [
            label("Header", "Inbox", at: Point2(x: 16, y: 80), size: 34, weight: 700), row, write,
        ])
        let back = button("Back", "‹ Inbox", at: Point2(x: 8, y: 64), width: 108, fill: ColorValue(white: 0.95), text: blue)
        let message = page("Message", fill: .white, [
            back,
            label("Subject", "Ada Lovelace", at: Point2(x: 16, y: 136), size: 28, weight: 700),
            label("Body", "The engine weaves algebraic patterns\njust as the loom weaves flowers and leaves.", at: Point2(x: 16, y: 184), color: ColorValue(white: 0.3)),
        ])
        let close = button("Close", "Cancel", at: Point2(x: 8, y: 64), width: 100, fill: ColorValue(white: 0.95), text: blue)
        let compose = page("Compose", fill: .white, [
            close,
            label("Title", "New Message", at: Point2(x: 16, y: 136), size: 28, weight: 700),
            label("Hint", "This screen came up from the bottom.", at: Point2(x: 16, y: 184), color: ColorValue(white: 0.45)),
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
        let size = LayerProperty.size.defaultValue(for: .screen).sizeValue
        let purple = ColorValue(hex: "#5E5CE6")!
        func page(_ name: String, _ children: [Layer]) -> Layer {
            var layer = Layer.newPage(name: name)
            layer.properties[.fill] = .color(ColorValue(white: 0.96))
            layer.children = children
            return layer
        }
        let card = Layer(name: "Card", kind: .view, properties: [
            .position: .point(Point2(x: 16, y: 136)), .size: .size(Size2(width: size.width - 32, height: 220)),
            .fill: .color(purple), .cornerRadius: .number(24),
            .shadowRadius: .number(16), .shadowColor: .color(ColorValue(white: 0, alpha: 0.15)),
        ])
        let feed = page("Feed", [
            label("Header", "Discover", at: Point2(x: 16, y: 72), size: 34, weight: 700),
            card,
            label("Title", "Northern Lights", at: Point2(x: 16, y: 372), size: 22, weight: 700),
            label("Hint", "Tap the card", at: Point2(x: 16, y: 404), size: 15, color: ColorValue(white: 0.45)),
        ])
        let bigCard = Layer(name: "Card", kind: .view, properties: [
            .position: .point(.zero), .size: .size(Size2(width: size.width, height: 420)),
            .fill: .color(purple), .cornerRadius: .number(0),
        ])
        let close = Layer(name: "Close", kind: .view, properties: [
            .position: .point(Point2(x: 16, y: 56)), .size: .size(Size2(width: 84, height: 40)),
            .fill: .color(ColorValue(white: 1, alpha: 0.9)), .cornerRadius: .number(20),
        ], children: [label("Label", "Close", at: Point2(x: 20, y: 10), size: 15, weight: 600)])
        let detail = page("Detail", [
            bigCard, close,
            label("Title", "Northern Lights", at: Point2(x: 16, y: 444), size: 34, weight: 700),
            label("Body", "The card grew into this screen. It has the\nsame name on both, and the flow's style\nis Morph.", at: Point2(x: 16, y: 500), size: 17, color: ColorValue(white: 0.35)),
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
        let glyph = Layer(name: "Glyph", kind: .symbol, properties: [
            .position: .point(Point2(x: 115, y: 115)), .size: .size(Size2(width: 80, height: 80)),
            .symbol: .text("mountain.2.fill"), .fill: .color(ColorValue(white: 1, alpha: 0.9)),
        ])
        let rest = Point2(x: 40, y: 250)
        let photo = Layer(name: "Photo", kind: .view, properties: [
            .position: .point(rest), .size: .size(Size2(width: 310, height: 310)),
            .fill: .color(ColorValue(hex: "#34A7A0")!), .cornerRadius: .number(32),
        ], children: [glyph])
        let hint = Layer(name: "Hint", kind: .text, properties: [
            .position: .point(Point2(x: 0, y: 600)), .size: .size(Size2(width: 390, height: 60)),
            .text: .text("Drag, pinch or twist the picture.\nHold Option for a second finger;\nShift moves both."),
            .fontSize: .number(15), .textColor: .color(ColorValue(white: 0.45)), .textAlignment: .text("Center"),
        ])
        let screen = Layer(name: "Screen", kind: .screen, properties: [
            .fill: .color(ColorValue(white: 0.96)),
        ], children: [hint, photo])

        var b = Builder(screen: screen)
        func spring(_ name: String, target: Double, at position: Point2) -> NodeID {
            b.add("spring", at: position, name: name, inputs: [
                "target": .number(target), "response": .number(0.3), "damping": .number(0.7),
            ])
        }
        let pan = b.attach(PatchKind.pan, to: photo.id, at: Point2(x: 40, y: 80))
        let travel = b.add("splitPoint", at: Point2(x: 300, y: 80))
        let x = spring("X", target: rest.x, at: Point2(x: 540, y: 80))
        let y = spring("Y", target: rest.y, at: Point2(x: 540, y: 300))
        let pinch = b.attach(PatchKind.pinch, to: photo.id, at: Point2(x: 40, y: 520))
        let size = spring("Scale", target: 1, at: Point2(x: 540, y: 520))
        let rotation = b.attach(PatchKind.rotation, to: photo.id, at: Point2(x: 40, y: 780))
        let turn = spring("Turn", target: 0, at: Point2(x: 540, y: 780))
        let view = b.view(photo.id, at: Point2(x: 800, y: 80))

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
        return PinchZoom(document: b.document, photo: photo.id, pan: pan, pinch: pinch, rotation: rotation)
    }

    public struct HoverButton {
        public let document: Document
        public let button: LayerID
        public let hover: NodeID
    }

    /// A button that lifts when a pointer rests on it, as on iPad or the web.
    public static func hoverButton() -> HoverButton {
        let buttonLabel = Layer(name: "Label", kind: .text, properties: [
            .size: .size(Size2(width: 230, height: 22)), .position: .point(Point2(x: 0, y: 19)),
            .text: .text("Point at me"), .fontWeight: .number(600), .textColor: .color(.white),
            .textAlignment: .text("Center"),
        ])
        let button = Layer(name: "Button", kind: .view, properties: [
            .position: .point(Point2(x: 80, y: 380)), .size: .size(Size2(width: 230, height: 60)),
            .fill: .color(ColorValue(hex: "#5B5BD6")!), .cornerRadius: .number(30),
            .shadowColor: .color(ColorValue(red: 0.357, green: 0.357, blue: 0.839, alpha: 0.45)), .shadowOffset: .point(Point2(x: 0, y: 8)),
        ], children: [buttonLabel])
        let screen = Layer(name: "Screen", kind: .screen, properties: [
            .fill: .color(ColorValue(white: 0.96)),
        ], children: [button])

        var b = Builder(screen: screen)
        let hover = b.attach("hover", to: button.id, at: Point2(x: 40, y: 80))
        let spring = b.add("spring", at: Point2(x: 300, y: 80), inputs: ["response": .number(0.3), "damping": .number(0.65)])
        let grow = b.add("transition", at: Point2(x: 560, y: 80), name: "Lift", type: .number, inputs: [
            "start": .number(1), "end": .number(1.08),
        ])
        let glow = b.add("transition", at: Point2(x: 560, y: 240), name: "Glow", type: .number, inputs: [
            "start": .number(0), "end": .number(18),
        ])
        let scale = b.property(.scale, of: button.id, at: Point2(x: 820, y: 80))
        let shadow = b.property(.shadowRadius, of: button.id, at: Point2(x: 820, y: 240))
        b.connect(hover, "hovering", to: spring, "target")
        b.connect(spring, "value", to: grow, "progress")
        b.connect(spring, "value", to: glow, "progress")
        b.connect(grow, "value", to: scale, "value")
        b.connect(glow, "value", to: shadow, "value")
        return HoverButton(document: b.document, button: button.id, hover: hover)
    }

    public struct StickyHeader {
        public let document: Document
        public let header: LayerID
        public let title: LayerID
        public let list: LayerID
        public static let tall: Double = 180
        public static let short: Double = 96
        public static let rowCount = 12
    }

    /// A tall header that shrinks to a bar as the list scrolls under it, then stays put.
    public static func stickyHeader() -> StickyHeader {
        typealias Header = StickyHeader
        let rows: [Layer] = (0..<Header.rowCount).map { index in
            Layer(name: "Row \(index + 1)", kind: .view, properties: [
                .size: .size(Size2(width: 100, height: 72)), .fill: .color(.white), .cornerRadius: .number(18),
                .widthMode: .text("Grow"), .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .paddingHorizontal: .number(18), .paddingVertical: .number(18),
            ], children: [Layer(name: "Title", kind: .text, properties: [
                .text: .text("Trip \(index + 1)"), .fontWeight: .number(600),
                .widthMode: .text("Auto"), .heightMode: .text("Auto"),
            ])])
        }
        // The list is a scroll view the size of the screen. An empty first row holds the
        // place of the tall header, so the rows start below it and can scroll up under it.
        let space = Layer(name: "Header Space", kind: .view, properties: [
            .size: .size(Size2(width: 100, height: Header.tall - 10)), .widthMode: .text("Grow"),
        ])
        var list = Layer.new(.scrollView, name: "List")
        list.set(.size, .size(Size2(width: 390, height: 844)))
        list.set(.spacing, .number(10))
        list.set(.paddingHorizontal, .number(16))
        list.set(.paddingVertical, .number(16))
        list.children = [space] + rows
        let header = Layer(name: "Header", kind: .view, properties: [
            .size: .size(Size2(width: 390, height: Header.tall)), .fill: .color(ColorValue(hex: "#1F2A44")!),
        ])
        let title = label("Title", "Journeys", at: Point2(x: 20, y: 116), size: 36, weight: 700, color: .white)
        let screen = Layer(name: "Screen", kind: .screen, properties: [
            .fill: .color(ColorValue(white: 0.95)),
        ], children: [list, header, title])

        var b = Builder(screen: screen)
        let scroll = b.view(list.id, at: Point2(x: 40, y: 260))
        let collapse = b.add("progress", at: Point2(x: 300, y: 260), name: "Collapse", inputs: [
            "start": .number(0), "end": .number(Header.short - Header.tall),
        ])
        let clamp = b.add("clamp", at: Point2(x: 540, y: 260))
        let height = b.add("transition", at: Point2(x: 780, y: 260), name: "Header Height", type: .size, inputs: [
            "start": .size(Size2(width: 390, height: Header.tall)), "end": .size(Size2(width: 390, height: Header.short)),
        ])
        let fontSize = b.add("transition", at: Point2(x: 780, y: 440), name: "Title Size", type: .number, inputs: [
            "start": .number(36), "end": .number(20),
        ])
        let place = b.add("transition", at: Point2(x: 780, y: 600), name: "Title Position", type: .point, inputs: [
            "start": .point(Point2(x: 20, y: 116)), "end": .point(Point2(x: 20, y: 56)),
        ])
        let headerSize = b.property(.size, of: header.id, at: Point2(x: 1040, y: 260))
        let titleSize = b.property(.fontSize, of: title.id, at: Point2(x: 1040, y: 440))
        let titlePosition = b.property(.position, of: title.id, at: Point2(x: 1040, y: 600))
        b.connect(scroll, "offset", to: collapse, "value")
        b.connect(collapse, "progress", to: clamp, "value")
        b.connect(clamp, "result", to: height, "progress")
        b.connect(clamp, "result", to: fontSize, "progress")
        b.connect(clamp, "result", to: place, "progress")
        b.connect(height, "value", to: headerSize, "value")
        b.connect(fontSize, "value", to: titleSize, "value")
        b.connect(place, "value", to: titlePosition, "value")
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

        public static let track = (x: 24.0, y: 380.0, width: 342.0)
    }

    /// A video that plays and loops by itself. A finger on the bar under it pauses it and
    /// moves its time; let go and it plays on from there. The knob follows the video.
    public static func videoScrubbing() -> VideoScrubbing {
        let track = VideoScrubbing.track
        let title = label("Title", "Scrub Through a Clip", at: Point2(x: 24, y: 96), size: 28, weight: 700)
        let clip = Layer(name: "Clip", kind: .video, properties: [
            .position: .point(Point2(x: 24, y: 152)), .size: .size(Size2(width: 342, height: 192)),
            .video: .text(VideoScrubbing.clipName), .cornerRadius: .number(16),
        ])
        let rail = Layer(name: "Track", kind: .view, properties: [
            .position: .point(Point2(x: track.x, y: track.y + 21)), .size: .size(Size2(width: track.width, height: 6)),
            .fill: .color(ColorValue(white: 0.86)), .cornerRadius: .number(3),
        ])
        let played = Layer(name: "Played", kind: .view, properties: [
            .position: .point(Point2(x: track.x, y: track.y + 21)), .size: .size(Size2(width: 0, height: 6)),
            .fill: .color(ColorValue(hex: "#3D7BF7")!), .cornerRadius: .number(3),
        ])
        let knob = Layer(name: "Knob", kind: .ellipse, properties: [
            .position: .point(Point2(x: track.x - 12, y: track.y + 12)), .size: .size(Size2(width: 24, height: 24)),
            .fill: .color(.white), .shadowRadius: .number(4), .shadowColor: .color(ColorValue(white: 0, alpha: 0.3)),
        ])
        // What the finger touches: the whole height around the thin track.
        let scrubber = Layer(name: "Scrubber", kind: .view, properties: [
            .position: .point(Point2(x: track.x, y: track.y)), .size: .size(Size2(width: track.width, height: 48)),
        ])
        let hint = label("Hint", "Drag along the bar to scrub. Let go and it plays on.", at: Point2(x: 24, y: 448),
                         size: 15, color: ColorValue(white: 0.45))
        let screen = Layer(name: "Screen", kind: .screen, properties: [
            .fill: .color(.white),
        ], children: [title, clip, rail, played, knob, scrubber, hint])

        var b = Builder(screen: screen)
        // The finger's place along the track, as seconds of the clip.
        let touch = b.interaction(on: scrubber.id, at: Point2(x: 40, y: 80))
        let split = b.add("splitPoint", at: Point2(x: 300, y: 80))
        let along = b.add("progress", at: Point2(x: 540, y: 80), name: "Along the Track", inputs: [
            "start": .number(track.x), "end": .number(track.x + track.width),
        ])
        let clamp = b.add("clamp", at: Point2(x: 780, y: 80))
        let seconds = b.add("multiply", at: Point2(x: 1020, y: 80), name: "Seconds")
        // It plays except under the finger.
        let still = b.add("not", at: Point2(x: 780, y: 320), name: "Not Touching")
        let video = b.view(clip.id, at: Point2(x: 1260, y: 80))
        // The bar follows the clip.
        let time = b.attach(PatchKind.videoTime, to: clip.id, at: Point2(x: 40, y: 480))
        let fill = b.add("transition", at: Point2(x: 540, y: 480), name: "Played Width", type: .number, inputs: [
            "start": .number(0), "end": .number(track.width),
        ])
        let slide = b.add("transition", at: Point2(x: 540, y: 660), name: "Knob X", type: .number, inputs: [
            "start": .number(track.x - 12), "end": .number(track.x + track.width - 12),
        ])
        let playedView = b.view(played.id, at: Point2(x: 1260, y: 480))
        let knobView = b.view(knob.id, at: Point2(x: 1260, y: 660))
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
        return VideoScrubbing(document: b.document, clip: clip.id, scrubber: scrubber.id, knob: knob.id, time: time)
    }
}

/// The prototypes that ship with the app, for the gallery, `papertool` and `Examples/`.
public struct GalleryItem: Identifiable, Sendable {
    public enum Section: String, Sendable, CaseIterable {
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
        GalleryItem(id: "card", title: "Card That Opens", summary: "One tap, one progress value, four properties moving together.",
                    section: .examples, fileName: "Card") { SampleDocuments.card().document },
        GalleryItem(id: "signin", title: "Typing a Name", summary: "A text field whose text drives a greeting and wakes a button.",
                    section: .examples, fileName: "SignIn") { SampleDocuments.signIn().document },
        GalleryItem(id: "search", title: "Searching a List", summary: "A search field that narrows a list as you type.",
                    section: .examples, fileName: "SearchList") { SampleDocuments.searchList().document },
        GalleryItem(id: "people", title: "List from a Loop", summary: "One row, repeated for every name, that knows which was tapped.",
                    section: .examples, fileName: "People") { SampleDocuments.people().document },
        GalleryItem(id: "live", title: "List from Live Data", summary: "A network request with loading, success and failure states.",
                    section: .examples, fileName: "LiveList") { SampleDocuments.liveList().document },
        GalleryItem(id: "controls", title: "iOS Controls", summary: "The prebuilt switch, slider, stepper, button and tab bar, wired up.",
                    section: .examples, fileName: "Controls") { SampleDocuments.controls().document },
        GalleryItem(id: "kit", title: "Settings from the Shelf", summary: "A whole screen from the iOS components: bars, grouped rows, a switch, an alert. Three cables.",
                    section: .examples, fileName: "SystemKit") { SampleDocuments.systemKit().document },
        GalleryItem(id: "camera", title: "Camera with Feedback", summary: "A viewfinder with a shutter, a haptic and a sound.",
                    section: .examples, fileName: "Camera") { SampleDocuments.camera().document },
        GalleryItem(id: "sheet", title: "Bottom Sheet", summary: "Follows a finger, then settles open or closed on release.",
                    section: .patterns, fileName: "Sheet") { SampleDocuments.sheet().document },
        GalleryItem(id: "list", title: "Scrolling List", summary: "A stack that scrolls with physics and fades its header.",
                    section: .patterns, fileName: "List") { SampleDocuments.scrollingList().document },
        GalleryItem(id: "header", title: "Sticky Header", summary: "A tall header that shrinks to a bar as the list scrolls.",
                    section: .patterns, fileName: "StickyHeader") { SampleDocuments.stickyHeader().document },
        GalleryItem(id: "swipe", title: "Swipe Menu", summary: "A row that slides aside on a swipe to show an action.",
                    section: .patterns, fileName: "SwipeMenu") { SampleDocuments.swipeMenu().document },
        GalleryItem(id: "flow", title: "Screens and Flows", summary: "Three screens: a row pushes one in, a button brings one up, and each goes back.",
                    section: .patterns, fileName: "ScreenFlow") { SampleDocuments.screenFlow().document },
        GalleryItem(id: "morph", title: "Card to Screen", summary: "A card grows into its own screen and back: views named the same move between screens.",
                    section: .patterns, fileName: "MorphingCard") { SampleDocuments.morphingCard().document },
        GalleryItem(id: "pinch", title: "Pinch to Zoom", summary: "Fingers move, zoom and turn a picture at once; it springs back.",
                    section: .patterns, fileName: "PinchZoom") { SampleDocuments.pinchZoom().document },
        GalleryItem(id: "hover", title: "Hover Highlight", summary: "A button that lifts when a pointer rests on it.",
                    section: .patterns, fileName: "HoverButton") { SampleDocuments.hoverButton().document },
        GalleryItem(id: "aurora", title: "Shader Background", summary: "A background drawn by Metal code, with an input a tap drives.",
                    section: .patterns, fileName: "ShaderBackground") { SampleDocuments.shaderBackground().document },
        GalleryItem(id: "lens", title: "Shader Lens", summary: "A shader over ordinary views: a glass lens that follows a finger.",
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
