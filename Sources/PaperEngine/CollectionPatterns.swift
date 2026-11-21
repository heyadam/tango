import Foundation
import PaperModel

// Two gallery items about collections of things (spec 7.11): a vertical page of horizontal
// carousels, and a photo grid you select from. Built in code like the other examples.

extension SampleDocuments {
    private static func caption(
        _ name: String, _ string: String, at point: Point2 = .zero, size: Double = 17, weight: Double = 400,
        color: ColorValue = .black
    ) -> Layer {
        Layer(name: name, kind: .text, properties: [
            .position: .point(point), .text: .text(string), .fontSize: .number(size), .fontWeight: .number(weight),
            .textColor: .color(color), .widthMode: .text("Auto"), .heightMode: .text("Auto"),
        ])
    }

    /// A stack that holds one thing and indents it from the sides of the page.
    private static func inset(_ name: String, _ child: Layer, spacing: Double = 0) -> Layer {
        Layer(name: name, kind: .view, properties: [
            .layout: .text("Stack"), .spacing: .number(spacing), .paddingHorizontal: .number(20),
            .widthMode: .text("Grow"), .heightMode: .text("Auto"),
        ], children: [child])
    }

    // MARK: Nested scrolling

    public struct NestedScroll {
        public let document: Document
        /// The vertical page.
        public let feed: LayerID
        /// The carousels, top to bottom: Featured (paging), Memories (free), Shared Albums (paging).
        public let carousels: [LayerID]
        /// The repeated card of each carousel, in the same order.
        public let cards: [LayerID]
        /// The heart on each card, which fills when the card is tapped.
        public let hearts: [LayerID]
        /// The view patches of the carousels, whose Offset output says how far each has scrolled.
        public let carouselPatches: [NodeID]
        public let feedPatch: NodeID

        public struct Shelf: Sendable {
            public let name: String
            public let kicker: String
            public let card: Size2
            /// 0 scrolls freely; otherwise the carousel stops on multiples of this.
            public let page: Double
            public let titles: [String]
            public let colors: [String]
            public let symbols: [String]
        }

        public static let spacing: Double = 12
        public static let shelves: [Shelf] = [
            Shelf(name: "Featured", kicker: "MEMORY", card: Size2(width: 362, height: 260), page: 362 + spacing,
                  titles: ["Summer in Lisbon", "Weekend Hikes", "Ocean Days", "Night Lights"],
                  colors: ["#F28C38", "#3E8E5E", "#2F7FD8", "#5B4BC4"],
                  symbols: ["sun.max.fill", "mountain.2.fill", "water.waves", "moon.stars.fill"]),
            Shelf(name: "Memories", kicker: "", card: Size2(width: 150, height: 196), page: 0,
                  titles: ["Birthdays", "Pets", "Gardens", "Concerts", "Road Trips", "Snow Days"],
                  colors: ["#E0567A", "#E8A33D", "#3AA6A0", "#7A6FF0", "#D9644A", "#4F86C6"],
                  symbols: ["birthday.cake.fill", "pawprint.fill", "leaf.fill", "music.note", "car.fill", "snowflake"]),
            Shelf(name: "Shared Albums", kicker: "", card: Size2(width: 170, height: 150), page: 170 + spacing,
                  titles: ["Family", "Book Club", "Climbing", "Cooking", "Running", "Travel"],
                  colors: ["#8E6FD8", "#C9753D", "#4D8F6E", "#D4574E", "#3D7BF7", "#2E9AA8"],
                  symbols: ["house.fill", "book.fill", "figure.climbing", "fork.knife", "figure.run", "airplane"]),
        ]
    }

