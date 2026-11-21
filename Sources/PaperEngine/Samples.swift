import Foundation
import PaperModel

/// The spec's example prototypes, built in code. They back the tests, the app's
/// "New from Example" menu, and the files in `Examples/`.
public enum SampleDocuments {
    /// Small helper for wiring a graph by port name.
    ///
    /// Every layer has a view patch from the start. `view(_:at:)` and `property(_:of:at:)`
    /// give one a place; the view patches nobody placed are lined up to the right of the
    /// rest whenever the document is read.
    public struct Builder {
        private var storage: Document
        private var placed: Set<LayerID> = []
        /// What `property` handed out: each stands for one input of a view patch.
        private var handles: [NodeID: PortRef] = [:]
        /// Comments to draw around patches once they are all in their places.
        private var notes: [(id: UUID, text: String, around: [NodeID])] = []

        public var document: Document {
            get {
                var result = storage
                let measure = PatchRegistry.standard.with(components: storage.components).height
                result.arrangeViews(of: Set(result.screen.flattened.map(\.id)).subtracting(placed), measure: measure)
                result.separateViews(of: placed, measure: measure)
                for note in notes {
                    // Views' patches (a component's too) are moved about to keep them apart,
                    // so the comment is drawn round the patches that do the work.
                    let all = note.around.compactMap { result.graph.node(handles[$0]?.node ?? $0) }
                    let working = all.filter { $0.kind != PatchKind.view }
                    let nodes = working.isEmpty ? all : working
                    guard !nodes.isEmpty else { continue }
                    let left = nodes.map(\.position.x).min()!, top = nodes.map(\.position.y).min()!
                    let right = nodes.map { $0.position.x + PatchGrid.nodeWidth }.max()!
                    let bottom = nodes.map { $0.position.y + measure($0) }.max()!
                    result.graph.comments.append(GraphComment(
                        id: note.id, text: note.text, origin: Point2(x: left - 24, y: top - 48),
                        size: Size2(width: right - left + 48, height: bottom - top + 72)
                    ))
                }
                // Each patch goes in the level of the views it works on.
                result.settleHomes()
                return result
            }
            set {
                storage = newValue
                // The comments `note` draws are drawn again on every read.
                let drawn = Set(notes.map(\.id))
                storage.graph.comments.removeAll { drawn.contains($0.id) }
                storage.normalize()
            }
        }

        /// A screen with no size is given the iPhone 18 Pro's, as a new document is.
        public init(screen: Layer) {
            var screen = screen
            if screen.kind == .screen, screen.properties[.size] == nil {
                screen.properties[.size] = .size(ExampleStyle.device)
            }
            storage = Document(screen: screen)
            storage.normalize()
        }

        @discardableResult
        public mutating func add(
            _ kind: String,
            at position: Point2,
            name: String? = nil,
            type: PortType? = nil,
            inputs: [String: Value] = [:]
        ) -> NodeID {
            storage.graph.add(PatchNode(kind: kind, position: PatchGrid.snap(position), name: name, inputs: inputs, valueType: type))
        }

        @discardableResult
        public mutating func interaction(on layer: LayerID, at position: Point2) -> NodeID {
            storage.graph.add(.interaction(on: layer, position: PatchGrid.snap(position)))
        }

        /// The view patch of a layer. The first place given for it is where it goes.
        @discardableResult
        public mutating func view(_ layer: LayerID, at position: Point2? = nil) -> NodeID {
            let id = storage.graph.viewNode(layer: layer)?.id ?? storage.graph.add(.view(of: layer))
            if let position, placed.insert(layer).inserted {
                storage.graph.update(id) { $0.position = PatchGrid.snap(position) }
            }
            return id
        }

        /// An input of a layer's view patch, to connect to as port "value".
        @discardableResult
        public mutating func property(_ property: LayerProperty, of layer: LayerID, at position: Point2) -> NodeID {
            let handle = NodeID()
            handles[handle] = PortRef(node: view(layer, at: position), port: property.rawValue)
            return handle
        }

        /// A comment drawn round these patches (or `property` handles), saying what they do
        /// together. Its place is worked out once every patch has its own.
        public mutating func note(_ text: String, around nodes: [NodeID]) {
            notes.append((UUID(), text, nodes))
        }

        /// The view patch input a handle from `property` stands for.
        public func input(_ handle: NodeID) -> PortRef {
            handles[handle] ?? PortRef(node: handle, port: "value")
        }

        public mutating func connect(_ from: NodeID, _ output: String, to: NodeID, _ input: String) {
            let target = input == "value" ? handles[to] ?? PortRef(node: to, port: input) : PortRef(node: to, port: input)
            storage.graph.connect(from: PortRef(node: from, port: output), to: target)
        }
    }

    public struct Card {
        public let document: Document
        public let card: LayerID
        public let dim: LayerID
        public let close: LayerID
        public let spring: NodeID
        public let expanded: NodeID

        public static let collapsedSize = Size2(width: 362, height: 350)
        public static let expandedSize = ExampleStyle.device
        public static let collapsedPosition = Point2(x: 20, y: 150)
        public static let expandedPosition = Point2.zero
    }

