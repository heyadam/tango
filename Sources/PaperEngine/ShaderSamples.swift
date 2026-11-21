import Foundation
import PaperModel

/// Examples of shader views: one that draws from nothing, one that changes the look of
/// the views inside it.
extension SampleDocuments {
    public struct ShaderBackground {
        public let document: Document
        public let background: LayerID
        public let card: LayerID
    }

    static let auroraSource = """
    // An aurora: bands of light that drift on their own, and flare with `energy`.
    struct Inputs {
        float speed = 0.4;
        float energy = 0;
        float4 sky = float4(0.04, 0.05, 0.16, 1);
        float4 light = float4(0.2, 0.9, 0.7, 1);
        float4 accent = float4(0.6, 0.3, 1, 1);
    };

    float hash(float2 p) {
        return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
    }

    float noise(float2 p) {
        float2 cell = floor(p);
        float2 f = fract(p);
        f = f * f * (3 - 2 * f);
        float top = mix(hash(cell), hash(cell + float2(1, 0)), f.x);
        float bottom = mix(hash(cell + float2(0, 1)), hash(cell + float2(1, 1)), f.x);
        return mix(top, bottom, f.y);
    }

    float4 shader(Frame frame, Inputs in) {
        float2 p = frame.uv * float2(frame.size.x / frame.size.y, 1);
        float t = frame.time * in.speed;
        float band = noise(float2(p.x * 3 + t, t * 0.5)) * 0.5 + noise(float2(p.x * 7 - t, 4)) * 0.25;
        float spread = 2.4 - 1.2 * in.energy;
        float curtain = smoothstep(0.0, 0.5, band + 0.25 - abs(frame.uv.y - 0.32 - band * 0.2) * spread);
        float3 color = mix(in.sky.rgb, in.light.rgb, curtain);
        color = mix(color, in.accent.rgb, curtain * noise(p * 4 + t) * (0.35 + 0.65 * in.energy));
        return float4(color, 1);
    }
    """

    /// A background drawn by a shader, with ordinary views over it. A tap on the card
    /// drives one of the shader's inputs.
    public static func shaderBackground() -> ShaderBackground {
        typealias S = ExampleStyle
        var background = Layer.new(.shader, name: "Aurora")
        background.shader = ShaderUse(source: auroraSource)
        background.properties[.size] = .size(S.device)
        background.properties[.enabled] = .bool(false)

        let glyph = S.symbol("Glyph", "sparkles", at: Point2(x: 24, y: 26), side: 26, color: .white)
        let title = Layer(name: "Title", kind: .text, properties: [
            .position: .point(Point2(x: 64, y: 24)), .size: .size(Size2(width: 270, height: 30)),
            .text: .text("Stir the sky"), .fontSize: .number(22), .fontWeight: .number(700), .textColor: .color(.white),
        ])
        let caption = Layer(name: "Caption", kind: .text, properties: [
            .position: .point(Point2(x: 24, y: 66)), .size: .size(Size2(width: S.column - 48, height: 44)),
            .text: .text("The sky is a shader. A tap here springs its Energy input up, and another lets it settle."),
            .fontSize: .number(15), .textColor: .color(ColorValue(white: 1, alpha: 0.75)),
        ])
        let card = Layer(name: "Card", kind: .view, properties: [
            .position: .point(Point2(x: S.margin, y: 612)), .size: .size(Size2(width: S.column, height: 132)),
            .fill: .color(ColorValue(white: 1, alpha: 0.14)), .cornerRadius: .number(28), .backgroundBlur: .number(20),
            .strokeColor: .color(ColorValue(white: 1, alpha: 0.3)), .strokeWidth: .number(1),
        ], children: [glyph, title, caption])
        let screen = Layer(name: "Screen", kind: .screen, properties: [.fill: .color(.black)], children: [
            background,
        ] + S.header("Tonight in Tromsø", "Aurora", color: .white) + [card, S.hint("Tap the card", y: 774, dark: true)])

        var b = Builder(screen: screen)
        let touch = b.interaction(on: card.id, at: Point2(x: 48, y: 96))
        let stirred = b.add("switch", at: Point2(x: 336, y: 96), name: "Stirred")
        let spring = b.add("spring", at: Point2(x: 624, y: 96), inputs: ["response": .number(0.9), "damping": .number(0.8)])
        let aurora = b.view(background.id, at: Point2(x: 912, y: 96))
        b.connect(touch, "tap", to: stirred, "flip")
        b.connect(stirred, "on", to: spring, "target")
        b.connect(spring, "value", to: aurora, ShaderUse.portID("energy"))
        b.note("Energy · A tap springs the shader's input", around: [touch, stirred, spring])
        return ShaderBackground(document: b.document, background: background.id, card: card.id)
    }

