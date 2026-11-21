import Foundation
import PaperModel

/// The shelf's side of the comparison with real SwiftUI: for each case of the reference
/// app (`Reference/ReferenceApp.swift`, same ids), a document that should look the same,
/// and the part of the screen to hold against the picture taken in the simulator.
public struct ReferenceCase: Identifiable, Sendable {
    public let id: String
    public let title: String
    /// The part of the 402 × 874 screen that is compared, in points.
    public let region: (x: Double, y: Double, width: Double, height: Double)
    public let make: @Sendable () -> Document

    public static let device = Size2(width: 402, height: 874)

    public static let all: [ReferenceCase] = {
        typealias Library = ComponentLibrary
        let status = SystemStyle.statusBarHeight
        @Sendable func screen() -> SampleDocuments.Builder {
            SampleDocuments.Builder(screen: Layer(name: "Screen", kind: .screen, properties: [
                .size: .size(device), .fill: .color(SystemStyle.groupedBackground.light),
            ]))
        }
        /// A control alone with its corner at (20, 100), as the reference app stands it.
        func alone(_ id: String, _ title: String, _ component: String, width: Double? = nil, inputs: [String: Value] = [:], tall: Double = 90) -> ReferenceCase {
            ReferenceCase(id: id, title: title, region: (0, 80, 402, tall)) {
                var b = screen()
                _ = b.place(Library.iOS(component), at: Point2(x: 20, y: 100), width: width, inputs: inputs)
                return b.document
            }
        }
        /// A pane of the shelf's glass over a backdrop drawn by a shader view, as the reference
        /// app draws it with a Canvas (`GlassOver`). Its inputs are the Glass template's.
        func glass(_ id: String, _ title: String, backdrop: String, frame: (x: Double, y: Double, width: Double, height: Double) = (51, 380, 300, 80)) -> ReferenceCase {
            ReferenceCase(id: id, title: title, region: (frame.x - 24, frame.y - 24, frame.width + 48, frame.height + 48)) {
                var behind = Layer(name: "Backdrop", kind: .view, properties: [.size: .size(device), .fill: .color(.white)])
                behind.shader = ShaderUse(source: backdrop)
                var pane = Library.glass("Glass", [
                    .position: .point(Point2(x: frame.x, y: frame.y)), .size: .size(Size2(width: frame.width, height: frame.height)),
                ], radius: min(frame.width, frame.height) / 2)
                pane.name = "Glass"
                var b = SampleDocuments.Builder(screen: Layer(name: "Screen", kind: .screen, properties: [
                    .size: .size(device), .fill: .color(.white),
                ], children: [behind, pane]))
                return b.document
            }
        }
        let checker = """
        float4 shader(Frame frame, Inputs in) {
            float2 cell = floor(frame.position / 20.0);
            bool dark = fmod(cell.x + cell.y, 2.0) > 0.5;
            return dark ? float4(0, 0, 0, 1) : float4(1, 1, 1, 1);
        }
        """
        let stripes = """
        float4 shader(Frame frame, Inputs in) {
            int i = int(floor(frame.position.x / 24.0)) % 4;
            if (i == 0) return float4(1, 0, 0, 1);
            if (i == 1) return float4(0, 1, 0, 1);
            if (i == 2) return float4(0, 0, 1, 1);
            return float4(1, 1, 0, 1);
        }
        """
        let bottom = device.height - 34
        return [
            alone("toggle-on", "Toggle, on", "Toggle", inputs: ["On": .bool(true)]),
            alone("toggle-off", "Toggle, off", "Toggle"),
            alone("slider", "Slider at half", "Slider", width: 280),
            alone("stepper", "Stepper", "Stepper"),
            alone("segmented", "Segmented Control", "Segmented Control", width: 300),
            alone("button-filled", "Button, filled", "Button", width: 200, tall: 100),
            alone("button-gray", "Button, gray", "Button", width: 200, inputs: ["Style": .text("Gray")], tall: 100),
            alone("button-tinted", "Button, tinted", "Button", width: 200, inputs: ["Style": .text("Tinted")], tall: 100),
            alone("button-plain", "Button, plain", "Button", width: 200, inputs: ["Style": .text("Plain")], tall: 100),
            ReferenceCase(id: "search-field", title: "Search Field under a large title", region: (0, 155, 402, 72)) {
                var b = screen()
                _ = b.place(Library.iOS("Search Field"), at: Point2(x: SystemStyle.margin, y: 169), width: device.width - 2 * SystemStyle.margin)
                return b.document
            },
            alone("menu-button", "Menu Button", "Menu Button", tall: 100),
            alone("activity", "Activity Indicator", "Activity Indicator", tall: 100),
            // As wide as UIKit's own for three pages, so the dots are centered on the same place.
            alone("page-control", "Page Control", "Page Control", width: 74, tall: 100),
            ReferenceCase(id: "sheet", title: "Sheet", region: (0, 300, 402, 574)) {
                var b = screen()
                let sheet = ComponentLibrary.sheet
                var document = b.document
                document.screen.insert(sheet.root, into: document.screen.id)
                for node in sheet.nodes { _ = document.graph.add(node) }
                for connection in sheet.connections { document.graph.connect(from: connection.from, to: connection.to) }
                for component in sheet.components { document.adopt(component) }
                b.document = document
                return b.document
            },
            ReferenceCase(id: "keyboard", title: "Keyboard", region: (0, 520, 402, 354)) {
                var b = screen()
                let keyboard = Library.iOS("Keyboard")
                let height = keyboard.root.value(.size).sizeValue.height
                _ = b.place(keyboard, at: Point2(x: 0, y: device.height - height), width: device.width)
                return b.document
            },
            glass("glass-checker", "Glass over a checkerboard", backdrop: checker),
            glass("glass-stripes", "Glass over colored stripes", backdrop: stripes),
            glass("glass-circle", "A circle of glass", backdrop: checker, frame: (161, 380, 80, 80)),
            alone("progress", "Progress Bar at half", "Progress Bar", width: 280, tall: 50),
            alone("text-field", "Text Field", "Text Field", width: 300, tall: 100),
            ReferenceCase(id: "tab-bar", title: "Tab Bar", region: (0, 740, 402, 134)) {
                var b = screen()
                // A picture taken of the simulator has no home indicator in it, so ours has none.
                _ = b.place(Library.iOS("Tab Bar"), at: Point2(x: 0, y: device.height - 83), width: device.width)
                return b.document
            },
            ReferenceCase(id: "nav-bar", title: "Navigation Bar", region: (0, 0, 402, 130)) {
                var b = screen()
                _ = b.place(Library.iOS("Status Bar"), width: device.width)
                _ = b.place(Library.iOS("Navigation Bar"), at: Point2(x: 0, y: status), width: device.width, inputs: [
                    "Shows Back": .bool(false), "Action": .text("Edit"),
                ])
                return b.document
            },
            ReferenceCase(id: "toolbar", title: "Toolbar", region: (0, 740, 402, 134)) {
                var b = screen()
                _ = b.place(Library.iOS("Toolbar"), at: Point2(x: 0, y: device.height - 76), width: device.width)
                return b.document
            },
            ReferenceCase(id: "alert", title: "Alert", region: (0, 200, 402, 480)) {
                var b = screen()
                _ = b.place(Library.iOS("Alert"), properties: [.size: .size(device)])
                return b.document
            },
            ReferenceCase(id: "action-sheet", title: "Action Sheet", region: (0, 300, 402, 300)) {
                var b = screen()
                _ = b.place(Library.iOS("Action Sheet"), inputs: ["Actions": .text("Duplicate, Delete"), "Destructive": .number(1)], properties: [.size: .size(device)])
                return b.document
            },
            ReferenceCase(id: "list", title: "Large title and a grouped list", region: (0, 0, 402, 520)) {
                let care = Library.Section(name: "Coverage", header: "", footer: "34 days left to protect your iPhone.", grows: true)
                let network = Library.Section(name: "Network", header: "", grows: true)
                let form = Layer(name: "Form", kind: .view, properties: [
                    .position: .point(Point2(x: 0, y: status + SystemStyle.barHeight)),
                    .size: .size(Size2(width: device.width, height: device.height - status - SystemStyle.barHeight)),
                    .fill: .color(SystemStyle.groupedBackground.light), .clips: .bool(true),
                    .layout: .text("Stack"), .axis: .text("Vertical"), .scrolls: .bool(true), .spacing: .number(SystemStyle.sectionGap),
                    .paddingHorizontal: .number(SystemStyle.margin), .paddingVertical: .number(SystemStyle.margin), .paddingTop: .number(52 + 10),
                ], children: [care.root, network.root])
                var b = SampleDocuments.Builder(screen: Layer(name: "Screen", kind: .screen, properties: [
                    .size: .size(device), .fill: .color(SystemStyle.groupedBackground.light),
                ], children: [form]))
                care.wire(&b, rows: [["Title": .text("Eligible to Add AppleCare")]])
                network.wire(&b, row: 2, rows: [
                    ["Title": .text("Airplane Mode"), "Symbol": .text("airplane"), "Accessory": .text("Switch")],
                    ["Title": .text("Wi-Fi"), "Symbol": .text("wifi"), "Detail": .text("Beacon")],
                    ["Title": .text("Bluetooth"), "Symbol": .text("dot.radiowaves.left.and.right"), "Detail": .text("On")],
                    ["Title": .text("Cellular"), "Symbol": .text("antenna.radiowaves.left.and.right")],
                ])
                _ = b.place(Library.iOS("Status Bar"), width: device.width)
                _ = b.place(Library.iOS("Large Title Bar"), at: Point2(x: 0, y: status), width: device.width, inputs: ["Title": .text("Settings")])
                return b.document
            },
        ]
    }()
}

