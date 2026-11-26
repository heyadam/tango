import Foundation
import PaperModel

extension SampleDocuments {
    public struct StockPicker {
        public let document: Document
        public let watchlist: LayerID
        public let chart: LayerID
        public let heroCard: LayerID
        public let nvdaRow: LayerID
        public let aaplRow: LayerID
        public let spotRow: LayerID
        public let chartCard: LayerID
        public let back: LayerID
        public let scrubArea: LayerID
        public let range1D: LayerID
        public let range1M: LayerID
        public let range1Y: LayerID
        public let rangeThumb: LayerID
        public let detailTicker: LayerID
        public let detailPrice: LayerID
        public let detailChange: LayerID
        public let scrubTime: LayerID
        public let openValue: LayerID
        public let stock: NodeID
        public let range: NodeID
        public let rangeMotion: NodeID
        public let scrubActive: NodeID
        public let trendMotion: NodeID
    }

    static let sparklineSource = """
    // Crisp mini sparkline for a watchlist row on white surface; no clock, zero idle CPU.
    struct Inputs {
        float stock = 0.0;
        float up = 1.0;
    };

    float spark_curve(float x, int s) {
        float v = 0.5;
        if (s == 0) {
            v = mix(0.28, 0.78, x) + 0.09 * sin(x * 7.4 + 0.4) + 0.05 * sin(x * 16.5 - 0.8) + 0.025 * sin(x * 29.0 + 1.2);
        } else if (s == 1) {
            v = mix(0.42, 0.68, x) + 0.07 * sin(x * 6.8 + 1.1) + 0.045 * sin(x * 15.2 - 0.4) + 0.02 * sin(x * 27.0 + 0.6);
        } else {
            v = mix(0.68, 0.34, x) + 0.08 * sin(x * 7.0 - 0.6) + 0.05 * sin(x * 15.8 + 0.9) + 0.022 * sin(x * 26.0 - 0.5);
        }
        return clamp(v, 0.12, 0.88);
    }

    float4 shader(Frame frame, Inputs in) {
        float2 size = max(frame.size, float2(1.0, 1.0));
        float2 uv = frame.uv;
        int s = int(clamp(round(in.stock), 0.0, 2.0));
        float3 emerald = float3(0.086, 0.639, 0.290);
        float3 coral = float3(0.882, 0.114, 0.282);
        float3 accent = mix(coral, emerald, clamp(in.up, 0.0, 1.0));
        float3 color = float3(1.0);

        float padX = 0.06;
        float cx = (uv.x - padX) / max(1.0 - 2.0 * padX, 0.001);
        float cy = 1.0 - uv.y;
        float inX = step(0.0, cx) * step(cx, 1.0);

        float clampedX = clamp(cx, 0.0, 1.0);
        float yVal = spark_curve(clampedX, s);
        float eps = 0.02;
        float yPrev = spark_curve(max(clampedX - eps, 0.0), s);
        float yNext = spark_curve(min(clampedX + eps, 1.0), s);
        float dydx = (yNext - yPrev) / max(min(clampedX + eps, 1.0) - max(clampedX - eps, 0.0), 0.001);
        float plotW = max(size.x * (1.0 - 2.0 * padX), 1.0);
        float slopePx = dydx * (size.y / plotW);
        float perpPx = abs((cy - yVal) * size.y) / sqrt(1.0 + slopePx * slopePx);

        if (inX > 0.5 && cy < yVal) {
            float below = clamp((yVal - cy) / max(yVal, 0.001), 0.0, 1.0);
            color = mix(color, accent, pow(1.0 - below, 1.8) * 0.16);
        }
        if (inX > 0.5) {
            float line = smoothstep(2.0, 0.8, perpPx);
            color = mix(color, accent, line);
        }
        float2 endPos = float2((1.0 - padX) * size.x, (1.0 - spark_curve(1.0, s)) * size.y);
        float endDist = length(frame.position - endPos);
        color = mix(color, accent, smoothstep(3.0, 1.8, endDist));
        return float4(color, 1.0);
    }
    """

