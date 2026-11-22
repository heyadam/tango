import Foundation
import PaperModel

// Three showcase prototypes, where shaders, glass and motion work together as they would in
// a finished app: a music player, a weather screen and a holographic card. Each is still
// small enough to take apart, and says in its graph what each group of patches does.

extension SampleDocuments {
    // MARK: Now Playing

    public struct NowPlaying {
        public let document: Document
        public let background: LayerID
        public let cover: LayerID
        public let play: LayerID
        public let glyph: LayerID
        public let played: LayerID
        public let playing: NodeID
        public let energy: NodeID

        public static let coverSide: Double = 330
        public static let trackWidth: Double = 330
        /// The song's length and where it starts, in seconds.
        public static let duration: Double = 223
        public static let start: Double = 72
    }

    static let meshSource = """
    // A living mesh of color: four soft lights drift and swirl over a dark ground.
    // Energy makes them brighter, bigger and quicker; at 0 they barely move.
    struct Inputs {
        float energy = 1;
        float4 ground = float4(0.05, 0.03, 0.10, 1);
        float4 first = float4(0.98, 0.33, 0.42, 1);
        float4 second = float4(0.52, 0.24, 0.95, 1);
        float4 third = float4(0.10, 0.50, 0.95, 1);
        float4 fourth = float4(1.0, 0.60, 0.26, 1);
    };

    float mesh_hash(float2 p) {
        return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
    }

    float3 mesh_light(float2 p, float2 center, float reach, float3 color) {
        float2 d = p - center;
        return color * exp(-dot(d, d) / (reach * reach));
    }

    float4 shader(Frame frame, Inputs in) {
        float tall = frame.size.y / max(frame.size.x, 1.0);
        float2 p = float2(frame.uv.x, frame.uv.y * tall);
        float t = frame.time * (0.08 + 0.32 * in.energy);
        // The space itself swirls a little, so the lights bend as they pass.
        p += 0.05 * float2(sin(p.y * 5.0 + t * 1.3), cos(p.x * 4.0 - t));
        float reach = 0.34 + 0.14 * in.energy;
        float3 c = in.ground.rgb;
        c += mesh_light(p, float2(0.20 + 0.25 * sin(t * 0.9), tall * (0.22 + 0.10 * cos(t * 0.7))), reach, in.first.rgb);
        c += mesh_light(p, float2(0.85 + 0.15 * cos(t * 0.6), tall * (0.40 + 0.12 * sin(t * 0.8))), reach, in.second.rgb);
        c += mesh_light(p, float2(0.30 + 0.20 * cos(t * 0.5 + 2.0), tall * (0.72 + 0.10 * sin(t * 0.6))), reach * 1.2, in.third.rgb);
        c += mesh_light(p, float2(0.75 + 0.20 * sin(t * 0.7 + 1.0), tall * (0.92 + 0.06 * cos(t))), reach, in.fourth.rgb);
        // Softly brought down where the lights add up, and dimmer at rest.
        c = c / (1.0 + c * 0.55);
        c *= 0.5 + 0.5 * in.energy;
        // A fine grain, as in print.
        c += (mesh_hash(frame.position + fract(frame.time) * 91.0) - 0.5) * 0.035;
        return float4(c, 1);
    }
    """

    static let coverSource = """
    // The album's cover: a moon over the sea at dusk, its path on the water shimmering.
    // Energy is how fast the water moves.
    struct Inputs {
        float energy = 1;
    };

    float4 shader(Frame frame, Inputs in) {
        float2 uv = frame.uv;
        float t = frame.time * (0.3 + 0.9 * in.energy);
        float horizon = 0.6;
        float2 moon = float2(0.5, 0.36);
        float3 color;
        if (uv.y < horizon) {
            color = mix(float3(0.12, 0.06, 0.28), float3(0.98, 0.45, 0.48), pow(uv.y / horizon, 1.7));
            float d = length(uv - moon);
            color += float3(1.0, 0.62, 0.55) * 0.45 * exp(-d * d * 28.0);
            color = mix(color, float3(1.0, 0.95, 0.85), smoothstep(0.125, 0.118, d));
        } else {
            float depth = (uv.y - horizon) / (1.0 - horizon);
            color = mix(float3(0.42, 0.14, 0.38), float3(0.04, 0.03, 0.13), sqrt(depth));
            // The moon's path: broken stripes that ripple and narrow toward the horizon.
            float ripple = 0.5 + 0.5 * sin(uv.y * 150.0 - t * 2.5 + sin(uv.x * 30.0 + t) * 2.0);
            float width = 0.03 + depth * 0.2;
            float path = smoothstep(width, 0.0, abs(uv.x - 0.5 + 0.015 * sin(uv.y * 40.0 + t)));
            color += float3(1.0, 0.78, 0.62) * path * smoothstep(0.35, 0.75, ripple) * (1.0 - depth * 0.5);
        }
        return float4(color, 1);
    }
    """

