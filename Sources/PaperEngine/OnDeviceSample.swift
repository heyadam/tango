import Foundation
import PaperModel

// A showcase for Apple's on-device model: pick a city and Generate Object plans a day
// there, field by field, while a glow runs round the card as Apple Intelligence's does.

extension SampleDocuments {
    public struct PlanADay {
        public let document: Document
        public let chip: LayerID
        public let card: LayerID
        public let glow: LayerID
        public let title: LayerID
        public let morning: LayerID
        public let tip: LayerID
        public let button: LayerID
        public let buttonLabel: LayerID
        public let plan: NodeID
        public let thinking: NodeID

        public static let cities = ["Kyoto", "Lisbon", "Marrakesh"]
        public static let cardPosition = Point2(x: 20, y: 252)
        public static let cardSize = Size2(width: 362, height: 472)
        /// How far the glow reaches past the card on each side.
        public static let glowReach = 28.0
        public static let buttonY = 778.0

        public static let instructions = "You are a well-travelled local friend. Name real places. Keep every part short and vivid."
        public static let fields = """
        title: text - an evocative title for the day, at most six words
        vibe: calm | lively | romantic | adventurous | foodie
        morning: text - what to do in the morning, under twelve words
        afternoon: text - what to do in the afternoon, under twelve words
        evening: text - what to do in the evening, under twelve words
        tip: text - one insider tip, one short sentence
        """
    }

    static let glowSource = """
    // Apple Intelligence's glow: a line of shifting color along the card's edge with a soft
    // halo past it. Strength fades it in and out; Phase turns the colors round the card.
    struct Inputs {
        float strength = 0;
        float phase = 0;
        float radius = 30;
        float inset = 28;
    };

    float glow_box(float2 p, float2 half_size, float r) {
        float2 q = abs(p) - half_size + r;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    float4 shader(Frame frame, Inputs in) {
        float2 middle = frame.size * 0.5;
        float2 p = frame.position - middle;
        float d = glow_box(p, middle - in.inset, in.radius);
        // Four colors round the card, turning with Phase.
        float turn = fract(atan2(p.y, p.x) / 6.2831853 + in.phase * 0.12);
        float3 orange = float3(1.0, 0.56, 0.26), pink = float3(0.98, 0.32, 0.62);
        float3 violet = float3(0.62, 0.38, 1.0), blue = float3(0.28, 0.62, 1.0);
        float k = turn * 4.0;
        float3 color = k < 1.0 ? mix(orange, pink, k) : k < 2.0 ? mix(pink, violet, k - 1.0)
                     : k < 3.0 ? mix(violet, blue, k - 2.0) : mix(blue, orange, k - 3.0);
        // A bright edge that breathes a little, and a halo that falls away outside.
        float breathe = 0.85 + 0.15 * sin(in.phase * 3.0 + turn * 12.566);
        float edge = exp(-abs(d) / 2.2) * breathe;
        float halo = d > 0.0 ? exp(-d / 11.0) * 0.55 : exp(d / 5.0) * 0.25;
        // Gone before the view's own edge, so no box shows round it.
        float2 room = middle - abs(p);
        float fade = smoothstep(0.0, in.inset * 0.6, min(room.x, room.y));
        float alpha = saturate((edge + halo) * in.strength * fade);
        return float4(mix(color, float3(1.0), edge * 0.35), alpha);
    }
    """

    static let backdropSource = """
    // Night over the city: a deep gradient with two soft lights, a little brighter while
    // the model is thinking.
    struct Inputs {
        float thinking = 0;
    };

    float4 shader(Frame frame, Inputs in) {
        float2 uv = frame.uv;
        float3 color = mix(float3(0.05, 0.05, 0.11), float3(0.09, 0.06, 0.17), uv.y);
        float2 a = (frame.position - float2(0.15, 0.12) * frame.size) / frame.size.x;
        float2 b = (frame.position - float2(0.95, 0.62) * frame.size) / frame.size.x;
        color += float3(0.36, 0.20, 0.62) * exp(-dot(a, a) * 6.0) * (0.55 + 0.35 * in.thinking);
        color += float3(0.12, 0.30, 0.62) * exp(-dot(b, b) * 5.0) * (0.45 + 0.35 * in.thinking);
        return float4(color, 1);
    }
    """