    static let stockChartSource = """
    // Interactive stock area chart driven by `stock` (0..2), `range` (0..2), `scrub` (0..1),
    // `active` (0..1), `mode` (0 = card, 1 = full screen), and `up` (0 = coral, 1 = emerald).
    // No clock: it redraws only when inputs change, resting at zero CPU.
    struct Inputs {
        float stock = 0.0;
        float range = 0.0;
        float scrub = 0.72;
        float active = 0.0;
        float mode = 0.0;
        float up = 1.0;
    };

    float stock_sample_one(float x, int s, int r) {
        // Matches the JavaScript Stock Data patch so scrubbed prices follow the plotted curve.
        float v = 0.5;
        if (s == 0) {
            if (r == 0) {
                v = mix(0.28, 0.78, x) + 0.09 * sin(x * 7.4 + 0.4) + 0.05 * sin(x * 16.5 - 0.8) + 0.025 * sin(x * 29.0 + 1.2);
            } else if (r == 1) {
                v = mix(0.22, 0.84, x) + 0.11 * sin(x * 5.8 - 0.9) + 0.06 * sin(x * 13.0 + 0.5) + 0.025 * sin(x * 24.0 - 0.3);
            } else {
                v = mix(0.16, 0.88, x) + 0.10 * sin(x * 4.6 - 1.2) + 0.05 * sin(x * 11.2 + 0.7) + 0.022 * sin(x * 21.0 + 0.2);
            }
        } else if (s == 1) {
            if (r == 0) {
                v = mix(0.42, 0.68, x) + 0.07 * sin(x * 6.8 + 1.1) + 0.045 * sin(x * 15.2 - 0.4) + 0.02 * sin(x * 27.0 + 0.6);
            } else if (r == 1) {
                v = mix(0.32, 0.76, x) + 0.09 * sin(x * 5.2 + 0.3) + 0.05 * sin(x * 12.6 + 1.4) + 0.022 * sin(x * 23.0 - 0.7);
            } else {
                v = mix(0.24, 0.82, x) + 0.08 * sin(x * 4.2 + 0.8) + 0.045 * sin(x * 10.5 - 0.5) + 0.02 * sin(x * 19.0 + 1.0);
            }
        } else {
            if (r == 0) {
                v = mix(0.68, 0.34, x) + 0.08 * sin(x * 7.0 - 0.6) + 0.05 * sin(x * 15.8 + 0.9) + 0.022 * sin(x * 26.0 - 0.5);
            } else if (r == 1) {
                v = mix(0.26, 0.74, x) + 0.10 * sin(x * 5.6 + 0.5) + 0.055 * sin(x * 13.4 - 0.9) + 0.025 * sin(x * 22.0 + 0.4);
            } else {
                v = mix(0.20, 0.86, x) + 0.09 * sin(x * 4.8 - 0.4) + 0.05 * sin(x * 11.8 + 1.1) + 0.022 * sin(x * 20.0 - 0.6);
            }
        }
        return clamp(v, 0.10, 0.90);
    }

    float stock_sample_stock(float x, int s, float range) {
        float r0 = clamp(range, 0.0, 1.0);
        float r1 = clamp(range - 1.0, 0.0, 1.0);
        float c0 = stock_sample_one(x, s, 0);
        float c1 = stock_sample_one(x, s, 1);
        float c2 = stock_sample_one(x, s, 2);
        return mix(mix(c0, c1, r0), c2, r1);
    }

    float stock_curve(float x, float stock, float range) {
        float s0 = clamp(stock, 0.0, 1.0);
        float s1 = clamp(stock - 1.0, 0.0, 1.0);
        float a = stock_sample_stock(x, 0, range);
        float b = stock_sample_stock(x, 1, range);
        float c = stock_sample_stock(x, 2, range);
        return mix(mix(a, b, s0), c, s1);
    }

    float4 shader(Frame frame, Inputs in) {
        float2 uv = frame.uv;
        float2 size = max(frame.size, float2(1.0, 1.0));
        float mode = clamp(in.mode, 0.0, 1.0);
        float active = clamp(in.active, 0.0, 1.0);
        float scrub = clamp(in.scrub, 0.0, 1.0);
        float up = clamp(in.up, 0.0, 1.0);

        float3 emerald = float3(0.16, 0.84, 0.50);
        float3 coral = float3(0.96, 0.31, 0.44);
        float3 accent = mix(coral, emerald, up);

        // Deep obsidian backdrop with ambient glow tinted by trend.
        float3 topBg = float3(0.042, 0.058, 0.098);
        float3 botBg = float3(0.068, 0.094, 0.152);
        float3 color = mix(topBg, botBg, smoothstep(0.0, 1.0, uv.y));

        float2 glowCenter = mix(float2(0.76, 0.34), float2(0.54, 0.41), mode);
        float2 aspect = float2(size.x / size.y, 1.0);
        float glowDist = length((uv - glowCenter) * aspect);
        color += accent * exp(-glowDist * glowDist * 3.6) * mix(0.14, 0.12, mode);

        // Chart region in normalized view coordinates.
        float leftX = mix(0.055, 0.050, mode);
        float rightX = mix(0.945, 0.950, mode);
        float topY = mix(0.49, 0.335, mode);
        float botY = mix(0.82, 0.565, mode);

        float cx = (uv.x - leftX) / max(rightX - leftX, 0.001);
        float cy = (botY - uv.y) / max(botY - topY, 0.001);
        float inX = step(0.0, cx) * step(cx, 1.0);
        float inY = step(0.0, cy) * step(cy, 1.0);
        float inPlot = inX * inY;

        float chartH = max((botY - topY) * size.y, 1.0);
        float chartW = max((rightX - leftX) * size.x, 1.0);
        if (inPlot > 0.5) {
            // Precision dot-matrix backdrop on the full-screen chart.
            if (mode > 0.2) {
                float2 dotCell = fract(float2(cx * 22.0, cy * 10.0)) - 0.5;
                float dotVal = smoothstep(0.11, 0.03, length(dotCell));
                color += float3(1.0) * dotVal * 0.045 * mode;
            }

            // Subtle horizontal reference gridlines and dashed opening baseline.
            float g1 = smoothstep(0.9, 0.0, abs(cy - 0.25) * chartH);
            float g2 = smoothstep(0.9, 0.0, abs(cy - 0.50) * chartH);
            float g3 = smoothstep(0.9, 0.0, abs(cy - 0.75) * chartH);
            color += float3(1.0) * (g1 + g2 + g3) * mix(0.04, 0.055, mode);

            float openY = stock_curve(0.0, in.stock, in.range);
            float dash = step(0.45, fract(cx * 36.0));
            float baseLine = smoothstep(0.9, 0.0, abs(cy - openY) * chartH) * dash;
            color += float3(1.0) * baseLine * mix(0.10, 0.15, mode);
        }

        // Evaluate curve and slope for crisp uniform-thickness anti-aliased stroke.
        float clampedX = clamp(cx, 0.0, 1.0);
        float yVal = stock_curve(clampedX, in.stock, in.range);
        float eps = 0.006;
        float yPrev = stock_curve(max(clampedX - eps, 0.0), in.stock, in.range);
        float yNext = stock_curve(min(clampedX + eps, 1.0), in.stock, in.range);
        float dydx = (yNext - yPrev) / max(min(clampedX + eps, 1.0) - max(clampedX - eps, 0.0), 0.001);
        float slopePx = dydx * (chartH / chartW);

        float dyPx = (cy - yVal) * chartH;
        float perpPx = abs(dyPx) / sqrt(1.0 + slopePx * slopePx);

        // Dim the portion to the right of the finger while scrubbing.
        float rightSide = smoothstep(scrub - 0.004, scrub + 0.004, clampedX);
        float emphasis = mix(1.0, 0.28, rightSide * active);

        // Area gradient fill beneath the price curve.
        if (inPlot > 0.5 && cy < yVal) {
            float below = clamp((yVal - cy) / max(yVal, 0.001), 0.0, 1.0);
            float fillAlpha = pow(1.0 - below, 1.85) * mix(0.28, 0.36, mode) * emphasis;
            color = mix(color, accent, fillAlpha);
        }

        // Soft outer glow and crisp luminous stroke along the curve.
        if (inX > 0.5 && uv.y > topY - 0.03 && uv.y < botY + 0.03) {
            float glow = exp(-perpPx * 0.22) * 0.36 * emphasis;
            color += accent * glow;

            float strokeWidth = mix(2.1, 2.6, mode);
            float line = smoothstep(strokeWidth + 0.9, strokeWidth - 0.4, perpPx);
            float3 lineColor = mix(accent, float3(1.0), 0.30 * emphasis);
            color = mix(color, lineColor, line * emphasis);
        }

        // Endpoint dot at x = 1 when idle, fading out as scrubbing begins.
        float2 endPos = float2(rightX, botY - stock_curve(1.0, in.stock, in.range) * (botY - topY)) * size;
        float endDist = length(frame.position - endPos);
        float idleVis = 1.0 - active;
        color += accent * exp(-endDist * 0.15) * 0.48 * idleVis;
        color = mix(color, float3(1.0), smoothstep(4.2, 3.0, endDist) * idleVis);
        color = mix(color, accent, smoothstep(2.5, 1.5, endDist) * idleVis);

        // Interactive scrub crosshair (vertical + horizontal) and glowing reticle dot when active > 0.
        if (active > 0.001) {
            float scrubX = mix(leftX, rightX, scrub) * size.x;
            float scrubY = (botY - stock_curve(scrub, in.stock, in.range) * (botY - topY)) * size.y;
            float vHair = smoothstep(1.1, 0.2, abs(frame.position.x - scrubX)) * inY;
            float hHair = smoothstep(1.0, 0.15, abs(frame.position.y - scrubY)) * inX;
            color = mix(color, float3(1.0), vHair * 0.34 * active);
            color = mix(color, float3(1.0), hHair * 0.14 * active);

            float dotDist = length(frame.position - float2(scrubX, scrubY));
            color += accent * exp(-dotDist * 0.045) * 0.20 * active;
            color += accent * exp(-dotDist * 0.13) * 0.68 * active;
            color = mix(color, accent, smoothstep(7.4, 6.0, dotDist) * active);
            color = mix(color, float3(1.0), smoothstep(4.5, 3.3, dotDist) * active);
        }

        return float4(color, 1.0);
    }
    """