    /// A music player whose whole screen is alive while it plays: a mesh of light behind,
    /// a cover that shimmers, glass controls over both. Pause and everything settles: the
    /// cover sinks back, the light dims and slows, the clock stops.
    public static func nowPlaying() -> NowPlaying {
        typealias S = ExampleStyle
        typealias Library = ComponentLibrary
        let w = S.device.width
        let white = ColorValue(white: 1)
        func faint(_ alpha: Double) -> ColorValue { ColorValue(white: 1, alpha: alpha) }

        var background = Layer.new(.shader, name: "Light")
        background.shader = ShaderUse(source: meshSource)
        background.properties[.size] = .size(S.device)

        func glassButton(_ name: String, symbol: String, at point: Point2, side: Double, glyph: Double) -> Layer {
            Library.glass(name, [
                .position: .point(point), .size: .size(Size2(width: side, height: side)),
                .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .distribution: .text("Center"),
            ], radius: side / 2, inputs: ["tint": .color(ColorValue(white: 1, alpha: 0.12))],
            [S.symbol("Glyph", symbol, side: glyph, color: white, weight: 700)])
        }
        let collapse = glassButton("Collapse", symbol: "chevron.down", at: Point2(x: S.margin, y: 70), side: 44, glyph: 16)
        let more = glassButton("More", symbol: "ellipsis", at: Point2(x: w - S.margin - 44, y: 70), side: 44, glyph: 18)
        let source = S.text("Source", "PLAYING FROM PLAYLIST", at: Point2(x: 80, y: 72), size: 11, weight: 700,
                            color: faint(0.6), width: w - 160, align: "Center")
        let playlist = S.text("Playlist", "Late Drive", at: Point2(x: 80, y: 89), size: 15, weight: 600,
                              color: white, width: w - 160, align: "Center")

        let side = NowPlaying.coverSide
        var cover = Layer.new(.shader, name: "Cover")
        cover.shader = ShaderUse(source: coverSource)
        cover.properties[.position] = .point(Point2(x: (w - side) / 2, y: 142))
        cover.properties[.size] = .size(Size2(width: side, height: side))
        cover.properties[.cornerRadius] = .number(24)
        cover.properties[.shadowColor] = .color(ColorValue(white: 0, alpha: 0.45))
        cover.properties[.shadowRadius] = .number(36)
        cover.properties[.shadowOffset] = .point(Point2(x: 0, y: 18))

        let left = (w - NowPlaying.trackWidth) / 2
        let title = S.text("Song", "Night Swim", at: Point2(x: left, y: 500), size: 26, weight: 700, color: white)
        let artist = S.text("Artist", "Moon Static", at: Point2(x: left, y: 534), size: 19, color: faint(0.62))
        let heart = S.symbol("Heart", "heart.fill", at: Point2(x: w - left - 26, y: 512), side: 24, color: faint(0.9))
        let track = Layer(name: "Track", kind: .view, properties: [
            .position: .point(Point2(x: left, y: 588)), .size: .size(Size2(width: NowPlaying.trackWidth, height: 6)),
            .fill: .color(faint(0.22)), .cornerRadius: .number(3),
        ])
        let played = Layer(name: "Played", kind: .view, properties: [
            .position: .point(Point2(x: left, y: 588)), .size: .size(Size2(width: 106, height: 6)),
            .fill: .color(white), .cornerRadius: .number(3),
        ])
        let elapsed = S.text("Elapsed", "1:12", at: Point2(x: left, y: 604), size: 13, weight: 600, color: faint(0.55))
        let remaining = S.text("Remaining", "-2:31", at: Point2(x: w - left - 60, y: 604), size: 13, weight: 600,
                               color: faint(0.55), width: 60, align: "Right")

        let glyph = S.symbol("Glyph", "pause.fill", side: 30, color: white)
        let play = Library.glass("Play", [
            .size: .size(Size2(width: 84, height: 84)),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .distribution: .text("Center"),
        ], radius: 42, inputs: ["tint": .color(ColorValue(white: 1, alpha: 0.18))], [glyph])
        let controls = Layer(name: "Controls", kind: .view, properties: [
            .position: .point(Point2(x: 0, y: 642)), .size: .size(Size2(width: w, height: 84)),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .distribution: .text("Center"),
            .spacing: .number(44),
        ], children: [
            S.symbol("Back", "backward.fill", side: 34, color: white),
            play,
            S.symbol("Forward", "forward.fill", side: 34, color: white),
        ])
        let dock = Library.glass("Dock", [
            .position: .point(Point2(x: (w - 210) / 2, y: 786)), .size: .size(Size2(width: 210, height: 52)),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .distribution: .text("Center"),
            .spacing: .number(44),
        ], radius: 26, inputs: ["tint": .color(ColorValue(white: 1, alpha: 0.12))], [
            S.symbol("Lyrics", "quote.bubble", side: 20, color: faint(0.85)),
            S.symbol("Output", "airplayaudio", side: 20, color: faint(0.85)),
            S.symbol("Queue", "list.bullet", side: 20, color: faint(0.85)),
        ])
        let screen = Layer(name: "Screen", kind: .screen, properties: [.fill: .color(.black)], children: [
            background, collapse, source, playlist, more, cover, title, artist, heart, track, played, elapsed, remaining,
            controls, S.hint("Tap pause, then play", y: 740, dark: true), dock,
        ])

        var b = Builder(screen: screen)
        // Playing or not.
        let tap = b.interaction(on: play.id, at: Point2(x: 48, y: 96))
        let playing = b.add("switch", at: Point2(x: 336, y: 96), name: "Playing", inputs: ["start": .bool(true)])
        let symbol = b.add("if", at: Point2(x: 624, y: 96), name: "Play or Pause", type: .text, inputs: [
            "then": .text("pause.fill"), "else": .text("play.fill"),
        ])
        let glyphSymbol = b.property(.symbol, of: glyph.id, at: Point2(x: 912, y: 96))
        b.connect(tap, "tap", to: playing, "flip")
        b.connect(playing, "on", to: symbol, "condition")
        b.connect(symbol, "value", to: glyphSymbol, "value")

        // How alive everything is: one spring, read by both shaders and the cover.
        let energy = b.add("spring", at: Point2(x: 336, y: 408), name: "Energy", inputs: [
            "target": .number(1), "response": .number(0.7), "damping": .number(0.9),
        ])
        let grow = b.add("transition", at: Point2(x: 624, y: 408), name: "Cover Size", type: .number, inputs: [
            "start": .number(0.82), "end": .number(1),
        ])
        let lift = b.add("transition", at: Point2(x: 624, y: 576), name: "Cover Shadow", type: .number, inputs: [
            "start": .number(12), "end": .number(36),
        ])
        let light = b.view(background.id, at: Point2(x: 912, y: 408))
        let coverView = b.view(cover.id, at: Point2(x: 1200, y: 408))
        b.connect(playing, "on", to: energy, "target")
        b.connect(energy, "value", to: light, ShaderUse.portID("energy"))
        b.connect(energy, "value", to: coverView, ShaderUse.portID("energy"))
        b.connect(energy, "value", to: grow, "progress")
        b.connect(energy, "value", to: lift, "progress")
        b.connect(grow, "value", to: coverView, LayerProperty.scale.rawValue)
        b.connect(lift, "value", to: coverView, LayerProperty.shadowRadius.rawValue)

        // The clock runs only while playing; a script writes it as the player shows it.
        let time = b.add("time", at: Point2(x: 336, y: 840))
        let clock = b.document.graph.add(PatchNode(
            kind: PatchKind.javascript, position: PatchGrid.snap(Point2(x: 624, y: 840)), name: "Clock",
            script: """
            // Seconds played, as the times beside the bar and how far along it is.
            inputs = { seconds: 0 };
            outputs = { elapsed: "", remaining: "", progress: 0 };

            const length = \(Int(NowPlaying.duration)), start = \(Int(NowPlaying.start));
            function clock(s) {
              s = Math.max(0, Math.floor(s));
              return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0");
            }
            function evaluate(inputs, outputs) {
              const at = (start + inputs.seconds) % length;
              outputs.elapsed = clock(at);
              outputs.remaining = "-" + clock(length - at);
              outputs.progress = at / length;
            }
            """
        ))
        let width = b.add("transition", at: Point2(x: 912, y: 840), name: "Played Width", type: .number, inputs: [
            "start": .number(0), "end": .number(NowPlaying.trackWidth),
        ])
        let elapsedText = b.property(.text, of: elapsed.id, at: Point2(x: 1200, y: 792))
        let remainingText = b.property(.text, of: remaining.id, at: Point2(x: 1200, y: 960))
        let playedView = b.view(played.id, at: Point2(x: 1200, y: 1128))
        b.connect(playing, "on", to: time, "running")
        b.connect(time, "time", to: clock, "seconds")
        b.connect(clock, "elapsed", to: elapsedText, "value")
        b.connect(clock, "remaining", to: remainingText, "value")
        b.connect(clock, "progress", to: width, "progress")
        b.connect(width, "value", to: playedView, "width")

        b.note("Play · A tap flips Playing", around: [tap, playing, symbol])
        b.note("Energy · Both shaders and the cover follow one spring", around: [energy, grow, lift])
        b.note("Clock · Runs while playing", around: [time, clock, width])

        return NowPlaying(
            document: b.document, background: background.id, cover: cover.id, play: play.id, glyph: glyph.id,
            played: played.id, playing: playing, energy: energy
        )
    }