    /// Plan a Day: Apple's on-device model, held to six fields, fills in a card about a
    /// city. A chip asks; the fields stream in one by one; the glow runs while it thinks.
    /// Nothing is sent anywhere and no key is needed.
    public static func planADay() -> PlanADay {
        typealias S = ExampleStyle
        typealias P = PlanADay
        let white = ColorValue(white: 1)
        func faint(_ alpha: Double) -> ColorValue { ColorValue(white: 1, alpha: alpha) }

        var backdrop = Layer.new(.shader, name: "Night")
        backdrop.shader = ShaderUse(source: backdropSource)
        backdrop.properties[.size] = .size(S.device)

        let reach = P.glowReach
        var glow = Layer.new(.shader, name: "Glow")
        glow.shader = ShaderUse(source: glowSource, inputs: ["inset": .number(reach), "radius": .number(30)])
        glow.properties[.position] = .point(Point2(x: P.cardPosition.x - reach, y: P.cardPosition.y - reach))
        glow.properties[.size] = .size(Size2(width: P.cardSize.width + reach * 2, height: P.cardSize.height + reach * 2))
        glow.properties[.fill] = .color(.clear)

        // A chip for each city, repeated from one.
        let chipLabel = S.text("City", "Kyoto", size: 15, weight: 600, color: white)
        let chip = Layer(name: "Chip", kind: .view, properties: [
            .size: .size(Size2(width: 80, height: 38)), .widthMode: .text("Auto"),
            .fill: .color(faint(0.08)), .cornerRadius: .number(19),
            .strokeColor: .color(faint(0.16)), .strokeWidth: .number(1),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
            .paddingHorizontal: .number(18), .paddingVertical: .number(0),
        ], children: [chipLabel])
        let chips = Layer(name: "Cities", kind: .view, properties: [
            .position: .point(Point2(x: S.margin, y: 196)), .size: .size(Size2(width: S.column, height: 38)),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .spacing: .number(8),
        ], children: [chip])

        // The card: what the model wrote, in a pane of frosted glass.
        let vibe = S.text("Vibe", "CALM", size: 12, weight: 700, color: white)
        let vibePill = Layer(name: "Vibe Pill", kind: .view, properties: [
            .size: .size(Size2(width: 60, height: 26)), .widthMode: .text("Auto"),
            .fill: .color(S.plum.withAlpha(0.35)), .cornerRadius: .number(13),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"),
            .paddingHorizontal: .number(12), .paddingVertical: .number(0),
        ], children: [vibe])
        let topRow = Layer(name: "Top", kind: .view, properties: [
            .size: .size(Size2(width: 314, height: 26)), .widthMode: .text("Grow"),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .distribution: .text("Space Between"),
        ], children: [
            vibePill,
            S.symbol("Sparkle", "apple.intelligence", side: 20, color: faint(0.7)),
        ])
        let title = S.text("Plan Title", "Temples, Tea and Lantern Light", size: 28, weight: 700, color: white, width: 314, height: 70)
        func part(_ name: String, _ symbol: String, _ tint: ColorValue, _ words: String) -> (Layer, LayerID) {
            // Two lines at most: the fields ask for under twelve words.
            let text = S.text("\(name) Plan", words, size: 16, weight: 500, color: white, width: 256, height: 42)
            let row = Layer(name: name, kind: .view, properties: [
                .size: .size(Size2(width: 314, height: 62)), .widthMode: .text("Grow"),
                .layout: .text("Stack"), .axis: .text("Horizontal"), .spacing: .number(14),
            ], children: [
                Layer(name: "Badge", kind: .view, properties: [
                    .size: .size(Size2(width: 44, height: 44)), .cornerRadius: .number(14), .fill: .color(tint.withAlpha(0.22)),
                    .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .distribution: .text("Center"),
                ], children: [S.symbol("Glyph", symbol, side: 20, color: tint)]),
                Layer(name: "Words", kind: .view, properties: [
                    .size: .size(Size2(width: 256, height: 62)),
                    .layout: .text("Stack"), .spacing: .number(3),
                ], children: [
                    S.text("When", name.uppercased(), size: 12, weight: 700, color: faint(0.5)),
                    text,
                ]),
            ])
            return (row, text.id)
        }
        let (morning, morningText) = part("Morning", "sunrise.fill", S.amber, "Walk Fushimi Inari's vermilion gates before the crowds.")
        let (afternoon, afternoonText) = part("Afternoon", "cup.and.saucer.fill", S.sage, "Matcha and sweets in a quiet Uji teahouse.")
        let (evening, eveningText) = part("Evening", "moon.stars.fill", S.sky, "Wander Gion's lantern-lit lanes as the shops close.")
        let rule = Layer(name: "Rule", kind: .view, properties: [
            .size: .size(Size2(width: 314, height: 1)), .widthMode: .text("Grow"), .fill: .color(faint(0.12)),
        ])
        let tipGlyph = S.symbol("Tip Glyph", "lightbulb.fill", side: 16, color: S.amber)
        let tip = S.text("Tip", "Buy an ICOCA card: it pays for trains, buses and snacks.", size: 14, color: faint(0.7), width: 288, height: 38)
        let tipRow = Layer(name: "Tip Row", kind: .view, properties: [
            .size: .size(Size2(width: 314, height: 38)), .widthMode: .text("Grow"),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .spacing: .number(10),
        ], children: [tipGlyph, tip])
        let content = Layer(name: "Plan", kind: .view, properties: [
            .size: .size(P.cardSize),
            .layout: .text("Stack"), .spacing: .number(16), .paddingHorizontal: .number(24), .paddingVertical: .number(24),
        ], children: [topRow, title, morning, afternoon, evening, rule, tipRow])
        let card = Layer(name: "Card", kind: .view, properties: [
            .position: .point(P.cardPosition), .size: .size(P.cardSize),
            .fill: .color(faint(0.07)), .backgroundBlur: .number(24), .cornerRadius: .number(30), .clips: .bool(true),
            .strokeColor: .color(faint(0.14)), .strokeWidth: .number(1),
        ], children: [content])

        let buttonLabel = S.text("Label", "Plan again", size: 17, weight: 600, color: S.ink)
        let button = Layer(name: "Plan Button", kind: .view, properties: [
            .position: .point(Point2(x: S.margin, y: P.buttonY)), .size: .size(Size2(width: S.column, height: 56)),
            .fill: .color(white), .cornerRadius: .number(28),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .distribution: .text("Center"),
            .spacing: .number(8),
        ], children: [S.symbol("Glyph", "sparkles", side: 18, color: S.ink, weight: 600), buttonLabel])

        let screen = Layer(name: "Screen", kind: .screen, properties: [.fill: .color(.black)], children:
            [backdrop] + S.header("On device · Private", "Plan a Day", color: white) + [
                S.text("Blurb", "Pick a city. The model on this device plans it: no key, nothing sent.",
                       at: Point2(x: S.margin, y: 152), size: 15, color: faint(0.6), width: S.column, height: 40),
                chips, glow, card,
                S.hint("Tap a city to plan a day there", symbol: "apple.intelligence", y: 734, dark: true),
                button,
            ])

        var b = Builder(screen: screen)

        // One chip per city; the one tapped is chosen, and asks.
        let cities = b.add("splitText", at: Point2(x: 48, y: 96), name: "Cities", inputs: ["text": .text(P.cities.joined(separator: ", "))])
        let each = b.add("loopOverArray", at: Point2(x: 336, y: 96), type: .text)
        let touch = b.interaction(on: chip.id, at: Point2(x: 48, y: 312))
        let choice = b.add("loopOptionSwitch", at: Point2(x: 336, y: 312), name: "Chosen City")
        let isChosen = b.add("equal", at: Point2(x: 624, y: 312), name: "Is Chosen")
        let lit = b.add("spring", at: Point2(x: 912, y: 312), name: "Lit", inputs: ["response": .number(0.3), "damping": .number(0.85)])
        let chipFill = b.add("transition", at: Point2(x: 1200, y: 312), name: "Chip Fill", type: .color, inputs: [
            "start": .color(faint(0.08)), "end": .color(white),
        ])
        let chipInk = b.add("transition", at: Point2(x: 1200, y: 480), name: "Chip Ink", type: .color, inputs: [
            "start": .color(white), "end": .color(S.ink),
        ])
        let city = b.add("loopSelect", at: Point2(x: 624, y: 528), name: "City", type: .text)
        let chipView = b.view(chip.id, at: Point2(x: 1488, y: 312))
        let labelView = b.view(chipLabel.id, at: Point2(x: 1488, y: 96))
        b.connect(cities, "array", to: each, "array")
        b.connect(each, "value", to: labelView, LayerProperty.text.rawValue)
        b.connect(touch, "tap", to: choice, "set")
        b.connect(each, "index", to: isChosen, "a")
        b.connect(choice, "option", to: isChosen, "b")
        b.connect(isChosen, "result", to: lit, "target")
        b.connect(lit, "value", to: chipFill, "progress")
        b.connect(lit, "value", to: chipInk, "progress")
        b.connect(chipFill, "value", to: chipView, LayerProperty.fill.rawValue)
        b.connect(chipInk, "value", to: labelView, LayerProperty.textColor.rawValue)
        b.connect(each, "value", to: city, "loop")
        b.connect(choice, "option", to: city, "index")

        // The model, on the device, held to the fields: a chip or the button asks.
        let ask = b.add("joinText", at: Point2(x: 912, y: 864), name: "Prompt", inputs: ["a": .text("Plan one perfect day in ")])
        let press = b.interaction(on: button.id, at: Point2(x: 48, y: 1032))
        let either = b.add("eitherPulse", at: Point2(x: 624, y: 1032), name: "Ask")
        let plan = b.add("aiObject", at: Point2(x: 1200, y: 864), name: "Plan the Day", inputs: [
            "instructions": .text(P.instructions), "fields": .text(P.fields),
        ])
        b.connect(city, "value", to: ask, "b")
        b.connect(ask, "text", to: plan, "prompt")
        b.connect(choice, "picked", to: either, "a")
        b.connect(press, "tap", to: either, "b")
        b.connect(either, "pulse", to: plan, "send")

        // A script puts the answer on the card as it streams, and keeps the first plan
        // until there is one of the model's own.
        let cardWords = b.document.graph.add(PatchNode(
            kind: PatchKind.javascript, position: PatchGrid.snap(Point2(x: 1488, y: 864)), name: "Card Words",
            script: """
            // The plan as the card shows it. Until the model has answered, the plan the card
            // was drawn with stays; a failure shows in the tip, which is where the eye ends.
            // The last plan fades back while a new one is asked for, until its first field.
            inputs = { plan: {}, loading: false, error: "" };
            outputs = { title: "", vibe: "", morning: "", afternoon: "", evening: "", tip: "", tipSymbol: "", button: "", shown: 1 };

            let asked = null;

            const first = {
              title: "Temples, Tea and Lantern Light", vibe: "calm",
              morning: "Walk Fushimi Inari's vermilion gates before the crowds.",
              afternoon: "Matcha and sweets in a quiet Uji teahouse.",
              evening: "Wander Gion's lantern-lit lanes as the shops close.",
              tip: "Buy an ICOCA card: it pays for trains, buses and snacks.",
            };
            function evaluate(inputs, outputs) {
              const answered = inputs.plan && typeof inputs.plan === "object" && Object.keys(inputs.plan).length > 0;
              const plan = answered ? inputs.plan : first;
              for (const key of ["title", "morning", "afternoon", "evening", "tip"]) {
                outputs[key] = typeof plan[key] === "string" ? plan[key] : "";
              }
              outputs.vibe = String(plan.vibe || (inputs.loading ? "…" : "")).toUpperCase();
              outputs.tipSymbol = inputs.error ? "exclamationmark.triangle.fill" : "lightbulb.fill";
              if (inputs.error && !inputs.loading) outputs.tip = inputs.error;
              outputs.button = inputs.loading ? "Planning…" : "Plan again";
              const now = JSON.stringify(inputs.plan);
              if (!inputs.loading) asked = null;
              else if (asked === null) asked = now;
              outputs.shown = inputs.loading && now === asked ? 0.35 : 1;
            }
            """
        ))
        b.connect(plan, "object", to: cardWords, "plan")
        b.connect(plan, "loading", to: cardWords, "loading")
        b.connect(plan, "error", to: cardWords, "error")
        for (output, layer, property) in [
            ("title", title.id, LayerProperty.text), ("vibe", vibe.id, .text), ("morning", morningText, .text),
            ("afternoon", afternoonText, .text), ("evening", eveningText, .text), ("tip", tip.id, .text),
            ("tipSymbol", tipGlyph.id, .symbol), ("button", buttonLabel.id, .text),
        ] {
            let target = b.view(layer)
            b.connect(cardWords, output, to: target, property.rawValue)
        }

        // The last plan fades back while a new one is on its way.
        let shown = b.add("spring", at: Point2(x: 1776, y: 864), name: "Shown", inputs: [
            "target": .number(1), "response": .number(0.35), "damping": .number(1),
        ])
        let contentView = b.view(content.id, at: Point2(x: 2064, y: 864))
        b.connect(cardWords, "shown", to: shown, "target")
        b.connect(shown, "value", to: contentView, LayerProperty.opacity.rawValue)

        // While it thinks the glow fades in and turns, and the night brightens; it all
        // rests once the answer is in.
        let thinking = b.add("spring", at: Point2(x: 336, y: 1392), name: "Thinking", inputs: ["response": .number(0.5), "damping": .number(1)])
        let phase = b.add("time", at: Point2(x: 336, y: 1608), name: "Phase")
        let glowView = b.view(glow.id, at: Point2(x: 912, y: 1392))
        let nightView = b.view(backdrop.id, at: Point2(x: 912, y: 1728))
        b.connect(plan, "loading", to: thinking, "target")
        b.connect(plan, "loading", to: phase, "running")
        b.connect(thinking, "value", to: glowView, ShaderUse.portID("strength"))
        b.connect(phase, "time", to: glowView, ShaderUse.portID("phase"))
        b.connect(thinking, "value", to: nightView, ShaderUse.portID("thinking"))

        b.note("Cities · One chip per city; the tapped one is lit", around: [cities, each, touch, choice, isChosen, lit, chipFill, chipInk, city])
        b.note("Ask · Apple's on-device model, held to six fields", around: [ask, press, either, plan])
        b.note("Card · The answer streams onto the card", around: [cardWords, shown])
        b.note("Glow · Only while it thinks", around: [thinking, phase])

        return PlanADay(
            document: b.document, chip: chip.id, card: card.id, glow: glow.id, title: title.id, morning: morningText,
            tip: tip.id, button: button.id, buttonLabel: buttonLabel.id, plan: plan, thinking: thinking
        )
    }
}