    /// Example A: a card that opens into a whole story and closes again. One tap flips a
    /// switch, a spring turns it into one progress value, and that value drives the card's
    /// place, size and corners, the dimming behind it and the close button, together.
    public static func card() -> Card {
        typealias S = ExampleStyle
        let header = Layer(name: "Header", kind: .view, properties: [
            .size: .size(Size2(width: S.device.width, height: 140)),
        ], children: S.header("Tuesday, November 21", "Discover"))
        let thumbnail = S.scene("Thumbnail", size: Size2(width: 72, height: 72), sky: S.sky,
                                hills: (ColorValue(hex: "#8FD0B0")!, S.sage), subject: "tram.fill", radius: 14)
        var thumb = thumbnail
        thumb.properties[.position] = .point(Point2(x: 12, y: 12))
        let row = Layer(name: "Row", kind: .view, properties: [
            .position: .point(Point2(x: 20, y: 520)), .size: .size(Size2(width: S.column, height: 96)),
            .fill: .color(S.surface), .cornerRadius: .number(22),
        ], children: [
            thumb,
            S.text("Next Title", "Lisbon by Tram", at: Point2(x: 100, y: 26), weight: 600),
            S.text("Next Detail", "Up next · 8 min read", at: Point2(x: 100, y: 50), size: 15, color: S.secondary),
        ])
        let dim = Layer(name: "Dim", kind: .view, properties: [
            .size: .size(S.device), .fill: .color(S.ink), .opacity: .number(0),
        ])
        // The card holds the whole story; while it is small it clips all but the top.
        var picture = S.scene("Picture", size: Size2(width: 440, height: 240), sky: ColorValue(hex: "#FFB27A")!,
                              hills: (ColorValue(hex: "#E0674A")!, ColorValue(hex: "#9E3B33")!),
                              sun: ColorValue(hex: "#FFF1C9")!, subject: "leaf.fill")
        picture.properties[.position] = .point(Point2(x: -20, y: 0))
        let body = """
        The maples turn first on the hills above the city. By the middle of November the \
        paths of the temples are red and gold, and the mornings are cold enough to see your breath.

        Go early. The light comes low through the trees, and for an hour the gardens belong \
        to the people who sweep them.
        """
        let card = Layer(name: "Card", kind: .view, properties: [
            .position: .point(Card.collapsedPosition), .size: .size(Card.collapsedSize),
            .fill: .color(S.surface), .cornerRadius: .number(28), .clips: .bool(true),
            .shadowColor: .color(S.shadow), .shadowRadius: .number(24), .shadowOffset: .point(Point2(x: 0, y: 12)),
        ], children: [
            picture,
            S.text("Place", "KYOTO, JAPAN", at: Point2(x: 20, y: 258), size: 13, weight: 600, color: S.coral),
            S.text("Headline", "Autumn in Kyoto", at: Point2(x: 20, y: 278), size: 26, weight: 700),
            S.text("Byline", "12 min read · Mika Ito", at: Point2(x: 20, y: 314), size: 15, color: S.secondary),
            S.text("Story", body, at: Point2(x: 20, y: 362), size: 17, color: ColorValue(hex: "#3A3940")!, width: S.column, height: 360),
        ])
        let close = S.roundButton("Close", symbol: "xmark", at: Point2(x: S.device.width - 56, y: S.top + 10))
        var closed = close
        closed.properties[.opacity] = .number(0)
        let screen = Layer(name: "Screen", kind: .screen, properties: [
            .fill: .color(S.paper),
        ], children: [header, row, S.hint("Tap the card to open it, and again to close it"), dim, card, closed])

        var b = Builder(screen: screen)
        let touch = b.interaction(on: card.id, at: Point2(x: 48, y: 96))
        let expanded = b.add("switch", at: Point2(x: 336, y: 96), name: "Open")
        let spring = b.add("spring", at: Point2(x: 624, y: 96), inputs: [
            "response": .number(0.5), "damping": .number(0.82),
        ])
        let position = b.add("transition", at: Point2(x: 912, y: 96), name: "Card Position", type: .point, inputs: [
            "start": .point(Card.collapsedPosition), "end": .point(Card.expandedPosition),
        ])
        let size = b.add("transition", at: Point2(x: 912, y: 264), name: "Card Size", type: .size, inputs: [
            "start": .size(Card.collapsedSize), "end": .size(Card.expandedSize),
        ])
        let corners = b.add("transition", at: Point2(x: 912, y: 432), name: "Corners", type: .number, inputs: [
            "start": .number(28), "end": .number(0),
        ])
        let dimming = b.add("transition", at: Point2(x: 912, y: 600), name: "Dimming", type: .number, inputs: [
            "start": .number(0), "end": .number(0.4),
        ])
        let cardPosition = b.property(.position, of: card.id, at: Point2(x: 1200, y: 96))
        let cardSize = b.property(.size, of: card.id, at: Point2(x: 1200, y: 96))
        let cardCorners = b.property(.cornerRadius, of: card.id, at: Point2(x: 1200, y: 96))
        let dimOpacity = b.property(.opacity, of: dim.id, at: Point2(x: 1200, y: 600))
        let closeOpacity = b.property(.opacity, of: close.id, at: Point2(x: 1200, y: 768))

        b.connect(touch, "tap", to: expanded, "flip")
        b.connect(expanded, "on", to: spring, "target")
        b.connect(spring, "value", to: position, "progress")
        b.connect(spring, "value", to: size, "progress")
        b.connect(spring, "value", to: corners, "progress")
        b.connect(spring, "value", to: dimming, "progress")
        b.connect(position, "value", to: cardPosition, "value")
        b.connect(size, "value", to: cardSize, "value")
        b.connect(corners, "value", to: cardCorners, "value")
        b.connect(dimming, "value", to: dimOpacity, "value")
        b.connect(spring, "value", to: closeOpacity, "value")

        b.note("Tap · Each tap flips Open on or off", around: [touch, expanded])
        b.note("Spring · Glides 0 to 1", around: [spring])
        b.note("Mapping · One value, four properties", around: [position, size, corners, dimming])

        return Card(document: b.document, card: card.id, dim: dim.id, close: close.id, spring: spring, expanded: expanded)
    }

    public struct Sheet {
        public let document: Document
        public let sheet: LayerID
        public let dim: LayerID
        public let spring: NodeID

        public static let closedY: Double = 624
        public static let openY: Double = 120
        public static let threshold: Double = 372
    }