    public struct ShaderLens {
        public let document: Document
        public let lens: LayerID
        public static let rest = Point2(x: 201, y: 437)
    }

    static let lensSource = """
    // A glass lens over the views inside this one. It follows `touch` and
    // appears with `amount`.
    struct Inputs {
        float2 touch = float2(201, 437);
        float amount = 0;
        float radius = 110;
    };

    float4 shader(Frame frame, Inputs in) {
        float2 offset = frame.position - in.touch;
        float d = length(offset) / max(in.radius, 1.0);
        if (d >= 1 || in.amount <= 0.001) {
            return content(frame, frame.position);
        }
        // Inside the lens the picture is pulled toward the middle.
        float bend = 1 - in.amount * 0.45 * (1 - d * d);
        float2 point = in.touch + offset * bend;
        // The colors come apart toward the rim, as in real glass.
        float2 along = normalize(offset + 0.0001);
        float split = in.amount * 6 * d * d;
        float4 color = content(frame, point);
        color.r = content(frame, point + along * split).r;
        color.b = content(frame, point - along * split).b;
        float rim = smoothstep(0.9, 1.0, d) * in.amount;
        return float4(mix(color.rgb, float3(1), rim * 0.35), color.a);
    }
    """

    /// A shader over ordinary views: a lens that appears under a finger and follows it.
    public static func shaderLens() -> ShaderLens {
        typealias S = ExampleStyle
        let colors = ["#FF7059", "#FFB340", "#5DB48A", "#5AA9FF", "#8466F5"]
        let names = ["Coral", "Amber", "Sage", "Sky", "Plum"]
        let rows: [Layer] = zip(colors, names).enumerated().map { index, pair in
            Layer(name: pair.1, kind: .view, properties: [
                .position: .point(Point2(x: S.margin, y: 156 + Double(index) * 100)), .size: .size(Size2(width: S.column, height: 88)),
                .fill: .color(ColorValue(hex: pair.0)!), .cornerRadius: .number(24),
            ], children: [
                S.text("Label", pair.1, at: Point2(x: 22, y: 20), size: 22, weight: 700, color: .white),
                S.text("Code", pair.0, at: Point2(x: 22, y: 50), size: 13, weight: 600, color: ColorValue(white: 1, alpha: 0.75)),
                S.text("Fine Print", "Aa Bb Cc 123", at: Point2(x: S.column - 132, y: 34), size: 15, weight: 600,
                       color: ColorValue(white: 1, alpha: 0.85), width: 110, align: "Right"),
            ])
        }
        var lens = Layer.new(.shader, name: "Lens")
        lens.shader = ShaderUse(source: lensSource)
        lens.properties[.size] = .size(S.device)
        lens.properties[.fill] = .color(S.paper)
        lens.children = S.header("Palette", "Swatches") + rows + [S.hint("Press and drag anywhere", symbol: "hand.draw.fill")]
        let screen = Layer(name: "Screen", kind: .screen, children: [lens])

        var b = Builder(screen: screen)
        let touch = b.interaction(on: lens.id, at: Point2(x: 48, y: 96))
        let spring = b.add("spring", at: Point2(x: 336, y: 96), inputs: ["response": .number(0.35), "damping": .number(0.7)])
        let view = b.view(lens.id, at: Point2(x: 624, y: 96))
        b.connect(touch, "down", to: spring, "target")
        b.connect(spring, "value", to: view, ShaderUse.portID("amount"))
        b.connect(touch, "position", to: view, ShaderUse.portID("touch"))
        b.note("Lens · Down shows it, Position moves it", around: [touch, spring])
        return ShaderLens(document: b.document, lens: lens.id)
    }
}