extension ReferenceCase {
    /// The case's document as it would be in dark appearance, as the reference app is when
    /// the simulator is dark: every component and template given Dark, and the backgrounds
    /// the shelf takes from `SystemStyle` given their dark colors.
    public func makeDark() -> Document { Self.darkened(make()) }

    /// A document of the shelf as it would be in dark appearance (see `makeDark`).
    public static func darkened(_ document: Document) -> Document {
        var document = document
        let swaps: [(ColorValue, ColorValue)] = [SystemStyle.groupedBackground].map { ($0.light, $0.dark) }
        let components = document.components
        func darken(_ layer: inout Layer) {
            if var use = layer.component, let port = components.first(where: { $0.id == use.id })?.input(named: "Dark") {
                use.inputs[port] = .bool(true)
                layer.component = use
            }
            for (light, dark) in swaps where layer.properties[.fill] == .color(light) { layer.set(.fill, .color(dark)) }
            // Glass takes its dark tint, as the shelf's components give it with Dark.
            if layer.shader?.source == SystemStyle.glassShader { layer.shader?.inputs["tint"] = .color(SystemStyle.glassTint.dark) }
            for index in layer.children.indices { darken(&layer.children[index]) }
        }
        darken(&document.screen)
        // Templates (a Sheet, a List Section) keep Dark in a value patch they publish.
        for node in document.graph.nodes where node.kind == "value" && node.name == "Dark" {
            _ = document.graph.update(node.id) { $0.inputs["value"] = .bool(true) }
        }
        return document
    }
}