    /// A page that scrolls up and down, with rows of cards that scroll sideways, as in the
    /// App Store or Photos' For You. The direction a drag starts in decides which one moves.
    /// A tap on a card still reaches it: the heart fills and the card gives a small bump.
    public static func nestedScroll() -> NestedScroll {
        typealias Nested = NestedScroll
        let heading = Layer(name: "Heading", kind: .view, properties: [
            .layout: .text("Stack"), .spacing: .number(2), .paddingHorizontal: .number(20),
            .widthMode: .text("Grow"), .heightMode: .text("Auto"),
        ], children: [
            caption("Date", "TUESDAY, NOVEMBER 21", size: 13, weight: 600, color: ExampleStyle.secondary),
            caption("Title", "For You", size: 34, weight: 700),
        ])

        var carousels: [Layer] = []
        var cards: [Layer] = []
        var parts: [(title: LayerID, symbol: LayerID, heart: LayerID)] = []
        var sections: [Layer] = []
        for shelf in Nested.shelves {
            let big = shelf.card.width > 300
            let white = ColorValue(white: 1)
            let symbolSide = big ? 150.0 : 64.0
            let symbol = Layer(name: "Symbol", kind: .symbol, properties: [
                .position: .point(big ? Point2(x: shelf.card.width - symbolSide - 24, y: 28) : Point2(x: 18, y: 18)),
                .size: .size(Size2(width: symbolSide, height: symbolSide)),
                .symbol: .text(shelf.symbols[0]), .fill: .color(ColorValue(white: 1, alpha: big ? 0.35 : 0.9)),
            ])
            let title = caption("Card Title", shelf.titles[0],
                                at: Point2(x: big ? 20 : 16, y: shelf.card.height - (big ? 50 : 40)),
                                size: big ? 26 : 17, weight: 700, color: white)
            let heart = Layer(name: "Heart", kind: .symbol, properties: [
                .position: .point(Point2(x: shelf.card.width - (big ? 44 : 36), y: big ? 18 : 14)),
                .size: .size(Size2(width: big ? 26 : 22, height: big ? 26 : 22)),
                .symbol: .text("heart"), .fill: .color(white),
            ])
            var inside = [symbol, title, heart]
            if !shelf.kicker.isEmpty {
                inside.insert(caption("Kicker", shelf.kicker, at: Point2(x: 20, y: shelf.card.height - 72),
                                      size: 13, weight: 700, color: ColorValue(white: 1, alpha: 0.75)), at: 1)
            }
            let card = Layer(name: "\(shelf.name) Card", kind: .view, properties: [
                .size: .size(shelf.card), .fill: .color(ColorValue(hex: shelf.colors[0])!),
                .cornerRadius: .number(big ? 26 : 20), .clips: .bool(true),
            ], children: inside)
            var carousel = Layer.new(.scrollView, name: shelf.name)
            carousel.set(.axis, .text("Horizontal"))
            carousel.set(.size, .size(Size2(width: ExampleStyle.device.width, height: shelf.card.height)))
            carousel.set(.widthMode, .text("Grow"))
            carousel.set(.spacing, .number(Nested.spacing))
            carousel.set(.paddingHorizontal, .number(20))
            carousel.set(.paddingVertical, .number(0))
            if shelf.page > 0 { carousel.set(.pageSize, .number(shelf.page)) }
            carousel.children = [card]
            let section = Layer(name: "\(shelf.name) Section", kind: .view, properties: [
                .layout: .text("Stack"), .spacing: .number(12),
                .widthMode: .text("Grow"), .heightMode: .text("Auto"),
            ], children: [inset("\(shelf.name) Header", caption("\(shelf.name) Label", shelf.name, size: 22, weight: 700)), carousel])
            carousels.append(carousel)
            cards.append(card)
            parts.append((title.id, symbol.id, heart.id))
            sections.append(section)
        }

        var feed = Layer.new(.scrollView, name: "Feed")
        feed.set(.size, .size(ExampleStyle.device))
        feed.set(.spacing, .number(28))
        feed.set(.paddingTop, .number(ExampleStyle.top + 14))
        feed.set(.paddingBottom, .number(100))
        feed.children = [heading] + sections
        let screen = Layer(name: "Screen", kind: .screen, properties: [
            .fill: .color(ExampleStyle.paper),
        ], children: [feed, ExampleStyle.hint("Drag across a row, or down the page", symbol: "hand.draw.fill")])

        var b = Builder(screen: screen)
        let feedPatch = b.view(feed.id, at: Point2(x: 40, y: 60))
        var carouselPatches: [NodeID] = []
        for (index, shelf) in Nested.shelves.enumerated() {
            let card = cards[index].id
            let (title, symbol, heart) = parts[index]
            carouselPatches.append(b.view(carousels[index].id, at: Point2(x: 40, y: 240 + Double(index) * 180)))

            // What each card shows: one value per card, which also repeats the card.
            let titles = b.add("splitText", at: Point2(x: 40, y: 60), name: "\(shelf.name) Titles", inputs: [
                "text": .text(shelf.titles.joined(separator: ", ")),
            ])
            let eachTitle = b.add("loopOverArray", at: Point2(x: 300, y: 60), type: .text)
            let titleText = b.property(.text, of: title, at: Point2(x: 1080, y: 60))
            let symbols = b.add("splitText", at: Point2(x: 40, y: 240), name: "\(shelf.name) Symbols", inputs: [
                "text": .text(shelf.symbols.joined(separator: ", ")),
            ])
            let eachSymbol = b.add("loopOverArray", at: Point2(x: 300, y: 240), type: .text)
            let symbolName = b.property(.symbol, of: symbol, at: Point2(x: 1080, y: 240))
            let colors = b.add("splitText", at: Point2(x: 40, y: 600), name: "\(shelf.name) Colors", inputs: [
                "text": .text(shelf.colors.joined(separator: ", ")),
            ])
            let eachColor = b.add("loopOverArray", at: Point2(x: 300, y: 600), type: .color)
            let fill = b.property(.fill, of: card, at: Point2(x: 820, y: 600))
            let scale = b.property(.scale, of: card, at: Point2(x: 820, y: 600))

            // A tap saves the card: the heart fills, and the card bumps.
            let touch = b.interaction(on: card, at: Point2(x: 40, y: 420))
            let saved = b.add("switch", at: Point2(x: 300, y: 420), name: "Saved")
            let heartName = b.add("if", at: Point2(x: 560, y: 420), name: "Heart", type: .text, inputs: [
                "then": .text("heart.fill"), "else": .text("heart"),
            ])
            let heartSymbol = b.property(.symbol, of: heart, at: Point2(x: 1080, y: 420))
            let bump = b.add("impulse", at: Point2(x: 300, y: 780), name: "Bump", inputs: ["duration": .number(0.4)])
            let press = b.add("transition", at: Point2(x: 560, y: 780), name: "Press", type: .number, inputs: [
                "start": .number(1), "end": .number(0.95),
            ])

            b.connect(titles, "array", to: eachTitle, "array")
            b.connect(eachTitle, "value", to: titleText, "value")
            b.connect(symbols, "array", to: eachSymbol, "array")
            b.connect(eachSymbol, "value", to: symbolName, "value")
            b.connect(colors, "array", to: eachColor, "array")
            b.connect(eachColor, "value", to: fill, "value")
            b.connect(touch, "tap", to: saved, "flip")
            b.connect(saved, "on", to: heartName, "condition")
            b.connect(heartName, "value", to: heartSymbol, "value")
            b.connect(touch, "tap", to: bump, "trigger")
            b.connect(bump, "value", to: press, "progress")
            b.connect(press, "value", to: scale, "value")
        }
        return NestedScroll(
            document: b.document, feed: feed.id, carousels: carousels.map(\.id), cards: cards.map(\.id),
            hearts: parts.map(\.heart), carouselPatches: carouselPatches, feedPatch: feedPatch
        )
    }