    /// A two-screen stock picker and chart explorer: tapping any stock morphs the hero
    /// chart card into a full-screen explorer where you scrub the live price curve and
    /// switch timeframes with one spring.
    public static func stockPicker() -> StockPicker {
        typealias S = ExampleStyle
        typealias Library = ComponentLibrary
        let w = S.device.width
        let white = ColorValue(white: 1)
        let emerald = ColorValue(hex: "#16A34A")!
        let emeraldBright = ColorValue(hex: "#4ADE80")!
        let coral = ColorValue(hex: "#E11D48")!
        let darkBg = ColorValue(hex: "#0B101B")!
        func faint(_ alpha: Double) -> ColorValue { ColorValue(white: 1, alpha: alpha) }
        func page(_ name: String, fill: ColorValue, _ children: [Layer]) -> Layer {
            var layer = Layer.newPage(name: name)
            layer.properties[.fill] = .color(fill)
            layer.children = children
            return layer
        }
        // Distinct hint names per screen so Morph crossfades them instead of matching them.
        func screenHint(_ prefix: String, _ words: String, symbol: String, y: Double, dark: Bool = false) -> Layer {
            let ink = dark ? white : S.ink
            let pill = Layer(name: "\(prefix) Pill", kind: .view, properties: [
                .size: .size(Size2(width: 100, height: 36)), .widthMode: .text("Auto"),
                .fill: .color(dark ? faint(0.14) : ColorValue(white: 1, alpha: 0.92)),
                .cornerRadius: .number(18),
                .strokeColor: .color(dark ? faint(0.22) : S.hairline), .strokeWidth: .number(1),
                .shadowColor: .color(dark ? .clear : S.shadow), .shadowRadius: .number(12),
                .shadowOffset: .point(Point2(x: 0, y: 4)),
                .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
                .spacing: .number(8), .paddingHorizontal: .number(16), .paddingVertical: .number(0),
            ], children: [
                S.symbol("\(prefix) Glyph", symbol, side: 15, color: dark ? ink : S.accent),
                S.text("\(prefix) Words", words, size: 14, weight: 600, color: ink),
            ])
            return Layer(name: "\(prefix) Hint", kind: .view, properties: [
                .position: .point(Point2(x: 0, y: y)), .size: .size(Size2(width: w, height: 36)),
                .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
                .distribution: .text("Center"),
            ], children: [pill])
        }

        // MARK: Screen 1 — Watchlist

        let portfolioPill = Layer(name: "Portfolio Pill", kind: .view, properties: [
            .position: .point(Point2(x: w - S.margin - 110, y: S.top + 36)),
            .size: .size(Size2(width: 110, height: 36)), .cornerRadius: .number(18),
            .fill: .color(S.surface), .strokeColor: .color(S.hairline), .strokeWidth: .number(1),
            .shadowColor: .color(S.shadow), .shadowRadius: .number(10), .shadowOffset: .point(Point2(x: 0, y: 3)),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
            .distribution: .text("Center"), .spacing: .number(5),
        ], children: [
            S.symbol("Portfolio Arrow", "arrow.up.right", side: 12, color: emerald, weight: 700),
            S.text("Portfolio Gain", "+$1,842", size: 14, weight: 600, color: emerald),
        ])

        // Matched across both screens: the dark chart shader expands full-bleed on Chart.
        var heroCard = Layer.new(.shader, name: "Chart Card")
        heroCard.shader = ShaderUse(source: stockChartSource, inputs: [
            "stock": .number(0), "range": .number(0), "scrub": .number(0.72),
            "active": .number(0), "mode": .number(0), "up": .number(1),
        ])
        heroCard.properties[.position] = .point(Point2(x: S.margin, y: 152))
        heroCard.properties[.size] = .size(Size2(width: S.column, height: 274))
        heroCard.properties[.cornerRadius] = .number(28)
        heroCard.properties[.clips] = .bool(true)
        heroCard.properties[.strokeColor] = .color(faint(0.14))
        heroCard.properties[.strokeWidth] = .number(1)
        heroCard.properties[.shadowColor] = .color(ColorValue(red: 0.04, green: 0.07, blue: 0.16, alpha: 0.26))
        heroCard.properties[.shadowRadius] = .number(24)
        heroCard.properties[.shadowOffset] = .point(Point2(x: 0, y: 12))

        // Matched sibling overlays aligned on the left so Ticker, Price and Change glide
        // upward together in parallel during Morph.
        let heroTicker = S.text("Hero Ticker", "NVDA", size: 12, weight: 700, color: white)
        let heroTickerBadge = Layer(name: "Ticker Badge", kind: .view, properties: [
            .position: .point(Point2(x: 40, y: 172)), .size: .size(Size2(width: 68, height: 28)),
            .cornerRadius: .number(14), .fill: .color(faint(0.12)),
            .strokeColor: .color(faint(0.22)), .strokeWidth: .number(1),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
            .distribution: .text("Center"),
        ], children: [heroTicker])

        let heroCompany = S.text("Hero Company", "NVIDIA Corp.", at: Point2(x: 118, y: 178),
                                 size: 13, weight: 500, color: faint(0.72), width: 146)

        let heroLivePill = Layer(name: "Hero Live", kind: .view, properties: [
            .position: .point(Point2(x: S.margin + S.column - 86, y: 172)),
            .size: .size(Size2(width: 66, height: 28)), .cornerRadius: .number(14),
            .fill: .color(faint(0.10)), .strokeColor: .color(faint(0.18)), .strokeWidth: .number(1),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
            .distribution: .text("Center"), .spacing: .number(5),
        ], children: [
            Layer(name: "Hero Live Dot", kind: .ellipse, properties: [
                .size: .size(Size2(width: 6, height: 6)), .fill: .color(emeraldBright),
            ]),
            S.text("Hero Live Text", "LIVE", size: 10, weight: 700, color: white),
        ])

        var heroPrice = S.text("Price", "$142.80", at: Point2(x: 40, y: 204),
                               size: 38, weight: 700, color: white, width: 196, height: 46)
        heroPrice.properties[.singleLine] = .bool(true)

        let heroChangeText = S.text("Hero Change", "+4.12%", size: 12, weight: 700, color: emeraldBright)
        let heroChangePill = Layer(name: "Change Pill", kind: .view, properties: [
            .position: .point(Point2(x: 40, y: 254)),
            .size: .size(Size2(width: 82, height: 26)), .cornerRadius: .number(13),
            .fill: .color(emerald.withAlpha(0.24)),
            .strokeColor: .color(emeraldBright.withAlpha(0.42)), .strokeWidth: .number(1),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
            .distribution: .text("Center"),
        ], children: [heroChangeText])

        let heroRangeCaption = S.text("Hero Caption", "Intraday · 1D", at: Point2(x: 40, y: 386),
                                      size: 12, weight: 500, color: faint(0.55))

        let inspectChip = Layer(name: "Inspect Chip", kind: .view, properties: [
            .position: .point(Point2(x: S.margin + S.column - 104, y: 378)),
            .size: .size(Size2(width: 86, height: 32)), .cornerRadius: .number(16),
            .fill: .color(ColorValue(white: 1, alpha: 0.94)),
            .shadowColor: .color(ColorValue(white: 0, alpha: 0.16)), .shadowRadius: .number(8),
            .shadowOffset: .point(Point2(x: 0, y: 2)),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
            .distribution: .text("Center"), .spacing: .number(5),
        ], children: [
            S.text("Inspect Label", "Chart", size: 13, weight: 600, color: S.ink),
            S.symbol("Inspect Arrow", "chevron.right", side: 10, color: S.accent, weight: 700),
        ])

        let sectionLabel = S.text("Section Label", "YOUR WATCHLIST", at: Point2(x: S.margin + 2, y: 444),
                                  size: 11, weight: 700, color: S.secondary)
        let sectionCount = S.text("Section Count", "3 stocks", at: Point2(x: w - S.margin - 82, y: 443),
                                  size: 12, weight: 500, color: S.tertiary, width: 80, align: "Right")

        func stockRow(
            _ prefix: String, stockIndex: Double, ticker: String, company: String, icon: String,
            tileColor: ColorValue, price: String, change: String, positive: Bool, y: Double,
            selected: Bool
        ) -> Layer {
            let changeColor = positive ? emerald : coral
            var spark = Layer.new(.shader, name: "\(prefix) Sparkline")
            spark.shader = ShaderUse(source: sparklineSource, inputs: [
                "stock": .number(stockIndex), "up": .number(positive ? 1.0 : 0.0),
            ])
            spark.properties[.position] = .point(Point2(x: 184, y: 24))
            spark.properties[.size] = .size(Size2(width: 68, height: 34))
            return Layer(name: "\(prefix) Row", kind: .view, properties: [
                .position: .point(Point2(x: S.margin, y: y)), .size: .size(Size2(width: S.column, height: 82)),
                .fill: .color(S.surface), .cornerRadius: .number(22),
                .strokeColor: .color(selected ? S.ink.withAlpha(0.18) : S.hairline.withAlpha(0.6)),
                .strokeWidth: .number(selected ? 1.5 : 1.0),
                .shadowColor: .color(S.shadow), .shadowRadius: .number(12), .shadowOffset: .point(Point2(x: 0, y: 4)),
            ], children: [
                Layer(name: "\(prefix) Icon Tile", kind: .view, properties: [
                    .position: .point(Point2(x: 16, y: 17)), .size: .size(Size2(width: 48, height: 48)),
                    .cornerRadius: .number(15), .fill: .color(tileColor),
                    .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
                    .distribution: .text("Center"),
                ], children: [
                    S.symbol("\(prefix) Glyph", icon, side: 21, color: white, weight: 600),
                ]),
                S.text("\(prefix) Ticker", ticker, at: Point2(x: 76, y: 19), size: 17, weight: 700, color: S.ink),
                S.text("\(prefix) Name", company, at: Point2(x: 76, y: 43), size: 13, color: S.secondary, width: 104),
                spark,
                S.text("\(prefix) Price", price, at: Point2(x: 256, y: 19), size: 17, weight: 700, color: S.ink,
                       width: 88, align: "Right"),
                S.text("\(prefix) Change", change, at: Point2(x: 256, y: 43), size: 13, weight: 600, color: changeColor,
                       width: 88, align: "Right"),
            ])
        }

        let nvdaRow = stockRow("NVDA", stockIndex: 0, ticker: "NVDA", company: "NVIDIA Corp.", icon: "cpu.fill",
                               tileColor: ColorValue(hex: "#10B981")!, price: "$142.80", change: "+4.12%", positive: true, y: 470, selected: true)
        let aaplRow = stockRow("AAPL", stockIndex: 1, ticker: "AAPL", company: "Apple Inc.", icon: "laptopcomputer",
                               tileColor: S.accent, price: "$234.50", change: "+1.68%", positive: true, y: 562, selected: false)
        let spotRow = stockRow("SPOT", stockIndex: 2, ticker: "SPOT", company: "Spotify Tech.", icon: "waveform",
                               tileColor: S.rose, price: "$468.20", change: "-0.84%", positive: false, y: 654, selected: false)

        let watchlist = page("Watchlist", fill: S.paper, S.header("Markets · Open", "Watchlist") + [
            portfolioPill, heroCard, heroTickerBadge, heroCompany, heroLivePill,
            heroPrice, heroChangePill, heroRangeCaption, inspectChip,
            sectionLabel, sectionCount, nvdaRow, aaplRow, spotRow,
            screenHint("Watchlist", "Tap any stock to explore its chart", symbol: "hand.tap.fill", y: 786),
        ])

        // MARK: Screen 2 — Chart

        var chartCard = Layer.new(.shader, name: "Chart Card")
        chartCard.shader = ShaderUse(source: stockChartSource, inputs: [
            "stock": .number(0), "range": .number(0), "scrub": .number(0.72),
            "active": .number(0), "mode": .number(1), "up": .number(1),
        ])
        chartCard.properties[.size] = .size(S.device)
        chartCard.properties[.cornerRadius] = .number(0)
        chartCard.properties[.clips] = .bool(true)

        let back = Library.glass("Back", [
            .position: .point(Point2(x: S.margin, y: 66)), .size: .size(Size2(width: 44, height: 44)),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .distribution: .text("Center"),
        ], radius: 22, inputs: ["tint": .color(faint(0.16))], [
            S.symbol("Back Icon", "chevron.left", side: 16, color: white, weight: 700),
        ])
        let detailCompany = S.text("Detail Company", "NVIDIA Corp.", at: Point2(x: 80, y: 77),
                                   size: 17, weight: 600, color: white, width: w - 160, align: "Center")
        let exchangePill = Library.glass("Exchange Pill", [
            .position: .point(Point2(x: w - S.margin - 76, y: 72)), .size: .size(Size2(width: 76, height: 32)),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
            .distribution: .text("Center"), .spacing: .number(6),
        ], radius: 16, inputs: ["tint": .color(faint(0.14))], [
            Layer(name: "Market Dot", kind: .ellipse, properties: [
                .size: .size(Size2(width: 7, height: 7)), .fill: .color(emeraldBright),
            ]),
            S.text("Exchange Text", "LIVE", size: 11, weight: 700, color: white),
        ])

        let detailTicker = S.text("Detail Ticker", "NVDA", size: 12, weight: 700, color: white)
        let detailTickerBadge = Layer(name: "Ticker Badge", kind: .view, properties: [
            .position: .point(Point2(x: 24, y: 128)), .size: .size(Size2(width: 68, height: 28)),
            .cornerRadius: .number(14), .fill: .color(faint(0.12)),
            .strokeColor: .color(faint(0.22)), .strokeWidth: .number(1),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
            .distribution: .text("Center"),
        ], children: [detailTicker])

        var detailPrice = S.text("Price", "$142.80", at: Point2(x: 24, y: 162),
                                 size: 52, weight: 700, color: white, width: 256, height: 62)
        detailPrice.properties[.singleLine] = .bool(true)

        let detailChangeText = S.text("Detail Change", "+4.12%", size: 12, weight: 700, color: emeraldBright)
        let detailChangePill = Layer(name: "Change Pill", kind: .view, properties: [
            .position: .point(Point2(x: 24, y: 232)), .size: .size(Size2(width: 82, height: 26)),
            .cornerRadius: .number(13), .fill: .color(emerald.withAlpha(0.24)),
            .strokeColor: .color(emeraldBright.withAlpha(0.42)), .strokeWidth: .number(1),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
            .distribution: .text("Center"),
        ], children: [detailChangeText])

        let scrubTime = S.text("Scrub Time", "Today · 4:00 PM", at: Point2(x: 118, y: 236),
                               size: 14, weight: 500, color: faint(0.72), width: 256)

        // Subtle monospace high/low axis bounds framing the right side of the plot.
        var axisHigh = S.text("Axis High", "$144.20", at: Point2(x: w - S.margin - 84, y: 274),
                              size: 11, weight: 500, color: faint(0.45), width: 84, align: "Right")
        axisHigh.properties[.fontFamily] = .text("SF Mono")
        var axisLow = S.text("Axis Low", "$135.40", at: Point2(x: w - S.margin - 84, y: 492),
                             size: 11, weight: 500, color: faint(0.45), width: 84, align: "Right")
        axisLow.properties[.fontFamily] = .text("SF Mono")

        // Touch target directly over the plotted curve for horizontal scrubbing.
        let scrubArea = Layer(name: "Scrub Area", kind: .view, properties: [
            .position: .point(Point2(x: S.margin, y: 284)), .size: .size(Size2(width: S.column, height: 212)),
        ])

        // Timeframe Switcher: Liquid Glass capsule with a sliding white thumb and three tab hits.
        let rangeBar = Library.glass("Range Bar", [
            .position: .point(Point2(x: S.margin, y: 516)), .size: .size(Size2(width: S.column, height: 50)),
        ], radius: 25, inputs: ["tint": .color(ColorValue(red: 0.05, green: 0.08, blue: 0.16, alpha: 0.38))], [])
        let rangeThumb = Layer(name: "Range Thumb", kind: .view, properties: [
            .position: .point(Point2(x: 25, y: 521)), .size: .size(Size2(width: 116, height: 40)),
            .cornerRadius: .number(20), .fill: .color(ColorValue(white: 1, alpha: 0.95)),
            .shadowColor: .color(ColorValue(white: 0, alpha: 0.2)), .shadowRadius: .number(8),
            .shadowOffset: .point(Point2(x: 0, y: 2)),
        ])
        let label1D = S.text("1D Label", "1D", at: Point2(x: 25, y: 532),
                             size: 15, weight: 600, color: S.ink, width: 116, align: "Center")
        let label1M = S.text("1M Label", "1M", at: Point2(x: 143, y: 532),
                             size: 15, weight: 600, color: faint(0.92), width: 116, align: "Center")
        let label1Y = S.text("1Y Label", "1Y", at: Point2(x: 261, y: 532),
                             size: 15, weight: 600, color: faint(0.92), width: 116, align: "Center")
        let range1D = Layer(name: "1D Tab", kind: .view, properties: [
            .position: .point(Point2(x: 25, y: 521)), .size: .size(Size2(width: 116, height: 40)),
        ])
        let range1M = Layer(name: "1M Tab", kind: .view, properties: [
            .position: .point(Point2(x: 143, y: 521)), .size: .size(Size2(width: 116, height: 40)),
        ])
        let range1Y = Layer(name: "1Y Tab", kind: .view, properties: [
            .position: .point(Point2(x: 261, y: 521)), .size: .size(Size2(width: 116, height: 40)),
        ])

        // Key Statistics Liquid Glass card, with live readouts layered cleanly on top.
        let statsGlass = Library.glass("Stats Card", [
            .position: .point(Point2(x: S.margin, y: 582)), .size: .size(Size2(width: S.column, height: 192)),
        ], radius: 28, inputs: ["tint": .color(ColorValue(red: 0.05, green: 0.08, blue: 0.16, alpha: 0.46))], [
            S.text("Stats Heading", "KEY STATISTICS", at: Point2(x: 22, y: 20), size: 11, weight: 700, color: faint(0.60)),
            S.text("Open Caption", "Open", at: Point2(x: 6, y: 92), size: 12, color: faint(0.62), width: 110, align: "Center"),
            Layer(name: "Stat Rule 1", kind: .view, properties: [
                .position: .point(Point2(x: 121, y: 56)), .size: .size(Size2(width: 1, height: 52)), .fill: .color(faint(0.14)),
            ]),
            S.text("High Caption", "Range High", at: Point2(x: 126, y: 92), size: 12, color: faint(0.62), width: 110, align: "Center"),
            Layer(name: "Stat Rule 2", kind: .view, properties: [
                .position: .point(Point2(x: 241, y: 56)), .size: .size(Size2(width: 1, height: 52)), .fill: .color(faint(0.14)),
            ]),
            S.text("Volume Caption", "Volume", at: Point2(x: 246, y: 92), size: 12, color: faint(0.62), width: 110, align: "Center"),
            Layer(name: "Stats Rule", kind: .view, properties: [
                .position: .point(Point2(x: 22, y: 126)), .size: .size(Size2(width: S.column - 44, height: 1)),
                .fill: .color(faint(0.14)),
            ]),
            S.text("Cap Caption", "Market Cap", at: Point2(x: 22, y: 140), size: 12, color: faint(0.60)),
        ])

        let sectorTag = S.text("Sector Tag", "Semiconductors", at: Point2(x: 202, y: 601),
                               size: 12, weight: 600, color: emeraldBright, width: 158, align: "Right")
        let openValue = S.text("Open Value", "$137.15", at: Point2(x: 26, y: 640),
                               size: 21, weight: 700, color: white, width: 110, align: "Center")
        let highValue = S.text("High Value", "$144.20", at: Point2(x: 146, y: 640),
                               size: 21, weight: 700, color: white, width: 110, align: "Center")
        let volumeValue = S.text("Volume Value", "48.2M", at: Point2(x: 266, y: 640),
                                 size: 21, weight: 700, color: white, width: 110, align: "Center")
        let capValue = S.text("Cap Value", "$3.49T", at: Point2(x: 42, y: 738),
                              size: 18, weight: 700, color: white, width: 140)
        let ratingText = S.text("Rating Text", "Strong Buy", size: 12, weight: 600, color: white)
        let ratingPill = Layer(name: "Rating Pill", kind: .view, properties: [
            .position: .point(Point2(x: 248, y: 726)), .size: .size(Size2(width: 112, height: 32)),
            .cornerRadius: .number(16), .fill: .color(emerald.withAlpha(0.28)),
            .strokeColor: .color(emeraldBright.withAlpha(0.48)), .strokeWidth: .number(1),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
            .distribution: .text("Center"),
        ], children: [ratingText])

        let chart = page("Chart", fill: darkBg, [
            chartCard, back, detailCompany, exchangePill,
            detailTickerBadge, detailPrice, detailChangePill, scrubTime, axisHigh, axisLow, scrubArea,
            rangeBar, rangeThumb, label1D, label1M, label1Y, range1D, range1M, range1Y,
            statsGlass, sectorTag, openValue, highValue, volumeValue, capValue, ratingPill,
            screenHint("Chart", "Drag across the chart, or switch range", symbol: "hand.draw.fill", y: 794, dark: true),
        ])

        let screen = Layer(name: "Device", kind: .screen, properties: [.fill: .color(.black)], children: [watchlist, chart])

        // MARK: Graph

        var b = Builder(screen: screen)

        // Watchlist taps: pick a stock and morph into Chart.
        let tapNVDA = b.attach(PatchKind.tap, to: nvdaRow.id, at: Point2(x: 48, y: 2736))
        let tapAAPL = b.attach(PatchKind.tap, to: aaplRow.id, at: Point2(x: 48, y: 2904))
        let tapSPOT = b.attach(PatchKind.tap, to: spotRow.id, at: Point2(x: 48, y: 3072))
        let tapHero = b.attach(PatchKind.tap, to: heroCard.id, at: Point2(x: 48, y: 3240))
        b.note("Watchlist · Tapping any stock or card", around: [tapNVDA, tapAAPL, tapSPOT, tapHero])

        // Top level: active stock selection and Morph navigation to Chart.
        let stock = b.add("optionSwitch", at: Point2(x: 48, y: 96), name: "Stock")
        let stockMotion = b.add("spring", at: Point2(x: 336, y: 96), name: "Stock Motion", inputs: [
            "response": .number(0.46), "damping": .number(0.86),
        ])
        let pick1 = b.add("eitherPulse", at: Point2(x: 48, y: 300), name: "NVDA or AAPL")
        let pick2 = b.add("eitherPulse", at: Point2(x: 48, y: 456), name: "SPOT or Card")
        let openAny = b.add("eitherPulse", at: Point2(x: 336, y: 372), name: "Open Trigger")
        let open = b.attach(PatchKind.navigate, to: chart.id, at: Point2(x: 624, y: 372), inputs: [
            "style": .text(Navigation.Style.morph.rawValue), "response": .number(0.52),
        ])
        b.connect(tapNVDA, "tapped", to: stock, "set0")
        b.connect(tapAAPL, "tapped", to: stock, "set1")
        b.connect(tapSPOT, "tapped", to: stock, "set2")
        b.connect(stock, "option", to: stockMotion, "target")
        b.connect(tapNVDA, "tapped", to: pick1, "a")
        b.connect(tapAAPL, "tapped", to: pick1, "b")
        b.connect(tapSPOT, "tapped", to: pick2, "a")
        b.connect(tapHero, "tapped", to: pick2, "b")
        b.connect(pick1, "pulse", to: openAny, "a")
        b.connect(pick2, "pulse", to: openAny, "b")
        b.connect(openAny, "pulse", to: open, "go")
        b.view(watchlist.id, at: Point2(x: 912, y: 96))
        b.view(chart.id, at: Point2(x: 912, y: 240))
        b.note("Open · Picked stock morphs to Chart", around: [stock, stockMotion, pick1, pick2, openAny, open])

        // Inside Chart: return to Watchlist via Back or a downward swipe on the backdrop.
        let tapBack = b.attach(PatchKind.tap, to: back.id, at: Point2(x: 48, y: 1320))
        let swipeDown = b.attach(PatchKind.swipe, to: chartCard.id, at: Point2(x: 48, y: 1488))
        let returnPulse = b.add("eitherPulse", at: Point2(x: 336, y: 1320), name: "Return")
        let goBack = b.add(PatchKind.navigateBack, at: Point2(x: 624, y: 1320), name: "Back to Watchlist", inputs: [
            "response": .number(0.44),
        ])
        let cardArrive = b.add("transition", at: Point2(x: 912, y: 1320), name: "Card Arrive", type: .number, inputs: [
            "start": .number(0.94), "end": .number(1.0),
        ])
        b.connect(tapBack, "tapped", to: returnPulse, "a")
        b.connect(swipeDown, "down", to: returnPulse, "b")
        b.connect(returnPulse, "pulse", to: goBack, "go")
        b.connect(open, "progress", to: cardArrive, "progress")
        b.note("Return · Tap Back or swipe down", around: [tapBack, swipeDown, returnPulse, goBack, cardArrive])

        // Inside Chart: scrub across the curve with a fluid spring-smoothed crosshair.
        let scrubTouch = b.interaction(on: scrubArea.id, at: Point2(x: 48, y: 1704))
        let scrubXY = b.add("splitPoint", at: Point2(x: 336, y: 1704), name: "Finger X")
        let scrubProgress = b.add("progress", at: Point2(x: 624, y: 1704), name: "Along Chart", inputs: [
            "start": .number(S.margin), "end": .number(S.margin + S.column),
        ])
        let scrubClamp = b.add("clamp", at: Point2(x: 912, y: 1704), name: "Scrub")
        let scrubXMotion = b.add("spring", at: Point2(x: 1200, y: 1704), name: "Scrub Glide", inputs: [
            "response": .number(0.14), "damping": .number(0.92),
        ])
        let scrubActive = b.add("spring", at: Point2(x: 336, y: 1920), name: "Reticle", inputs: [
            "response": .number(0.24), "damping": .number(0.84),
        ])
        let priceLift = b.add("transition", at: Point2(x: 624, y: 1920), name: "Price Lift", type: .number, inputs: [
            "start": .number(1.0), "end": .number(1.04),
        ])
        let focusDim = b.add("transition", at: Point2(x: 912, y: 1920), name: "Focus Dim", type: .number, inputs: [
            "start": .number(1.0), "end": .number(0.72),
        ])
        b.connect(scrubTouch, "position", to: scrubXY, "point")
        b.connect(scrubXY, "x", to: scrubProgress, "value")
        b.connect(scrubProgress, "progress", to: scrubClamp, "value")
        b.connect(scrubClamp, "result", to: scrubXMotion, "target")
        b.connect(scrubTouch, "down", to: scrubActive, "target")
        b.connect(scrubActive, "value", to: priceLift, "progress")
        b.connect(scrubActive, "value", to: focusDim, "progress")
        b.note("Scrub · Fluid crosshair and live focus", around: [
            scrubTouch, scrubXY, scrubProgress, scrubClamp, scrubXMotion, scrubActive, priceLift, focusDim,
        ])

        // Inside Chart: timeframe switcher drives one fluid spring for pill and shader curve.
        let tap1D = b.attach(PatchKind.tap, to: range1D.id, at: Point2(x: 48, y: 2280))
        let tap1M = b.attach(PatchKind.tap, to: range1M.id, at: Point2(x: 48, y: 2448))
        let tap1Y = b.attach(PatchKind.tap, to: range1Y.id, at: Point2(x: 48, y: 2616))
        let range = b.add("optionSwitch", at: Point2(x: 336, y: 2280), name: "Range")
        let rangeRatio = b.add("progress", at: Point2(x: 624, y: 2280), name: "Range Ratio", inputs: [
            "start": .number(0), "end": .number(2),
        ])
        let rangeMotion = b.add("spring", at: Point2(x: 912, y: 2280), name: "Range Motion", inputs: [
            "response": .number(0.46), "damping": .number(0.78),
        ])
        let thumbX = b.add("transition", at: Point2(x: 1200, y: 2280), name: "Thumb X", type: .number, inputs: [
            "start": .number(25), "end": .number(261),
        ])
        let shaderRange = b.add("transition", at: Point2(x: 1200, y: 2472), name: "Chart Range", type: .number, inputs: [
            "start": .number(0), "end": .number(2),
        ])
        b.connect(tap1D, "tapped", to: range, "set0")
        b.connect(tap1M, "tapped", to: range, "set1")
        b.connect(tap1Y, "tapped", to: range, "set2")
        b.connect(range, "option", to: rangeRatio, "value")
        b.connect(rangeRatio, "progress", to: rangeMotion, "target")
        b.connect(rangeMotion, "value", to: thumbX, "progress")
        b.connect(rangeMotion, "value", to: shaderRange, "progress")
        b.note("Range · Pick 1D, 1M or 1Y", around: [tap1D, tap1M, tap1Y, range])
        b.note("Spring · Slides pill and morphs curve", around: [rangeRatio, rangeMotion, thumbX, shaderRange])

        // Stock data & live scrub readout shared by both screens (sits at top level).
        let stockData = b.document.graph.add(PatchNode(
            kind: PatchKind.javascript, position: PatchGrid.snap(Point2(x: 336, y: 672)), name: "Stock Data",
            script: """
            // Prices, stats, colors and live scrub readouts for NVDA (0), AAPL (1) and SPOT (2)
            // across 1D (0), 1M (1) and 1Y (2), matching the Metal chart curve.
            inputs = { stock: 0, range: 0, scrub: 0.72, scrubbing: false };
            outputs = {
              ticker: "NVDA",
              company: "NVIDIA Corp.",
              sector: "Semiconductors",
              heroPrice: "$142.80",
              detailPrice: "$142.80",
              change: "+4.12%",
              time: "Today · 4:00 PM",
              open: "$137.15",
              high: "$144.20",
              low: "$135.40",
              volume: "48.2M",
              cap: "$3.49T",
              rating: "Strong Buy",
              up: 1,
              badgeFill: color("#16A34A3D"),
              badgeStroke: color("#4ADE806B"),
              badgeText: color("#4ADE80"),
              color1D: color("#18181D"),
              color1M: color("#FFFFFFEB"),
              color1Y: color("#FFFFFFEB"),
              nvdaStroke: color("#18181D2E"),
              aaplStroke: color("#E6E2DA99"),
              spotStroke: color("#E6E2DA99")
            };

            const stocks = [
              {
                ticker: "NVDA", company: "NVIDIA Corp.", sector: "Semiconductors", cap: "$3.49T", rating: "Strong Buy",
                ranges: [
                  { low: 135.4, high: 144.2, close: 142.80, open: "$137.15", highText: "$144.20", lowText: "$135.40", vol: "48.2M", pct: "+4.12%", up: 1 },
                  { low: 118.0, high: 145.6, close: 142.80, open: "$122.40", highText: "$145.60", lowText: "$118.00", vol: "52.1M", pct: "+16.6%", up: 1 },
                  { low: 62.0, high: 149.8, close: 142.80, open: "$64.20", highText: "$149.80", lowText: "$62.00", vol: "46.8M", pct: "+122.4%", up: 1 }
                ]
              },
              {
                ticker: "AAPL", company: "Apple Inc.", sector: "Consumer Tech", cap: "$3.56T", rating: "Buy",
                ranges: [
                  { low: 229.8, high: 236.1, close: 234.50, open: "$230.62", highText: "$236.10", lowText: "$229.80", vol: "39.4M", pct: "+1.68%", up: 1 },
                  { low: 218.2, high: 237.4, close: 234.50, open: "$221.90", highText: "$237.40", lowText: "$218.20", vol: "41.8M", pct: "+5.68%", up: 1 },
                  { low: 169.4, high: 239.2, close: 234.50, open: "$186.10", highText: "$239.20", lowText: "$169.40", vol: "44.5M", pct: "+26.0%", up: 1 }
                ]
              },
              {
                ticker: "SPOT", company: "Spotify Tech.", sector: "Streaming", cap: "$93.6B", rating: "Outperform",
                ranges: [
                  { low: 464.0, high: 476.8, close: 468.20, open: "$472.16", highText: "$476.80", lowText: "$464.00", vol: "1.9M", pct: "-0.84%", up: 0 },
                  { low: 418.0, high: 478.4, close: 468.20, open: "$424.50", highText: "$478.40", lowText: "$418.00", vol: "2.3M", pct: "+10.3%", up: 1 },
                  { low: 248.0, high: 482.0, close: 468.20, open: "$262.40", highText: "$482.00", lowText: "$248.00", vol: "2.1M", pct: "+78.4%", up: 1 }
                ]
              }
            ];

            function curve(x, s, r) {
              let v = 0.5;
              if (s === 0) {
                if (r === 0) v = 0.28 + 0.50 * x + 0.09 * Math.sin(x * 7.4 + 0.4) + 0.05 * Math.sin(x * 16.5 - 0.8) + 0.025 * Math.sin(x * 29.0 + 1.2);
                else if (r === 1) v = 0.22 + 0.62 * x + 0.11 * Math.sin(x * 5.8 - 0.9) + 0.06 * Math.sin(x * 13.0 + 0.5) + 0.025 * Math.sin(x * 24.0 - 0.3);
                else v = 0.16 + 0.72 * x + 0.10 * Math.sin(x * 4.6 - 1.2) + 0.05 * Math.sin(x * 11.2 + 0.7) + 0.022 * Math.sin(x * 21.0 + 0.2);
              } else if (s === 1) {
                if (r === 0) v = 0.42 + 0.26 * x + 0.07 * Math.sin(x * 6.8 + 1.1) + 0.045 * Math.sin(x * 15.2 - 0.4) + 0.02 * Math.sin(x * 27.0 + 0.6);
                else if (r === 1) v = 0.32 + 0.44 * x + 0.09 * Math.sin(x * 5.2 + 0.3) + 0.05 * Math.sin(x * 12.6 + 1.4) + 0.022 * Math.sin(x * 23.0 - 0.7);
                else v = 0.24 + 0.58 * x + 0.08 * Math.sin(x * 4.2 + 0.8) + 0.045 * Math.sin(x * 10.5 - 0.5) + 0.02 * Math.sin(x * 19.0 + 1.0);
              } else {
                if (r === 0) v = 0.68 - 0.34 * x + 0.08 * Math.sin(x * 7.0 - 0.6) + 0.05 * Math.sin(x * 15.8 + 0.9) + 0.022 * Math.sin(x * 26.0 - 0.5);
                else if (r === 1) v = 0.26 + 0.48 * x + 0.10 * Math.sin(x * 5.6 + 0.5) + 0.055 * Math.sin(x * 13.4 - 0.9) + 0.025 * Math.sin(x * 22.0 + 0.4);
                else v = 0.20 + 0.66 * x + 0.09 * Math.sin(x * 4.8 - 0.4) + 0.05 * Math.sin(x * 11.8 + 1.1) + 0.022 * Math.sin(x * 20.0 - 0.6);
              }
              return Math.max(0.10, Math.min(0.90, v));
            }

            function scrubLabel(x, r) {
              if (r === 0) {
                const mins = Math.round(9 * 60 + 30 + x * 390);
                const h24 = Math.floor(mins / 60);
                const m = mins % 60;
                const h12 = h24 > 12 ? h24 - 12 : h24;
                const ampm = h24 >= 12 ? "PM" : "AM";
                return "Today · " + h12 + ":" + (m < 10 ? "0" : "") + m + " " + ampm;
              }
              if (r === 1) {
                const day = Math.max(1, Math.min(30, Math.round(1 + x * 29)));
                return "Nov " + day + " · Close";
              }
              const months = ["Dec", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov"];
              return months[Math.max(0, Math.min(11, Math.round(x * 11)))] + " · 2026";
            }

            function evaluate(inputs, outputs) {
              const s = Math.max(0, Math.min(2, Math.round(inputs.stock)));
              const r = Math.max(0, Math.min(2, Math.round(inputs.range)));
              const x = Math.max(0, Math.min(1, inputs.scrub));
              const st = stocks[s];
              const rg = st.ranges[r];
              const hero = "$" + rg.close.toFixed(2);
              const val = rg.low + ((curve(x, s, r) - 0.10) / 0.80) * (rg.high - rg.low);
              const detail = inputs.scrubbing ? ("$" + val.toFixed(2)) : hero;

              outputs.ticker = st.ticker;
              outputs.company = st.company;
              outputs.sector = st.sector;
              outputs.heroPrice = hero;
              outputs.detailPrice = detail;
              outputs.change = rg.pct;
              outputs.time = inputs.scrubbing ? scrubLabel(x, r) : (r === 0 ? "Today · 4:00 PM" : (r === 1 ? "Past Month" : "Past Year"));
              outputs.open = rg.open;
              outputs.high = rg.highText;
              outputs.low = rg.lowText;
              outputs.volume = rg.vol;
              outputs.cap = st.cap;
              outputs.rating = st.rating;
              outputs.up = rg.up;

              const positive = rg.up > 0.5;
              outputs.badgeFill = positive ? color("#16A34A3D") : color("#E11D483D");
              outputs.badgeStroke = positive ? color("#4ADE806B") : color("#FB71856B");
              outputs.badgeText = positive ? color("#4ADE80") : color("#FB7185");

              const active = color("#18181D");
              const idle = color("#FFFFFFEB");
              outputs.color1D = r === 0 ? active : idle;
              outputs.color1M = r === 1 ? active : idle;
              outputs.color1Y = r === 2 ? active : idle;

              const picked = color("#18181D2E");
              const muted = color("#E6E2DA99");
              outputs.nvdaStroke = s === 0 ? picked : muted;
              outputs.aaplStroke = s === 1 ? picked : muted;
              outputs.spotStroke = s === 2 ? picked : muted;
            }
            """
        ))
        // Smoothly blends emerald and coral when a stock's trend flips across ranges.
        let trendMotion = b.add("spring", at: Point2(x: 624, y: 672), name: "Trend Color", inputs: [
            "target": .number(1), "response": .number(0.50), "damping": .number(0.85),
        ])

        b.connect(stock, "option", to: stockData, "stock")
        b.connect(range, "option", to: stockData, "range")
        b.connect(scrubXMotion, "value", to: stockData, "scrub")
        b.connect(scrubTouch, "down", to: stockData, "scrubbing")
        b.connect(stockData, "up", to: trendMotion, "target")
        b.note("Data · Quotes, stats and live scrub price", around: [stockData, trendMotion])

        // Wire shader inputs & readouts on Screen 1 (Hero) and Screen 2 (Chart).
        let heroCardView = b.view(heroCard.id, at: Point2(x: 912, y: 96))
        b.connect(stockMotion, "value", to: heroCardView, ShaderUse.portID("stock"))
        b.connect(trendMotion, "value", to: heroCardView, ShaderUse.portID("up"))

        let heroTickerText = b.property(.text, of: heroTicker.id, at: Point2(x: 912, y: 288))
        let heroCompanyText = b.property(.text, of: heroCompany.id, at: Point2(x: 912, y: 432))
        let heroPriceText = b.property(.text, of: heroPrice.id, at: Point2(x: 912, y: 576))
        let heroChangeProp = b.property(.text, of: heroChangeText.id, at: Point2(x: 912, y: 720))
        let heroChangeColor = b.property(.textColor, of: heroChangeText.id, at: Point2(x: 912, y: 720))
        let heroBadgeFill = b.property(.fill, of: heroChangePill.id, at: Point2(x: 912, y: 864))
        let heroBadgeStroke = b.property(.strokeColor, of: heroChangePill.id, at: Point2(x: 912, y: 864))
        let nvdaStroke = b.property(.strokeColor, of: nvdaRow.id, at: Point2(x: 912, y: 1008))
        let aaplStroke = b.property(.strokeColor, of: aaplRow.id, at: Point2(x: 912, y: 1152))
        let spotStroke = b.property(.strokeColor, of: spotRow.id, at: Point2(x: 912, y: 1296))
        b.connect(stockData, "ticker", to: heroTickerText, "value")
        b.connect(stockData, "company", to: heroCompanyText, "value")
        b.connect(stockData, "heroPrice", to: heroPriceText, "value")
        b.connect(stockData, "change", to: heroChangeProp, "value")
        b.connect(stockData, "badgeText", to: heroChangeColor, "value")
        b.connect(stockData, "badgeFill", to: heroBadgeFill, "value")
        b.connect(stockData, "badgeStroke", to: heroBadgeStroke, "value")
        b.connect(stockData, "nvdaStroke", to: nvdaStroke, "value")
        b.connect(stockData, "aaplStroke", to: aaplStroke, "value")
        b.connect(stockData, "spotStroke", to: spotStroke, "value")

        let chartCardView = b.view(chartCard.id, at: Point2(x: 1488, y: 480))
        b.connect(stockMotion, "value", to: chartCardView, ShaderUse.portID("stock"))
        b.connect(shaderRange, "value", to: chartCardView, ShaderUse.portID("range"))
        b.connect(scrubXMotion, "value", to: chartCardView, ShaderUse.portID("scrub"))
        b.connect(scrubActive, "value", to: chartCardView, ShaderUse.portID("active"))
        b.connect(open, "progress", to: chartCardView, ShaderUse.portID("mode"))
        b.connect(trendMotion, "value", to: chartCardView, ShaderUse.portID("up"))

        let thumbView = b.view(rangeThumb.id, at: Point2(x: 1488, y: 1128))
        b.connect(thumbX, "value", to: thumbView, "x")

        let rangeBarScale = b.property(.scale, of: rangeBar.id, at: Point2(x: 1488, y: 960))
        let rangeBarOpacity = b.property(.opacity, of: rangeBar.id, at: Point2(x: 1488, y: 960))
        let statsCardScale = b.property(.scale, of: statsGlass.id, at: Point2(x: 1488, y: 1044))
        let statsCardOpacity = b.property(.opacity, of: statsGlass.id, at: Point2(x: 1488, y: 1044))
        let detailPriceScale = b.property(.scale, of: detailPrice.id, at: Point2(x: 1488, y: 1584))
        b.connect(cardArrive, "value", to: rangeBarScale, "value")
        b.connect(focusDim, "value", to: rangeBarOpacity, "value")
        b.connect(cardArrive, "value", to: statsCardScale, "value")
        b.connect(focusDim, "value", to: statsCardOpacity, "value")
        b.connect(priceLift, "value", to: detailPriceScale, "value")

        let detailTickerProp = b.property(.text, of: detailTicker.id, at: Point2(x: 1488, y: 1296))
        let detailCompanyProp = b.property(.text, of: detailCompany.id, at: Point2(x: 1488, y: 1440))
        let detailPriceProp = b.property(.text, of: detailPrice.id, at: Point2(x: 1488, y: 1584))
        let detailChangeProp = b.property(.text, of: detailChangeText.id, at: Point2(x: 1488, y: 1728))
        let detailChangeColor = b.property(.textColor, of: detailChangeText.id, at: Point2(x: 1488, y: 1728))
        let detailBadgeFill = b.property(.fill, of: detailChangePill.id, at: Point2(x: 1488, y: 1872))
        let detailBadgeStroke = b.property(.strokeColor, of: detailChangePill.id, at: Point2(x: 1488, y: 1872))
        let scrubTimeProp = b.property(.text, of: scrubTime.id, at: Point2(x: 1488, y: 2016))
        let axisHighProp = b.property(.text, of: axisHigh.id, at: Point2(x: 1488, y: 2160))
        let axisLowProp = b.property(.text, of: axisLow.id, at: Point2(x: 1488, y: 2304))
        let sectorProp = b.property(.text, of: sectorTag.id, at: Point2(x: 1488, y: 2448))
        let sectorColor = b.property(.textColor, of: sectorTag.id, at: Point2(x: 1488, y: 2448))
        let openProp = b.property(.text, of: openValue.id, at: Point2(x: 1488, y: 2592))
        let highProp = b.property(.text, of: highValue.id, at: Point2(x: 1488, y: 2736))
        let volProp = b.property(.text, of: volumeValue.id, at: Point2(x: 1488, y: 2880))
        let capProp = b.property(.text, of: capValue.id, at: Point2(x: 1488, y: 3024))
        let ratingProp = b.property(.text, of: ratingText.id, at: Point2(x: 1488, y: 3168))
        let ratingFill = b.property(.fill, of: ratingPill.id, at: Point2(x: 1488, y: 3312))
        let ratingStroke = b.property(.strokeColor, of: ratingPill.id, at: Point2(x: 1488, y: 3312))
        let color1D = b.property(.textColor, of: label1D.id, at: Point2(x: 1488, y: 3456))
        let color1M = b.property(.textColor, of: label1M.id, at: Point2(x: 1488, y: 3600))
        let color1Y = b.property(.textColor, of: label1Y.id, at: Point2(x: 1488, y: 3744))

        b.connect(stockData, "ticker", to: detailTickerProp, "value")
        b.connect(stockData, "company", to: detailCompanyProp, "value")
        b.connect(stockData, "detailPrice", to: detailPriceProp, "value")
        b.connect(stockData, "change", to: detailChangeProp, "value")
        b.connect(stockData, "badgeText", to: detailChangeColor, "value")
        b.connect(stockData, "badgeFill", to: detailBadgeFill, "value")
        b.connect(stockData, "badgeStroke", to: detailBadgeStroke, "value")
        b.connect(stockData, "time", to: scrubTimeProp, "value")
        b.connect(stockData, "high", to: axisHighProp, "value")
        b.connect(stockData, "low", to: axisLowProp, "value")
        b.connect(stockData, "sector", to: sectorProp, "value")
        b.connect(stockData, "badgeText", to: sectorColor, "value")
        b.connect(stockData, "open", to: openProp, "value")
        b.connect(stockData, "high", to: highProp, "value")
        b.connect(stockData, "volume", to: volProp, "value")
        b.connect(stockData, "cap", to: capProp, "value")
        b.connect(stockData, "rating", to: ratingProp, "value")
        b.connect(stockData, "badgeFill", to: ratingFill, "value")
        b.connect(stockData, "badgeStroke", to: ratingStroke, "value")
        b.connect(stockData, "color1D", to: color1D, "value")
        b.connect(stockData, "color1M", to: color1M, "value")
        b.connect(stockData, "color1Y", to: color1Y, "value")

        return StockPicker(
            document: b.document,
            watchlist: watchlist.id,
            chart: chart.id,
            heroCard: heroCard.id,
            nvdaRow: nvdaRow.id,
            aaplRow: aaplRow.id,
            spotRow: spotRow.id,
            chartCard: chartCard.id,
            back: back.id,
            scrubArea: scrubArea.id,
            range1D: range1D.id,
            range1M: range1M.id,
            range1Y: range1Y.id,
            rangeThumb: rangeThumb.id,
            detailTicker: detailTicker.id,
            detailPrice: detailPrice.id,
            detailChange: detailChangeText.id,
            scrubTime: scrubTime.id,
            openValue: openValue.id,
            stock: stock,
            range: range,
            rangeMotion: rangeMotion,
            scrubActive: scrubActive,
            trendMotion: trendMotion
        )
    }
}
