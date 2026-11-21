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

        public var document: Document {
            get {
                var result = storage
                let measure = PatchRegistry.standard.with(components: storage.components).height
                result.arrangeViews(of: Set(result.screen.flattened.map(\.id)).subtracting(placed), measure: measure)
                result.separateViews(of: placed, measure: measure)
                // Each patch goes in the level of the views it works on.
                result.settleHomes()
                return result
            }
            set {
                storage = newValue
                storage.normalize()
            }
        }

        public init(screen: Layer) {
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

        public static let collapsedSize = Size2(width: 310, height: 200)
        public static let expandedSize = Size2(width: 358, height: 560)
        public static let collapsedPosition = Point2(x: 40, y: 320)
        public static let expandedPosition = Point2(x: 16, y: 96)
    }

    /// Example A: a card that opens and closes. One progress value drives the card's bounds,
    /// the background dimming, and the visibility of a control.
    public static func card() -> Card {
        let header = Layer(name: "Header", kind: .view, properties: [
            .position: .point(Point2(x: 40, y: 96)),
            .size: .size(Size2(width: 180, height: 28)),
            .fill: .color(ColorValue(white: 0.82)),
            .cornerRadius: .number(8),
        ])
        let row = Layer(name: "Row", kind: .view, properties: [
            .position: .point(Point2(x: 40, y: 560)),
            .size: .size(Size2(width: 310, height: 120)),
            .fill: .color(ColorValue(white: 0.88)),
            .cornerRadius: .number(24),
        ])
        let dim = Layer(name: "Dim", kind: .view, properties: [
            .size: .size(Size2(width: 390, height: 844)),
            .fill: .color(.black),
            .opacity: .number(0),
        ])
        let card = Layer(name: "Card", kind: .view, properties: [
            .position: .point(Card.collapsedPosition),
            .size: .size(Card.collapsedSize),
            .fill: .color(ColorValue(hex: "#3D7BF7")!),
            .cornerRadius: .number(28),
            .shadowRadius: .number(24),
            .shadowOffset: .point(Point2(x: 0, y: 12)),
        ])
        let close = Layer(name: "Close", kind: .ellipse, properties: [
            .position: .point(Point2(x: 318, y: 112)),
            .size: .size(Size2(width: 36, height: 36)),
            .fill: .color(ColorValue(white: 1, alpha: 0.9)),
            .opacity: .number(0),
        ])
        let screen = Layer(name: "Screen", kind: .screen, properties: [
            .fill: .color(ColorValue(white: 0.96)),
        ], children: [header, row, dim, card, close])

        var b = Builder(screen: screen)
        let touch = b.interaction(on: card.id, at: Point2(x: 40, y: 80))
        let expanded = b.add("switch", at: Point2(x: 260, y: 80), name: "Expanded")
        let spring = b.add("spring", at: Point2(x: 480, y: 80), inputs: [
            "response": .number(0.45), "damping": .number(0.75),
        ])
        let position = b.add("transition", at: Point2(x: 740, y: 40), name: "Card Position", type: .point, inputs: [
            "start": .point(Card.collapsedPosition), "end": .point(Card.expandedPosition),
        ])
        let size = b.add("transition", at: Point2(x: 740, y: 200), name: "Card Size", type: .size, inputs: [
            "start": .size(Card.collapsedSize), "end": .size(Card.expandedSize),
        ])
        let dimming = b.add("transition", at: Point2(x: 740, y: 360), name: "Dimming", type: .number, inputs: [
            "start": .number(0), "end": .number(0.5),
        ])
        let cardPosition = b.property(.position, of: card.id, at: Point2(x: 1000, y: 40))
        let cardSize = b.property(.size, of: card.id, at: Point2(x: 1000, y: 200))
        let dimOpacity = b.property(.opacity, of: dim.id, at: Point2(x: 1000, y: 360))
        let closeOpacity = b.property(.opacity, of: close.id, at: Point2(x: 1000, y: 480))

        b.connect(touch, "tap", to: expanded, "flip")
        b.connect(expanded, "on", to: spring, "target")
        b.connect(spring, "value", to: position, "progress")
        b.connect(spring, "value", to: size, "progress")
        b.connect(spring, "value", to: dimming, "progress")
        b.connect(position, "value", to: cardPosition, "value")
        b.connect(size, "value", to: cardSize, "value")
        b.connect(dimming, "value", to: dimOpacity, "value")
        b.connect(spring, "value", to: closeOpacity, "value")

        return Card(document: b.document, card: card.id, dim: dim.id, close: close.id, spring: spring, expanded: expanded)
    }

    public struct Sheet {
        public let document: Document
        public let sheet: LayerID
        public let dim: LayerID
        public let spring: NodeID

        public static let closedY: Double = 644
        public static let openY: Double = 144
        public static let threshold: Double = 394
    }

    /// Example B: a sheet that follows a finger, then settles open or closed on release.
    public static func sheet() -> Sheet {
        let content = Layer(name: "Content", kind: .view, properties: [
            .position: .point(Point2(x: 24, y: 96)),
            .size: .size(Size2(width: 342, height: 220)),
            .fill: .color(ColorValue(hex: "#F2B84B")!),
            .cornerRadius: .number(28),
        ])
        let dim = Layer(name: "Dim", kind: .view, properties: [
            .size: .size(Size2(width: 390, height: 844)),
            .fill: .color(.black),
            .opacity: .number(0),
        ])
        let handle = Layer(name: "Handle", kind: .view, properties: [
            .position: .point(Point2(x: 175, y: 10)),
            .size: .size(Size2(width: 40, height: 5)),
            .fill: .color(ColorValue(white: 0.75)),
            .cornerRadius: .number(2.5),
        ])
        let title = Layer(name: "Title", kind: .text, properties: [
            .position: .point(Point2(x: 24, y: 36)),
            .size: .size(Size2(width: 342, height: 30)),
            .text: .text("Drag me"),
            .fontSize: .number(22),
            .fontWeight: .number(600),
        ])
        let sheet = Layer(name: "Sheet", kind: .view, properties: [
            .position: .point(Point2(x: 0, y: Sheet.closedY)),
            .size: .size(Size2(width: 390, height: 760)),
            .fill: .color(.white),
            .cornerRadius: .number(28),
        ], children: [handle, title])
        let screen = Layer(name: "Screen", kind: .screen, properties: [
            .fill: .color(ColorValue(white: 0.96)),
        ], children: [content, dim, sheet])

        var b = Builder(screen: screen)
        let touch = b.interaction(on: sheet.id, at: Point2(x: 40, y: 120))
        let dragY = b.add("splitPoint", at: Point2(x: 260, y: 200), name: "Drag Y")
        let edges = b.add("pulse", at: Point2(x: 260, y: 40), name: "Touch Began / Ended")
        let spring = b.add("spring", at: Point2(x: 940, y: 120), inputs: [
            "response": .number(0.4), "damping": .number(0.85),
        ])
        let isAbove = b.add("less", at: Point2(x: 260, y: 400), name: "Above Threshold", inputs: [
            "b": .number(Sheet.threshold),
        ])
        let open = b.add("sampleHold", at: Point2(x: 480, y: 440), name: "Open", type: .bool)
        let destination = b.add("if", at: Point2(x: 700, y: 440), name: "Destination", type: .number, inputs: [
            "then": .number(Sheet.openY), "else": .number(Sheet.closedY),
        ])
        let point = b.add("makePoint", at: Point2(x: 1180, y: 120))
        let sheetPosition = b.property(.position, of: sheet.id, at: Point2(x: 1400, y: 120))
        let progress = b.add("progress", at: Point2(x: 1180, y: 280), inputs: [
            "start": .number(Sheet.closedY), "end": .number(Sheet.openY),
        ])
        let dimming = b.add("transition", at: Point2(x: 1400, y: 280), name: "Dimming", type: .number, inputs: [
            "start": .number(0), "end": .number(0.4),
        ])
        let dimOpacity = b.property(.opacity, of: dim.id, at: Point2(x: 1640, y: 280))

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

        return Sheet(document: b.document, sheet: sheet.id, dim: dim.id, spring: spring)
    }

    public struct ScrollingList {
        public let document: Document
        public let list: LayerID
        public let rows: [LayerID]
        public let scroll: NodeID

        public static let rowCount = 14
        public static let rowHeight: Double = 76
        public static let spacing: Double = 12
        public static let padding: Double = 16
        /// Where the list starts, below the header.
        public static let top: Double = 110
        /// How long the list's content is: more than fits, so it scrolls.
        public static var contentHeight: Double {
            padding * 2 + Double(rowCount) * rowHeight + Double(rowCount - 1) * spacing
        }
    }

    /// A scroll view of rows. Rows grow to the list's width, and a variable carries the
    /// scroll offset to a header that fades as the list moves.
    public static func scrollingList() -> ScrollingList {
        typealias List = ScrollingList
        let rows: [Layer] = (0..<List.rowCount).map { index in
            let title = Layer(name: "Title", kind: .text, properties: [
                .text: .text("Row \(index + 1)"),
                .fontSize: .number(17),
                .fontWeight: .number(600),
                .widthMode: .text("Auto"),
                .heightMode: .text("Auto"),
            ])
            return Layer(name: "Row \(index + 1)", kind: .view, properties: [
                .size: .size(Size2(width: 100, height: List.rowHeight)),
                .fill: .color(index % 2 == 0 ? ColorValue(white: 1) : ColorValue(hex: "#EEF3FF")!),
                .cornerRadius: .number(18),
                .widthMode: .text("Grow"),
                .layout: .text("Stack"), .axis: .text("Horizontal"),
                .alignment: .text("Center"),
                .paddingHorizontal: .number(18), .paddingVertical: .number(18),
            ], children: [title])
        }
        // The list is a scroll view filling the screen below the header. How far it
        // scrolls follows from how long its rows are; nothing is typed in.
        let top = List.top
        var list = Layer.new(.scrollView, name: "List")
        list.set(.position, .point(Point2(x: 0, y: top)))
        list.set(.size, .size(Size2(width: 390, height: 844 - top)))
        list.set(.spacing, .number(List.spacing))
        list.set(.paddingHorizontal, .number(List.padding))
        list.set(.paddingVertical, .number(List.padding))
        list.children = rows
        let header = Layer(name: "Header", kind: .text, properties: [
            .position: .point(Point2(x: 16, y: 56)),
            .text: .text("Inbox"),
            .fontSize: .number(34),
            .fontWeight: .number(700),
            .widthMode: .text("Auto"),
            .heightMode: .text("Auto"),
        ])
        let screen = Layer(name: "Screen", kind: .screen, properties: [
            .fill: .color(ColorValue(white: 0.95)),
        ], children: [list, header])

        var b = Builder(screen: screen)
        let scroll = b.view(list.id, at: Point2(x: 40, y: 60))
        let send = b.add("broadcast", at: Point2(x: 300, y: 60), type: .number, inputs: ["name": .text("Scroll Offset")])
        let receive = b.add("receive", at: Point2(x: 40, y: 400), type: .number, inputs: ["name": .text("Scroll Offset")])
        let fade = b.add("progress", at: Point2(x: 300, y: 400), name: "Header Fade", inputs: [
            "start": .number(-60), "end": .number(0),
        ])
        let clamp = b.add("clamp", at: Point2(x: 540, y: 400))
        let opacity = b.property(.opacity, of: header.id, at: Point2(x: 780, y: 400))

        b.connect(scroll, "offset", to: send, "value")
        b.connect(receive, "value", to: fade, "value")
        b.connect(fade, "progress", to: clamp, "value")
        b.connect(clamp, "result", to: opacity, "value")

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
        public static let rowHeight: Double = 64
        public static let spacing: Double = 10
        public static let padding: Double = 16
        public static let top: Double = 120
    }

    /// A list described by a rule instead of drawn row by row: one Row layer, repeated by a
    /// loop over an array of names. Tapping a row selects it; the graph knows which one.
    public static func people() -> People {
        let title = Layer(name: "Name", kind: .text, properties: [
            .fontSize: .number(17),
            .fontWeight: .number(600),
            .widthMode: .text("Auto"),
            .heightMode: .text("Auto"),
        ])
        let row = Layer(name: "Row", kind: .view, properties: [
            .size: .size(Size2(width: 100, height: People.rowHeight)),
            .fill: .color(.white),
            .cornerRadius: .number(18),
            .widthMode: .text("Grow"),
            .layout: .text("Stack"), .axis: .text("Horizontal"),
            .alignment: .text("Center"),
            .paddingHorizontal: .number(18), .paddingVertical: .number(18),
        ], children: [title])
        let list = Layer(name: "List", kind: .view, properties: [
            .position: .point(Point2(x: 0, y: People.top)),
            .size: .size(Size2(width: 390, height: 100)),
            .layout: .text("Stack"),
            .spacing: .number(People.spacing),
            .paddingHorizontal: .number(People.padding), .paddingVertical: .number(People.padding),
            .heightMode: .text("Auto"),
        ], children: [row])
        let header = Layer(name: "Header", kind: .text, properties: [
            .position: .point(Point2(x: 16, y: 56)),
            .text: .text("People"),
            .fontSize: .number(34),
            .fontWeight: .number(700),
            .widthMode: .text("Auto"),
            .heightMode: .text("Auto"),
        ])
        let screen = Layer(name: "Screen", kind: .screen, properties: [
            .fill: .color(ColorValue(white: 0.95)),
        ], children: [list, header])

        var b = Builder(screen: screen)
        let names = b.add("splitText", at: Point2(x: 40, y: 60), name: "Names", inputs: [
            "text": .text(People.names.joined(separator: ", ")),
        ])
        let each = b.add("loopOverArray", at: Point2(x: 280, y: 60), type: .text)
        let text = b.property(.text, of: title.id, at: Point2(x: 760, y: 40))

        let touch = b.interaction(on: row.id, at: Point2(x: 40, y: 260))
        let selection = b.add("loopOptionSwitch", at: Point2(x: 280, y: 260), name: "Selected Row")
        let isSelected = b.add("equal", at: Point2(x: 540, y: 200), name: "Is Selected")
        let spring = b.add("spring", at: Point2(x: 780, y: 200), inputs: ["response": .number(0.3), "damping": .number(0.85)])
        let fill = b.add("transition", at: Point2(x: 1040, y: 160), name: "Row Color", type: .color, inputs: [
            "start": .color(.white), "end": .color(ColorValue(hex: "#3D7BF7")!),
        ])
        let ink = b.add("transition", at: Point2(x: 1040, y: 340), name: "Name Color", type: .color, inputs: [
            "start": .color(.black), "end": .color(.white),
        ])
        let rowFill = b.property(.fill, of: row.id, at: Point2(x: 1300, y: 160))
        let textColor = b.property(.textColor, of: title.id, at: Point2(x: 1300, y: 340))

        let chosen = b.add("loopSelect", at: Point2(x: 520, y: 520), name: "Selected Name", type: .text)
        let headerText = b.property(.text, of: header.id, at: Point2(x: 780, y: 520))

        b.connect(names, "array", to: each, "array")
        b.connect(each, "value", to: text, "value")
        b.connect(touch, "tap", to: selection, "set")
        b.connect(each, "index", to: isSelected, "a")
        b.connect(selection, "option", to: isSelected, "b")
        b.connect(isSelected, "result", to: spring, "target")
        b.connect(spring, "value", to: fill, "progress")
        b.connect(spring, "value", to: ink, "progress")
        b.connect(fill, "value", to: rowFill, "value")
        b.connect(ink, "value", to: textColor, "value")
        b.connect(each, "value", to: chosen, "loop")
        b.connect(selection, "option", to: chosen, "index")
        b.connect(chosen, "value", to: headerText, "value")

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

    /// A settings screen assembled from the prebuilt iOS components and wired together:
    /// the toggle changes a row's detail, the slider and stepper drive labels, the tab bar
    /// renames the navigation bar.
    public static func controls() -> Controls {
        typealias Library = ComponentLibrary
        let screen = Layer(name: "Screen", kind: .screen, properties: [
            .fill: .color(ColorValue(hex: "#F2F2F7")!),
        ])
        var b = Builder(screen: screen)
        func label(_ name: String, _ string: String, at point: Point2, color: ColorValue = .black) -> Layer {
            Layer(name: name, kind: .text, properties: [
                .position: .point(point), .text: .text(string), .fontSize: .number(17), .textColor: .color(color),
                .widthMode: .text("Auto"), .heightMode: .text("Auto"),
            ])
        }

        let bar = b.place(Library.iOS("Navigation Bar"), at: Point2(x: 0, y: 47), inputs: [
            "Title": .text("Settings"), "Shows Back": .bool(false),
        ], patchAt: Point2(x: 760, y: 40))

        // A grouped table: one hand-built row holding a Toggle, then two List Rows.
        let wifiLabel = Layer(name: "Wi-Fi Label", kind: .text, properties: [
            .text: .text("Wi-Fi"), .fontSize: .number(17), .widthMode: .text("Grow"), .heightMode: .text("Auto"),
        ])
        let wifiRow = Layer(name: "Wi-Fi Row", kind: .view, properties: [
            .size: .size(Size2(width: 358, height: 52)), .widthMode: .text("Grow"), .layout: .text("Stack"), .axis: .text("Horizontal"),
            .alignment: .text("Center"), .paddingHorizontal: .number(16), .paddingVertical: .number(16),
        ], children: [wifiLabel])
        let table = Layer(name: "Table", kind: .view, properties: [
            .position: .point(Point2(x: 16, y: 110)), .size: .size(Size2(width: 358, height: 100)),
            .fill: .color(.white), .cornerRadius: .number(12), .clips: .bool(true),
            .layout: .text("Stack"), .heightMode: .text("Auto"),
        ], children: [wifiRow])
        b.document.screen.insert(table, into: screen.id)
        let toggle = b.place(Library.iOS("Toggle"), in: wifiRow.id, inputs: ["On": .bool(true)], patchAt: Point2(x: 40, y: 40))
        let network = b.place(Library.iOS("List Row"), name: "Network Row", in: table.id, inputs: [
            "Title": .text("Network"),
        ], properties: [.widthMode: .text("Grow")], patchAt: Point2(x: 520, y: 40))
        _ = b.place(Library.iOS("List Row"), name: "General Row", in: table.id, inputs: [
            "Title": .text("General"),
        ], properties: [.widthMode: .text("Grow")])

        let segments = b.place(Library.iOS("Segmented Control"), at: Point2(x: 16, y: 290), width: 358, inputs: [
            "Segments": .text("Day, Week, Month"),
        ])

        b.document.screen.insert(label("Brightness Title", "Brightness", at: Point2(x: 16, y: 352)), into: screen.id)
        let brightness = label("Brightness Value", "50%", at: Point2(x: 322, y: 352), color: ColorValue(hex: "#8E8E93")!)
        b.document.screen.insert(brightness, into: screen.id)
        let slider = b.place(Library.iOS("Slider"), at: Point2(x: 16, y: 386), width: 358, patchAt: Point2(x: 40, y: 260))

        b.document.screen.insert(label("Count Title", "Guests", at: Point2(x: 16, y: 452)), into: screen.id)
        let count = label("Count Value", "0", at: Point2(x: 240, y: 452), color: ColorValue(hex: "#8E8E93")!)
        b.document.screen.insert(count, into: screen.id)
        let stepper = b.place(Library.iOS("Stepper"), at: Point2(x: 280, y: 446), patchAt: Point2(x: 40, y: 440))

        let button = b.place(Library.iOS("Button"), at: Point2(x: 16, y: 530), width: 358, inputs: [
            "Title": .text("Continue"),
        ], patchAt: Point2(x: 520, y: 620))
        let tabs = b.place(Library.iOS("Tab Bar"), at: Point2(x: 0, y: 761), inputs: [
            "Titles": .text("Settings, Search, Profile"),
            "Symbols": .text("gearshape.fill, magnifyingglass, person.fill"),
        ], patchAt: Point2(x: 40, y: 800))

        // Toggle → the Network row's detail.
        let state = b.add("if", at: Point2(x: 280, y: 40), name: "Wi-Fi State", type: .text, inputs: [
            "then": .text("Home Wi-Fi"), "else": .text("Off"),
        ])
        b.wire(toggle.node!, "On", to: state, "condition")
        b.wire(state, "value", to: network.node!, "Detail")

        // Slider → a percentage label.
        // A JavaScript patch does the formatting.
        let percent = b.document.graph.add(PatchNode(
            kind: PatchKind.javascript, position: PatchGrid.snap(Point2(x: 280, y: 260)), name: "Percent",
            script: """
            // Turns a value from 0 to 1 into text such as "50%".
            inputs = { value: 0 };
            outputs = { text: "" };

            function evaluate(inputs, outputs) {
              outputs.text = Math.round(inputs.value * 100) + "%";
            }
            """
        ))
        let percentText = b.property(.text, of: brightness.id, at: Point2(x: 560, y: 260))
        b.wire(slider.node!, "Value", to: percent, "value")
        b.connect(percent, "text", to: percentText, "value")

        // Stepper → a count label.
        let countText = b.property(.text, of: count.id, at: Point2(x: 280, y: 440))
        b.wire(stepper.node!, "Value", to: countText, "value")

        // Button: each tap flips its own title.
        let done = b.add("switch", at: Point2(x: 40, y: 620), name: "Confirmed")
        let title = b.add("if", at: Point2(x: 280, y: 620), name: "Button Title", type: .text, inputs: [
            "then": .text("Done"), "else": .text("Continue"),
        ])
        b.wire(button.node!, "Tap", to: done, "flip")
        b.connect(done, "on", to: title, "condition")
        b.wire(title, "value", to: button.node!, "Title")

        // Tab Bar → the navigation bar's title.
        let heading = b.add("optionPicker", at: Point2(x: 400, y: 800), name: "Screen Title", type: .text, inputs: [
            "value0": .text("Settings"), "value1": .text("Search"), "value2": .text("Profile"),
        ])
        b.wire(tabs.node!, "Selected", to: heading, "option")
        b.wire(heading, "value", to: bar.node!, "Title")

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
        let gray = ColorValue(hex: "#8E8E93")!
        var b = Builder(screen: Layer(name: "Screen", kind: .screen, properties: [
            .fill: .color(ColorValue(hex: "#F2F2F7")!),
        ]))
        let screen = b.document.screen.id
        func text(_ name: String, _ string: String, at point: Point2, size: Double = 17, color: ColorValue = .black,
                  _ extra: [LayerProperty: Value] = [:]) -> Layer {
            var properties: [LayerProperty: Value] = [
                .position: .point(point), .text: .text(string), .fontSize: .number(size), .textColor: .color(color),
                .widthMode: .text("Auto"), .heightMode: .text("Auto"),
            ]
            properties.merge(extra) { _, new in new }
            return Layer(name: name, kind: .text, properties: properties)
        }

        _ = b.place(Library.iOS("Navigation Bar"), at: Point2(x: 0, y: 47), inputs: [
            "Title": .text("People"), "Shows Back": .bool(false),
        ])
        let caption = text("Selected Caption", "SELECTED", at: Point2(x: 32, y: 108), size: 13, color: gray)
        let selected = text("Selected Name", "", at: Point2(x: 120, y: 106), size: 15)
        b.document.screen.insert(caption, into: screen)
        b.document.screen.insert(selected, into: screen)

        let list = Layer(name: "List", kind: .view, properties: [
            .position: .point(Point2(x: 16, y: 136)), .size: .size(Size2(width: 358, height: 44)),
            .fill: .color(.white), .cornerRadius: .number(12), .clips: .bool(true),
            .layout: .text("Stack"), .heightMode: .text("Auto"),
        ])
        b.document.screen.insert(list, into: screen)
        let row = b.place(Library.iOS("List Row"), name: "Row", in: list.id, properties: [
            .widthMode: .text("Grow"),
        ], patchAt: Point2(x: 1040, y: 60))

        let loading = text("Loading", "Loading…", at: Point2(x: 0, y: 400), color: gray, [
            .size: .size(Size2(width: 390, height: 24)), .widthMode: .text("Fixed"), .textAlignment: .text("Center"),
        ])
        b.document.screen.insert(loading, into: screen)

        let message = text("Message", "Something went wrong.", at: .zero, size: 15, color: gray, [
            .widthMode: .text("Grow"), .textAlignment: .text("Center"),
        ])
        let problem = Layer(name: "Problem", kind: .view, properties: [
            .position: .point(Point2(x: 32, y: 360)), .size: .size(Size2(width: 326, height: 120)),
            .layout: .text("Stack"), .spacing: .number(16), .heightMode: .text("Auto"), .opacity: .number(0),
        ], children: [message])
        b.document.screen.insert(problem, into: screen)
        let retry = b.place(Library.iOS("Button"), name: "Try Again", in: problem.id, inputs: [
            "Title": .text("Try Again"),
        ], properties: [.widthMode: .text("Grow")], patchAt: Point2(x: 40, y: 620))

        // Request → array → one List Row per person.
        let request = b.add("networkRequest", at: Point2(x: 300, y: 60), name: "People Request", inputs: ["url": .text(LiveList.url)])
        let each = b.add("loopOverArray", at: Point2(x: 560, y: 60), name: "Each Person", type: .json)
        let name = b.add("jsonValue", at: Point2(x: 800, y: 40), name: "Name", type: .text, inputs: ["path": .text("name")])
        let detail = b.add("jsonValue", at: Point2(x: 800, y: 190), name: "Username", type: .text, inputs: ["path": .text("username")])
        b.connect(request, "response", to: each, "array")
        b.connect(each, "value", to: name, "json")
        b.connect(each, "value", to: detail, "json")
        b.wire(name, "value", to: row.node!, "Title")
        b.wire(detail, "value", to: row.node!, "Detail")

        // Tapping a row selects that person.
        let choice = b.add("loopOptionSwitch", at: Point2(x: 1300, y: 60), name: "Selected Row", inputs: ["start": .number(-1)])
        let chosen = b.add("loopSelect", at: Point2(x: 1540, y: 60), name: "Selected Person", type: .text)
        b.wire(row.node!, "Tap", to: choice, "set")
        b.connect(name, "value", to: chosen, "loop")
        b.connect(choice, "option", to: chosen, "index")
        b.connect(chosen, "value", to: b.property(.text, of: selected.id, at: Point2(x: 1780, y: 60)), "value")

        // Loading and failure are states of the screen, not afterthoughts.
        b.connect(request, "loading", to: b.property(.opacity, of: loading.id, at: Point2(x: 600, y: 460)), "value")
        b.connect(request, "hasError", to: b.property(.opacity, of: problem.id, at: Point2(x: 600, y: 560)), "value")
        b.connect(request, "hasError", to: b.property(.enabled, of: problem.id, at: Point2(x: 600, y: 660)), "value")
        b.connect(request, "error", to: b.property(.text, of: message.id, at: Point2(x: 600, y: 760)), "value")
        b.wire(retry.node!, "Tap", to: request, "send")

        b.document.graph.comments = [
            GraphComment(text: "Data · A request returns JSON; each item of its array becomes a row", origin: Point2(x: 280, y: 0), size: Size2(width: 990, height: 390)),
            GraphComment(text: "Selection · Which row was tapped", origin: Point2(x: 1280, y: 0), size: Size2(width: 720, height: 200)),
            GraphComment(text: "States · Loading and failure", origin: Point2(x: 20, y: 410), size: Size2(width: 800, height: 440)),
        ]

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
        let viewfinder = Layer(name: "Viewfinder", kind: .camera, properties: [
            .position: .point(Point2(x: 0, y: 110)), .size: .size(Size2(width: 390, height: 520)),
        ])
        let notice = Layer(name: "Notice", kind: .text, properties: [
            .position: .point(Point2(x: 0, y: 420)), .size: .size(Size2(width: 390, height: 22)),
            .text: .text("Camera not available"), .fontSize: .number(15), .textColor: .color(ColorValue(white: 0.6)),
            .textAlignment: .text("Center"),
        ])
        let ring = Layer(name: "Ring", kind: .ellipse, properties: [
            .position: .point(Point2(x: 155, y: 692)), .size: .size(Size2(width: 80, height: 80)),
            .fill: .color(.clear), .strokeColor: .color(.white), .strokeWidth: .number(4),
        ])
        let shutter = Layer(name: "Shutter", kind: .ellipse, properties: [
            .position: .point(Point2(x: 163, y: 700)), .size: .size(Size2(width: 64, height: 64)), .fill: .color(.white),
        ])
        let thumbnail = Layer(name: "Last Photo", kind: .image, properties: [
            .position: .point(Point2(x: 28, y: 704)), .size: .size(Size2(width: 56, height: 56)), .cornerRadius: .number(10),
        ])
        let flash = Layer(name: "Flash", kind: .view, properties: [
            .size: .size(Size2(width: 390, height: 844)), .fill: .color(.white), .opacity: .number(0),
        ])
        var b = Builder(screen: Layer(name: "Screen", kind: .screen, properties: [.fill: .color(.black)], children: [
            viewfinder, notice, ring, shutter, thumbnail, flash,
        ]))

        let touch = b.interaction(on: shutter.id, at: Point2(x: 40, y: 80))
        let camera = b.add("camera", at: Point2(x: 320, y: 60))
        b.connect(touch, "tap", to: camera, "capture")
        b.connect(camera, "photo", to: b.property(.image, of: thumbnail.id, at: Point2(x: 600, y: 40)), "value")
        let unavailable = b.add("not", at: Point2(x: 600, y: 150), name: "No Camera")
        b.connect(camera, "available", to: unavailable, "value")
        b.connect(unavailable, "result", to: b.property(.opacity, of: notice.id, at: Point2(x: 820, y: 150)), "value")

        // Feedback: the button gives under the finger; the capture flashes, clicks and taps.
        let press = b.add("spring", at: Point2(x: 320, y: 330), inputs: ["response": .number(0.2), "damping": .number(0.8)])
        let squeeze = b.add("transition", at: Point2(x: 560, y: 330), name: "Squeeze", type: .number, inputs: [
            "start": .number(1), "end": .number(0.86),
        ])
        b.connect(touch, "down", to: press, "target")
        b.connect(press, "value", to: squeeze, "progress")
        b.connect(squeeze, "value", to: b.property(.scale, of: shutter.id, at: Point2(x: 800, y: 330)), "value")
        let burst = b.add("impulse", at: Point2(x: 320, y: 560), name: "Flash", inputs: ["duration": .number(0.4)])
        b.connect(touch, "tap", to: burst, "trigger")
        b.connect(burst, "value", to: b.property(.opacity, of: flash.id, at: Point2(x: 560, y: 560)), "value")
        let sound = b.add("playSound", at: Point2(x: 320, y: 700), inputs: ["sound": .text("Shutter")])
        let haptic = b.add("hapticFeedback", at: Point2(x: 560, y: 700))
        b.connect(touch, "tap", to: sound, "trigger")
        b.connect(touch, "tap", to: haptic, "trigger")

        b.document.graph.comments = [
            GraphComment(text: "Capture · The shutter takes a photo; the photo becomes the thumbnail", origin: Point2(x: 20, y: 0), size: Size2(width: 1020, height: 250)),
            GraphComment(text: "Feedback · What the person feels, sees and hears", origin: Point2(x: 300, y: 280), size: Size2(width: 740, height: 560)),
        ]
        return CameraExample(
            document: b.document, viewfinder: viewfinder.id, shutter: shutter.id, flash: flash.id,
            thumbnail: thumbnail.id, notice: notice.id, camera: camera
        )
    }
}
