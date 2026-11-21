import Foundation
import PaperModel

/// The shelf's side of comparing motion with real SwiftUI: for each moving case of the
/// reference app (`Reference/ReferenceApp.swift`, same ids), a document at rest and the
/// tap that sets it going, the part of the screen to follow, and lines along which the
/// moving edge is found frame by frame.
///
/// The reference app makes the same change itself a few seconds after it opens, and the
/// simulator records the screen; `Redline.motion` lines the two up where each starts to
/// move and compares how they get there.
public struct ReferenceMotion: Identifiable, Sendable {
    public let id: String
    public let title: String
    /// The part of the 402 × 874 screen that is followed, in points.
    public let region: (x: Double, y: Double, width: Double, height: Double)
    /// Where ours is tapped to set it going.
    public let tap: Point2
    /// How long after it starts to move both are followed.
    public let seconds: Double
    public let tracks: [Track]
    public let make: @Sendable () -> Document

    /// A line along which the first edge is found in every frame: where the moving thing
    /// is, in points from `from`.
    public struct Track: Sendable {
        public let name: String
        public let from: Point2
        public let to: Point2
        public init(_ name: String, from: Point2, to: Point2) {
            self.name = name; self.from = from; self.to = to
        }
    }

    public func makeDark() -> Document { ReferenceCase.darkened(make()) }

    /// The color a pushed or covering screen has on both sides, far from the gray it covers.
    public static let arriving = ColorValue(hex: "#5AC8FA")!

    public static let all: [ReferenceMotion] = {
        typealias Library = ComponentLibrary
        let device = ReferenceCase.device
        let gray = SystemStyle.groupedBackground.light
        @Sendable func screen(_ children: [Layer] = []) -> SampleDocuments.Builder {
            SampleDocuments.Builder(screen: Layer(name: "Screen", kind: .screen, properties: [
                .size: .size(device), .fill: .color(gray),
            ], children: children))
        }
        /// A view the size of the screen behind everything, whose Tap sets a presentation going:
        /// the reference app presents it from code, which a person cannot tap.
        @Sendable func catcher() -> Layer {
            Layer(name: "Trigger", kind: .view, properties: [.size: .size(device), .fill: .color(gray)])
        }
        func presenting(_ id: String, _ title: String, _ component: String, inputs: [String: Value] = [:], region: (Double, Double, Double, Double)) -> ReferenceMotion {
            ReferenceMotion(id: id, title: title, region: region, tap: Point2(x: 201, y: 120), seconds: 1.5, tracks: [
                Track("Card's left edge", from: Point2(x: 1, y: 437), to: Point2(x: 201, y: 437)),
            ]) {
                let trigger = catcher()
                var b = screen([trigger])
                var given = inputs
                given["Presented"] = .bool(false)
                let placed = b.place(Library.iOS(component), inputs: given, properties: [.size: .size(device)], patchAt: Point2(x: 336, y: 96))
                let tap = b.attach(PatchKind.tap, to: trigger.id, at: Point2(x: 48, y: 96))
                if let node = placed.node { b.wire(tap, "tapped", to: node, "Present") }
                return b.document
            }
        }
        /// Two screens, the second the color that arrives, and a Tap on the first that goes to it.
        func navigating(_ id: String, _ title: String, style: Navigation.Style, track: Track) -> ReferenceMotion {
            ReferenceMotion(id: id, title: title, region: (0, 0, 402, 874), tap: Point2(x: 201, y: 437), seconds: 1.5, tracks: [track]) {
                var home = Layer.newPage(name: "Home")
                home.properties[.fill] = .color(gray)
                let trigger = catcher()
                home.children = [trigger]
                var next = Layer.newPage(name: "Next")
                next.properties[.fill] = .color(arriving)
                var b = SampleDocuments.Builder(screen: Layer(name: "Device", kind: .screen, properties: [
                    .size: .size(device), .fill: .color(.black),
                ], children: [home, next]))
                let tap = b.attach(PatchKind.tap, to: trigger.id, at: Point2(x: 48, y: 96))
                let go = b.attach(PatchKind.navigate, to: next.id, at: Point2(x: 48, y: 240), inputs: ["style": .text(style.rawValue)])
                b.connect(tap, "tapped", to: go, "go")
                return b.document
            }
        }
        let bottom = device.height
        return [
            ReferenceMotion(id: "motion-toggle", title: "Toggle turning on", region: (0, 80, 402, 70), tap: Point2(x: 51, y: 114), seconds: 1, tracks: [
                // From just inside the track's left end: the first edge is the knob's.
                Track("Knob's left edge", from: Point2(x: 21, y: 114), to: Point2(x: 82, y: 114)),
            ]) {
                var b = screen()
                _ = b.place(Library.iOS("Toggle"), at: Point2(x: 20, y: 100))
                return b.document
            },
            ReferenceMotion(id: "motion-segmented", title: "Segmented Control choosing the second", region: (0, 80, 402, 70), tap: Point2(x: 170, y: 116), seconds: 1, tracks: []) {
                var b = screen()
                _ = b.place(Library.iOS("Segmented Control"), at: Point2(x: 20, y: 100), width: 300)
                return b.document
            },
            ReferenceMotion(id: "motion-tab-bar", title: "Tab Bar choosing the second tab", region: (0, 740, 402, 134), tap: Point2(x: 201, y: 822), seconds: 1.2, tracks: []) {
                var b = screen()
                _ = b.place(Library.iOS("Tab Bar"), at: Point2(x: 0, y: bottom - 83), width: device.width)
                return b.document
            },
            ReferenceMotion(id: "motion-sheet", title: "Sheet coming up", region: (0, 0, 402, 874), tap: Point2(x: 201, y: 120), seconds: 1.5, tracks: [
                Track("Sheet's top", from: Point2(x: 201, y: 200), to: Point2(x: 201, y: 873)),
            ]) {
                let trigger = catcher()
                var b = screen([trigger])
                var document = b.document
                let sheet = ComponentLibrary.sheet
                document.screen.insert(sheet.root, into: document.screen.id)
                for node in sheet.nodes { _ = document.graph.add(node) }
                for connection in sheet.connections { document.graph.connect(from: connection.from, to: connection.to) }
                for component in sheet.components { document.adopt(component) }
                b.document = document
                let tap = b.attach(PatchKind.tap, to: trigger.id, at: Point2(x: 48, y: 96))
                // The sheet starts away, and the Tap is cabled to what its Present stands for.
                let published = b.document.graph.viewNode(layer: sheet.root.id)?.published ?? []
                if let presented = published.first(where: { $0.name == "Presented" })?.inner {
                    _ = b.document.graph.update(presented.node) { $0.inputs[presented.port] = .bool(false) }
                }
                if let present = published.first(where: { $0.name == "Present" })?.inner {
                    b.connect(tap, "tapped", to: present.node, present.port)
                }
                return b.document
            },
            presenting("motion-alert", "Alert coming up", "Alert", region: (0, 200, 402, 480)),
            presenting("motion-action-sheet", "Action Sheet coming up", "Action Sheet", inputs: [
                "Actions": .text("Duplicate, Delete"), "Destructive": .number(1),
            ], region: (0, 300, 402, 300)),
            navigating("motion-push", "Push to the next screen", style: .push, track: Track(
                "Arriving screen's left edge", from: Point2(x: 1, y: 437), to: Point2(x: 401, y: 437)
            )),
            navigating("motion-cover", "Full-screen cover (Modal)", style: .modal, track: Track(
                "Arriving screen's top", from: Point2(x: 201, y: 1), to: Point2(x: 201, y: 873)
            )),
        ]
    }()
}
