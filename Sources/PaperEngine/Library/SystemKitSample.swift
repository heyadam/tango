import Foundation
import PaperModel

extension SampleDocuments {
    public struct SystemKit {
        public let document: Document
        public let form: LayerID
        public let bar: LayerID
        public let alert: LayerID
        public let signOut: LayerID
        public let airplane: LayerID
        public let tabs: LayerID
    }

    /// The first screen of Settings on an iPhone, made of the iOS shelf: a status bar, a
    /// large title that shrinks as the form scrolls, grouped sections, a row with a switch,
    /// a floating tab bar, and a row that brings up an alert. Three cables are all it has.
    /// Its sizes are the ones measured on a phone; only the card with a picture at the top
    /// is drawn by hand, as an app's own views would be.
    public static func systemKit() -> SystemKit {
        typealias Library = ComponentLibrary
        let device = Size2(width: 402, height: 874)
        let barTop = SystemStyle.statusBarHeight, collapsed = SystemStyle.barHeight, travel = 52.0
        let tile = ColorValue(hex: "#363636")!
        func section(_ name: String, footer: String = "") -> Library.Section { Library.Section(name: name, header: "", footer: footer, grows: true) }
        let account = section("Account"), care = section("Coverage", footer: "34 days left to protect your iPhone.")
        let network = section("Network"), general = section("General")
        let form = Layer(name: "Form", kind: .view, properties: [
            .position: .point(Point2(x: 0, y: barTop + collapsed)), .size: .size(Size2(width: device.width, height: device.height - barTop - collapsed)),
            .fill: .color(SystemStyle.groupedBackground.light), .clips: .bool(true),
            .layout: .text("Stack"), .axis: .text("Vertical"), .scrolls: .bool(true), .spacing: .number(SystemStyle.sectionGap),
            .paddingHorizontal: .number(SystemStyle.margin), .paddingVertical: .number(SystemStyle.margin),
            // The content begins ten points under the large title and ends above the tab bar.
            .paddingTop: .number(travel + 10), .paddingBottom: .number(130),
        ], children: [account.root, care.root, network.root, general.root])
        // Clear, as the bar under it is until the title has gone into it.
        let statusBackground = Layer(name: "Status Background", kind: .view, properties: [
            .size: .size(Size2(width: device.width, height: barTop)), .fill: .color(SystemStyle.groupedBackground.light),
        ])
        let screen = Layer(name: "Screen", kind: .screen, properties: [
            .size: .size(device), .fill: .color(SystemStyle.groupedBackground.light),
        ], children: [form, statusBackground])

        var b = Builder(screen: screen)
        func at(_ column: Double, _ row: Double) -> Point2 { Point2(x: 60 + column * 300, y: 60 + row * 260) }
        func row(_ title: String, _ symbol: String, _ more: [String: Value] = [:]) -> [String: Value] {
            ["Title": .text(title), "Symbol": .text(symbol), "Symbol Color": .color(tile)].merging(more) { _, new in new }
        }
        account.wire(&b, column: 0, row: 8, rows: [])
        care.wire(&b, column: 0, row: 9, rows: [["Title": .text("Eligible to Add AppleCare")]])
        let networkRows = network.wire(&b, column: 0, row: 10, rows: [
            row("Airplane Mode", "airplane", ["Accessory": .text("Switch")]),
            row("Wi-Fi", "wifi", ["Detail": .text("Beacon")]),
            row("Bluetooth", "dot.radiowaves.left.and.right", ["Detail": .text("On")]),
            row("Cellular", "antenna.radiowaves.left.and.right"),
            row("Personal Hotspot", "personalhotspot"),
            row("Battery", "battery.100percent"),
            row("VPN", "network", ["Detail": .text("Not Connected")]),
        ])
        let generalRows = general.wire(&b, column: 0, row: 11, rows: [
            row("General", "gear"), row("Accessibility", "accessibility"),
            ["Title": .text("Sign Out"), "Accessory": .text("None")],
        ], patchesAt: { $0 == 2 ? at(1, 1) : nil })

        // The card at the top is the app's own: a picture, a name and a line under it.
        let picture = Layer(name: "Picture", kind: .view, properties: [
            .size: .size(Size2(width: 60, height: 60)), .cornerRadius: .number(30), .fill: .color(ColorValue(hex: "#B5B5BA")!),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .distribution: .text("Center"),
        ], children: [Library.symbol("Person", "person.fill", width: 34, height: 34, color: .white)])
        let name = Library.text("Name", "Ada Lovelace", size: SystemStyle.title3.size, weight: SystemStyle.title3.weight, [.widthMode: .text("Grow")])
        let line = Library.text("Line", "Apple Account, iCloud+, and more", size: SystemStyle.subheadline.size, color: SystemStyle.secondaryLabel.light, [.widthMode: .text("Grow")])
        let words = Library.group("Words", [
            .widthMode: .text("Grow"), .heightMode: .text("Auto"), .layout: .text("Stack"), .axis: .text("Vertical"), .spacing: .number(1),
        ], [name, line])
        let profile = Library.group("Profile", [
            .size: .size(Size2(width: 370, height: 90)), .widthMode: .text("Grow"), .layout: .text("Stack"), .axis: .text("Horizontal"),
            .alignment: .text("Center"), .paddingHorizontal: .number(SystemStyle.rowInset), .paddingVertical: .number(0),
            .paddingRight: .number(SystemStyle.rowTrailing), .spacing: .number(8),
        ], [picture, words, Library.symbol("Chevron", "chevron.right", width: 9, height: 15, color: SystemStyle.tertiaryLabel.light, weight: 600)])
        b.document.screen.insert(profile, into: account.rows.id)

        _ = b.place(Library.iOS("Status Bar"), width: device.width, inputs: ["Time": .text("6:44")])
        let bar = b.place(Library.iOS("Large Title Bar"), at: Point2(x: 0, y: barTop), width: device.width, inputs: ["Title": .text("Settings")], patchAt: at(1, 0))
        let tabs = b.place(Library.iOS("Tab Bar"), at: Point2(x: 0, y: device.height - 83), width: device.width, inputs: [
            "Titles": .text("Settings, Search, Updates"), "Symbols": .text("gearshape.fill, magnifyingglass, square.and.arrow.down"),
        ])
        _ = b.place(Library.iOS("Home Indicator"), at: Point2(x: 0, y: device.height - 34), width: device.width)
        let alert = b.place(Library.iOS("Alert"), inputs: [
            "Title": .text("Sign Out?"), "Message": .text("You will need your password to sign in again."),
            "Buttons": .text("Cancel, Sign Out"), "Presented": .bool(false),
        ], properties: [.size: .size(device)], patchAt: at(2, 1))
        // The form's offset shrinks the title; a tap on Sign Out brings the alert.
        b.wire(b.view(form.id, at: at(0, 0)), "offset", to: bar.node!, "Scroll Offset")
        b.wire(generalRows[2].node!, "Tap", to: alert.node!, "Present")
        return SystemKit(
            document: b.document, form: form.id, bar: bar.layer, alert: alert.layer, signOut: generalRows[2].layer,
            airplane: networkRows[0].layer, tabs: tabs.layer
        )
    }
}