    // MARK: Weather

    public struct Weather {
        public let document: Document
        public let sky: LayerID
        public let scrubber: LayerID
        public let temperature: LayerID
        public let clock: LayerID
        public let hour: NodeID

        /// The hour it starts at: late afternoon.
        public static let startHour: Double = 17.5
        /// The track the knob runs along, inside the card.
        public static let track = (x: 24.0, width: 322.0)
    }

    static let skySource = """
    // A whole day's sky from one number: `hour`, from 0 to 24. The sun rises at six on the
    // left and sets at six on the right, the moon takes its place, the colors follow, stars
    // come out at night and clouds drift all the time.
    struct Inputs {
        float hour = 17.5;
    };

    float sky_hash(float2 p) {
        return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
    }

    float sky_noise(float2 p) {
        float2 cell = floor(p);
        float2 f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        float top = mix(sky_hash(cell), sky_hash(cell + float2(1, 0)), f.x);
        float bottom = mix(sky_hash(cell + float2(0, 1)), sky_hash(cell + float2(1, 1)), f.x);
        return mix(top, bottom, f.y);
    }

    float sky_clouds(float2 p) {
        float sum = 0.0;
        float weight = 0.5;
        for (int i = 0; i < 4; i++) {
            sum += sky_noise(p) * weight;
            p = p * 2.03 + float2(1.7, 9.2);
            weight *= 0.5;
        }
        return sum;
    }

    float4 shader(Frame frame, Inputs in) {
        float h = fmod(fmod(in.hour, 24.0) + 24.0, 24.0);
        // How high the sun is: -1 at midnight, 1 at noon.
        float height = -cos(h / 24.0 * 6.2831853);
        float day = smoothstep(-0.2, 0.35, height);
        float golden = exp(-pow(height * 3.0, 2.0));
        float night = 1.0 - smoothstep(-0.35, 0.0, height);
        float2 uv = frame.uv;

        float3 top = mix(float3(0.02, 0.03, 0.10), float3(0.13, 0.42, 0.90), day);
        float3 low = mix(float3(0.07, 0.09, 0.24), float3(0.60, 0.80, 1.00), day);
        top = mix(top, float3(0.28, 0.22, 0.52), golden * 0.6);
        low = mix(low, float3(1.00, 0.52, 0.30), golden * 0.9);
        float3 color = mix(top, low, smoothstep(0.0, 0.78, uv.y));

        // The sun along its arc, and the moon twelve hours behind it.
        float along = (h - 6.0) / 12.0;
        float2 sun = float2(0.1 + 0.8 * along, 0.66 - 0.5 * height) * frame.size;
        float r = length(frame.position - sun);
        float3 sunColor = mix(float3(1.0, 0.50, 0.28), float3(1.0, 0.97, 0.88), day);
        float up = smoothstep(-0.25, 0.0, height);
        color += sunColor * exp(-r * r / 20000.0) * 0.55 * up;
        color = mix(color, sunColor, smoothstep(30.0, 27.0, r) * up);
        float moonAlong = fmod(h + 6.0, 24.0) / 12.0;
        float2 moon = float2(0.1 + 0.8 * moonAlong, 0.66 + 0.5 * height) * frame.size;
        float m = length(frame.position - moon);
        float moonUp = smoothstep(-0.25, 0.0, -height);
        color += float3(0.6, 0.7, 1.0) * exp(-m * m / 9000.0) * 0.25 * moonUp;
        color = mix(color, float3(0.92, 0.94, 1.0), smoothstep(20.0, 18.0, m) * moonUp);

        // Stars, which twinkle.
        float star = sky_hash(floor(frame.position / 3.0));
        float twinkle = 0.55 + 0.45 * sin(frame.time * 2.5 + star * 60.0);
        color += step(0.995, star) * twinkle * night * (1.0 - uv.y);

        // Clouds drift; their color follows the light.
        float2 drift = float2(uv.x * 2.6 + frame.time * 0.012, uv.y * 7.0);
        float cloud = smoothstep(0.52, 0.82, sky_clouds(drift)) * smoothstep(0.7, 0.1, uv.y);
        float3 cloudColor = mix(float3(0.13, 0.14, 0.26), float3(1.0), day);
        cloudColor = mix(cloudColor, float3(1.0, 0.68, 0.55), golden * 0.7);
        color = mix(color, cloudColor, cloud * 0.8);

        // Two lines of hills.
        float far = 0.70 + 0.035 * sin(uv.x * 6.0 + 1.0) + 0.015 * sin(uv.x * 17.0);
        float near = 0.79 + 0.045 * sin(uv.x * 3.5 + 2.4) + 0.012 * sin(uv.x * 23.0);
        float3 hills = mix(float3(0.05, 0.06, 0.15), float3(0.28, 0.46, 0.62), day);
        hills = mix(hills, float3(0.46, 0.28, 0.44), golden * 0.5);
        color = mix(color, hills, smoothstep(far, far + 0.003, uv.y));
        color = mix(color, hills * 0.55, smoothstep(near, near + 0.003, uv.y));
        return float4(color, 1);
    }
    """

