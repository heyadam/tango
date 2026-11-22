import Foundation
import PaperModel

// A showcase for Apple's on-device model: a chat in the manner of ChatGPT, answered by
// Generate Text with apple-on-device. The answer streams in, the conversation is kept, and
// the composer glows as Apple Intelligence does while the model thinks. No key, nothing sent.

extension SampleDocuments {
    public struct OnDeviceChat {
        public let document: Document
        public let field: LayerID
        public let send: LayerID
        public let newChat: LayerID
        public let suggestion: LayerID
        public let welcome: LayerID
        public let glow: LayerID
        public let chat: NodeID
        public let thread: NodeID
        public let thinking: NodeID

        public static let instructions = "You are a friendly assistant inside a phone app. Answer in two to four short sentences of plain text, with no Markdown."
        public static let suggestions: [(title: String, detail: String, prompt: String)] = [
            ("Plan a trip", "to Kyoto in spring", "Plan a three-day trip to Kyoto in spring."),
            ("Explain", "black holes simply", "Explain black holes like I'm five."),
            ("Write a haiku", "about Mondays", "Write a haiku about Monday mornings."),
            ("Help me name", "my grey kitten", "Help me name my grey kitten."),
        ]
        public static let composerY = 774.0
        public static let suggestionsY = 604.0
        /// Where the messages are: under the bar, over the composer.
        public static let messagesTop = 112.0
        public static var messagesHeight: Double { composerY - 12 - messagesTop }
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

    /// How the chat's scripts size a message's words: generously, so a line too many is
    /// spare room and never a line cut off.
    static let chatMeasure = """
    const wide = \(Int(ExampleStyle.column)), narrow = 268, perChar = 8.6, line = 22;
        function lines(text, width) {
          const perLine = Math.max(1, Math.floor(width / perChar));
          let count = 0;
          for (const paragraph of String(text).split("\\n")) {
            let left = 0;
            // Words that do not fit go to the next line, as the renderer wraps them.
            for (const word of paragraph.split(" ")) {
              const length = word.length + (left > 0 ? 1 : 0);
              if (left > 0 && left + length > perLine) { count++; left = word.length; } else { left += length; }
            }
            count++;
          }
          return Math.max(count, 1);
        }
    """

