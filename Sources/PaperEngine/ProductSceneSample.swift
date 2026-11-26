import Foundation
import PaperModel

extension SampleDocuments {
    public struct ProductScene {
        public let document: Document
        /// The scene view the speaker stands in.
        public let stage: LayerID
        public let swatches: [LayerID]
        public let turn: NodeID
        /// The colors the swatches give the speaker, in their order.
        public static let finishes: [ColorValue] = [
            ColorValue(hex: "#2E3A8C")!, ColorValue(hex: "#D9614C")!, ColorValue(hex: "#E9E4D8")!,
        ]
        public static let finishNames = ["Midnight", "Terracotta", "Bone"]
        /// The ids of the things in the scene, which name their ports.
        public static let body = "body", band = "band", stand = "stand"
    }

    /// A speaker in three dimensions on a stand, drawn by a scene view with real light:
    /// with rays it casts a shadow and its metal band mirrors the room. A drag turns the
    /// camera round it and a spring brings it back to the front; a swatch recolors it.
    public static func productScene() -> ProductScene {
        typealias S = ExampleStyle
        typealias P = ProductScene
        let scene = SceneUse(objects: [
            SceneObject(id: P.body, name: "Body", shape: .capsule, values: [
                "color": .color(P.finishes[0]), "roughness": .number(0.55), "scale": .number(1.25), "y": .number(0.125),
            ]),
            SceneObject(id: P.band, name: "Band", shape: .torus, values: [
                "color": .color(ColorValue(hex: "#F1C987")!), "metalness": .number(1), "roughness": .number(0.18),
                "scale": .number(0.86), "y": .number(0.2),
            ]),
            SceneObject(id: P.stand, name: "Stand", shape: .cylinder, values: [
                "color": .color(ColorValue(white: 0.93)), "roughness": .number(0.9), "scale": .number(1.9), "y": .number(-1.45),
            ]),
        ], values: ["cameraPitch": .number(14), "cameraDistance": .number(4.1), "lightYaw": .number(-40), "lightPitch": .number(55)])
        var stage = Layer.new(.scene, name: "Stage")
        stage.scene = scene
        stage.properties = [
            .position: .point(Point2(x: S.margin, y: 152)), .size: .size(Size2(width: S.device.width - S.margin * 2, height: 420)),
            .fill: .color(S.surface), .cornerRadius: .number(32), .clips: .bool(true),
            .shadowColor: .color(S.shadow), .shadowRadius: .number(20), .shadowOffset: .point(Point2(x: 0, y: 8)),
        ]
        stage.children = [
            S.text("Tag", "NEW", at: Point2(x: 22, y: 20), size: 12, weight: 700, color: S.accent),
            S.text("Price", "$189", at: Point2(x: 22, y: 376), size: 22, weight: 700),
        ]

        let side = 40.0, gap = 16.0
        let left = (S.device.width - side * 3 - gap * 2) / 2
        let swatches = P.finishes.enumerated().map { index, color in
            Layer(name: P.finishNames[index], kind: .ellipse, properties: [
                .position: .point(Point2(x: left + Double(index) * (side + gap), y: 632)),
                .size: .size(Size2(width: side, height: side)), .fill: .color(color),
                .strokeColor: .color(S.surface), .strokeWidth: .number(3),
                .shadowColor: .color(S.shadow), .shadowRadius: .number(8), .shadowOffset: .point(Point2(x: 0, y: 3)),
            ])
        }
        let caption = S.text("Caption", "Three finishes", at: Point2(x: 0, y: 600), size: 13, weight: 600,
                             color: S.secondary, width: S.device.width, align: "Center")
        let screen = Layer(name: "Screen", kind: .screen, properties: [.fill: .color(S.paper)],
                           children: S.header("Studio", "Orbit Speaker") + [stage, caption] + swatches
                               + [S.hint("Drag to turn it", symbol: "hand.draw.fill")])

        var b = Builder(screen: screen)
        // Row one: the drag turns the camera, and a spring carries it home.
        let pan = b.attach(PatchKind.pan, to: stage.id, at: Point2(x: 48, y: 96))
        let split = b.add("splitPoint", at: Point2(x: 336, y: 96))
        let degrees = b.add("multiply", at: Point2(x: 624, y: 96), name: "Degrees", inputs: ["b": .number(-0.5)])
        let turn = b.add("spring", at: Point2(x: 912, y: 96), name: "Turn", inputs: ["response": .number(0.55), "damping": .number(0.7)])
        let view = b.view(stage.id, at: Point2(x: 1200, y: 96))
        b.connect(pan, "translation", to: split, "point")
        b.connect(split, "x", to: degrees, "a")
        b.connect(degrees, "result", to: turn, "held")
        b.connect(pan, "panning", to: turn, "hold")
        b.connect(turn, "value", to: view, SceneUse.portID("cameraYaw"))

        // Row two: a tap on a swatch chooses a finish, which is the body's color.
        let taps = swatches.enumerated().map { index, swatch in
            b.attach(PatchKind.tap, to: swatch.id, at: Point2(x: 48, y: 516 + Double(index) * 216))
        }
        let finish = b.add("optionSwitch", at: Point2(x: 336, y: 516), name: "Finish")
        let color = b.add("optionPicker", at: Point2(x: 624, y: 516), name: "Color", type: .color, inputs: [
            "value0": .color(P.finishes[0]), "value1": .color(P.finishes[1]), "value2": .color(P.finishes[2]),
        ])
        for (index, tap) in taps.enumerated() { b.connect(tap, "tapped", to: finish, "set\(index)") }
        b.connect(finish, "option", to: color, "option")
        b.connect(color, "value", to: view, SceneUse.portID(object: P.body, "color"))

        b.note("Turn · A drag circles the camera", around: [pan, split, degrees])
        b.note("Home · Let go and it springs back", around: [turn])
        b.note("Finish · A swatch picks the color", around: taps + [finish, color])
        return ProductScene(document: b.document, stage: stage.id, swatches: swatches.map(\.id), turn: turn)
    }
}