    /// A weather screen whose sky is one shader with an hour as its input. A finger along
    /// the card scrubs through the day: the sun crosses, the light turns golden, the stars
    /// come out, and a script works out what the words say.
    public static func weather() -> Weather {
        typealias S = ExampleStyle
        typealias Library = ComponentLibrary
        let w = S.device.width
        let white = ColorValue(white: 1)
        func faint(_ alpha: Double) -> ColorValue { ColorValue(white: 1, alpha: alpha) }
        func lift(_ layer: Layer) -> Layer {
            var layer = layer
            layer.properties[.shadowColor] = .color(ColorValue(white: 0, alpha: 0.22))
            layer.properties[.shadowRadius] = .number(10)
            layer.properties[.shadowOffset] = .point(Point2(x: 0, y: 2))
            return layer
        }

        var sky = Layer.new(.shader, name: "Sky")
        sky.shader = ShaderUse(source: skySource, inputs: ["hour": .number(Weather.startHour)])
        sky.properties[.size] = .size(S.device)

        let place = lift(S.text("Place", "MY LOCATION", at: Point2(x: 0, y: 82), size: 13, weight: 700, color: faint(0.8), width: w, align: "Center"))
        let city = lift(S.text("City", "Lisbon", at: Point2(x: 0, y: 102), size: 34, weight: 600, color: white, width: w, align: "Center"))
        let temperature = lift(S.text("Temperature", "22°", at: Point2(x: 0, y: 140), size: 104, weight: 200, color: white, width: w, align: "Center"))
        let condition = lift(S.text("Condition", "Golden hour", at: Point2(x: 0, y: 272), size: 20, weight: 500, color: white, width: w, align: "Center"))
        let range = lift(S.text("Range", "H 22°  L 12°", at: Point2(x: 0, y: 300), size: 17, weight: 500, color: faint(0.8), width: w, align: "Center"))

        let track = Weather.track
        let ticks: [Layer] = ["12 AM", "6 AM", "12 PM", "6 PM", "12 AM"].enumerated().map { index, label in
            S.text("Tick \(index + 1)", label, at: Point2(x: track.x + Double(index) * track.width / 4 - 30, y: 150),
                   size: 11, weight: 600, color: faint(0.6), width: 60, align: "Center")
        }
        let rail = Layer(name: "Rail", kind: .view, properties: [
            .position: .point(Point2(x: track.x, y: 128)), .size: .size(Size2(width: track.width, height: 4)),
            .fill: .color(faint(0.3)), .cornerRadius: .number(2),
        ])
        let knob = Layer(name: "Knob", kind: .ellipse, properties: [
            .position: .point(Point2(x: track.x + track.width * Weather.startHour / 24 - 11, y: 119)),
            .size: .size(Size2(width: 22, height: 22)), .fill: .color(white),
            .shadowColor: .color(ColorValue(red: 1, green: 0.85, blue: 0.5, alpha: 0.9)), .shadowRadius: .number(10),
        ])
        let clock = S.text("Clock", "5:30 PM", at: Point2(x: 24, y: 46), size: 30, weight: 600, color: white)
        let icon = S.symbol("Icon", "sun.haze.fill", at: Point2(x: 314, y: 48), side: 32, color: white)
        let card = Library.glass("Card", [
            .position: .point(Point2(x: 16, y: 596)), .size: .size(Size2(width: w - 32, height: 190)),
        ], radius: 30, inputs: ["tint": .color(ColorValue(white: 1, alpha: 0.16))], [
            S.text("Heading", "THROUGH THE DAY", at: Point2(x: 24, y: 22), size: 12, weight: 700, color: faint(0.7)),
            clock, icon, rail, knob,
        ] + ticks)
        // What the finger touches: the whole card.
        let scrubber = Layer(name: "Scrubber", kind: .view, properties: [
            .position: .point(Point2(x: 16, y: 596)), .size: .size(Size2(width: w - 32, height: 190)),
        ])
        let screen = Layer(name: "Screen", kind: .screen, properties: [.fill: .color(.black)], children: [
            sky, place, city, temperature, condition, range, card, scrubber,
            S.hint("Drag across the card to change the hour", symbol: "hand.draw.fill", y: 800, dark: true),
        ])

        var b = Builder(screen: screen)
        // The finger moves the hour: a spring held by the finger follows it from wherever it
        // was, and on release it stays where it was let go.
        let touch = b.interaction(on: scrubber.id, at: Point2(x: 48, y: 96))
        let split = b.add("splitPoint", at: Point2(x: 336, y: 96))
        let hours = b.add("multiply", at: Point2(x: 624, y: 96), name: "In Hours", inputs: ["b": .number(24 / track.width)])
        let hour = b.add("spring", at: Point2(x: 912, y: 96), name: "Hour", inputs: [
            "target": .number(Weather.startHour), "response": .number(0.5), "damping": .number(1),
        ])
        let edges = b.add("pulse", at: Point2(x: 336, y: 432), name: "Touch Began / Ended")
        let offset = b.add("subtract", at: Point2(x: 624, y: 432), name: "From the Start", inputs: ["b": .number(Weather.startHour)])
        let kept = b.add("sampleHold", at: Point2(x: 912, y: 432), name: "Let Go At", type: .number)
        let resting = b.add("add", at: Point2(x: 1200, y: 432), name: "Resting Hour", inputs: ["b": .number(Weather.startHour)])
        b.connect(touch, "position", to: split, "point")
        b.connect(split, "x", to: hours, "a")
        b.connect(hours, "result", to: hour, "held")
        b.connect(touch, "down", to: hour, "hold")
        b.connect(touch, "down", to: edges, "value")
        b.connect(hour, "value", to: offset, "a")
        b.connect(offset, "result", to: kept, "value")
        b.connect(edges, "turnedOff", to: kept, "sample")
        b.connect(kept, "value", to: resting, "a")
        b.connect(resting, "result", to: hour, "target")

        // The hour paints the sky and, through a script, writes the words.
        let skyView = b.view(sky.id, at: Point2(x: 1488, y: 96))
        b.connect(hour, "value", to: skyView, ShaderUse.portID("hour"))
        let forecast = b.document.graph.add(PatchNode(
            kind: PatchKind.javascript, position: PatchGrid.snap(Point2(x: 912, y: 696)), name: "Forecast",
            script: """
            // What the screen says at an hour of the day: the time, the temperature, a few
            // words and a symbol, and where the knob is along the track.
            inputs = { hour: 17.5 };
            outputs = { time: "", temperature: "", condition: "", symbol: "", knob: 0 };

            function evaluate(inputs, outputs) {
              const h = ((inputs.hour % 24) + 24) % 24;
              const minutes = Math.floor(h * 60) % 1440;
              const hh = Math.floor(minutes / 60), mm = minutes % 60;
              const twelve = hh % 12 === 0 ? 12 : hh % 12;
              outputs.time = twelve + ":" + String(Math.floor(mm / 15) * 15).padStart(2, "0") + (hh < 12 ? " AM" : " PM");
              // Coolest just before dawn, warmest late in the afternoon.
              const warmth = 0.5 - 0.5 * Math.cos((h - 4.5) / 24 * 2 * Math.PI);
              outputs.temperature = Math.round(12 + 10 * warmth) + "°";
              const [words, symbol] =
                h < 5 ? ["Clear night", "moon.stars.fill"] :
                h < 7.5 ? ["Sunrise", "sunrise.fill"] :
                h < 11 ? ["Bright morning", "sun.max.fill"] :
                h < 15.5 ? ["Sunny", "sun.max.fill"] :
                h < 18 ? ["Golden hour", "sun.haze.fill"] :
                h < 19.5 ? ["Sunset", "sunset.fill"] :
                ["Clear night", "moon.stars.fill"];
              outputs.condition = words;
              outputs.symbol = symbol;
              outputs.knob = \(track.x) + h / 24 * \(track.width) - 11;
            }
            """
        ))
        b.connect(hour, "value", to: forecast, "hour")
        let temperatureText = b.property(.text, of: temperature.id, at: Point2(x: 1200, y: 648))
        let conditionText = b.property(.text, of: condition.id, at: Point2(x: 1200, y: 816))
        let clockText = b.property(.text, of: clock.id, at: Point2(x: 1200, y: 984))
        let iconSymbol = b.property(.symbol, of: icon.id, at: Point2(x: 1200, y: 1152))
        let knobView = b.view(knob.id, at: Point2(x: 1200, y: 1320))
        b.connect(forecast, "temperature", to: temperatureText, "value")
        b.connect(forecast, "condition", to: conditionText, "value")
        b.connect(forecast, "time", to: clockText, "value")
        b.connect(forecast, "symbol", to: iconSymbol, "value")
        b.connect(forecast, "knob", to: knobView, "x")

        b.note("Scrub · Held, the hour follows the finger", around: [touch, split, hours, hour])
        b.note("Stay · Let go, it rests where it was left", around: [edges, offset, kept, resting])
        b.note("Words · A script reads the hour", around: [forecast])

        return Weather(document: b.document, sky: sky.id, scrubber: scrubber.id, temperature: temperature.id, clock: clock.id, hour: hour)
    }