    // MARK: Photo selection

    public struct PhotoSelection {
        public let document: Document
        public let library: LayerID
        public let photo: LayerID
        public let check: LayerID
        public let title: LayerID
        public let button: LayerID
        public let buttonLabel: LayerID
        public let selecting: NodeID
        public let count: NodeID

        public struct Picture: Sendable {
            public let sky: String
            public let ground: String
            public let subject: String
        }

        /// What each photo shows: a sky, a hill and something in front of it.
        public static let pictures: [Picture] = [
            Picture(sky: "#8EC5FC", ground: "#4F9D69", subject: "tree.fill"),
            Picture(sky: "#FFB88C", ground: "#C0603A", subject: "sun.horizon.fill"),
            Picture(sky: "#2B3A67", ground: "#151D3B", subject: "moon.stars.fill"),
            Picture(sky: "#A1E3D8", ground: "#2E8B8B", subject: "sailboat.fill"),
            Picture(sky: "#F6D365", ground: "#D98E2B", subject: "sun.max.fill"),
            Picture(sky: "#C3B1E1", ground: "#7B5EA7", subject: "camera.macro"),
            Picture(sky: "#D4E7FF", ground: "#9DB4CF", subject: "snowflake"),
            Picture(sky: "#FF9A9E", ground: "#D35D6E", subject: "heart.fill"),
            Picture(sky: "#B6E388", ground: "#5E9E3A", subject: "leaf.fill"),
            Picture(sky: "#6A82FB", ground: "#3A4CB5", subject: "bird.fill"),
            Picture(sky: "#FDCB82", ground: "#B9783F", subject: "pawprint.fill"),
            Picture(sky: "#84FAB0", ground: "#2F9E6E", subject: "mountain.2.fill"),
            Picture(sky: "#FBC2EB", ground: "#B56BA6", subject: "umbrella.fill"),
            Picture(sky: "#5EE7DF", ground: "#2A8C99", subject: "fish.fill"),
            Picture(sky: "#3B2E5A", ground: "#1E1633", subject: "sparkles"),
            Picture(sky: "#FFE29F", ground: "#E0A54A", subject: "cup.and.saucer.fill"),
            Picture(sky: "#A8C0FF", ground: "#5A6FC0", subject: "cloud.sun.fill"),
            Picture(sky: "#F5A962", ground: "#A45A2A", subject: "flame.fill"),
            Picture(sky: "#9BE15D", ground: "#3E8E41", subject: "tortoise.fill"),
            Picture(sky: "#E0C3FC", ground: "#8E7CC3", subject: "music.note"),
            Picture(sky: "#96E6A1", ground: "#4DA167", subject: "bicycle"),
        ]
        public static let top: Double = 124
        public static let spacing: Double = 2
        public static let side: Double = (402 - 2 * 2) / 3
        /// How much smaller a selected photo is drawn.
        public static let selectedScale: Double = 0.9
    }