    /// Example B: a sheet over a map that follows a finger, then settles open or closed
    /// when the finger lifts, whichever it is nearer.
    public static func sheet() -> Sheet {
        typealias S = ExampleStyle
        // A map drawn with views: blocks, streets, a park, the river and a few pins.
        func block(_ name: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ color: ColorValue, radius: Double = 10, turn: Double = 0) -> Layer {
            Layer(name: name, kind: .view, properties: [
                .position: .point(Point2(x: x, y: y)), .size: .size(Size2(width: w, height: h)),
                .fill: .color(color), .cornerRadius: .number(radius), .rotation: .number(turn),
            ])
        }
        let street = S.surface
        func pin(_ name: String, _ x: Double, _ y: Double, _ color: ColorValue) -> Layer {
            Layer(name: name, kind: .view, properties: [
                .position: .point(Point2(x: x, y: y)), .size: .size(Size2(width: 34, height: 34)), .cornerRadius: .number(17),
                .fill: .color(color), .strokeColor: .color(.white), .strokeWidth: .number(3),
                .shadowColor: .color(S.shadow), .shadowRadius: .number(6), .shadowOffset: .point(Point2(x: 0, y: 3)),
                .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .distribution: .text("Center"),
            ], children: [S.symbol("Cup", "cup.and.saucer.fill", side: 15, color: .white)])
        }
        let content = Layer(name: "Map", kind: .view, properties: [
            .size: .size(S.device), .fill: .color(ColorValue(hex: "#ECE7DD")!), .clips: .bool(true),
        ], children: [
            block("Park", 210, 150, 230, 210, ColorValue(hex: "#C9E3C0")!, radius: 40),
            block("River", -60, 440, 560, 90, ColorValue(hex: "#BFDDF2")!, radius: 45, turn: -12),
            block("Avenue", -40, 300, 520, 22, street, radius: 0, turn: -12),
            block("Street", 120, -40, 22, 700, street, radius: 0, turn: 8),
            block("Lane", -40, 610, 520, 14, street, radius: 0, turn: 6),
            block("Road", 300, 380, 16, 600, street, radius: 0, turn: -4),
            pin("Pin 1", 72, 200, S.coral), pin("Pin 2", 260, 248, S.coral), pin("Pin 3", 180, 400, S.coral),
            pin("Pin 4", 320, 520, S.coral),
            Layer(name: "You", kind: .ellipse, properties: [
                .position: .point(Point2(x: 176, y: 300)), .size: .size(Size2(width: 22, height: 22)),
                .fill: .color(S.accent), .strokeColor: .color(.white), .strokeWidth: .number(4),
            ]),
        ])
        let search = Layer(name: "Search", kind: .view, properties: [
            .position: .point(Point2(x: S.margin, y: S.top + 8)), .size: .size(Size2(width: S.column, height: 48)),
            .fill: .color(S.surface), .cornerRadius: .number(24),
            .shadowColor: .color(S.shadow), .shadowRadius: .number(12), .shadowOffset: .point(Point2(x: 0, y: 4)),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .spacing: .number(10),
            .paddingHorizontal: .number(18), .paddingVertical: .number(0),
        ], children: [
            S.symbol("Glass", "magnifyingglass", side: 17, color: S.secondary, weight: 600),
            S.text("Query", "Coffee near you", color: S.secondary),
        ])
        let dim = Layer(name: "Dim", kind: .view, properties: [
            .size: .size(S.device), .fill: .color(S.ink), .opacity: .number(0),
        ])
        let handle = Layer(name: "Handle", kind: .view, properties: [
            .position: .point(Point2(x: (S.device.width - 40) / 2, y: 8)), .size: .size(Size2(width: 40, height: 5)),
            .fill: .color(S.hairline), .cornerRadius: .number(2.5),
        ])
        let places: [(String, String, ColorValue)] = [
            ("Little Wren", "Espresso bar · 3 min walk", S.coral), ("Fold & Pour", "Pour-over · 6 min walk", S.amber),
            ("Common Ground", "Café and bakery · 9 min walk", S.sage), ("Night Owl", "Open till 11 · 12 min walk", S.plum),
            ("Paper Cup", "Takeaway · 14 min walk", S.sky),
        ]
        let rows: [Layer] = places.enumerated().map { index, place in
            Layer(name: "Place \(index + 1)", kind: .view, properties: [
                .size: .size(Size2(width: 100, height: 72)), .widthMode: .text("Grow"),
                .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .spacing: .number(14),
            ], children: [
                Layer(name: "Icon", kind: .view, properties: [
                    .size: .size(Size2(width: 48, height: 48)), .cornerRadius: .number(14), .fill: .color(place.2),
                    .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .distribution: .text("Center"),
                ], children: [S.symbol("Cup", "cup.and.saucer.fill", side: 22, color: .white)]),
                Layer(name: "Words", kind: .view, properties: [
                    .widthMode: .text("Grow"), .heightMode: .text("Auto"), .layout: .text("Stack"), .spacing: .number(2),
                ], children: [
                    S.text("Name", place.0, weight: 600),
                    S.text("Detail", place.1, size: 15, color: S.secondary),
                ]),
            ])
        }
        let list = Layer(name: "Places", kind: .view, properties: [
            .position: .point(Point2(x: S.margin, y: 96)), .size: .size(Size2(width: S.column, height: 400)),
            .layout: .text("Stack"), .heightMode: .text("Auto"),
        ], children: rows)
        let sheet = Layer(name: "Sheet", kind: .view, properties: [
            .position: .point(Point2(x: 0, y: Sheet.closedY)),
            .size: .size(Size2(width: S.device.width, height: S.device.height - Sheet.openY + 40)),
            .fill: .color(S.surface), .cornerRadius: .number(32),
            .shadowColor: .color(ColorValue(white: 0, alpha: 0.14)), .shadowRadius: .number(24), .shadowOffset: .point(Point2(x: 0, y: -4)),
        ], children: [
            handle,
            S.text("Title", "Coffee nearby", at: Point2(x: S.margin, y: 30), size: 24, weight: 700),
            S.text("Subtitle", "5 places open now", at: Point2(x: S.margin, y: 62), size: 15, color: S.secondary),
            list,
        ])
        let screen = Layer(name: "Screen", kind: .screen, properties: [
            .fill: .color(S.paper),
        ], children: [content, search, S.hint("Drag the sheet up, then let go", symbol: "hand.draw.fill", y: Sheet.closedY - 52), dim, sheet])

        var b = Builder(screen: screen)
        let touch = b.interaction(on: sheet.id, at: Point2(x: 48, y: 96))
        let edges = b.add("pulse", at: Point2(x: 336, y: 96), name: "Touch Began / Ended")
        let dragY = b.add("splitPoint", at: Point2(x: 336, y: 288), name: "Drag Y")
        let isAbove = b.add("less", at: Point2(x: 624, y: 504), name: "Past Halfway", inputs: [
            "b": .number(Sheet.threshold),
        ])
        let open = b.add("sampleHold", at: Point2(x: 912, y: 504), name: "Open", type: .bool)
        let destination = b.add("if", at: Point2(x: 1200, y: 504), name: "Destination", type: .number, inputs: [
            "then": .number(Sheet.openY), "else": .number(Sheet.closedY),
        ])
        let spring = b.add("spring", at: Point2(x: 624, y: 96), inputs: [
            "response": .number(0.4), "damping": .number(0.85),
        ])
        let point = b.add("makePoint", at: Point2(x: 912, y: 96))
        let sheetPosition = b.property(.position, of: sheet.id, at: Point2(x: 1200, y: 96))
        let progress = b.add("progress", at: Point2(x: 912, y: 756), name: "How Open", inputs: [
            "start": .number(Sheet.closedY), "end": .number(Sheet.openY),
        ])
        let dimming = b.add("transition", at: Point2(x: 1200, y: 756), name: "Dimming", type: .number, inputs: [
            "start": .number(0), "end": .number(0.35),
        ])
        let dimOpacity = b.property(.opacity, of: dim.id, at: Point2(x: 1488, y: 756))

        b.connect(touch, "down", to: edges, "value")
        b.connect(touch, "drag", to: dragY, "point")
        b.connect(touch, "down", to: spring, "hold")
        // While the finger is down the spring moves with the drag, from wherever it was grabbed.
        b.connect(dragY, "y", to: spring, "held")
        // On release, pick a destination from where the sheet is.
        b.connect(spring, "value", to: isAbove, "a")
        b.connect(isAbove, "result", to: open, "value")
        b.connect(edges, "turnedOff", to: open, "sample")
        b.connect(open, "value", to: destination, "condition")
        b.connect(destination, "value", to: spring, "target")
        b.connect(spring, "value", to: point, "y")
        b.connect(point, "point", to: sheetPosition, "value")
        b.connect(spring, "value", to: progress, "value")
        b.connect(progress, "progress", to: dimming, "progress")
        b.connect(dimming, "value", to: dimOpacity, "value")

        b.note("Follow · While held, the spring tracks the finger", around: [touch, edges, dragY, spring, point])
        b.note("Settle · On release, go to the nearer end", around: [isAbove, open, destination])
        b.note("Dim · The map darkens as it opens", around: [progress, dimming])

        return Sheet(document: b.document, sheet: sheet.id, dim: dim.id, spring: spring)
    }