    // MARK: Holographic card

    public struct HoloCard {
        public let document: Document
        public let card: LayerID
        public let pan: NodeID
        public let tiltX: NodeID
        public let tiltY: NodeID

        public static let cardSize = Size2(width: 362, height: 228)
        public static let cardPosition = Point2(x: 20, y: 152)
        /// Points of drag for a full tilt.
        public static let reach: Double = 140
    }

    static let foilSource = """
    // Holographic foil over the views inside this one. Tilt (from -1 to 1 each way)
    // slides the rainbow and moves the glare the other way; Shine is how strong it is.
    struct Inputs {
        float2 tilt = float2(0, 0);
        float shine = 0.7;
    };

    float3 foil_spectrum(float x) {
        return 0.5 + 0.5 * cos(6.2831853 * (x + float3(0.0, 0.33, 0.67)));
    }

    float foil_hash(float2 p) {
        return fract(sin(dot(p, float2(41.3, 289.1))) * 43758.5453);
    }

    float4 shader(Frame frame, Inputs in) {
        float4 base = content(frame, frame.position);
        float2 uv = frame.uv;
        float2 tilt = clamp(in.tilt, float2(-1.0), float2(1.0));

        // Diagonal bands of color that slide as the card turns.
        float band = dot(uv, float2(0.75, 0.45)) * 1.5 + tilt.x * 0.7 + tilt.y * 0.45;
        float3 rainbow = foil_spectrum(band);
        // A fine diamond pattern pressed into the foil.
        float2 g = frame.position / 7.0;
        float pattern = 0.85 + 0.15 * sin(g.x + g.y) * sin(g.x - g.y);
        // The glare: a soft light that moves against the tilt.
        float2 light = float2(0.5 - tilt.x * 0.65, 0.3 - tilt.y * 0.65);
        float glare = exp(-length((uv - light) * float2(1.4, 1.0)) * 3.0);
        // Specks that catch the light as the bands pass over them.
        float speck = foil_hash(floor(frame.position / 2.0));
        float sparkle = step(0.988, speck) * (0.5 + 0.5 * sin(band * 40.0 + speck * 60.0));

        float strength = in.shine * (0.3 + 0.7 * glare);
        float3 color = base.rgb + rainbow * 0.5 * pattern * strength;
        color += glare * glare * 0.35 * in.shine + sparkle * strength;
        return float4(color * base.a, base.a);
    }
    """