    /// A photo grid that is one repeated view. Select starts choosing; a tap then picks or
    /// unpicks a photo, which shrinks into its cell, dims, and shows a checkmark, while the
    /// title counts what is chosen. Cancel ends it and lets everything go.
    public static func photoSelection() -> PhotoSelection {
        typealias Photos = PhotoSelection
        let first = Photos.pictures[0]
        let side = Photos.side
        let blue = ColorValue(hex: "#0A84FF")!
        let ground = Layer(name: "Hill", kind: .ellipse, properties: [
            .position: .point(Point2(x: -46, y: 82)), .size: .size(Size2(width: 230, height: 120)),
            .fill: .color(ColorValue(hex: first.ground)!),
        ])
        let sun = Layer(name: "Sun", kind: .ellipse, properties: [
            .position: .point(Point2(x: 88, y: 18)), .size: .size(Size2(width: 22, height: 22)),
            .fill: .color(ColorValue(white: 1, alpha: 0.7)),
        ])
        let subject = Layer(name: "Subject", kind: .symbol, properties: [
            .position: .point(Point2(x: 38, y: 40)), .size: .size(Size2(width: 52, height: 52)),
            .symbol: .text(first.subject), .fill: .color(ColorValue(white: 1, alpha: 0.92)),
            .shadowColor: .color(ColorValue(white: 0, alpha: 0.18)), .shadowRadius: .number(6),
            .shadowOffset: .point(Point2(x: 0, y: 2)),
        ])
        let dim = Layer(name: "Dim", kind: .view, properties: [
            .size: .size(Size2(width: side + 2, height: side + 2)), .fill: .color(.white), .opacity: .number(0),
        ])
        let ring = Layer(name: "Ring", kind: .symbol, properties: [
            .position: .point(Point2(x: side - 30, y: side - 30)), .size: .size(Size2(width: 24, height: 24)),
            .symbol: .text("circle"), .fill: .color(.white), .opacity: .number(0),
            .shadowColor: .color(ColorValue(white: 0, alpha: 0.35)), .shadowRadius: .number(3),
        ])
        let check = Layer(name: "Check", kind: .view, properties: [
            .position: .point(Point2(x: side - 31, y: side - 31)), .size: .size(Size2(width: 26, height: 26)),
            .opacity: .number(0), .fill: .color(ColorValue(white: 1, alpha: 0)),
        ], children: [
            Layer(name: "Border", kind: .ellipse, properties: [
                .size: .size(Size2(width: 26, height: 26)), .fill: .color(.white),
            ]),
            Layer(name: "Dot", kind: .ellipse, properties: [
                .position: .point(Point2(x: 2, y: 2)), .size: .size(Size2(width: 22, height: 22)), .fill: .color(blue),
            ]),
            Layer(name: "Tick", kind: .symbol, properties: [
                .position: .point(Point2(x: 7, y: 7)), .size: .size(Size2(width: 12, height: 12)),
                .symbol: .text("checkmark"), .fill: .color(.white), .fontWeight: .number(800),
            ]),
        ])
        let photo = Layer(name: "Photo", kind: .view, properties: [
            .size: .size(Size2(width: side, height: side)), .widthMode: .text("Grow"),
            .fill: .color(ColorValue(hex: first.sky)!), .clips: .bool(true), .enabled: .bool(false),
        ], children: [sun, ground, subject, dim, ring, check])
        let grid = Layer(name: "Grid", kind: .view, properties: [
            .layout: .text("Grid"), .columns: .number(3), .spacing: .number(Photos.spacing),
            .widthMode: .text("Grow"), .heightMode: .text("Auto"),
        ], children: [photo])
        var library = Layer.new(.scrollView, name: "Library")
        library.set(.size, .size(ExampleStyle.device))
        library.set(.paddingTop, .number(Photos.top))
        library.set(.paddingBottom, .number(100))
        library.children = [grid]

        let title = caption("Title", "Library", at: Point2(x: 20, y: 70), size: 34, weight: 700)
        let buttonLabel = Layer(name: "Label", kind: .text, properties: [
            .position: .point(Point2(x: 0, y: 8)), .size: .size(Size2(width: 84, height: 20)),
            .text: .text("Select"), .fontSize: .number(16), .fontWeight: .number(600),
            .textAlignment: .text("Center"),
        ])
        let button = Layer(name: "Select", kind: .view, properties: [
            .position: .point(Point2(x: 298, y: 76)), .size: .size(Size2(width: 84, height: 36)),
            .fill: .color(ColorValue(white: 0.92)), .cornerRadius: .number(18),
        ], children: [buttonLabel])
        let mark = Layer(name: "Mark", kind: .view, properties: [
            .size: .size(Size2(width: 1, height: 1)), .fill: .color(ColorValue(white: 1, alpha: 0)),
        ])
        let tally = Layer(name: "Picked Marks", kind: .view, properties: [
            .layout: .text("Stack"), .axis: .text("Horizontal"), .widthMode: .text("Auto"),
            .size: .size(Size2(width: 0, height: 1)), .opacity: .number(0),
        ], children: [mark])
        let bar = Layer(name: "Bar", kind: .view, properties: [
            .size: .size(Size2(width: ExampleStyle.device.width, height: Photos.top - 6)), .fill: .color(ColorValue(white: 1, alpha: 0.94)),
        ], children: [tally, title, button])
        let screen = Layer(name: "Screen", kind: .screen, properties: [
            .fill: .color(.white),
        ], children: [library, bar, ExampleStyle.hint("Tap Select, then tap a few photos")])

        var b = Builder(screen: screen)
        // Selecting or not: the button flips it, and it decides whether photos take taps.
        let tapButton = b.interaction(on: button.id, at: Point2(x: 40, y: 60))
        // The bar takes the touches that land on it, so a photo scrolled under it is not picked.
        _ = b.interaction(on: bar.id, at: Point2(x: 40, y: 2220))
        let selecting = b.add("switch", at: Point2(x: 300, y: 60), name: "Selecting")
        let buttonText = b.add("if", at: Point2(x: 560, y: 60), name: "Button Title", type: .text, inputs: [
            "then": .text("Cancel"), "else": .text("Select"),
        ])
        let labelText = b.property(.text, of: buttonLabel.id, at: Point2(x: 820, y: 60))
        let ended = b.add("pulse", at: Point2(x: 560, y: 660), name: "Selecting Ended")
        let modeSpring = b.add("spring", at: Point2(x: 560, y: 240), name: "Show Rings", inputs: [
            "response": .number(0.3), "damping": .number(1),
        ])
        b.connect(tapButton, "tap", to: selecting, "flip")
        b.connect(selecting, "on", to: buttonText, "condition")
        b.connect(buttonText, "value", to: labelText, "value")
        b.connect(selecting, "on", to: ended, "value")
        b.connect(selecting, "on", to: modeSpring, "target")

        // The pictures: one value per photo, which is what repeats the photo.
        func list(_ name: String, _ values: [String], type: PortType, y: Double) -> NodeID {
            let split = b.add("splitText", at: Point2(x: 40, y: y), name: name, inputs: [
                "text": .text(values.joined(separator: ", ")),
            ])
            let each = b.add("loopOverArray", at: Point2(x: 300, y: y), type: type)
            b.connect(split, "array", to: each, "array")
            return each
        }
        let skies = list("Skies", Photos.pictures.map(\.sky), type: .color, y: 960)
        let hills = list("Hills", Photos.pictures.map(\.ground), type: .color, y: 1140)
        let subjects = list("Subjects", Photos.pictures.map(\.subject), type: .text, y: 1320)
        let photoFill = b.property(.fill, of: photo.id, at: Point2(x: 1080, y: 1500))
        let hillFill = b.property(.fill, of: ground.id, at: Point2(x: 1340, y: 1140))
        let subjectSymbol = b.property(.symbol, of: subject.id, at: Point2(x: 1340, y: 1320))
        let ringOpacity = b.property(.opacity, of: ring.id, at: Point2(x: 820, y: 240))
        b.connect(skies, "value", to: photoFill, "value")
        b.connect(hills, "value", to: hillFill, "value")
        b.connect(subjects, "value", to: subjectSymbol, "value")
        b.connect(modeSpring, "value", to: ringOpacity, "value")
        b.connect(selecting, "on", to: b.property(.enabled, of: photo.id, at: Point2(x: 1080, y: 1500)), "value")

        // Each photo remembers whether it is picked, and shows it.
        let touch = b.interaction(on: photo.id, at: Point2(x: 40, y: 1500))
        let picked = b.add("switch", at: Point2(x: 300, y: 1500), name: "Picked")
        let pickSpring = b.add("spring", at: Point2(x: 560, y: 1500), inputs: [
            "response": .number(0.3), "damping": .number(0.75),
        ])
        let shrink = b.add("transition", at: Point2(x: 820, y: 1500), name: "Shrink", type: .number, inputs: [
            "start": .number(1), "end": .number(Photos.selectedScale),
        ])
        let round = b.add("transition", at: Point2(x: 820, y: 1680), name: "Round", type: .number, inputs: [
            "start": .number(0), "end": .number(10),
        ])
        let fade = b.add("transition", at: Point2(x: 820, y: 1860), name: "Dim", type: .number, inputs: [
            "start": .number(0), "end": .number(0.28),
        ])
        let pop = b.add("transition", at: Point2(x: 820, y: 2040), name: "Check Size", type: .number, inputs: [
            "start": .number(0.4), "end": .number(1),
        ])
        b.connect(touch, "tap", to: picked, "flip")
        b.connect(ended, "turnedOff", to: picked, "turnOff")
        b.connect(picked, "on", to: pickSpring, "target")
        b.connect(pickSpring, "value", to: shrink, "progress")
        b.connect(pickSpring, "value", to: round, "progress")
        b.connect(pickSpring, "value", to: fade, "progress")
        b.connect(pickSpring, "value", to: pop, "progress")
        b.connect(shrink, "value", to: b.property(.scale, of: photo.id, at: Point2(x: 1080, y: 1500)), "value")
        b.connect(round, "value", to: b.property(.cornerRadius, of: photo.id, at: Point2(x: 1080, y: 1500)), "value")
        b.connect(fade, "value", to: b.property(.opacity, of: dim.id, at: Point2(x: 1080, y: 1860)), "value")
        b.connect(pickSpring, "value", to: b.property(.opacity, of: check.id, at: Point2(x: 1080, y: 2040)), "value")
        b.connect(pop, "value", to: b.property(.scale, of: check.id, at: Point2(x: 1080, y: 2040)), "value")

        // Counting: every picked photo shows one invisible point-wide mark in a row of
        // marks that sizes to fit, so the row's width is the count. It is worked out from
        // what is picked, not from taps, so it never drifts.
        let markVisible = b.property(.visible, of: mark.id, at: Point2(x: 560, y: 1860))
        let count = b.attach("layerSize", to: tally.id, at: Point2(x: 820, y: 900))
        b.connect(picked, "on", to: markVisible, "value")

        // The title: the library's name, or what is chosen while choosing.
        let counted = b.add("joinText", at: Point2(x: 1080, y: 900), name: "Count Title", inputs: ["b": .text(" Selected")])
        let anything = b.add("if", at: Point2(x: 1340, y: 900), name: "Anything Picked", type: .text, inputs: [
            "else": .text("Select Items"),
        ])
        let heading = b.add("if", at: Point2(x: 1600, y: 720), name: "Title", type: .text, inputs: [
            "else": .text("Library"),
        ])
        let titleText = b.property(.text, of: title.id, at: Point2(x: 1860, y: 720))
        b.connect(count, "width", to: counted, "a")
        b.connect(count, "width", to: anything, "condition")
        b.connect(counted, "text", to: anything, "then")
        b.connect(selecting, "on", to: heading, "condition")
        b.connect(anything, "value", to: heading, "then")
        b.connect(heading, "value", to: titleText, "value")

        b.note("Mode · Select starts and ends choosing", around: [tapButton, selecting, buttonText, ended, modeSpring])
        b.note("Photos · One per value", around: [skies, hills, subjects])
        b.note("Pick · Each photo remembers it is picked", around: [touch, picked, pickSpring, shrink, round, fade, pop])
        b.note("Count · Picked photos, counted", around: [counted, anything, heading])

        return PhotoSelection(
            document: b.document, library: library.id, photo: photo.id, check: check.id, title: title.id,
            button: button.id, buttonLabel: buttonLabel.id, selecting: selecting, count: count
        )
    }
}
