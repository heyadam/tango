import Foundation
import PaperModel

extension SystemStyle {
    /// Liquid Glass, faked: a shader over a picture of what is behind the view. The rim
    /// bends what is behind it as a thick lens would, everything is softened a little and
    /// tinted, the colors come apart at the very edge, and light catches the rim. The views
    /// inside are drawn over it. Give `radius` the view's own corner radius.
    public static let glassShader = """
    // Liquid Glass: what is behind the view, mostly blurred away under a light veil, a
    // little of it still sharp and more vivid than it was, and at the rim a lens that bends
    // it. Light catches the edge. The views inside are drawn over it.
    // Its numbers were fitted to iOS 26's own glass in the simulator (Reference/run.sh).
    struct Inputs {
        float radius = 28;
        float blur = 24;
        float detail = 0.3;
        float refraction = \(glassRefraction);
        float rim = 19;
        float4 tint = float4(1, 1, 1, 0.275);
        float vibrancy = 2;
        float shine = \(glassShine);
    };

    // How far a point is from the edge of the rounded shape: below zero inside it.
    float glass_edge(float2 p, float2 mid, float r) {
        float2 q = abs(p) - mid + r;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    // Light adds up in linear terms, not in the numbers a picture stores.
    float3 glass_linear(float3 c) { return pow(max(c, 0.0), float3(2.2)); }
    float3 glass_stored(float3 c) { return pow(max(c, 0.0), float3(1.0 / 2.2)); }

    float4 shader(Frame frame, Inputs in) {
        float2 mid = frame.size * 0.5;
        float r = min(max(in.radius, 0.0), min(mid.x, mid.y));
        float2 p = frame.position - mid;
        float d = glass_edge(p, mid, r);
        float2 slope = float2(
            glass_edge(p + float2(1, 0), mid, r) - glass_edge(p - float2(1, 0), mid, r),
            glass_edge(p + float2(0, 1), mid, r) - glass_edge(p - float2(0, 1), mid, r));
        float2 outward = normalize(slope + 0.00001);

        // The rim is a lens: near the edge it shows what is further in.
        float depth = saturate(-d / max(in.rim, 1.0));
        float bend = (1 - depth) * (1 - depth);
        float2 seen = frame.position - outward * in.refraction * bend;

        // Mostly blurred away: samples on a spiral, evenly over a wide disc. Past the edge
        // of the screen there is nothing behind, and nothing is what those samples count for.
        float4 sum = float4(0);
        for (int i = 0; i < 128; i++) {
            float turn = 2.39996323 * float(i);
            float reach = in.blur * sqrt((float(i) + 0.5) / 128.0);
            float4 found = behind(frame, seen + float2(cos(turn), sin(turn)) * reach);
            sum += float4(glass_linear(found.rgb) * found.a, found.a);
        }
        float3 tint = glass_linear(in.tint.rgb);
        float3 wide = sum.a > 0.001 ? sum.rgb / sum.a : tint;
        // A little of it stays sharp.
        float4 near = behind(frame, seen);
        float3 sharp = near.a > 0.001 ? glass_linear(near.rgb) : wide;
        float3 color = mix(wide, sharp, saturate(in.detail));

        // The veil, and then more vivid than that, so color comes through it.
        color = glass_stored(mix(color, tint, saturate(in.tint.a)));
        float grey = dot(color, float3(0.2126, 0.7152, 0.0722));
        color = saturate(mix(float3(grey), color, in.vibrancy));

        // Light on the rim, brightest toward the top left and the bottom right.
        float line = smoothstep(1.5, 0.0, abs(d + 0.9));
        float facing = 0.25 + 0.75 * abs(dot(outward, float2(-0.7071, -0.7071)));
        color += in.shine * (0.6 * line * facing + 0.07 * bend);

        float4 inside = content(frame, frame.position);
        color = mix(color, inside.rgb, inside.a);
        return float4(color, saturate(0.5 - d));
    }
    """

    /// The tint of glass in each appearance: the veil it lays over what is behind it, which
    /// in light is the shader's own (fitted to iOS 26's glass).
    /// Fitted to iOS 26's glass over a checkerboard and stripes in each appearance; the dark
    /// one is the gray that real dark glass lifts black to (31), at the strength that fits.
    public static let glassTint = Dynamic(light: ColorValue(white: 1, alpha: 0.275), dark: ColorValue(white: 0.174, alpha: 0.655))
    /// How far the rim's lens reaches in, and the light on the edge: the shader's own, for
    /// what turns them off and on again (a tab bar that stops floating).
    public static let glassRefraction = 25.0
    public static let glassShine = 0.03
}

extension ComponentLibrary {
    /// A view of glass with a corner radius. Its fill stays clear: the shader draws it.
    static func glass(_ name: String, _ properties: [LayerProperty: Value], radius: Double, inputs: [String: Value] = [:], _ children: [Layer] = []) -> Layer {
        var all = properties
        all[.fill] = .color(ColorValue(white: 1, alpha: 0))
        all[.cornerRadius] = .number(radius)
        var layer = group(name, all, children)
        layer.shader = ShaderUse(source: SystemStyle.glassShader, inputs: ["radius": .number(radius)].merging(inputs) { _, new in new })
        return layer
    }

    // MARK: Glass

    /// A pane of Liquid Glass to put anything on: a floating button, a bar, a card.
    static let glassPane: ViewTemplate = {
        let root = glass("Glass", [
            .size: size(220, 64), .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
            .distribution: .text("Center"), .spacing: .number(10),
            .shadowColor: .color(ColorValue(white: 0, alpha: 0.12)), .shadowRadius: .number(16), .shadowOffset: .point(Point2(x: 0, y: 6)),
        ], radius: 32)
        return template(
            "Glass", "A pane of Liquid Glass: it bends and softens what is behind it and catches light on its rim. Put anything in it. Radius, Blur, Refraction, Rim, Tint and Shine are inputs on its patch; keep Radius the same as its corner radius.",
            root: root, content: "Glass"
        ) { _ in }
    }()
}
