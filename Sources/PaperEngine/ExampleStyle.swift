import Foundation
import PaperModel

/// The look every example in the gallery shares, so they read as one set: an iPhone 18 Pro
/// screen (402 × 874) with room for the status bar and the home indicator, one palette, one
/// set of text sizes, and a hint at the bottom that says what to try. A gallery example is
/// for showing one idea, so each keeps to a few views and says in its graph, with comments,
/// which patches make the idea work.
public enum ExampleStyle {
    /// iPhone 18 Pro, the size new documents start at.
    public static let device = Size2(width: 402, height: 874)
    /// The status bar.
    public static let top = 62.0
    /// The home indicator.
    public static let bottom = 34.0
    /// The space at each side of the screen.
    public static let margin = 20.0
    /// The width between the margins.
    public static var column: Double { device.width - margin * 2 }

    // MARK: Colors

    /// The page: a warm white, so white cards stand out from it.
    public static let paper = ColorValue(hex: "#F4F2EE")!
    public static let surface = ColorValue(white: 1)
    public static let ink = ColorValue(hex: "#18181D")!
    public static let secondary = ColorValue(hex: "#6E6C75")!
    public static let tertiary = ColorValue(hex: "#A8A6AE")!
    public static let hairline = ColorValue(hex: "#E6E2DA")!
    /// The one color things that act are drawn in.
    public static let accent = ColorValue(hex: "#4B5CF0")!
    public static let night = ColorValue(hex: "#14162B")!

    public static let coral = ColorValue(hex: "#FF7059")!
    public static let amber = ColorValue(hex: "#FFB340")!
    public static let sage = ColorValue(hex: "#5DB48A")!
    public static let sky = ColorValue(hex: "#5AA9FF")!
    public static let plum = ColorValue(hex: "#8466F5")!
    public static let rose = ColorValue(hex: "#F2678E")!
    public static let teal = ColorValue(hex: "#22A69B")!

    /// A soft shadow for cards that lie on the page.
    public static let shadow = ColorValue(red: 0.1, green: 0.08, blue: 0.2, alpha: 0.12)

    // MARK: Views

    /// A text view that is as big as its words, or as wide as `width` and as tall as its lines.
    public static func text(
        _ name: String, _ string: String, at point: Point2 = .zero, size: Double = 17, weight: Double = 400,
        color: ColorValue = ink, width: Double? = nil, height: Double? = nil, align: String? = nil
    ) -> Layer {
        var properties: [LayerProperty: Value] = [
            .position: .point(point), .text: .text(string), .fontSize: .number(size), .fontWeight: .number(weight),
            .textColor: .color(color), .heightMode: .text("Auto"),
        ]
        if let width {
            properties[.size] = .size(Size2(width: width, height: height ?? size * 1.3))
            properties[.widthMode] = .text("Fixed")
            if height != nil { properties[.heightMode] = .text("Fixed") }
        } else {
            properties[.widthMode] = .text("Auto")
        }
        if let align { properties[.textAlignment] = .text(align) }
        return Layer(name: name, kind: .text, properties: properties)
    }

    public static func symbol(
        _ name: String, _ symbol: String, at point: Point2 = .zero, side: Double = 24, color: ColorValue = ink,
        weight: Double? = nil
    ) -> Layer {
        var properties: [LayerProperty: Value] = [
            .position: .point(point), .size: .size(Size2(width: side, height: side)),
            .symbol: .text(symbol), .fill: .color(color),
        ]
        if let weight { properties[.fontWeight] = .number(weight) }
        return Layer(name: name, kind: .symbol, properties: properties)
    }

    /// A small heading over a big one, as at the top of a screen: "TODAY" over "Discover".
    public static func header(_ kicker: String, _ title: String, top: Double = ExampleStyle.top + 14, color: ColorValue = ink) -> [Layer] {
        [
            text("Kicker", kicker.uppercased(), at: Point2(x: margin, y: top), size: 13, weight: 600,
                 color: color == ink ? secondary : color.withAlpha(0.7)),
            text("Title", title, at: Point2(x: margin, y: top + 20), size: 34, weight: 700, color: color),
        ]
    }