    public struct ScrollingList {
        public let document: Document
        public let list: LayerID
        public let rows: [LayerID]
        public let scroll: NodeID

        public static let rowCount = 14
        public static let rowHeight: Double = 76
        public static let spacing: Double = 10
        public static let padding: Double = 16
        /// Where the list starts, below the header.
        public static let top: Double = 124
        /// How long the list's content is: more than fits, so it scrolls.
        public static var contentHeight: Double {
            padding * 2 + Double(rowCount) * rowHeight + Double(rowCount - 1) * spacing
        }
        public static let messages: [(sender: String, subject: String, time: String)] = [
            ("Mika Ito", "Photos from Kyoto", "9:41"), ("Sam Okafor", "Re: Friday's plan", "9:12"),
            ("Lena Park", "The deck, with your notes", "8:55"), ("Theo Grant", "Lunch?", "8:30"),
            ("Ines Duarte", "Your order has shipped", "Yesterday"), ("Noah Kim", "Climbing on Sunday", "Yesterday"),
            ("Ava Brooks", "Draft for the newsletter", "Yesterday"), ("Ravi Shah", "Quick question", "Mon"),
            ("Zoe Martin", "Tickets for the 14th", "Mon"), ("Omar Haddad", "Notes from the review", "Sun"),
            ("Ella Novak", "Recipe you asked for", "Sat"), ("Jon Reyes", "Re: The cabin", "Sat"),
            ("Mia Chen", "Moving day!", "Fri"), ("Leo Rossi", "Thanks again", "Thu"),
        ]
    }

    /// A scroll view of messages. Rows grow to the list's width, and a Send and a Receive
    /// carry the scroll offset to the title, which fades as the list is pulled down.
    public static func scrollingList() -> ScrollingList {
        typealias List = ScrollingList
        typealias S = ExampleStyle
        let colors = [S.coral, S.sky, S.sage, S.plum, S.amber, S.teal, S.rose]
        let rows: [Layer] = (0..<List.rowCount).map { index in
            let message = List.messages[index % List.messages.count]
            let initials = message.sender.split(separator: " ").compactMap(\.first).map(String.init).joined()
            let words = Layer(name: "Words", kind: .view, properties: [
                .widthMode: .text("Grow"), .heightMode: .text("Auto"), .layout: .text("Stack"), .spacing: .number(3),
            ], children: [
                S.text("Title", message.sender, weight: 600),
                S.text("Subject", message.subject, size: 15, color: S.secondary),
            ])
            return Layer(name: "Row \(index + 1)", kind: .view, properties: [
                .size: .size(Size2(width: 100, height: List.rowHeight)),
                .fill: .color(S.surface), .cornerRadius: .number(20),
                .widthMode: .text("Grow"),
                .layout: .text("Stack"), .axis: .text("Horizontal"),
                .alignment: .text("Center"), .spacing: .number(14),
                .paddingHorizontal: .number(16), .paddingVertical: .number(16),
            ], children: [
                S.avatar(initials: initials, color: colors[index % colors.count], side: 44),
                words,
                S.text("Time", message.time, size: 13, color: S.tertiary),
            ])
        }
        // The list is a scroll view filling the screen below the header. How far it
        // scrolls follows from how long its rows are; nothing is typed in.
        let top = List.top
        var list = Layer.new(.scrollView, name: "List")
        list.set(.position, .point(Point2(x: 0, y: top)))
        list.set(.size, .size(Size2(width: S.device.width, height: S.device.height - top)))
        list.set(.spacing, .number(List.spacing))
        list.set(.paddingHorizontal, .number(List.padding))
        list.set(.paddingVertical, .number(List.padding))
        list.children = rows
        let header = Layer(name: "Header", kind: .view, properties: [
            .size: .size(Size2(width: S.device.width, height: top)), .fill: .color(ColorValue(white: 1, alpha: 0)),
        ], children: S.header("14 unread", "Inbox"))
        let screen = Layer(name: "Screen", kind: .screen, properties: [
            .fill: .color(S.paper),
        ], children: [list, header, S.hint("Drag the list up and down", symbol: "hand.draw.fill")])

        var b = Builder(screen: screen)
        let scroll = b.view(list.id, at: Point2(x: 48, y: 96))
        let send = b.add("broadcast", at: Point2(x: 336, y: 96), type: .number, inputs: ["name": .text("Scroll Offset")])
        let receive = b.add("receive", at: Point2(x: 48, y: 408), type: .number, inputs: ["name": .text("Scroll Offset")])
        let fade = b.add("progress", at: Point2(x: 336, y: 408), name: "Header Fade", inputs: [
            "start": .number(-60), "end": .number(0),
        ])
        let clamp = b.add("clamp", at: Point2(x: 624, y: 408))
        let opacity = b.property(.opacity, of: header.id, at: Point2(x: 912, y: 408))

        b.connect(scroll, "offset", to: send, "value")
        b.connect(receive, "value", to: fade, "value")
        b.connect(fade, "progress", to: clamp, "value")
        b.connect(clamp, "result", to: opacity, "value")

        b.note("Send · The scroll offset", around: [scroll, send])
        b.note("Receive · Pulled down, the title fades out", around: [receive, fade, clamp])

        return ScrollingList(document: b.document, list: list.id, rows: rows.map(\.id), scroll: scroll)
    }

    public struct People {
        public let document: Document
        public let row: LayerID
        public let title: LayerID
        public let header: LayerID
        public let names: NodeID
        public let selection: NodeID

