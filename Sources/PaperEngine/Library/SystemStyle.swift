import Foundation
import PaperModel

/// The numbers the iOS shelf is drawn with: system colors in both appearances, the text
/// styles and the usual measures. A control takes its numbers from here, so the shelf reads
/// as one system and a change to a token reaches every control.
public enum SystemStyle {
    /// A color with a value for each appearance.
    public struct Dynamic: Sendable, Equatable {
        public let light: ColorValue
        public let dark: ColorValue

        public init(_ light: String, _ dark: String) {
            self.light = ColorValue(hex: light)!
            self.dark = ColorValue(hex: dark)!
        }

        public init(light: ColorValue, dark: ColorValue) {
            self.light = light
            self.dark = dark
        }
    }

    // MARK: Colors

    public static let label = Dynamic("#000000", "#FFFFFF")
    public static let secondaryLabel = Dynamic("#8E8E93", "#98989F")
    public static let tertiaryLabel = Dynamic("#C7C7CC", "#48484A")
    public static let placeholder = Dynamic("#B5B5BA", "#5A5A5F")
    public static let separator = Dynamic("#C6C6C8", "#38383A")
    /// The line between two rows of a list: a point thick and faint.
    public static let listSeparator = Dynamic("#ECECED", "#2C2C2E")
    /// What a screen is filled with behind grouped rows.
    public static let groupedBackground = Dynamic("#F2F2F7", "#000000")
    /// A row, a card or an alert on top of that.
    public static let surface = Dynamic("#FFFFFF", "#1C1C1E")
    /// A sheet or a menu, one step above a surface.
    public static let elevated = Dynamic("#FFFFFF", "#2C2C2E")
    /// A bar is a material: partly clear, over a blur of what scrolls under it (`barBlur`).
    public static let bar = Dynamic("#F9F9F9D9", "#161618D9")
    public static let barBlur = 20.0
    /// The track of a switch or a slider, the body of a stepper or a segmented control.
    public static let controlFill = Dynamic("#E9E9EB", "#39393D")
    /// A stepper's body, which in dark is near black, not the gray of a track (simulator).
    public static let stepperFill = Dynamic("#E2E2E8", "#121213")
    /// The pill under a tab bar's chosen tab, on its glass.
    public static let tabPill = Dynamic("#E5E4EA", "#0A0A0A")
    /// An alert's card, the gray capsules its buttons are, and its message.
    public static let alertSurface = Dynamic("#E7E7EB", "#2C2C2E")
    public static let alertButton = Dynamic("#CCCCD0", "#48484A")
    public static let alertMessage = Dynamic("#7B7B7D", "#98989F")
    /// The card of a confirmation dialog and the gray capsules its choices are.
    public static let sheetSurface = Dynamic("#F5F5FB", "#2C2C2E")
    public static let sheetButton = Dynamic("#DCDCE0", "#48484A")
    /// The part of a slider's track that is not filled.
    public static let sliderTrack = Dynamic("#E1E1E5", "#39393D")
    /// The hairline round a bordered text field.
    public static let fieldBorder = Dynamic("#D6D6D6", "#3A3A3C")
    /// The track of a switch that is off.
    public static let switchOff = Dynamic("#D0D0D1", "#39393D")
    /// The fill of a search field or a gray button.
    public static let fieldFill = Dynamic("#E3E3E8", "#2C2C2E")
    /// The chosen segment of a segmented control.
    public static let selectedSegment = Dynamic("#FFFFFF", "#636366")
    public static let pressed = Dynamic("#D1D1D6", "#3A3A3C")
    public static let dim = Dynamic(light: ColorValue(white: 0, alpha: 0.2), dark: ColorValue(white: 0, alpha: 0.48))

    public static let blue = Dynamic("#007AFF", "#0A84FF")
    public static let green = Dynamic("#34C759", "#30D158")
    public static let red = Dynamic("#FF3B30", "#FF453A")

    // MARK: Text

    public struct TextStyle: Sendable, Equatable {
        public let size: Double
        public let weight: Double
    }

    public static let largeTitle = TextStyle(size: 34, weight: 700)
    public static let title2 = TextStyle(size: 22, weight: 700)
    public static let title3 = TextStyle(size: 20, weight: 600)
    public static let headline = TextStyle(size: 17, weight: 600)
    public static let body = TextStyle(size: 17, weight: 400)
    public static let subheadline = TextStyle(size: 15, weight: 400)
    public static let footnote = TextStyle(size: 13, weight: 400)
    public static let caption = TextStyle(size: 12, weight: 400)
    /// The label of a segment.
    public static let segment = TextStyle(size: 13, weight: 500)
    /// The label under a tab's symbol.
    public static let tab = TextStyle(size: 10, weight: 500)