    static let spotlightSource = """
    // A dark room with a soft light where the card is, which drifts with the tilt.
    struct Inputs {
        float2 tilt = float2(0, 0);
    };

    float4 shader(Frame frame, Inputs in) {
        float2 center = float2(0.5 - in.tilt.x * 0.08, 0.3 - in.tilt.y * 0.05) * frame.size;
        float2 d = (frame.position - center) / frame.size.x;
        float glow = exp(-dot(d, d) * 3.5);
        float3 color = float3(0.035, 0.03, 0.06) + float3(0.22, 0.16, 0.36) * glow;
        return float4(color, 1);
    }
    """

    /// A membership card in holographic foil. Drag it and it tilts: the rainbow slides, the
    /// glare moves the other way, the card turns and lifts. Let go and it settles back.
    public static func holoCard() -> HoloCard {
        typealias S = ExampleStyle
        let white = ColorValue(white: 1)
        func faint(_ alpha: Double) -> ColorValue { ColorValue(white: 1, alpha: alpha) }

        var room = Layer.new(.shader, name: "Room")
        room.shader = ShaderUse(source: spotlightSource)
        room.properties[.size] = .size(S.device)

        let size = HoloCard.cardSize
        let chip = Layer(name: "Chip", kind: .view, properties: [
            .position: .point(Point2(x: 24, y: 78)), .size: .size(Size2(width: 44, height: 34)),
            .fill: .color(ColorValue(hex: "#C9B27A")!), .cornerRadius: .number(7),
            .strokeColor: .color(ColorValue(hex: "#8E7A48")!), .strokeWidth: .number(1),
        ], children: [
            Layer(name: "Line", kind: .view, properties: [
                .position: .point(Point2(x: 0, y: 16)), .size: .size(Size2(width: 44, height: 1)), .fill: .color(ColorValue(hex: "#8E7A48")!),
            ]),
            Layer(name: "Seam", kind: .view, properties: [
                .position: .point(Point2(x: 21, y: 0)), .size: .size(Size2(width: 1, height: 34)), .fill: .color(ColorValue(hex: "#8E7A48")!),
            ]),
        ])
        var card = Layer.new(.shader, name: "Card")
        card.shader = ShaderUse(source: foilSource)
        card.properties[.position] = .point(HoloCard.cardPosition)
        card.properties[.size] = .size(size)
        card.properties[.fill] = .color(ColorValue(hex: "#17161F")!)
        card.properties[.cornerRadius] = .number(22)
        card.properties[.strokeColor] = .color(faint(0.18))
        card.properties[.strokeWidth] = .number(1)
        card.properties[.shadowColor] = .color(ColorValue(white: 0, alpha: 0.6))
        card.properties[.shadowRadius] = .number(24)
        card.properties[.shadowOffset] = .point(Point2(x: 0, y: 16))
        card.children = [
            S.text("Brand", "AURORA", at: Point2(x: 24, y: 22), size: 20, weight: 800, color: white),
            S.text("Tier", "OBSIDIAN", at: Point2(x: size.width - 124, y: 27), size: 12, weight: 700, color: faint(0.7), width: 100, align: "Right"),
            chip,
            S.symbol("Contactless", "wave.3.right", at: Point2(x: 82, y: 84), side: 22, color: faint(0.7)),
            S.text("Number", "••••  ••••  ••••  4821", at: Point2(x: 24, y: 140), size: 19, weight: 600, color: white),
            S.text("Holder", "MIKA ITO", at: Point2(x: 24, y: 190), size: 13, weight: 700, color: faint(0.85)),
            S.text("Since", "MEMBER SINCE 2024", at: Point2(x: size.width - 164, y: 191), size: 11, weight: 700,
                   color: faint(0.55), width: 140, align: "Right"),
        ]

        func stat(_ name: String, _ value: String, _ label: String) -> Layer {
            Layer(name: name, kind: .view, properties: [
                .size: .size(Size2(width: 100, height: 76)), .widthMode: .text("Grow"),
                .fill: .color(faint(0.07)), .cornerRadius: .number(18),
                .strokeColor: .color(faint(0.1)), .strokeWidth: .number(1),
                .layout: .text("Stack"), .spacing: .number(4), .paddingHorizontal: .number(14), .paddingVertical: .number(16),
            ], children: [
                S.text("Value", value, size: 20, weight: 700, color: white),
                S.text("Label", label, size: 12, weight: 600, color: faint(0.5)),
            ])
        }
        let stats = Layer(name: "Stats", kind: .view, properties: [
            .position: .point(Point2(x: S.margin, y: 516)), .size: .size(Size2(width: S.column, height: 76)),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .spacing: .number(10),
        ], children: [stat("Points", "12,480", "POINTS"), stat("Visits", "38", "VISITS"), stat("Perks", "4", "PERKS")])
        let wallet = Layer(name: "Add to Wallet", kind: .view, properties: [
            .position: .point(Point2(x: S.margin, y: 768)), .size: .size(Size2(width: S.column, height: 56)),
            .fill: .color(white), .cornerRadius: .number(28),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .distribution: .text("Center"),
            .spacing: .number(10),
        ], children: [
            S.symbol("Glyph", "wallet.pass.fill", side: 20, color: S.ink),
            S.text("Label", "Add to Wallet", weight: 600, color: S.ink),
        ])
        let screen = Layer(name: "Screen", kind: .screen, properties: [.fill: .color(.black)], children: [room] + S.header("Membership", "Your Card", color: white) + [
            card,
            S.text("Name", "Obsidian", at: Point2(x: S.margin, y: 410), size: 30, weight: 700, color: white),
            S.text("Blurb", "Our rarest tier. Free shipping, early access and a lounge at every flagship store.",
                   at: Point2(x: S.margin, y: 452), size: 15, color: faint(0.6), width: S.column, height: 44),
            stats,
            S.hint("Drag the card to tilt it", symbol: "hand.draw.fill", y: 716, dark: true),
            wallet,
        ])

        var b = Builder(screen: screen)
        // A drag tilts the card: each way, a spring held by the finger follows it and
        // settles back to flat when it lets go.
        let pan = b.attach(PatchKind.pan, to: card.id, at: Point2(x: 48, y: 96))
        let split = b.add("splitPoint", at: Point2(x: 336, y: 96))
        func tilt(_ name: String, at y: Double) -> NodeID {
            b.add("spring", at: Point2(x: 624, y: y), name: name, inputs: [
                "target": .number(0), "response": .number(0.45), "damping": .number(0.6),
            ])
        }
        let reach = b.add("multiply", at: Point2(x: 336, y: 288), name: "Per Point", inputs: ["b": .number(1 / HoloCard.reach)])
        let reachY = b.add("multiply", at: Point2(x: 336, y: 456), name: "Per Point", inputs: ["b": .number(1 / HoloCard.reach)])
        let tiltX = tilt("Tilt X", at: 96)
        let tiltY = tilt("Tilt Y", at: 360)
        b.connect(pan, "translation", to: split, "point")
        b.connect(split, "x", to: reach, "a")
        b.connect(split, "y", to: reachY, "a")
        b.connect(reach, "result", to: tiltX, "held")
        b.connect(reachY, "result", to: tiltY, "held")
        b.connect(pan, "panning", to: tiltX, "hold")
        b.connect(pan, "panning", to: tiltY, "hold")

        // The tilt as one point, for the foil and the light in the room.
        let both = b.add("makePoint", at: Point2(x: 912, y: 96), name: "Tilt")
        let cardView = b.view(card.id, at: Point2(x: 1488, y: 96))
        let roomView = b.view(room.id, at: Point2(x: 1488, y: 528))
        b.connect(tiltX, "value", to: both, "x")
        b.connect(tiltY, "value", to: both, "y")
        b.connect(both, "point", to: cardView, ShaderUse.portID("tilt"))
        b.connect(both, "point", to: roomView, ShaderUse.portID("tilt"))

        // The card itself turns a little and lifts while it is held.
        let turn = b.add("transition", at: Point2(x: 912, y: 264), name: "Turn", type: .number, inputs: [
            "start": .number(0), "end": .number(6),
        ])
        let held = b.add("spring", at: Point2(x: 336, y: 696), name: "Held", inputs: ["response": .number(0.35), "damping": .number(0.7)])
        let grow = b.add("transition", at: Point2(x: 912, y: 696), name: "Lift", type: .number, inputs: [
            "start": .number(1), "end": .number(1.05),
        ])
        let shine = b.add("transition", at: Point2(x: 912, y: 864), name: "Shine", type: .number, inputs: [
            "start": .number(0.55), "end": .number(1),
        ])
        b.connect(tiltX, "value", to: turn, "progress")
        b.connect(turn, "value", to: cardView, LayerProperty.rotation.rawValue)
        b.connect(pan, "panning", to: held, "target")
        b.connect(held, "value", to: grow, "progress")
        b.connect(held, "value", to: shine, "progress")
        b.connect(grow, "value", to: cardView, LayerProperty.scale.rawValue)
        b.connect(shine, "value", to: cardView, ShaderUse.portID("shine"))

        b.note("Tilt · Held, each spring follows the drag", around: [pan, split, reach, reachY, tiltX, tiltY])
        b.note("Foil · One point tilts the foil and the light", around: [both, turn])
        b.note("Lift · Held, the card grows and shines", around: [held, grow, shine])

        return HoloCard(document: b.document, card: card.id, pan: pan, tiltX: tiltX, tiltY: tiltY)
    }
}