        public static let names = ["Ada", "Grace", "Linus", "Margaret", "Alan", "Barbara"]
        public static let colors = ["#FF7059", "#5AA9FF", "#5DB48A", "#8466F5", "#FFB340", "#F2678E"]
        public static let rowHeight: Double = 64
        public static let spacing: Double = 10
        public static let padding: Double = 20
        public static let top: Double = 140
    }

    /// A list described by a rule instead of drawn row by row: one Row view, repeated by a
    /// loop over an array of names. Tapping a row selects it; the graph knows which one,
    /// and the title says who.
    public static func people() -> People {
        typealias S = ExampleStyle
        let title = Layer(name: "Name", kind: .text, properties: [
            .fontSize: .number(17), .fontWeight: .number(600), .textColor: .color(S.ink),
            .widthMode: .text("Grow"), .heightMode: .text("Auto"),
        ])
        let avatar = Layer(name: "Avatar", kind: .view, properties: [
            .size: .size(Size2(width: 36, height: 36)), .cornerRadius: .number(18), .fill: .color(S.coral),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .distribution: .text("Center"),
        ], children: [S.symbol("Person", "person.fill", side: 17, color: .white)])
        let check = S.symbol("Check", "checkmark", side: 18, color: .white, weight: 700)
        var checkHidden = check
        checkHidden.properties[.opacity] = .number(0)
        let row = Layer(name: "Row", kind: .view, properties: [
            .size: .size(Size2(width: 100, height: People.rowHeight)),
            .fill: .color(S.surface), .cornerRadius: .number(20),
            .widthMode: .text("Grow"),
            .layout: .text("Stack"), .axis: .text("Horizontal"),
            .alignment: .text("Center"), .spacing: .number(14),
            .paddingHorizontal: .number(14), .paddingVertical: .number(14),
        ], children: [avatar, title, checkHidden])
        let list = Layer(name: "List", kind: .view, properties: [
            .position: .point(Point2(x: 0, y: People.top)),
            .size: .size(Size2(width: S.device.width, height: 100)),
            .layout: .text("Stack"),
            .spacing: .number(People.spacing),
            .paddingHorizontal: .number(People.padding), .paddingVertical: .number(0),
            .heightMode: .text("Auto"),
        ], children: [row])
        let header = S.text("Header", "Ada", at: Point2(x: S.margin, y: S.top + 34), size: 34, weight: 700)
        let kicker = S.text("Kicker", "TONIGHT'S HOST", at: Point2(x: S.margin, y: S.top + 14), size: 13, weight: 600, color: S.secondary)
        let screen = Layer(name: "Screen", kind: .screen, properties: [
            .fill: .color(S.paper),
        ], children: [list, kicker, header, S.hint("Tap a name to choose them")])

        var b = Builder(screen: screen)
        let names = b.add("splitText", at: Point2(x: 48, y: 96), name: "Names", inputs: [
            "text": .text(People.names.joined(separator: ", ")),
        ])
        let each = b.add("loopOverArray", at: Point2(x: 336, y: 96), type: .text)
        let colors = b.add("splitText", at: Point2(x: 48, y: 264), name: "Colors", inputs: [
            "text": .text(People.colors.joined(separator: ", ")),
        ])
        let eachColor = b.add("loopOverArray", at: Point2(x: 336, y: 264), type: .color)
        let text = b.property(.text, of: title.id, at: Point2(x: 1488, y: 96))
        let avatarFill = b.property(.fill, of: avatar.id, at: Point2(x: 1488, y: 264))

        let touch = b.interaction(on: row.id, at: Point2(x: 48, y: 480))
        let selection = b.add("loopOptionSwitch", at: Point2(x: 336, y: 480), name: "Selected Row")
        let isSelected = b.add("equal", at: Point2(x: 624, y: 480), name: "Is Selected")
        let spring = b.add("spring", at: Point2(x: 912, y: 480), inputs: ["response": .number(0.3), "damping": .number(0.85)])
        let fill = b.add("transition", at: Point2(x: 1200, y: 480), name: "Row Color", type: .color, inputs: [
            "start": .color(S.surface), "end": .color(S.accent),
        ])
        let ink = b.add("transition", at: Point2(x: 1200, y: 648), name: "Name Color", type: .color, inputs: [
            "start": .color(S.ink), "end": .color(.white),
        ])
        let rowFill = b.property(.fill, of: row.id, at: Point2(x: 1488, y: 480))
        let textColor = b.property(.textColor, of: title.id, at: Point2(x: 1488, y: 96))
        let checkOpacity = b.property(.opacity, of: check.id, at: Point2(x: 1488, y: 840))

        let chosen = b.add("loopSelect", at: Point2(x: 624, y: 1008), name: "Selected Name", type: .text)
        let headerText = b.property(.text, of: header.id, at: Point2(x: 912, y: 1008))

        b.connect(names, "array", to: each, "array")
        b.connect(each, "value", to: text, "value")
        b.connect(colors, "array", to: eachColor, "array")
        b.connect(eachColor, "value", to: avatarFill, "value")
        b.connect(touch, "tap", to: selection, "set")
        b.connect(each, "index", to: isSelected, "a")
        b.connect(selection, "option", to: isSelected, "b")
        b.connect(isSelected, "result", to: spring, "target")
        b.connect(spring, "value", to: fill, "progress")
        b.connect(spring, "value", to: ink, "progress")
        b.connect(spring, "value", to: checkOpacity, "value")
        b.connect(fill, "value", to: rowFill, "value")
        b.connect(ink, "value", to: textColor, "value")
        b.connect(each, "value", to: chosen, "loop")
        b.connect(selection, "option", to: chosen, "index")
        b.connect(chosen, "value", to: headerText, "value")

        b.note("Loop · One row per name", around: [names, each, colors, eachColor])
        b.note("Select · The tapped row remembers it is chosen", around: [touch, selection, isSelected, spring, fill, ink])
        b.note("Read · The chosen name", around: [chosen])

        return People(
            document: b.document, row: row.id, title: title.id, header: header.id,
            names: names, selection: selection
        )
    }

    public struct Controls {
        public let document: Document
        public let toggle: LayerID
        public let slider: LayerID
        public let stepper: LayerID
        public let segments: LayerID
        public let button: LayerID
        public let tabBar: LayerID
        public let wifiRow: LayerID
        public let brightness: LayerID
        public let count: LayerID
        public let nodes: [String: NodeID]
    }