    // MARK: Measures

    // Measured on an iPhone 17 Pro running iOS 26 (402 × 874 points), in Settings. That
    // phone's text was set one size down from the default (body 15), where a row is 50
    // points; the text styles above are the default ones, and a row is its line taller.

    /// The height of a row of a list.
    public static let rowHeight = 52.0
    /// The height of a row of a menu, and the smallest thing a finger is asked to hit.
    public static let menuRowHeight = 44.0
    public static let barHeight = 44.0
    /// The room at the top of the screen that the time and the battery have.
    public static let statusBarHeight = 62.0
    /// The space between the edge of the screen and what is on it.
    public static let margin = 16.0
    /// The space between the edge of a row and what is in it, and between the things in it.
    /// SwiftUI's `List` on iOS 26, measured in the simulator (Reference/run.sh). Settings,
    /// which the rest was first measured from, stands its rows' content 20 in.
    public static let rowInset = 16.0
    public static let rowSpacing = 10.0
    /// How far from the edge a chevron or a checkmark stands, and a switch.
    public static let rowTrailing = 16.5
    public static let switchTrailing = 14.0
    /// The square a row's symbol is on, and how far in it stands.
    public static let tileSize = 28.0
    public static let tileInset = 14.0
    /// Where a row's text begins when it has a symbol, from the row's edge.
    public static let tileTextInset = 56.0
    /// The space between one grouped section and the next, from rows to rows.
    public static let sectionGap = 35.0
    /// A switch and the knob in it, which stands two points in from the track.
    public static let switchSize = Size2(width: 63, height: 28)
    public static let knobSize = Size2(width: 37, height: 24)
    /// The corners of a grouped section, an alert, a sheet.
    public static let groupRadius = 26.0
    public static let alertRadius = 14.0
    /// A sheet that is not full height, measured in the simulator: 8 points in from the
    /// sides and the bottom, its top corners 36. (Its bottom corners follow the phone's, 53;
    /// a view has one radius, so ours are 36 too.)
    public static let sheetRadius = 36.0
    public static let sheetInset = 8.0
    /// Its glass, over the dim: what shows through it is mostly the dim itself.
    public static let sheetGlass = Dynamic(light: ColorValue(red: 1, green: 1, blue: 1, alpha: 0.54), dark: ColorValue(red: 0.17, green: 0.17, blue: 0.18, alpha: 0.82))
    public static let fieldRadius = 10.0
    public static let spring: [String: Value] = ["response": .number(0.3), "damping": .number(0.85)]
}

extension ComponentLibrary {
    /// A component's Dark input and the colors that follow it.
    ///
    /// A control does not follow the Mac's appearance by itself: what a person draws around
    /// it has fixed colors, so a control that turned dark alone would not match. Dark is an
    /// input like any other; cable Device Info's Dark Mode into it to follow the device.
    ///
    /// Make one after every patch a shipped control already had, so their ids stay.
    struct Look {
        let dark: NodeID
        private let column: Double
        private var row: Double

        /// Adds the Dark input at (`column`, `row`); the colors go below it.
        init(_ b: inout Builder, column: Double = 0, row: Double) {
            dark = b.input("Dark", .bool, .bool(false), at: at(column, row))
            self.column = column
            self.row = row
        }

        /// A patch whose `value` is the color for the appearance.
        mutating func color(_ b: inout Builder, _ token: SystemStyle.Dynamic, _ name: String) -> NodeID {
            row += 1
            let choice = b.add("if", at: at(column + 1, row), name: name, type: .color, inputs: [
                "then": .color(token.dark), "else": .color(token.light),
            ])
            b.connect(dark, "value", to: choice, "condition")
            return choice
        }

        /// Gives a property of a view the color for the appearance.
        mutating func paint(_ b: inout Builder, _ token: SystemStyle.Dynamic, _ name: String, _ property: LayerProperty, of layers: Layer...) {
            let choice = color(&b, token, name)
            for layer in layers {
                b.connect(choice, "value", to: b.property(property, of: layer.id, at: at(column + 2, row)), "value")
            }
        }
    }
}