    /// A chat answered by Apple's on-device model, laid out as ChatGPT is: suggestions to
    /// start from, the person's words in bubbles on the right, the answer as plain text on
    /// the left, streaming in, and a composer at the bottom that glows while it thinks.
    public static func onDeviceChat() -> OnDeviceChat {
        typealias S = ExampleStyle
        typealias C = OnDeviceChat
        let white = ColorValue(white: 1)
        func faint(_ alpha: Double) -> ColorValue { ColorValue(white: 1, alpha: alpha) }
        let ground = ColorValue(hex: "#212121")!
        let raised = ColorValue(hex: "#303030")!

        // The bar: a menu, the model's name, and a new chat.
        let newChat = Layer(name: "New Chat", kind: .view, properties: [
            .position: .point(Point2(x: S.device.width - 56, y: S.top + 2)), .size: .size(Size2(width: 40, height: 40)),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .distribution: .text("Center"),
        ], children: [S.symbol("Glyph", "square.and.pencil", side: 22, color: white)])
        let bar = Layer(name: "Bar", kind: .view, properties: [
            .position: .point(Point2(x: 0, y: S.top)), .size: .size(Size2(width: S.device.width, height: 44)),
            .fill: .color(ground),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .distribution: .text("Center"),
            .spacing: .number(6),
        ], children: [
            S.text("Model", "Apple Intelligence", size: 18, weight: 600, color: white),
            S.symbol("Chevron", "chevron.right", side: 12, color: faint(0.45), weight: 700),
        ])
        let menu = S.symbol("Menu", "line.3.horizontal", at: Point2(x: S.margin, y: S.top + 11), side: 22, color: white)

        // One message, repeated for every one shown: a bubble on the right for the person,
        // plain words on the left for the model. A script per message says which.
        let words = Layer(name: "Words", kind: .text, properties: [
            .text: .text(""), .fontSize: .number(16), .fontWeight: .number(400), .textColor: .color(white),
            .size: .size(Size2(width: S.column, height: 22)), .widthMode: .text("Fixed"), .heightMode: .text("Fixed"),
        ])
        let bubble = Layer(name: "Bubble", kind: .view, properties: [
            .size: .size(Size2(width: 100, height: 40)), .widthMode: .text("Auto"), .heightMode: .text("Auto"),
            .fill: .color(raised), .cornerRadius: .number(20),
            .layout: .text("Stack"), .paddingHorizontal: .number(16), .paddingVertical: .number(10),
        ], children: [words])
        let message = Layer(name: "Message", kind: .view, properties: [
            .size: .size(Size2(width: S.column, height: 40)), .widthMode: .text("Grow"), .heightMode: .text("Auto"),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .distribution: .text("End"),
        ], children: [bubble])
        let messages = Layer(name: "Messages", kind: .view, properties: [
            .position: .point(Point2(x: 0, y: C.messagesTop)), .size: .size(Size2(width: S.device.width, height: C.messagesHeight)),
            .clips: .bool(true),
            .layout: .text("Stack"), .distribution: .text("End"), .spacing: .number(20),
            .paddingHorizontal: .number(S.margin), .paddingVertical: .number(0),
        ], children: [message])

        // Before the first message: a question, a hint, and four ways to start.
        let title = Layer(name: "Suggestion Title", kind: .text, properties: [
            .text: .text("Plan a trip"), .fontSize: .number(15), .fontWeight: .number(600), .textColor: .color(white),
            .widthMode: .text("Grow"), .heightMode: .text("Auto"),
        ])
        let detail = Layer(name: "Suggestion Detail", kind: .text, properties: [
            .text: .text("to Kyoto in spring"), .fontSize: .number(14), .textColor: .color(faint(0.5)),
            .widthMode: .text("Grow"), .heightMode: .text("Auto"),
        ])
        let suggestion = Layer(name: "Suggestion", kind: .view, properties: [
            .size: .size(Size2(width: 176, height: 70)),
            .fill: .color(ColorValue(hex: "#272727")!), .cornerRadius: .number(18),
            .strokeColor: .color(faint(0.12)), .strokeWidth: .number(1),
            .layout: .text("Stack"), .distribution: .text("Center"), .spacing: .number(3),
            .paddingHorizontal: .number(16), .paddingVertical: .number(0),
        ], children: [title, detail])
        let suggestions = Layer(name: "Suggestions", kind: .view, properties: [
            .position: .point(Point2(x: S.margin, y: C.suggestionsY)), .size: .size(Size2(width: S.column, height: 150)),
            .layout: .text("Grid"), .columns: .number(2), .spacing: .number(10),
            .paddingHorizontal: .number(0), .paddingVertical: .number(0),
        ], children: [suggestion])
        let welcome = Layer(name: "Welcome", kind: .view, properties: [
            .size: .size(S.device),
        ], children: [
            S.symbol("Mark", "apple.intelligence", at: Point2(x: S.device.width / 2 - 22, y: 300), side: 44, color: white),
            S.text("Question", "What can I help with?", at: Point2(x: S.margin, y: 360), size: 28, weight: 700,
                   color: white, width: S.column, align: "Center"),
            S.text("Promise", "Answered on this device. Nothing is sent.", at: Point2(x: S.margin, y: 402),
                   size: 15, color: faint(0.5), width: S.column, align: "Center"),
            S.hint("Tap a suggestion, or type below", y: 548, dark: true),
            suggestions,
        ])

        // The composer, with the glow behind it.
        let field = Layer(name: "Ask", kind: .textField, properties: [
            .size: .size(Size2(width: 280, height: 40)), .widthMode: .text("Grow"),
            .placeholder: .text("Ask anything"), .fontSize: .number(17), .textColor: .color(white),
            .fill: .color(.clear), .padding: .number(0),
        ])
        let send = Layer(name: "Send", kind: .view, properties: [
            .size: .size(Size2(width: 40, height: 40)), .cornerRadius: .number(20), .fill: .color(white),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .distribution: .text("Center"),
        ], children: [S.symbol("Glyph", "arrow.up", side: 18, color: ground, weight: 700)])
        let composer = Layer(name: "Composer", kind: .view, properties: [
            .position: .point(Point2(x: 14, y: C.composerY)), .size: .size(Size2(width: S.device.width - 28, height: 54)),
            .fill: .color(raised), .cornerRadius: .number(27),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .spacing: .number(8),
            .paddingLeft: .number(20), .paddingRight: .number(7), .paddingVertical: .number(0),
        ], children: [field, send])
        let reach = 22.0
        var glow = Layer.new(.shader, name: "Glow")
        glow.shader = ShaderUse(source: glowSource, inputs: ["inset": .number(reach), "radius": .number(27)])
        glow.properties[.position] = .point(Point2(x: 14 - reach, y: C.composerY - reach))
        glow.properties[.size] = .size(Size2(width: S.device.width - 28 + reach * 2, height: 54 + reach * 2))
        glow.properties[.fill] = .color(.clear)

        let screen = Layer(name: "Screen", kind: .screen, properties: [.fill: .color(ground)], children: [
            messages, welcome, bar, menu, newChat, glow, composer,
        ])

        var b = Builder(screen: screen)

        // Four ways to start, one card each; a tap asks with that card's words.
        func list(_ values: [String]) -> Value { .text(values.joined(separator: "|")) }
        let titles = b.add("splitText", at: Point2(x: 48, y: 96), name: "Titles", inputs: [
            "text": list(C.suggestions.map(\.title)), "separator": .text("|"),
        ])
        let details = b.add("splitText", at: Point2(x: 48, y: 312), name: "Details", inputs: [
            "text": list(C.suggestions.map(\.detail)), "separator": .text("|"),
        ])
        let prompts = b.add("splitText", at: Point2(x: 48, y: 528), name: "Prompts", inputs: [
            "text": list(C.suggestions.map(\.prompt)), "separator": .text("|"),
        ])
        // A loop must reach the card itself for the card to repeat: each gets its fill.
        let fills = b.add("splitText", at: Point2(x: 48, y: 744), name: "Fills", inputs: [
            "text": list(Array(repeating: "#272727", count: C.suggestions.count)), "separator": .text("|"),
        ])
        let eachFill = b.add("loopOverArray", at: Point2(x: 336, y: 744), name: "Each Fill", type: .color)
        let eachTitle = b.add("loopOverArray", at: Point2(x: 336, y: 96), name: "Each Title", type: .text)
        let eachDetail = b.add("loopOverArray", at: Point2(x: 336, y: 312), name: "Each Detail", type: .text)
        let eachPrompt = b.add("loopOverArray", at: Point2(x: 336, y: 528), name: "Each Prompt", type: .text)
        let tapped = b.interaction(on: suggestion.id, at: Point2(x: 48, y: 960))
        let picked = b.add("loopOptionSwitch", at: Point2(x: 336, y: 960), name: "Picked")
        let cardView = b.view(suggestion.id, at: Point2(x: 624, y: 744))
        b.connect(fills, "array", to: eachFill, "array")
        b.connect(eachFill, "value", to: cardView, LayerProperty.fill.rawValue)
        let pickedPrompt = b.add("loopSelect", at: Point2(x: 624, y: 528), name: "Picked Prompt", type: .text)
        let titleView = b.view(title.id, at: Point2(x: 624, y: 96))
        let detailView = b.view(detail.id, at: Point2(x: 624, y: 312))
        b.connect(titles, "array", to: eachTitle, "array")
        b.connect(details, "array", to: eachDetail, "array")
        b.connect(prompts, "array", to: eachPrompt, "array")
        b.connect(eachTitle, "value", to: titleView, LayerProperty.text.rawValue)
        b.connect(eachDetail, "value", to: detailView, LayerProperty.text.rawValue)
        b.connect(tapped, "tap", to: picked, "set")
        b.connect(eachPrompt, "value", to: pickedPrompt, "loop")
        b.connect(picked, "option", to: pickedPrompt, "index")

        // What is asked: the card's words when a card was tapped, else what was typed.
        // Return or the arrow sends; the field empties once the model has it.
        let typing = b.attach("textInput", to: field.id, at: Point2(x: 48, y: 1248))
        let arrow = b.interaction(on: send.id, at: Point2(x: 48, y: 1488))
        let typed = b.add("eitherPulse", at: Point2(x: 336, y: 1248), name: "Typed")
        let asked = b.add("eitherPulse", at: Point2(x: 624, y: 1248), name: "Ask")
        let prompt = b.add("if", at: Point2(x: 912, y: 1248), name: "Prompt", type: .text)
        let fresh = b.interaction(on: newChat.id, at: Point2(x: 624, y: 1488))
        let chat = b.add("aiText", at: Point2(x: 1200, y: 1248), name: "Chat", inputs: [
            "model": .text(AIRequest.onDevice), "instructions": .text(C.instructions),
        ])
        b.connect(picked, "picked", to: prompt, "condition")
        b.connect(pickedPrompt, "value", to: prompt, "then")
        b.connect(typing, "text", to: prompt, "else")
        b.connect(typing, "submitted", to: typed, "a")
        b.connect(arrow, "tap", to: typed, "b")
        b.connect(picked, "picked", to: asked, "a")
        b.connect(typed, "pulse", to: asked, "b")
        b.connect(prompt, "value", to: chat, "prompt")
        b.connect(asked, "pulse", to: chat, "send")
        b.connect(fresh, "tap", to: chat, "reset")
        let sent = b.add("pulse", at: Point2(x: 912, y: 1488), name: "Sent")
        b.connect(chat, "loading", to: sent, "value")
        b.connect(sent, "turnedOn", to: typing, "clear")

        // The arrow is dim until there is something to send.
        let length = b.add("textLength", at: Point2(x: 336, y: 1800), name: "Typed Length")
        let ready = b.add("if", at: Point2(x: 624, y: 1800), name: "Ready", type: .number, inputs: [
            "then": .number(0.35), "else": .number(1),
        ])
        let sendView = b.view(send.id, at: Point2(x: 912, y: 1800))
        b.connect(typing, "text", to: length, "text")
        b.connect(length, "empty", to: ready, "condition")
        b.connect(ready, "value", to: sendView, LayerProperty.opacity.rawValue)

        // The conversation as it is shown: the newest messages that fit, the answer being
        // written with a dot after it, and the welcome only before the first.
        let thread = b.document.graph.add(PatchNode(
            kind: PatchKind.javascript, position: PatchGrid.snap(Point2(x: 1488, y: 1248)), name: "Thread",
            script: """
            // The messages to show, oldest first: as many of the newest as fit the screen.
            // While the model writes, its answer ends in a dot; before its first word it
            // says it is thinking. A failure shows as the model's message.
            inputs = { conversation: [], loading: false, error: "" };
            outputs = { shown: [], empty: true };

            const room = \(Int(C.messagesHeight));
            \(chatMeasure)
            function height(text, user) { return lines(text, user ? narrow : wide) * line + (user ? 20 : 0) + 20; }
            function evaluate(inputs, outputs) {
              const turns = (Array.isArray(inputs.conversation) ? inputs.conversation : []).map((turn, index, all) => {
                const user = turn.role === "user";
                const writing = !user && inputs.loading && index === all.length - 1;
                let text = String(turn.text || "");
                if (writing) text = text.length ? text + " ●" : "Thinking…";
                return { text: text, user: user, dim: writing && !turn.text };
              });
              if (inputs.error && !inputs.loading) turns.push({ text: inputs.error, user: false, dim: true });
              const shown = [];
              let used = 0;
              for (let i = turns.length - 1; i >= 0; i--) {
                used += height(turns[i].text, turns[i].user);
                if (used > room && shown.length > 0) break;
                shown.unshift(turns[i]);
              }
              outputs.shown = shown;
              outputs.empty = turns.length === 0;
            }
            """
        ))
        let style = b.document.graph.add(PatchNode(
            kind: PatchKind.javascript, position: PatchGrid.snap(Point2(x: 2064, y: 1248)), name: "Message Style",
            script: """
            // How one message looks: the person's in a bubble on the right, as wide as its
            // words; the model's as plain text across the screen on the left.
            inputs = { message: {} };
            outputs = { text: "", side: "End", fill: color("#303030"), padding: 16, width: 268, height: 22, opacity: 1 };

            \(chatMeasure)

            function evaluate(inputs, outputs) {
              const m = inputs.message || {};
              const text = String(m.text || "");
              outputs.text = text;
              outputs.side = m.user ? "End" : "Start";
              outputs.fill = m.user ? color("#303030") : color("#00000000");
              outputs.padding = m.user ? 16 : 0;
              const longest = Math.max(...text.split("\\n").map(p => p.length), 1);
              outputs.width = m.user ? Math.min(narrow, Math.ceil(longest * perChar) + 2) : wide;
              outputs.height = lines(text, outputs.width) * line;
              outputs.opacity = m.dim ? 0.5 : 1;
            }
            """
        ))
        let eachMessage = b.add("loopOverArray", at: Point2(x: 1776, y: 1248), name: "Each Message", type: .json)
        let welcomeView = b.view(welcome.id, at: Point2(x: 1776, y: 1608))
        let messageView = b.view(message.id, at: Point2(x: 2352, y: 1248))
        let bubbleView = b.view(bubble.id, at: Point2(x: 2352, y: 1536))
        let wordsView = b.view(words.id, at: Point2(x: 2352, y: 1824))
        b.connect(chat, "conversation", to: thread, "conversation")
        b.connect(chat, "loading", to: thread, "loading")
        b.connect(chat, "error", to: thread, "error")
        b.connect(thread, "shown", to: eachMessage, "array")
        b.connect(thread, "empty", to: welcomeView, LayerProperty.visible.rawValue)
        b.connect(eachMessage, "value", to: style, "message")
        b.connect(style, "side", to: messageView, LayerProperty.distribution.rawValue)
        b.connect(style, "fill", to: bubbleView, LayerProperty.fill.rawValue)
        b.connect(style, "padding", to: bubbleView, LayerProperty.paddingHorizontal.rawValue)
        b.connect(style, "padding", to: bubbleView, LayerProperty.paddingVertical.rawValue)
        b.connect(style, "text", to: wordsView, LayerProperty.text.rawValue)
        b.connect(style, "width", to: wordsView, "width")
        b.connect(style, "height", to: wordsView, "height")
        b.connect(style, "opacity", to: wordsView, LayerProperty.opacity.rawValue)

        // While the model thinks the composer glows; it rests once the answer is in.
        let thinking = b.add("spring", at: Point2(x: 1200, y: 2112), name: "Thinking", inputs: ["response": .number(0.5), "damping": .number(1)])
        let phase = b.add("time", at: Point2(x: 1200, y: 2328), name: "Phase")
        let glowView = b.view(glow.id, at: Point2(x: 1488, y: 2112))
        b.connect(chat, "loading", to: thinking, "target")
        b.connect(chat, "loading", to: phase, "running")
        b.connect(thinking, "value", to: glowView, ShaderUse.portID("strength"))
        b.connect(phase, "time", to: glowView, ShaderUse.portID("phase"))

        b.note("Start · One card per suggestion", around: [fills, eachFill, titles, details, prompts, eachTitle, eachDetail, eachPrompt, tapped, picked, pickedPrompt])
        b.note("Ask · Apple's model on this device keeps the chat", around: [typing, arrow, typed, asked, prompt, fresh, chat, sent])
        b.note("Send · Dim until something is typed", around: [length, ready])
        b.note("Thread · What fits, newest last", around: [thread, eachMessage])
        b.note("Style · Bubble or plain words", around: [style])
        b.note("Glow · While it thinks", around: [thinking, phase])

        return OnDeviceChat(
            document: b.document, field: field.id, send: send.id, newChat: newChat.id, suggestion: suggestion.id,
            welcome: welcome.id, glow: glow.id, chat: chat, thread: thread, thinking: thinking
        )
    }
}