    /// A screen assembled from the prebuilt iOS components and wired together: the toggle
    /// changes a row's detail, the slider and stepper drive labels, the button changes its
    /// own title and the tab bar renames the navigation bar.
    public static func controls() -> Controls {
        typealias Library = ComponentLibrary
        typealias S = ExampleStyle
        let width = S.device.width - 32
        let gray = ColorValue(hex: "#8E8E93")!
        let screen = Layer(name: "Screen", kind: .screen, properties: [
            .fill: .color(ColorValue(hex: "#F2F2F7")!),
        ])
        var b = Builder(screen: screen)
        func label(_ name: String, _ string: String, at point: Point2, color: ColorValue = .black, size: Double = 17, weight: Double = 400) -> Layer {
            S.text(name, string, at: point, size: size, weight: weight, color: color)
        }
        func caption(_ name: String, _ string: String, y: Double) {
            b.document.screen.insert(label(name, string.uppercased(), at: Point2(x: 32, y: y), color: gray, size: 13), into: screen.id)
        }

        let bar = b.place(Library.iOS("Navigation Bar"), at: Point2(x: 0, y: S.top), inputs: [
            "Title": .text("Settings"), "Shows Back": .bool(false),
        ], patchAt: Point2(x: 1200, y: 1104))

        // A grouped table: one hand-built row holding a Toggle, then two List Rows.
        caption("Network Caption", "Network", y: 124)
        let wifiLabel = Layer(name: "Wi-Fi Label", kind: .text, properties: [
            .text: .text("Wi-Fi"), .fontSize: .number(17), .widthMode: .text("Grow"), .heightMode: .text("Auto"),
        ])
        let wifiRow = Layer(name: "Wi-Fi Row", kind: .view, properties: [
            .size: .size(Size2(width: width, height: 52)), .widthMode: .text("Grow"), .layout: .text("Stack"), .axis: .text("Horizontal"),
            .alignment: .text("Center"), .paddingHorizontal: .number(16), .paddingVertical: .number(16),
        ], children: [wifiLabel])
        let table = Layer(name: "Table", kind: .view, properties: [
            .position: .point(Point2(x: 16, y: 146)), .size: .size(Size2(width: width, height: 100)),
            .fill: .color(.white), .cornerRadius: .number(26), .clips: .bool(true),
            .layout: .text("Stack"), .heightMode: .text("Auto"),
        ], children: [wifiRow])
        b.document.screen.insert(table, into: screen.id)
        let toggle = b.place(Library.iOS("Toggle"), in: wifiRow.id, inputs: ["On": .bool(true)], patchAt: Point2(x: 48, y: 96))
        let network = b.place(Library.iOS("List Row"), name: "Network Row", in: table.id, inputs: [
            "Title": .text("Network"),
        ], properties: [.widthMode: .text("Grow")], patchAt: Point2(x: 624, y: 96))
        _ = b.place(Library.iOS("List Row"), name: "General Row", in: table.id, inputs: [
            "Title": .text("General"),
        ], properties: [.widthMode: .text("Grow")])

        caption("Range Caption", "Range", y: 328)
        let segments = b.place(Library.iOS("Segmented Control"), at: Point2(x: 16, y: 350), width: width, inputs: [
            "Segments": .text("Day, Week, Month"),
        ])

        b.document.screen.insert(label("Brightness Title", "Brightness", at: Point2(x: 16, y: 412)), into: screen.id)
        let brightness = label("Brightness Value", "50%", at: Point2(x: S.device.width - 60, y: 412), color: gray)
        b.document.screen.insert(brightness, into: screen.id)
        let slider = b.place(Library.iOS("Slider"), at: Point2(x: 16, y: 444), width: width, patchAt: Point2(x: 48, y: 384))

        b.document.screen.insert(label("Count Title", "Guests", at: Point2(x: 16, y: 512)), into: screen.id)
        let count = label("Count Value", "0", at: Point2(x: S.device.width - 156, y: 512), color: gray)
        b.document.screen.insert(count, into: screen.id)
        let stepper = b.place(Library.iOS("Stepper"), at: Point2(x: S.device.width - 16 - 94, y: 506), patchAt: Point2(x: 48, y: 624))

        let button = b.place(Library.iOS("Button"), at: Point2(x: 16, y: 584), width: width, inputs: [
            "Title": .text("Continue"),
        ], patchAt: Point2(x: 48, y: 864))
        b.document.screen.insert(S.hint("Every control here is wired to something", symbol: "slider.horizontal.3", y: 690), into: screen.id)
        let tabs = b.place(Library.iOS("Tab Bar"), at: Point2(x: 0, y: S.device.height - 83), inputs: [
            "Titles": .text("Settings, Search, Profile"),
            "Symbols": .text("gearshape.fill, magnifyingglass, person.fill"),
        ], patchAt: Point2(x: 48, y: 1104))

        // Toggle → the Network row's detail.
        let state = b.add("if", at: Point2(x: 336, y: 96), name: "Wi-Fi State", type: .text, inputs: [
            "then": .text("Home Wi-Fi"), "else": .text("Off"),
        ])
        b.wire(toggle.node!, "On", to: state, "condition")
        b.wire(state, "value", to: network.node!, "Detail")

        // Slider → a percentage label. A JavaScript patch does the formatting.
        let percent = b.document.graph.add(PatchNode(
            kind: PatchKind.javascript, position: PatchGrid.snap(Point2(x: 336, y: 384)), name: "Percent",
            script: """
            // Turns a value from 0 to 1 into text such as "50%".
            inputs = { value: 0 };
            outputs = { text: "" };

            function evaluate(inputs, outputs) {
              outputs.text = Math.round(inputs.value * 100) + "%";
            }
            """
        ))
        let percentText = b.property(.text, of: brightness.id, at: Point2(x: 624, y: 384))
        b.wire(slider.node!, "Value", to: percent, "value")
        b.connect(percent, "text", to: percentText, "value")

        // Stepper → a count label.
        let countText = b.property(.text, of: count.id, at: Point2(x: 336, y: 624))
        b.wire(stepper.node!, "Value", to: countText, "value")

        // Button: each tap flips its own title.
        let done = b.add("switch", at: Point2(x: 336, y: 864), name: "Confirmed")
        let title = b.add("if", at: Point2(x: 624, y: 864), name: "Button Title", type: .text, inputs: [
            "then": .text("Done"), "else": .text("Continue"),
        ])
        b.wire(button.node!, "Tap", to: done, "flip")
        b.connect(done, "on", to: title, "condition")
        b.wire(title, "value", to: button.node!, "Title")

        // Tab Bar → the navigation bar's title.
        let heading = b.add("optionPicker", at: Point2(x: 624, y: 1104), name: "Screen Title", type: .text, inputs: [
            "value0": .text("Settings"), "value1": .text("Search"), "value2": .text("Profile"),
        ])
        b.wire(tabs.node!, "Selected", to: heading, "option")
        b.wire(heading, "value", to: bar.node!, "Title")

        b.note("Toggle · Picks the detail", around: [toggle.node!, state, network.node!])
        b.note("Slider · As a percentage", around: [slider.node!, percent, percentText])
        b.note("Button · Flips its title", around: [button.node!, done, title])
        b.note("Tab Bar · Names the screen", around: [tabs.node!, heading, bar.node!])

        return Controls(
            document: b.document, toggle: toggle.layer, slider: slider.layer, stepper: stepper.layer,
            segments: segments.layer, button: button.layer, tabBar: tabs.layer, wifiRow: network.layer,
            brightness: brightness.id, count: count.id,
            nodes: ["toggle": toggle.node!, "slider": slider.node!, "button": button.node!, "tabs": tabs.node!, "bar": bar.node!]
        )
    }