    /// What to try, in a pill across the middle of the screen at `y`. It listens for no
    /// touches, so it never takes one from what is under it.
    public static func hint(_ words: String, symbol: String = "hand.tap.fill", y: Double = device.height - bottom - 48, dark: Bool = false) -> Layer {
        let ink = dark ? ColorValue(white: 1) : ExampleStyle.ink
        let pill = Layer(name: "Pill", kind: .view, properties: [
            .size: .size(Size2(width: 100, height: 36)), .widthMode: .text("Auto"),
            .fill: .color(dark ? ColorValue(white: 1, alpha: 0.16) : ColorValue(white: 1, alpha: 0.92)),
            .cornerRadius: .number(18),
            .strokeColor: .color(dark ? ColorValue(white: 1, alpha: 0.22) : hairline), .strokeWidth: .number(1),
            .shadowColor: .color(dark ? .clear : shadow), .shadowRadius: .number(12), .shadowOffset: .point(Point2(x: 0, y: 4)),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
            .spacing: .number(8), .paddingHorizontal: .number(16), .paddingVertical: .number(0),
        ], children: [
            ExampleStyle.symbol("Glyph", symbol, side: 15, color: dark ? ink : accent),
            text("Words", words, size: 14, weight: 600, color: ink),
        ])
        return Layer(name: "Hint", kind: .view, properties: [
            .position: .point(Point2(x: 0, y: y)), .size: .size(Size2(width: device.width, height: 36)),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .distribution: .text("Center"),
        ], children: [pill])
    }

    /// A picture drawn with views: a sky, a sun, two hills and something in front. Used
    /// where an example needs a photo, so no example carries a picture file.
    public static func scene(
        _ name: String, size: Size2, sky: ColorValue, hills: (far: ColorValue, near: ColorValue),
        sun: ColorValue = ColorValue(white: 1, alpha: 0.85), subject: String? = nil, radius: Double = 0
    ) -> Layer {
        let w = size.width, h = size.height
        var children: [Layer] = [
            Layer(name: "Sun", kind: .ellipse, properties: [
                .position: .point(Point2(x: w * 0.68, y: h * 0.16)), .size: .size(Size2(width: h * 0.2, height: h * 0.2)),
                .fill: .color(sun),
            ]),
            Layer(name: "Far Hill", kind: .ellipse, properties: [
                .position: .point(Point2(x: -w * 0.25, y: h * 0.52)), .size: .size(Size2(width: w * 1.1, height: h * 0.9)),
                .fill: .color(hills.far),
            ]),
            Layer(name: "Near Hill", kind: .ellipse, properties: [
                .position: .point(Point2(x: w * 0.3, y: h * 0.66)), .size: .size(Size2(width: w * 1.1, height: h * 0.8)),
                .fill: .color(hills.near),
            ]),
        ]
        if let subject {
            let side = h * 0.3
            children.append(ExampleStyle.symbol("Subject", subject, at: Point2(x: w * 0.18, y: h * 0.46 - side / 2), side: side,
                                                color: ColorValue(white: 1, alpha: 0.95)))
        }
        return Layer(name: name, kind: .view, properties: [
            .size: .size(size), .fill: .color(sky), .clips: .bool(true), .cornerRadius: .number(radius),
        ], children: children)
    }

    /// A round button with a symbol in it, such as a close button over a picture.
    public static func roundButton(_ name: String, symbol: String, at point: Point2, side: Double = 36, light: Bool = true) -> Layer {
        Layer(name: name, kind: .view, properties: [
            .position: .point(point), .size: .size(Size2(width: side, height: side)), .cornerRadius: .number(side / 2),
            .fill: .color(light ? ColorValue(white: 1, alpha: 0.9) : ColorValue(white: 0, alpha: 0.35)),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .distribution: .text("Center"),
        ], children: [ExampleStyle.symbol("Glyph", symbol, side: side * 0.4, color: light ? ink : .white, weight: 700)])
    }

    /// A button as wide as `width`, with its title in the middle.
    public static func button(
        _ name: String, _ title: String, at point: Point2, width: Double = column, height: Double = 54,
        fill: ColorValue = accent, color: ColorValue = .white
    ) -> Layer {
        Layer(name: name, kind: .view, properties: [
            .position: .point(point), .size: .size(Size2(width: width, height: height)),
            .fill: .color(fill), .cornerRadius: .number(height / 2),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .distribution: .text("Center"),
        ], children: [text("Label", title, size: 17, weight: 600, color: color)])
    }

    /// A round tile with a letter or two, for a person.
    public static func avatar(_ name: String = "Avatar", initials: String, color: ColorValue, side: Double = 40) -> Layer {
        Layer(name: name, kind: .view, properties: [
            .size: .size(Size2(width: side, height: side)), .cornerRadius: .number(side / 2), .fill: .color(color),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .distribution: .text("Center"),
        ], children: [text("Initials", initials, size: side * 0.38, weight: 700, color: .white)])
    }
}

extension ColorValue {
    func withAlpha(_ alpha: Double) -> ColorValue { ColorValue(red: red, green: green, blue: blue, alpha: alpha) }
}
