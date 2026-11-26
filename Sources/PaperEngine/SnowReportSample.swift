import Foundation
import PaperModel

extension SampleDocuments {
    public struct SnowReport {
        public let document: Document
        public let report: LayerID
        public let summit: LayerID
        public let card: LayerID
        public let liftsCard: LayerID
        public let summitMountain: LayerID
        public let back: LayerID
        public let summitTab: LayerID
        public let midTab: LayerID
        public let baseTab: LayerID
        public let thumb: LayerID
        public let snowfall: LayerID
        public let temp: LayerID
        public let liftName: LayerID
        public let zone: NodeID
        public let zoneMotion: NodeID
    }

    static let alpineSource = """
    // An alpine winter vista driven by `altitude` (0 at base, 0.5 mid-mountain, 1 at summit).
    // No clock: it redraws only while altitude changes, and rests at zero CPU.
    struct Inputs {
        float altitude = 1.0;
    };

    float alpine_hash(float2 p) {
        return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
    }

    float alpine_noise(float2 p) {
        float2 cell = floor(p);
        float2 f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        float top = mix(alpine_hash(cell), alpine_hash(cell + float2(1.0, 0.0)), f.x);
        float bottom = mix(alpine_hash(cell + float2(0.0, 1.0)), alpine_hash(cell + float2(1.0, 1.0)), f.x);
        return mix(top, bottom, f.y);
    }

    float alpine_fbm(float2 p) {
        float sum = 0.0;
        float weight = 0.5;
        for (int i = 0; i < 3; i++) {
            sum += alpine_noise(p) * weight;
            p = p * 2.03 + float2(3.1, 5.7);
            weight *= 0.5;
        }
        return sum;
    }

    // A chiseled pyramidal peak: silhouette height with organic rocky shoulders.
    float alpine_peak_y(float x, float cx, float topY, float leftSlope, float rightSlope, float seed) {
        float dx = x - cx;
        float slope = dx < 0.0 ? -dx * leftSlope : dx * rightSlope;
        float detail = (alpine_fbm(float2(x * 7.5 + seed, seed * 1.7)) - 0.5) * 0.032 * smoothstep(0.01, 0.16, abs(dx));
        float crag = (alpine_noise(float2(x * 22.0 + seed * 3.1, 2.0)) - 0.5) * 0.010 * smoothstep(0.005, 0.08, abs(dx));
        return topY + slope + detail + crag;
    }

    // Shades one 3D pyramidal peak with a diagonal ridge spine separating sunlit snow from shadow.
    float4 alpine_peak(
        float2 uv, float cx, float topY, float leftSlope, float rightSlope, float spineLean, float seed,
        float3 litSnow, float3 shadeSnow, float3 rockShade, float3 haze, float hazeStrength
    ) {
        float h = alpine_peak_y(uv.x, cx, topY, leftSlope, rightSlope, seed);
        float alpha = smoothstep(h - 0.0025, h + 0.0025, uv.y);
        if (alpha <= 0.001) {
            return float4(0.0);
        }
        float below = max(uv.y - topY, 0.0);
        // Diagonal ridge spine descending from the summit tip, with natural alpine curvature.
        float spine = cx + below * spineLean + (alpine_fbm(float2(uv.y * 7.0 + seed, cx * 4.0)) - 0.5) * 0.048;
        float side = smoothstep(-0.016, 0.016, uv.x - spine);

        // Diagonal couloirs and wind-carved snow facets flowing down each face.
        float slopeCoord = (uv.x - spine) * 14.0 + (side > 0.5 ? -below * 8.0 : below * 8.0);
        float facets = alpine_fbm(float2(slopeCoord + seed * 2.0, below * 15.0));
        float snowCap = smoothstep(0.32, 0.68, facets + 0.18 - below * 0.65);

        float3 shadowFace = mix(rockShade, shadeSnow, snowCap * 0.85);
        float3 sunlitFace = mix(shadeSnow * 1.15, litSnow, clamp(0.55 + facets * 0.55, 0.0, 1.0));
        float3 col = mix(shadowFace, sunlitFace, side);

        // Bright wind-blown snow highlight right along the upper ridge crest.
        float rim = smoothstep(0.014, 0.0, uv.y - h) * (0.4 + 0.6 * side);
        col = mix(col, litSnow * 1.04, rim * 0.55);

        // Atmospheric depth toward the base of the peak.
        float depth = smoothstep(0.06, 0.36, uv.y - h);
        col = mix(col, haze, depth * hazeStrength);
        return float4(col, alpha);
    }

    float4 shader(Frame frame, Inputs in) {
        float alt = clamp(in.altitude, 0.0, 1.0);
        float2 uv = frame.uv;

        // Sky transitions from warm rosy alpine dawn (Base) to crisp high-altitude cobalt (Summit).
        float3 zenith = mix(float3(0.11, 0.22, 0.44), float3(0.04, 0.13, 0.34), alt);
        float3 midSky = mix(float3(0.36, 0.52, 0.78), float3(0.16, 0.42, 0.78), alt);
        float3 horizon = mix(float3(0.98, 0.80, 0.70), float3(0.74, 0.88, 0.99), alt);

        float3 color = mix(zenith, midSky, smoothstep(0.0, 0.34, uv.y));
        color = mix(color, horizon, smoothstep(0.24, 0.60, uv.y));

        // Crisp morning sun glow behind the eastern alpine peak.
        float2 sunPos = float2(0.83, 0.25 + (1.0 - alt) * 0.04);
        float2 aspect = float2(frame.size.x / max(frame.size.y, 1.0), 1.0);
        float sunDist = length((uv - sunPos) * aspect);
        float3 sunGlow = mix(float3(1.0, 0.80, 0.64), float3(0.92, 0.97, 1.0), alt);
        color += sunGlow * exp(-sunDist * sunDist * 24.0) * 0.38;
        color += float3(1.0, 0.98, 0.94) * exp(-sunDist * sunDist * 165.0) * 0.50;

        // High cirrus cloud wisps tinted by elevation light.
        float clouds = smoothstep(0.46, 0.78, alpine_fbm(float2(uv.x * 2.8 + alt * 0.30, uv.y * 7.5)));
        float3 cloudTint = mix(float3(1.0, 0.88, 0.82), float3(0.94, 0.98, 1.0), alt);
        color = mix(color, cloudTint, clouds * smoothstep(0.48, 0.08, uv.y) * 0.34);

        // Shared alpine lighting palette that shifts smoothly with elevation.
        float3 farLit = mix(float3(1.0, 0.91, 0.85), float3(0.97, 0.99, 1.0), alt);
        float3 farShade = mix(float3(0.42, 0.54, 0.76), float3(0.30, 0.48, 0.74), alt);
        float3 farRock = mix(float3(0.25, 0.35, 0.54), float3(0.18, 0.32, 0.55), alt);
        float3 farHaze = mix(float3(0.84, 0.80, 0.86), float3(0.68, 0.82, 0.96), alt);

        // Range 1: Distant glacier peaks (left shoulder, iconic central-right summit, east spire).
        float shift = (1.0 - alt) * 0.045;
        float4 pWest = alpine_peak(uv, 0.38, 0.40 + shift, 0.68, 0.76, -0.26, 1.3,
                                   farLit, farShade, farRock, farHaze, 0.55);
        color = mix(color, pWest.rgb, pWest.a);

        float4 pEast = alpine_peak(uv, 0.90, 0.39 + shift, 0.82, 0.65, -0.22, 4.7,
                                   farLit, farShade, farRock, farHaze, 0.50);
        color = mix(color, pEast.rgb, pEast.a);

        float4 pMain = alpine_peak(uv, 0.65, 0.31 + shift, 0.78, 0.70, -0.32, 2.9,
                                   farLit, farShade, farRock, farHaze, 0.48);
        color = mix(color, pMain.rgb, pMain.a);

        // Soft luminous valley mist separating distant glacier peaks from mid-mountain.
        float mist1 = exp(-pow((uv.y - (0.54 + shift * 0.6)) * 12.0, 2.0));
        color = mix(color, mix(float3(0.93, 0.86, 0.86), float3(0.82, 0.92, 1.0), alt), mist1 * 0.42);

        // Range 2: Mid-mountain ski bowl ridges framing left and right.
        float3 midLit = mix(float3(0.92, 0.88, 0.90), float3(0.84, 0.92, 0.99), alt);
        float3 midShade = mix(float3(0.22, 0.34, 0.54), float3(0.15, 0.30, 0.52), alt);
        float3 midRock = mix(float3(0.11, 0.19, 0.34), float3(0.08, 0.17, 0.34), alt);
        float3 midHaze = mix(float3(0.46, 0.54, 0.70), float3(0.36, 0.52, 0.72), alt);

        float4 mLeft = alpine_peak(uv, 0.14, 0.47 + shift * 0.7, 0.62, 0.56, -0.18, 6.2,
                                   midLit, midShade, midRock, midHaze, 0.45);
        color = mix(color, mLeft.rgb, mLeft.a);

        float4 mRight = alpine_peak(uv, 0.88, 0.49 + shift * 0.7, 0.58, 0.64, -0.25, 8.1,
                                    midLit, midShade, midRock, midHaze, 0.45);
        color = mix(color, mRight.rgb, mRight.a);

        // Range 3: Foreground deep alpine slope with bright snow crest and soft wind-drift contours.
        float nearY = 0.65 + 0.048 * sin(uv.x * 3.6 + 2.1) + 0.014 * sin(uv.x * 9.0 + 0.5) + shift * 0.75;
        if (uv.y >= nearY - 0.004) {
            float below = clamp((uv.y - nearY) / max(1.0 - nearY, 0.001), 0.0, 1.0);
            float drift = alpine_fbm(float2(uv.x * 6.5 - alt * 0.35, uv.y * 5.5));
            float3 topSlope = mix(float3(0.16, 0.25, 0.42), float3(0.11, 0.22, 0.39), alt);
            float3 deepSlope = mix(float3(0.05, 0.09, 0.19), float3(0.03, 0.07, 0.16), alt);
            float3 nearColor = mix(topSlope, deepSlope, pow(below, 0.72));
            nearColor += float3(0.09, 0.15, 0.26) * drift * (1.0 - below * 0.45);
            float crest = smoothstep(0.018, 0.0, uv.y - nearY);
            nearColor = mix(nearColor, mix(float3(0.95, 0.86, 0.84), float3(0.80, 0.91, 1.0), alt), crest * 0.55);
            color = mix(color, nearColor, smoothstep(nearY - 0.003, nearY + 0.003, uv.y));
        }

        // Delicate high-altitude snow crystals, subtle and fine so typography stays effortless.
        float2 snowGrid = (uv + float2(alt * 0.06, -alt * 0.12)) * float2(34.0, 52.0);
        float2 cell = floor(snowGrid);
        float2 local = fract(snowGrid) - 0.5;
        float rnd = alpine_hash(cell);
        float2 jitter = float2(alpine_hash(cell + 13.7), alpine_hash(cell + 41.2)) - 0.5;
        float flake = smoothstep(0.10, 0.02, length(local - jitter * 0.6)) * step(0.89, rnd);
        color += float3(1.0) * flake * (0.20 + 0.22 * alt) * smoothstep(0.92, 0.28, uv.y);

        // Soft upper-left and bottom atmospheric vignette for crisp white text contrast.
        color *= 1.0 - smoothstep(0.28, 0.0, uv.y) * 0.22;
        color *= 1.0 - smoothstep(0.68, 1.0, uv.y) * 0.20;
        return float4(color, 1.0);
    }
    """