    public struct LiveList {
        public let document: Document
        public let request: NodeID
        public let row: LayerID
        public let loading: LayerID
        public let problem: LayerID
        public let retry: LayerID
        public let selected: LayerID

        public static let url = "https://jsonplaceholder.typicode.com/users"
    }

    /// Example C: a list that uses actual content. A request returns JSON; its array
    /// becomes repeated List Row components that Layout arranges; tapping a row selects
    /// it; Loading and Has Error decide what the rest of the screen shows.
    public static func liveList() -> LiveList {
        typealias Library = ComponentLibrary
        typealias S = ExampleStyle
        let gray = ColorValue(hex: "#8E8E93")!
        let width = S.device.width - 32
        var b = Builder(screen: Layer(name: "Screen", kind: .screen, properties: [
            .fill: .color(ColorValue(hex: "#F2F2F7")!),
        ]))
        let screen = b.document.screen.id
        func text(_ name: String, _ string: String, at point: Point2, size: Double = 17, color: ColorValue = .black,
                  _ extra: [LayerProperty: Value] = [:]) -> Layer {
            var layer = S.text(name, string, at: point, size: size, color: color)
            layer.properties.merge(extra) { _, new in new }
            return layer
        }

        _ = b.place(Library.iOS("Navigation Bar"), at: Point2(x: 0, y: S.top), inputs: [
            "Title": .text("Directory"), "Shows Back": .bool(false),
        ])
        let caption = text("Selected Caption", "SELECTED", at: Point2(x: 32, y: 124), size: 13, color: gray)
        let selected = text("Selected Name", "", at: Point2(x: 104, y: 122), size: 15, color: S.accent, [.fontWeight: .number(600)])
        b.document.screen.insert(caption, into: screen)
        b.document.screen.insert(selected, into: screen)

        let list = Layer(name: "List", kind: .view, properties: [
            .position: .point(Point2(x: 16, y: 150)), .size: .size(Size2(width: width, height: 44)),
            .fill: .color(.white), .cornerRadius: .number(26), .clips: .bool(true),
            .layout: .text("Stack"), .heightMode: .text("Auto"),
        ])
        b.document.screen.insert(list, into: screen)
        let row = b.place(Library.iOS("List Row"), name: "Row", in: list.id, inputs: [
            "Symbol": .text("person.fill"), "Symbol Color": .color(S.accent),
        ], properties: [
            .widthMode: .text("Grow"),
        ], patchAt: Point2(x: 1200, y: 96))

        let loading = text("Loading", "Loading the directory…", at: Point2(x: 0, y: 420), color: gray, [
            .size: .size(Size2(width: S.device.width, height: 24)), .widthMode: .text("Fixed"), .textAlignment: .text("Center"),
        ])
        b.document.screen.insert(loading, into: screen)

        let message = text("Message", "Something went wrong.", at: .zero, size: 15, color: gray, [
            .widthMode: .text("Grow"), .textAlignment: .text("Center"),
        ])
        let problem = Layer(name: "Problem", kind: .view, properties: [
            .position: .point(Point2(x: 40, y: 380)), .size: .size(Size2(width: S.device.width - 80, height: 120)),
            .layout: .text("Stack"), .spacing: .number(16), .heightMode: .text("Auto"), .opacity: .number(0),
        ], children: [message])
        b.document.screen.insert(problem, into: screen)
        let retry = b.place(Library.iOS("Button"), name: "Try Again", in: problem.id, inputs: [
            "Title": .text("Try Again"),
        ], properties: [.widthMode: .text("Grow")], patchAt: Point2(x: 48, y: 696))
        b.document.screen.insert(S.hint("Rows come from a live request; tap one", symbol: "network"), into: screen)

        // Request → array → one List Row per person.
        let request = b.add("networkRequest", at: Point2(x: 336, y: 96), name: "People Request", inputs: ["url": .text(LiveList.url)])
        let each = b.add("loopOverArray", at: Point2(x: 624, y: 96), name: "Each Person", type: .json)
        let name = b.add("jsonValue", at: Point2(x: 912, y: 96), name: "Name", type: .text, inputs: ["path": .text("name")])
        let detail = b.add("jsonValue", at: Point2(x: 912, y: 264), name: "City", type: .text, inputs: ["path": .text("address.city")])
        b.connect(request, "response", to: each, "array")
        b.connect(each, "value", to: name, "json")
        b.connect(each, "value", to: detail, "json")
        b.wire(name, "value", to: row.node!, "Title")
        b.wire(detail, "value", to: row.node!, "Detail")

        // Tapping a row selects that person.
        let choice = b.add("loopOptionSwitch", at: Point2(x: 1488, y: 96), name: "Selected Row", inputs: ["start": .number(-1)])
        let chosen = b.add("loopSelect", at: Point2(x: 1776, y: 96), name: "Selected Person", type: .text)
        let selectedText = b.property(.text, of: selected.id, at: Point2(x: 2064, y: 96))
        b.wire(row.node!, "Tap", to: choice, "set")
        b.connect(name, "value", to: chosen, "loop")
        b.connect(choice, "option", to: chosen, "index")
        b.connect(chosen, "value", to: selectedText, "value")

        // Loading and failure are states of the screen, not afterthoughts.
        let loadingOpacity = b.property(.opacity, of: loading.id, at: Point2(x: 624, y: 552))
        let problemOpacity = b.property(.opacity, of: problem.id, at: Point2(x: 624, y: 696))
        b.connect(request, "loading", to: loadingOpacity, "value")
        b.connect(request, "hasError", to: problemOpacity, "value")
        b.connect(request, "hasError", to: b.property(.enabled, of: problem.id, at: Point2(x: 624, y: 696)), "value")
        b.connect(request, "error", to: b.property(.text, of: message.id, at: Point2(x: 624, y: 984)), "value")
        b.wire(retry.node!, "Tap", to: request, "send")

        b.note("Data · A request's JSON array becomes rows", around: [request, each, name, detail, row.node!])
        b.note("Selection · Which row was tapped", around: [choice, chosen, selectedText])

        return LiveList(
            document: b.document, request: request, row: row.layer, loading: loading.id,
            problem: problem.id, retry: retry.layer, selected: selected.id
        )
    }

