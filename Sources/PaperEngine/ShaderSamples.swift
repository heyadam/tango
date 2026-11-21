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
        var background = Layer.new(.shader, name: "Aurora")
        background.shader = ShaderUse(source: auroraSource)
        background.properties[.size] = .size(Size2(width: 390, height: 844))
        background.properties[.enabled] = .bool(false)

        let title = Layer(name: "Title", kind: .text, properties: [
            .position: .point(Point2(x: 24, y: 24)), .size: .size(Size2(width: 262, height: 30)),
            .text: .text("Northern Lights"), .fontSize: .number(22), .fontWeight: .number(700), .textColor: .color(.white),
        ])
        let caption = Layer(name: "Caption", kind: .text, properties: [
            .position: .point(Point2(x: 24, y: 60)), .size: .size(Size2(width: 262, height: 44)),
            .text: .text("Tap to stir the sky. The background is a shader."), .fontSize: .number(15),
            .textColor: .color(ColorValue(white: 1, alpha: 0.75)),
        ])
        let card = Layer(name: "Card", kind: .view, properties: [
            .position: .point(Point2(x: 40, y: 640)), .size: .size(Size2(width: 310, height: 128)),
            .fill: .color(ColorValue(white: 1, alpha: 0.14)), .cornerRadius: .number(28),
            .strokeColor: .color(ColorValue(white: 1, alpha: 0.3)), .strokeWidth: .number(1),
        ], children: [title, caption])
        let screen = Layer(name: "Screen", kind: .screen, properties: [.fill: .color(.black)], children: [background, card])

        var b = Builder(screen: screen)
        let touch = b.interaction(on: card.id, at: Point2(x: 40, y: 80))
        let stirred = b.add("switch", at: Point2(x: 300, y: 80), name: "Stirred")
        let spring = b.add("spring", at: Point2(x: 560, y: 80), inputs: ["response": .number(0.9), "damping": .number(0.8)])
        let aurora = b.view(background.id, at: Point2(x: 820, y: 80))
        b.connect(touch, "tap", to: stirred, "flip")
        b.connect(stirred, "on", to: spring, "target")
        b.connect(spring, "value", to: aurora, ShaderUse.portID("energy"))
        return ShaderBackground(document: b.document, background: background.id, card: card.id)
    }

    public struct ShaderLens {
        public let document: Document
        public let lens: LayerID
        public static let rest = Point2(x: 195, y: 422)
    }

    static let lensSource = """
    // A glass lens over the views inside this one. It follows `touch` and
    // appears with `amount`.
    struct Inputs {
        float2 touch = float2(195, 422);
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
        let colors = ["#FF6B6B", "#FFB84D", "#4DD4AC", "#4D9BFF", "#9B6BFF"]
        let names = ["Coral", "Amber", "Mint", "Sky", "Violet"]
        let rows: [Layer] = zip(colors, names).enumerated().map { index, pair in
            let label = Layer(name: "Label", kind: .text, properties: [
                .position: .point(Point2(x: 20, y: 30)), .size: .size(Size2(width: 280, height: 28)),
                .text: .text(pair.1), .fontSize: .number(22), .fontWeight: .number(700), .textColor: .color(.white),
            ])
            return Layer(name: pair.1, kind: .view, properties: [
                .position: .point(Point2(x: 24, y: 150 + Double(index) * 104)), .size: .size(Size2(width: 342, height: 88)),
                .fill: .color(ColorValue(hex: pair.0)!), .cornerRadius: .number(24),
            ], children: [label])
        }
        let heading = Layer(name: "Heading", kind: .text, properties: [
            .position: .point(Point2(x: 24, y: 84)), .size: .size(Size2(width: 342, height: 40)),
            .text: .text("Press and drag"), .fontSize: .number(30), .fontWeight: .number(800),
        ])
        var lens = Layer.new(.shader, name: "Lens")
        lens.shader = ShaderUse(source: lensSource)
        lens.properties[.size] = .size(Size2(width: 390, height: 844))
        lens.properties[.fill] = .color(ColorValue(white: 0.97))
        lens.children = [heading] + rows
        let screen = Layer(name: "Screen", kind: .screen, children: [lens])

        var b = Builder(screen: screen)
        let touch = b.interaction(on: lens.id, at: Point2(x: 40, y: 80))
        let spring = b.add("spring", at: Point2(x: 300, y: 80), inputs: ["response": .number(0.35), "damping": .number(0.7)])
        let view = b.view(lens.id, at: Point2(x: 560, y: 80))
        b.connect(touch, "down", to: spring, "target")
        b.connect(spring, "value", to: view, ShaderUse.portID("amount"))
        b.connect(touch, "position", to: view, ShaderUse.portID("touch"))
        return ShaderLens(document: b.document, lens: lens.id)
    }
}