    /// A two-screen ski resort snow report: tapping the alpine card morphs the mountain
    /// shader and fresh snow headline into a full-screen summit explorer, where one spring
    /// slides the elevation pill and shifts the peaks between Summit, Mid and Base.
    public static func snowReport() -> SnowReport {
        typealias S = ExampleStyle
        typealias Library = ComponentLibrary
        let w = S.device.width
        let white = ColorValue(white: 1)
        let alpineBlue = ColorValue(hex: "#2563EB")!
        let iceTint = ColorValue(hex: "#93C5FD")!
        func faint(_ alpha: Double) -> ColorValue { ColorValue(white: 1, alpha: alpha) }
        func lift(_ layer: Layer) -> Layer {
            var layer = layer
            layer.properties[.shadowColor] = .color(ColorValue(white: 0, alpha: 0.28))
            layer.properties[.shadowRadius] = .number(12)
            layer.properties[.shadowOffset] = .point(Point2(x: 0, y: 2))
            return layer
        }
        func page(_ name: String, fill: ColorValue, _ children: [Layer]) -> Layer {
            var layer = Layer.newPage(name: name)
            layer.properties[.fill] = .color(fill)
            layer.children = children
            return layer
        }
        // Each screen gets its own hint names so Morph crossfades them instead of matching them.
        func screenHint(_ prefix: String, _ words: String, y: Double, dark: Bool = false) -> Layer {
            let ink = dark ? white : S.ink
            let pill = Layer(name: "\(prefix) Pill", kind: .view, properties: [
                .size: .size(Size2(width: 100, height: 36)), .widthMode: .text("Auto"),
                .fill: .color(dark ? faint(0.16) : ColorValue(white: 1, alpha: 0.92)),
                .cornerRadius: .number(18),
                .strokeColor: .color(dark ? faint(0.22) : S.hairline), .strokeWidth: .number(1),
                .shadowColor: .color(dark ? .clear : S.shadow), .shadowRadius: .number(12),
                .shadowOffset: .point(Point2(x: 0, y: 4)),
                .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
                .spacing: .number(8), .paddingHorizontal: .number(16), .paddingVertical: .number(0),
            ], children: [
                S.symbol("\(prefix) Glyph", "hand.tap.fill", side: 15, color: dark ? ink : S.accent),
                S.text("\(prefix) Words", words, size: 14, weight: 600, color: ink),
            ])
            return Layer(name: "\(prefix) Hint", kind: .view, properties: [
                .position: .point(Point2(x: 0, y: y)), .size: .size(Size2(width: w, height: 36)),
                .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
                .distribution: .text("Center"),
            ], children: [pill])
        }

        // MARK: Screen 1 — Report

        let tempPill = Layer(name: "Temp Pill", kind: .view, properties: [
            .position: .point(Point2(x: w - S.margin - 86, y: S.top + 36)),
            .size: .size(Size2(width: 86, height: 36)), .cornerRadius: .number(18),
            .fill: .color(S.surface), .strokeColor: .color(S.hairline), .strokeWidth: .number(1),
            .shadowColor: .color(S.shadow), .shadowRadius: .number(10), .shadowOffset: .point(Point2(x: 0, y: 3)),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
            .distribution: .text("Center"), .spacing: .number(6),
        ], children: [
            S.symbol("Temp Pill Icon", "snowflake", side: 14, color: alpineBlue, weight: 600),
            S.text("Temp Pill Text", "16°F", size: 15, weight: 600, color: S.ink),
        ])

        // Matched across both screens: the hero alpine shader card expands full-bleed on Summit.
        var card = Layer.new(.shader, name: "Mountain")
        card.shader = ShaderUse(source: alpineSource, inputs: ["altitude": .number(1.0)])
        card.properties[.position] = .point(Point2(x: S.margin, y: 152))
        card.properties[.size] = .size(Size2(width: S.column, height: 340))
        card.properties[.cornerRadius] = .number(28)
        card.properties[.clips] = .bool(true)
        card.properties[.shadowColor] = .color(ColorValue(red: 0.05, green: 0.14, blue: 0.30, alpha: 0.24))
        card.properties[.shadowRadius] = .number(22)
        card.properties[.shadowOffset] = .point(Point2(x: 0, y: 10))

        // Matched sibling overlays over Mountain (same names on both screens so Morph moves each).
        let reportBadge = Layer(name: "Powder Badge", kind: .view, properties: [
            .position: .point(Point2(x: 40, y: 172)), .size: .size(Size2(width: 134, height: 30)),
            .cornerRadius: .number(15), .fill: .color(ColorValue(red: 0.05, green: 0.14, blue: 0.30, alpha: 0.32)),
            .strokeColor: .color(faint(0.35)), .strokeWidth: .number(1),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
            .distribution: .text("Center"), .spacing: .number(6),
        ], children: [
            S.symbol("Report Badge Icon", "snowflake", side: 12, color: white, weight: 700),
            S.text("Report Badge Text", "POWDER DAY", size: 11, weight: 700, color: white),
        ])
        var reportSnowfall = lift(S.text("Snowfall", "14″", at: Point2(x: 40, y: 356),
                                         size: 68, weight: 700, color: white, width: 170, height: 80))
        reportSnowfall.properties[.singleLine] = .bool(true)
        var reportSubtitle = lift(S.text("Snow Subtitle", "10,550 ft · 24h Summit", at: Point2(x: 40, y: 440),
                                         size: 15, weight: 500, color: faint(0.92), width: 214, height: 22))
        reportSubtitle.properties[.singleLine] = .bool(true)

        let exploreChip = Layer(name: "Explore Chip", kind: .view, properties: [
            .position: .point(Point2(x: S.margin + S.column - 114, y: 432)),
            .size: .size(Size2(width: 96, height: 38)), .cornerRadius: .number(19),
            .fill: .color(ColorValue(white: 1, alpha: 0.94)),
            .shadowColor: .color(ColorValue(white: 0, alpha: 0.16)), .shadowRadius: .number(10),
            .shadowOffset: .point(Point2(x: 0, y: 3)),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
            .distribution: .text("Center"), .spacing: .number(5),
        ], children: [
            S.text("Explore Text", "Summit", size: 14, weight: 600, color: S.ink),
            S.symbol("Explore Arrow", "chevron.right", side: 11, color: alpineBlue, weight: 700),
        ])

        func statCard(_ name: String, icon: String, tint: ColorValue, value: String, label: String, x: Double) -> Layer {
            Layer(name: name, kind: .view, properties: [
                .position: .point(Point2(x: x, y: 508)), .size: .size(Size2(width: 114, height: 96)),
                .fill: .color(S.surface), .cornerRadius: .number(22),
                .shadowColor: .color(S.shadow), .shadowRadius: .number(12), .shadowOffset: .point(Point2(x: 0, y: 4)),
            ], children: [
                S.symbol("\(name) Icon", icon, at: Point2(x: 16, y: 16), side: 18, color: tint, weight: 600),
                S.text("\(name) Value", value, at: Point2(x: 16, y: 44), size: 20, weight: 700, color: S.ink),
                S.text("\(name) Label", label, at: Point2(x: 16, y: 70), size: 12, weight: 500, color: S.secondary),
            ])
        }
        let liftsStat = statCard("Lifts Stat", icon: "cablecar.fill", tint: alpineBlue, value: "11 / 12", label: "Lifts Open", x: S.margin)
        let trailsStat = statCard("Trails Stat", icon: "figure.skiing.downhill", tint: S.teal, value: "94 / 106", label: "Trails", x: S.margin + 124)
        let baseStat = statCard("Base Stat", icon: "mountain.2.fill", tint: S.plum, value: "118″", label: "Base Depth", x: S.margin + 248)

        func previewLiftRow(_ prefix: String, title: String, detail: String, wait: String, y: Double) -> [Layer] {
            [
                Layer(name: "\(prefix) Dot", kind: .ellipse, properties: [
                    .position: .point(Point2(x: 18, y: y + 14)), .size: .size(Size2(width: 8, height: 8)),
                    .fill: .color(S.sage),
                ]),
                S.text("\(prefix) Name", title, at: Point2(x: 36, y: y), size: 16, weight: 600, color: S.ink),
                S.text("\(prefix) Detail", detail, at: Point2(x: 36, y: y + 20), size: 13, color: S.secondary),
                S.text("\(prefix) Wait", wait, at: Point2(x: S.column - 84, y: y + 8), size: 13, weight: 600,
                       color: alpineBlue, width: 66, align: "Right"),
            ]
        }
        let liftsCard = Layer(name: "Featured Lifts", kind: .view, properties: [
            .position: .point(Point2(x: S.margin, y: 620)), .size: .size(Size2(width: S.column, height: 146)),
            .fill: .color(S.surface), .cornerRadius: .number(24),
            .shadowColor: .color(S.shadow), .shadowRadius: .number(12), .shadowOffset: .point(Point2(x: 0, y: 4)),
        ], children: [
            S.text("Lifts Heading", "FEATURED LIFTS", at: Point2(x: 18, y: 16), size: 11, weight: 700, color: S.secondary),
            S.text("Lifts All Open", "All running", at: Point2(x: S.column - 104, y: 15), size: 12, weight: 600,
                   color: S.sage, width: 86, align: "Right"),
        ] + previewLiftRow("Tram", title: "Alpine Tram", detail: "10,550 ft · Expert & Bowls", wait: "3 min", y: 44) + [
            Layer(name: "Lifts Rule", kind: .view, properties: [
                .position: .point(Point2(x: 18, y: 92)), .size: .size(Size2(width: S.column - 36, height: 1)),
                .fill: .color(S.hairline),
            ]),
        ] + previewLiftRow("Collins", title: "Collins Express", detail: "9,240 ft · Cruisers & Trees", wait: "1 min", y: 100))

        let report = page("Report", fill: S.paper, S.header("Wasatch · 6:30 AM", "Alta Peak") + [
            tempPill, card, reportBadge, reportSnowfall, reportSubtitle, exploreChip,
            liftsStat, trailsStat, baseStat, liftsCard,
            screenHint("Report", "Tap the mountain for live conditions", y: 792),
        ])

        // MARK: Screen 2 — Summit

        var summitMountain = Layer.new(.shader, name: "Mountain")
        summitMountain.shader = ShaderUse(source: alpineSource, inputs: ["altitude": .number(1.0)])
        summitMountain.properties[.size] = .size(S.device)
        summitMountain.properties[.cornerRadius] = .number(0)
        summitMountain.properties[.clips] = .bool(true)

        let back = Library.glass("Back", [
            .position: .point(Point2(x: S.margin, y: 66)), .size: .size(Size2(width: 44, height: 44)),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .distribution: .text("Center"),
        ], radius: 22, inputs: ["tint": .color(faint(0.18))], [
            S.symbol("Back Icon", "chevron.left", side: 16, color: white, weight: 700),
        ])
        let resortTitle = lift(S.text("Resort Title", "Alta Peak", at: Point2(x: 80, y: 77),
                                      size: 17, weight: 600, color: white, width: w - 160, align: "Center"))
        let livePill = Library.glass("Live Pill", [
            .position: .point(Point2(x: w - S.margin - 70, y: 72)), .size: .size(Size2(width: 70, height: 32)),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
            .distribution: .text("Center"), .spacing: .number(6),
        ], radius: 16, inputs: ["tint": .color(faint(0.16))], [
            Layer(name: "Live Dot", kind: .ellipse, properties: [
                .size: .size(Size2(width: 7, height: 7)), .fill: .color(S.sage),
            ]),
            S.text("Live Text", "LIVE", size: 11, weight: 700, color: white),
        ])

        let summitBadge = Layer(name: "Powder Badge", kind: .view, properties: [
            .position: .point(Point2(x: 24, y: 128)), .size: .size(Size2(width: 134, height: 30)),
            .cornerRadius: .number(15), .fill: .color(ColorValue(red: 0.05, green: 0.14, blue: 0.30, alpha: 0.32)),
            .strokeColor: .color(faint(0.35)), .strokeWidth: .number(1),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
            .distribution: .text("Center"), .spacing: .number(6),
        ], children: [
            S.symbol("Summit Badge Icon", "snowflake", side: 12, color: white, weight: 700),
            S.text("Summit Badge Text", "POWDER DAY", size: 11, weight: 700, color: white),
        ])
        var snowfall = lift(S.text("Snowfall", "14″", at: Point2(x: 24, y: 162),
                                   size: 86, weight: 700, color: white, width: 200, height: 98))
        snowfall.properties[.singleLine] = .bool(true)
        var snowSubtitle = lift(S.text("Snow Subtitle", "10,550 ft · 24h Summit", at: Point2(x: 24, y: 266),
                                       size: 17, weight: 500, color: faint(0.92), width: 260, height: 24))
        snowSubtitle.properties[.singleLine] = .bool(true)

        // Elevation Switcher: Liquid Glass capsule with a sliding white thumb and three tab hits.
        let switcherGlass = Library.glass("Elevation Bar", [
            .position: .point(Point2(x: S.margin, y: 486)), .size: .size(Size2(width: S.column, height: 52)),
        ], radius: 26, inputs: ["tint": .color(ColorValue(red: 0.06, green: 0.13, blue: 0.26, alpha: 0.34))], [])
        let thumb = Layer(name: "Thumb", kind: .view, properties: [
            .position: .point(Point2(x: 25, y: 491)), .size: .size(Size2(width: 116, height: 42)),
            .cornerRadius: .number(21), .fill: .color(ColorValue(white: 1, alpha: 0.95)),
            .shadowColor: .color(ColorValue(white: 0, alpha: 0.18)), .shadowRadius: .number(8),
            .shadowOffset: .point(Point2(x: 0, y: 2)),
        ])
        let summitLabel = S.text("Summit Label", "Summit", at: Point2(x: 25, y: 502),
                                 size: 15, weight: 600, color: S.ink, width: 116, align: "Center")
        let midLabel = S.text("Mid Label", "Mid", at: Point2(x: 143, y: 502),
                              size: 15, weight: 600, color: faint(0.95), width: 116, align: "Center")
        let baseLabel = S.text("Base Label", "Base", at: Point2(x: 261, y: 502),
                               size: 15, weight: 600, color: faint(0.95), width: 116, align: "Center")
        let summitTab = Layer(name: "Summit Tab", kind: .view, properties: [
            .position: .point(Point2(x: 25, y: 491)), .size: .size(Size2(width: 116, height: 42)),
        ])
        let midTab = Layer(name: "Mid Tab", kind: .view, properties: [
            .position: .point(Point2(x: 143, y: 491)), .size: .size(Size2(width: 116, height: 42)),
        ])
        let baseTab = Layer(name: "Base Tab", kind: .view, properties: [
            .position: .point(Point2(x: 261, y: 491)), .size: .size(Size2(width: 116, height: 42)),
        ])

        // Zone Conditions Liquid Glass Card, with live readouts layered cleanly on top.
        let conditionsGlass = Library.glass("Conditions Card", [
            .position: .point(Point2(x: S.margin, y: 552)), .size: .size(Size2(width: S.column, height: 228)),
        ], radius: 28, inputs: ["tint": .color(ColorValue(red: 0.06, green: 0.13, blue: 0.26, alpha: 0.44))], [
            S.text("Zone Heading", "ZONE CONDITIONS", at: Point2(x: 22, y: 20), size: 11, weight: 700, color: faint(0.65)),
            S.symbol("Temp Icon", "thermometer.snowflake", at: Point2(x: 52, y: 52), side: 18, color: faint(0.8)),
            S.text("Temp Caption", "Temp", at: Point2(x: 6, y: 108), size: 12, color: faint(0.65), width: 110, align: "Center"),
            Layer(name: "Stat Rule 1", kind: .view, properties: [
                .position: .point(Point2(x: 121, y: 58)), .size: .size(Size2(width: 1, height: 58)), .fill: .color(faint(0.16)),
            ]),
            S.symbol("Wind Icon", "wind", at: Point2(x: 172, y: 52), side: 18, color: faint(0.8)),
            S.text("Wind Caption", "NW Wind", at: Point2(x: 126, y: 108), size: 12, color: faint(0.65), width: 110, align: "Center"),
            Layer(name: "Stat Rule 2", kind: .view, properties: [
                .position: .point(Point2(x: 241, y: 58)), .size: .size(Size2(width: 1, height: 58)), .fill: .color(faint(0.16)),
            ]),
            S.symbol("Depth Icon", "snowflake", at: Point2(x: 292, y: 52), side: 18, color: faint(0.8)),
            S.text("Depth Caption", "Snow Base", at: Point2(x: 246, y: 108), size: 12, color: faint(0.65), width: 110, align: "Center"),
            Layer(name: "Card Rule", kind: .view, properties: [
                .position: .point(Point2(x: 22, y: 142)), .size: .size(Size2(width: S.column - 44, height: 1)),
                .fill: .color(faint(0.16)),
            ]),
            Layer(name: "Lift Dot", kind: .ellipse, properties: [
                .position: .point(Point2(x: 22, y: 176)), .size: .size(Size2(width: 10, height: 10)),
                .fill: .color(S.sage),
            ]),
            Layer(name: "Lift Pill", kind: .view, properties: [
                .position: .point(Point2(x: 228, y: 166)), .size: .size(Size2(width: 112, height: 32)),
                .cornerRadius: .number(16), .fill: .color(S.sage.withAlpha(0.28)),
                .strokeColor: .color(S.sage.withAlpha(0.55)), .strokeWidth: .number(1),
            ]),
        ])

        let surfaceTag = S.text("Surface Tag", "Dry Powder", at: Point2(x: 222, y: 570),
                                size: 13, weight: 600, color: iceTint, width: 138, align: "Right")
        let tempValue = S.text("Temp Value", "16°F", at: Point2(x: 26, y: 628),
                               size: 24, weight: 700, color: white, width: 110, align: "Center")
        let windValue = S.text("Wind Value", "18 mph", at: Point2(x: 146, y: 628),
                               size: 24, weight: 700, color: white, width: 110, align: "Center")
        let depthValue = S.text("Depth Value", "118″", at: Point2(x: 266, y: 628),
                                size: 24, weight: 700, color: white, width: 110, align: "Center")
        let liftName = S.text("Lift Name", "Alpine Tram", at: Point2(x: 62, y: 712),
                              size: 17, weight: 600, color: white, width: 178)
        let liftDetail = S.text("Lift Detail", "10,550 ft · Expert & Bowls", at: Point2(x: 62, y: 736),
                                size: 13, color: faint(0.75), width: 184)
        let liftStatus = S.text("Lift Status", "Open · 3 min", at: Point2(x: 248, y: 726),
                                size: 12, weight: 600, color: white, width: 112, align: "Center")

        let summit = page("Summit", fill: ColorValue(hex: "#0A1426")!, [
            summitMountain, back, resortTitle, livePill,
            summitBadge, snowfall, snowSubtitle,
            switcherGlass, thumb, summitLabel, midLabel, baseLabel, summitTab, midTab, baseTab,
            conditionsGlass, surfaceTag, tempValue, windValue, depthValue, liftName, liftDetail, liftStatus,
            screenHint("Summit", "Switch elevation, or swipe down", y: 796, dark: true),
        ])

        let screen = Layer(name: "Device", kind: .screen, properties: [.fill: .color(.black)], children: [report, summit])

        // MARK: Graph

        var b = Builder(screen: screen)

        // Top level: tapping the mountain card or featured lifts morphs into Summit.
        let tapCard = b.attach(PatchKind.tap, to: card.id, at: Point2(x: 48, y: 96))
        let tapLifts = b.attach(PatchKind.tap, to: liftsCard.id, at: Point2(x: 48, y: 264))
        let openTrigger = b.add("eitherPulse", at: Point2(x: 48, y: 96), name: "Open Trigger")
        let open = b.attach(PatchKind.navigate, to: summit.id, at: Point2(x: 336, y: 96), inputs: [
            "style": .text(Navigation.Style.morph.rawValue), "response": .number(0.48),
        ])
        b.connect(tapCard, "tapped", to: openTrigger, "a")
        b.connect(tapLifts, "tapped", to: openTrigger, "b")
        b.connect(openTrigger, "pulse", to: open, "go")

        b.view(report.id, at: Point2(x: 624, y: 96))
        b.view(summit.id, at: Point2(x: 624, y: 240))
        b.note("Open · Card or lifts morph to Summit", around: [openTrigger, open])

        // Inside Summit: return to Report via Back or a downward swipe on the mountain.
        let tapBack = b.attach(PatchKind.tap, to: back.id, at: Point2(x: 48, y: 312))
        let swipeDown = b.attach(PatchKind.swipe, to: summitMountain.id, at: Point2(x: 48, y: 480))
        let returnPulse = b.add("eitherPulse", at: Point2(x: 336, y: 312), name: "Return")
        let goBack = b.add(PatchKind.navigateBack, at: Point2(x: 624, y: 312), name: "Back to Report", inputs: [
            "response": .number(0.48),
        ])
        b.connect(tapBack, "tapped", to: returnPulse, "a")
        b.connect(swipeDown, "down", to: returnPulse, "b")
        b.connect(returnPulse, "pulse", to: goBack, "go")
        b.note("Return · Tap Back or swipe down", around: [tapBack, swipeDown, returnPulse, goBack])

        // Inside Summit: elevation switcher drives one spring (pill + mountain shader) and the report.
        let tapSummit = b.attach(PatchKind.tap, to: summitTab.id, at: Point2(x: 48, y: 744))
        let tapMid = b.attach(PatchKind.tap, to: midTab.id, at: Point2(x: 48, y: 912))
        let tapBase = b.attach(PatchKind.tap, to: baseTab.id, at: Point2(x: 48, y: 1080))
        let zone = b.add("optionSwitch", at: Point2(x: 336, y: 744), name: "Zone")
        let zoneRatio = b.add("progress", at: Point2(x: 624, y: 744), name: "Zone Progress", inputs: [
            "start": .number(0), "end": .number(2),
        ])
        let zoneMotion = b.add("spring", at: Point2(x: 912, y: 744), name: "Zone Motion", inputs: [
            "response": .number(0.42), "damping": .number(0.84),
        ])
        let thumbX = b.add("transition", at: Point2(x: 1200, y: 744), name: "Thumb X", type: .number, inputs: [
            "start": .number(25), "end": .number(261),
        ])
        let altitude = b.add("transition", at: Point2(x: 1200, y: 936), name: "Altitude", type: .number, inputs: [
            "start": .number(1.0), "end": .number(0.0),
        ])
        let zoneReport = b.document.graph.add(PatchNode(
            kind: PatchKind.javascript, position: PatchGrid.snap(Point2(x: 624, y: 1092)), name: "Zone Report",
            script: """
            // Snow, wind, temperature and lift status for Summit (0), Mid (1) and Base (2).
            inputs = { zone: 0 };
            outputs = {
              snow: "14″",
              subtitle: "10,550 ft · 24h Summit",
              surface: "Dry Powder",
              temp: "16°F",
              wind: "18 mph",
              depth: "118″",
              lift: "Alpine Tram",
              detail: "10,550 ft · Expert & Bowls",
              status: "Open · 3 min",
              summitColor: color("#18181D"),
              midColor: color("#FFFFFFF2"),
              baseColor: color("#FFFFFFF2")
            };

            const zones = [
              { snow: "14″", subtitle: "10,550 ft · 24h Summit", surface: "Dry Powder", temp: "16°F", wind: "18 mph", depth: "118″", lift: "Alpine Tram", detail: "10,550 ft · Expert & Bowls", status: "Open · 3 min" },
              { snow: "11″", subtitle: "9,240 ft · Mid-Mountain", surface: "Packed Powder", temp: "21°F", wind: "11 mph", depth: "96″", lift: "Collins Express", detail: "9,240 ft · Cruisers & Trees", status: "Open · 1 min" },
              { snow: "7″", subtitle: "8,100 ft · Base Village", surface: "Groomed", temp: "26°F", wind: "6 mph", depth: "72″", lift: "Wildcat Quad", detail: "8,100 ft · Learning & Park", status: "Open · Walk-on" }
            ];

            function evaluate(inputs, outputs) {
              const i = Math.max(0, Math.min(2, Math.round(inputs.zone)));
              const z = zones[i];
              outputs.snow = z.snow;
              outputs.subtitle = z.subtitle;
              outputs.surface = z.surface;
              outputs.temp = z.temp;
              outputs.wind = z.wind;
              outputs.depth = z.depth;
              outputs.lift = z.lift;
              outputs.detail = z.detail;
              outputs.status = z.status;
              const active = color("#18181D");
              const idle = color("#FFFFFFF2");
              outputs.summitColor = i === 0 ? active : idle;
              outputs.midColor = i === 1 ? active : idle;
              outputs.baseColor = i === 2 ? active : idle;
            }
            """
        ))

        b.connect(tapSummit, "tapped", to: zone, "set0")
        b.connect(tapMid, "tapped", to: zone, "set1")
        b.connect(tapBase, "tapped", to: zone, "set2")
        b.connect(zone, "option", to: zoneRatio, "value")
        b.connect(zoneRatio, "progress", to: zoneMotion, "target")
        b.connect(zoneMotion, "value", to: thumbX, "progress")
        b.connect(zoneMotion, "value", to: altitude, "progress")
        b.connect(zone, "option", to: zoneReport, "zone")

        let thumbView = b.view(thumb.id, at: Point2(x: 1488, y: 744))
        let mountainView = b.view(summitMountain.id, at: Point2(x: 1488, y: 936))
        let snowfallText = b.property(.text, of: snowfall.id, at: Point2(x: 1488, y: 1128))
        let subtitleText = b.property(.text, of: snowSubtitle.id, at: Point2(x: 1488, y: 1272))
        let surfaceText = b.property(.text, of: surfaceTag.id, at: Point2(x: 1488, y: 1416))
        let tempText = b.property(.text, of: tempValue.id, at: Point2(x: 1488, y: 1560))
        let windText = b.property(.text, of: windValue.id, at: Point2(x: 1488, y: 1704))
        let depthText = b.property(.text, of: depthValue.id, at: Point2(x: 1488, y: 1848))
        let liftNameText = b.property(.text, of: liftName.id, at: Point2(x: 1488, y: 1992))
        let liftDetailText = b.property(.text, of: liftDetail.id, at: Point2(x: 1488, y: 2136))
        let liftStatusText = b.property(.text, of: liftStatus.id, at: Point2(x: 1488, y: 2280))
        let summitColor = b.property(.textColor, of: summitLabel.id, at: Point2(x: 1488, y: 2424))
        let midColor = b.property(.textColor, of: midLabel.id, at: Point2(x: 1488, y: 2568))
        let baseColor = b.property(.textColor, of: baseLabel.id, at: Point2(x: 1488, y: 2712))

        b.connect(thumbX, "value", to: thumbView, "x")
        b.connect(altitude, "value", to: mountainView, ShaderUse.portID("altitude"))
        b.connect(zoneReport, "snow", to: snowfallText, "value")
        b.connect(zoneReport, "subtitle", to: subtitleText, "value")
        b.connect(zoneReport, "surface", to: surfaceText, "value")
        b.connect(zoneReport, "temp", to: tempText, "value")
        b.connect(zoneReport, "wind", to: windText, "value")
        b.connect(zoneReport, "depth", to: depthText, "value")
        b.connect(zoneReport, "lift", to: liftNameText, "value")
        b.connect(zoneReport, "detail", to: liftDetailText, "value")
        b.connect(zoneReport, "status", to: liftStatusText, "value")
        b.connect(zoneReport, "summitColor", to: summitColor, "value")
        b.connect(zoneReport, "midColor", to: midColor, "value")
        b.connect(zoneReport, "baseColor", to: baseColor, "value")

        b.note("Zone · Pick Summit, Mid or Base", around: [tapSummit, tapMid, tapBase, zone])
        b.note("Spring · Eases the elevation change", around: [zoneRatio, zoneMotion])
        b.note("Slide · Moves the pill and peaks", around: [thumbX, altitude])
        b.note("Report · Updates snow, wind and lifts", around: [zoneReport])

        for (index, view) in report.children.enumerated() {
            b.view(view.id, at: Point2(x: 336, y: 96 + Double(index) * 192))
        }

        return SnowReport(
            document: b.document,
            report: report.id,
            summit: summit.id,
            card: card.id,
            liftsCard: liftsCard.id,
            summitMountain: summitMountain.id,
            back: back.id,
            summitTab: summitTab.id,
            midTab: midTab.id,
            baseTab: baseTab.id,
            thumb: thumb.id,
            snowfall: snowfall.id,
            temp: tempValue.id,
            liftName: liftName.id,
            zone: zone,
            zoneMotion: zoneMotion
        )
    }
}