    public struct CameraExample {
        public let document: Document
        public let viewfinder: LayerID
        public let shutter: LayerID
        public let flash: LayerID
        public let thumbnail: LayerID
        public let notice: LayerID
        public let camera: NodeID
    }

    /// Example D: a camera experience with feedback. A Viewfinder shows the camera; the
    /// shutter takes a photo, which appears as a thumbnail, and answers with a flash, a
    /// sound and a haptic tap on hardware that has them.
    public static func camera() -> CameraExample {
        typealias S = ExampleStyle
        let w = S.device.width
        let viewfinder = Layer(name: "Viewfinder", kind: .camera, properties: [
            .position: .point(Point2(x: 0, y: 118)), .size: .size(Size2(width: w, height: w * 4 / 3)),
            .cornerRadius: .number(0),
        ])
        let notice = Layer(name: "Notice", kind: .text, properties: [
            .position: .point(Point2(x: 0, y: 118 + w * 2 / 3 + 36)), .size: .size(Size2(width: w, height: 22)),
            .text: .text("Camera not available"), .fontSize: .number(15), .textColor: .color(ColorValue(white: 0.6)),
            .textAlignment: .text("Center"),
        ])
        let flashMode = S.symbol("Flash Mode", "bolt.slash.fill", at: Point2(x: 24, y: 76), side: 22, color: .white)
        let zoom = Layer(name: "Zoom", kind: .view, properties: [
            .position: .point(Point2(x: (w - 44) / 2, y: 610)), .size: .size(Size2(width: 44, height: 44)),
            .cornerRadius: .number(22), .fill: .color(ColorValue(white: 0, alpha: 0.4)),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .distribution: .text("Center"),
        ], children: [S.text("Factor", "1×", size: 13, weight: 700, color: S.amber)])
        let modes = Layer(name: "Modes", kind: .view, properties: [
            .position: .point(Point2(x: 0, y: 678)), .size: .size(Size2(width: w, height: 20)),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .distribution: .text("Center"),
            .spacing: .number(26),
        ], children: [
            S.text("Video", "VIDEO", size: 13, weight: 600, color: ColorValue(white: 1, alpha: 0.75)),
            S.text("Photo", "PHOTO", size: 13, weight: 700, color: S.amber),
            S.text("Portrait", "PORTRAIT", size: 13, weight: 600, color: ColorValue(white: 1, alpha: 0.75)),
        ])
        let ring = Layer(name: "Ring", kind: .ellipse, properties: [
            .position: .point(Point2(x: (w - 80) / 2, y: 722)), .size: .size(Size2(width: 80, height: 80)),
            .fill: .color(.clear), .strokeColor: .color(.white), .strokeWidth: .number(4),
        ])
        let shutter = Layer(name: "Shutter", kind: .ellipse, properties: [
            .position: .point(Point2(x: (w - 64) / 2, y: 730)), .size: .size(Size2(width: 64, height: 64)), .fill: .color(.white),
        ])
        let thumbnail = Layer(name: "Last Photo", kind: .image, properties: [
            .position: .point(Point2(x: 40, y: 734)), .size: .size(Size2(width: 56, height: 56)), .cornerRadius: .number(12),
            .fill: .color(ColorValue(white: 0.18)),
        ])
        let flip = S.roundButton("Switch Camera", symbol: "arrow.triangle.2.circlepath", at: Point2(x: w - 96, y: 734), side: 56, light: false)
        let flash = Layer(name: "Flash", kind: .view, properties: [
            .size: .size(S.device), .fill: .color(.white), .opacity: .number(0),
        ])
        var b = Builder(screen: Layer(name: "Screen", kind: .screen, properties: [.fill: .color(.black)], children: [
            viewfinder, notice, flashMode, zoom, modes, ring, shutter, thumbnail, flip,
            S.hint("Tap the shutter", y: 812, dark: true), flash,
        ]))

        let touch = b.interaction(on: shutter.id, at: Point2(x: 48, y: 96))
        let camera = b.add("camera", at: Point2(x: 336, y: 96))
        let photo = b.property(.image, of: thumbnail.id, at: Point2(x: 624, y: 96))
        b.connect(touch, "tap", to: camera, "capture")
        b.connect(camera, "photo", to: photo, "value")
        let unavailable = b.add("not", at: Point2(x: 624, y: 264), name: "No Camera")
        let noticeOpacity = b.property(.opacity, of: notice.id, at: Point2(x: 912, y: 264))
        b.connect(camera, "available", to: unavailable, "value")
        b.connect(unavailable, "result", to: noticeOpacity, "value")

        // Feedback: the button gives under the finger; the capture flashes, clicks and taps.
        let press = b.add("spring", at: Point2(x: 336, y: 504), inputs: ["response": .number(0.2), "damping": .number(0.8)])
        let squeeze = b.add("transition", at: Point2(x: 624, y: 504), name: "Squeeze", type: .number, inputs: [
            "start": .number(1), "end": .number(0.86),
        ])
        let scale = b.property(.scale, of: shutter.id, at: Point2(x: 912, y: 504))
        b.connect(touch, "down", to: press, "target")
        b.connect(press, "value", to: squeeze, "progress")
        b.connect(squeeze, "value", to: scale, "value")
        let burst = b.add("impulse", at: Point2(x: 336, y: 744), name: "Flash", inputs: ["duration": .number(0.4)])
        let flashOpacity = b.property(.opacity, of: flash.id, at: Point2(x: 624, y: 744))
        b.connect(touch, "tap", to: burst, "trigger")
        b.connect(burst, "value", to: flashOpacity, "value")
        let sound = b.add("playSound", at: Point2(x: 336, y: 912), inputs: ["sound": .text("Shutter")])
        let haptic = b.add("hapticFeedback", at: Point2(x: 624, y: 912))
        b.connect(touch, "tap", to: sound, "trigger")
        b.connect(touch, "tap", to: haptic, "trigger")

        b.note("Capture · The shutter takes a photo for the thumbnail", around: [touch, camera, photo, unavailable, noticeOpacity])
        b.note("Feedback · What the person feels, sees and hears", around: [press, squeeze, scale, burst, flashOpacity, sound, haptic])
        return CameraExample(
            document: b.document, viewfinder: viewfinder.id, shutter: shutter.id, flash: flash.id,
            thumbnail: thumbnail.id, notice: notice.id, camera: camera
        )
    }
}
