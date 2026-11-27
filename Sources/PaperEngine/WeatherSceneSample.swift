import Foundation
import PaperModel

extension SampleDocuments {
    public struct WeatherScene {
        public let document: Document
        /// The scene view the weather is drawn in.
        public let stage: LayerID
        /// The sky behind everything: a shader view.
        public let sky: LayerID
        /// The five days of the forecast, in order.
        public let days: [LayerID]
        /// The pill that slides behind the chosen day.
        public let pill: LayerID
        public let temperature: LayerID
        public let condition: LayerID
        public let range: LayerID
        /// The script that runs the weather.
        public let weather: NodeID

        /// The ids of the things in the scene, which name their ports.
        public static let sun = "sun", corona = "corona", cloud = "cloud", backCloud = "back", frontCloud = "front"
        public static let bolt = "bolt", rain = "rain", snow = "snow"

        public struct Day: Sendable {
            public let name: String, symbol: String, condition: String, temperature: Int, high: Int, low: Int
        }
        /// The forecast, today first. Each day's weather is one of the five the scene draws.
        public static let forecast: [Day] = [
            Day(name: "Today", symbol: "cloud.sun.fill", condition: "Partly Cloudy", temperature: 72, high: 76, low: 54),
            Day(name: "Fri", symbol: "sun.max.fill", condition: "Sunny", temperature: 78, high: 81, low: 55),
            Day(name: "Sat", symbol: "cloud.rain.fill", condition: "Rain", temperature: 59, high: 62, low: 47),
            Day(name: "Sun", symbol: "cloud.bolt.rain.fill", condition: "Thunderstorms", temperature: 63, high: 66, low: 49),
            Day(name: "Mon", symbol: "cloud.snow.fill", condition: "Snow", temperature: 31, high: 34, low: 22),
        ]
        /// How far up the middle of the scene view the weather stands.
        public static let lift = 0.3
        /// The box rain and snow fall through: from inside the cloud's base down to just
        /// above the forecast card, where the emitter shrinks them away (`top` and `bottom`
        /// in the scene, below the weather's own lift).
        public static let fallTop = 0.05, fallBottom = -1.18
        /// How many raindrops and snowflakes the emitters draw at the most.
        public static let raindrops = 1100, snowflakes = 800
    }

    /// A weather app with the weather itself in three dimensions, drawn by a scene view
    /// with real light: a sun that glows and blooms behind a halo, soft clouds of vapor
    /// (`WeatherModels` makes the cloud and the bolt in code), rain and snow as emitters of
    /// a thousand glassy streaks or drifting flakes, and lightning that is white-hot, blooms
    /// and lights the cloud from inside. A tap on a day of the forecast changes the weather:
    /// one script eases everything from one sky to the next (the sun sinking away, clouds
    /// gathering and darkening, the light swinging round, the bloom, the sky's colors) and
    /// gives the emitters the clock as their time, asking for frames only while something
    /// moves. The sky behind is a shader the same script drives: its gradient, haze and the
    /// distant weather. A drag turns the scene round and it springs back.
    public static func weatherScene() -> WeatherScene {
        typealias S = ExampleStyle
        typealias W = WeatherScene
        typealias Library = ComponentLibrary
        let white = ColorValue.white
        func faint(_ alpha: Double) -> ColorValue { ColorValue(white: 1, alpha: alpha) }
        let width = S.device.width

        // MARK: The scene

        let fallMiddle = W.lift + (W.fallTop + W.fallBottom) / 2, fallHeight = W.fallTop - W.fallBottom
        // Clouds are vapor: raymarched volumes, each in a box about twice as wide as tall.
        func cloud(_ id: String, _ name: String, x: Double, y: Double, z: Double, scale: Double, seed: Double) -> SceneObject {
            SceneObject(id: id, name: name, shape: .cloud, values: [
                "x": .number(x), "y": .number(W.lift + y), "z": .number(z),
                "scaleX": .number(scale * 1.1), "scaleY": .number(scale * 0.7), "scaleZ": .number(scale * 0.7),
                "color": .color(white), "coverage": .number(0.55), "fluffiness": .number(0.65), "seed": .number(seed),
            ])
        }
        let scene = SceneUse(objects: [
            // The sun glows: its light is far brighter than white, so it blooms, and it
            // lights the clouds in front of it.
            SceneObject(id: W.sun, name: "Sun", shape: .sphere, values: [
                "x": .number(0.44), "y": .number(W.lift + 0.34), "z": .number(-0.5), "scale": .number(0.9),
                "color": .color(ColorValue(hex: "#FFB21C")!), "roughness": .number(0.4),
                "emission": .number(3.2), "emissionColor": .color(ColorValue(hex: "#FFB43C")!),
            ]),
            // A soft, faint halo round it.
            SceneObject(id: W.corona, name: "Corona", shape: .sphere, values: [
                "x": .number(0.44), "y": .number(W.lift + 0.34), "z": .number(-0.6), "scale": .number(1.45),
                "color": .color(ColorValue(hex: "#FFD27A")!), "softness": .number(1), "opacity": .number(0.18),
                "emission": .number(0.5),
            ]),
            cloud(W.backCloud, "Far Cloud", x: 0.95, y: -0.32, z: -0.8, scale: 0.8, seed: 5),
            cloud(W.cloud, "Cloud", x: -0.12, y: -0.02, z: 0, scale: 1.75, seed: 1),
            cloud(W.frontCloud, "Near Cloud", x: -0.82, y: -0.5, z: 0.55, scale: 0.6, seed: 9),
            // Lightning: white-hot, so it blooms and lights the cloud it comes from.
            SceneObject(id: W.bolt, name: "Bolt", shape: .model, model: WeatherModels.boltName, values: [
                "x": .number(0.08), "y": .number(W.lift - 0.72), "z": .number(0.35), "scale": .number(0), "scaleX": .number(0),
                "color": .color(ColorValue(hex: "#FFF3B8")!), "emission": .number(4.5),
                "emissionColor": .color(ColorValue(hex: "#E8EEFF")!),
            ]),
            // Rain: glassy streaks, stretched along the way they fall.
            SceneObject(id: W.rain, name: "Rain", shape: .particles, values: [
                "y": .number(fallMiddle), "particle": .text("Sphere"), "count": .number(0),
                "spreadX": .number(2.2), "spreadY": .number(fallHeight), "spreadZ": .number(1.1),
                "velocityX": .number(-0.35), "velocityY": .number(-5.5), "size": .number(0.016), "sizeRange": .number(0.5),
                "stretch": .number(8), "color": .color(ColorValue(hex: "#CFE6FF")!), "roughness": .number(0.05),
                "opacity": .number(0.45), "seed": .number(3),
            ]),
            // Snow: small soft flakes drifting down and sideways.
            SceneObject(id: W.snow, name: "Snow", shape: .particles, values: [
                "y": .number(fallMiddle), "particle": .text("Sphere"), "count": .number(0),
                "spreadX": .number(2.6), "spreadY": .number(fallHeight), "spreadZ": .number(1.3),
                "velocityY": .number(-0.42), "size": .number(0.034), "sizeRange": .number(0.6), "sway": .number(0.09),
                "color": .color(white), "roughness": .number(0.9), "softness": .number(0.6), "emission": .number(0.12),
                "seed": .number(7),
            ]),
        ], values: [
            "cameraPitch": .number(6), "cameraDistance": .number(4.2), "environment": .text("Daylight"),
            "lightYaw": .number(38), "lightPitch": .number(34), "lightIntensity": .number(3.5), "bloom": .number(0.9),
        ])
        var stage = Layer.new(.scene, name: "Weather")
        stage.scene = scene
        stage.properties = [
            .position: .point(Point2(x: 0, y: 262)), .size: .size(Size2(width: width, height: 378)),
            .fill: .color(.clear),
        ]

        // MARK: The page

        var sky = Layer.new(.shader, name: "Sky")
        sky.shader = ShaderUse(source: skyShader, inputs: [
            "top": .color(ColorValue(hex: "#3A86D6")!), "bottom": .color(ColorValue(hex: "#A3CBEF")!),
            "glow": .number(0.6), "sun": .point(Point2(x: 261, y: 360)), "rays": .number(0.3), "haze": .number(0.35),
        ])
        sky.properties[.size] = .size(S.device)

        func lift(_ layer: Layer) -> Layer {
            var layer = layer
            layer.properties[.shadowColor] = .color(ColorValue(white: 0, alpha: 0.18))
            layer.properties[.shadowRadius] = .number(10)
            layer.properties[.shadowOffset] = .point(Point2(x: 0, y: 2))
            return layer
        }
        let today = W.forecast[0]
        let place = lift(S.text("Place", "MY LOCATION", at: Point2(x: 0, y: 78), size: 13, weight: 700, color: faint(0.8), width: width, align: "Center"))
        let city = lift(S.text("City", "Denver", at: Point2(x: 0, y: 98), size: 34, weight: 600, color: white, width: width, align: "Center"))
        let temperature = lift(S.text("Temperature", "\(today.temperature)°", at: Point2(x: 0, y: 134), size: 96, weight: 200,
                                      color: white, width: width, height: 112, align: "Center"))
        let condition = lift(S.text("Condition", today.condition, at: Point2(x: 0, y: 248), size: 20, weight: 500,
                                    color: white, width: width, align: "Center"))
        let range = lift(S.text("Range", "H:\(today.high)°  L:\(today.low)°", at: Point2(x: 0, y: 276), size: 17, weight: 500,
                                color: faint(0.85), width: width, align: "Center"))

        // The forecast: a pane of glass with a column for each day and a pill behind the chosen one.
        let cardX = 16.0, cardTop = 620.0, cardWidth = width - 32, tileWidth = (cardWidth - 16) / 5
        let card = Library.glass("Forecast", [
            .position: .point(Point2(x: cardX, y: cardTop)), .size: .size(Size2(width: cardWidth, height: 160)),
            .shadowColor: .color(ColorValue(white: 0, alpha: 0.12)), .shadowRadius: .number(20), .shadowOffset: .point(Point2(x: 0, y: 8)),
        ], radius: 30, inputs: ["tint": .color(ColorValue(red: 0.06, green: 0.12, blue: 0.24, alpha: 0.2))])
        let heading = S.text("Heading", "5-DAY FORECAST", at: Point2(x: cardX + 20, y: cardTop + 16), size: 12, weight: 700, color: faint(0.7))
        let rule = Layer(name: "Rule", kind: .view, properties: [
            .position: .point(Point2(x: cardX + 20, y: cardTop + 40)), .size: .size(Size2(width: cardWidth - 40, height: 1)),
            .fill: .color(faint(0.22)),
        ])
        let tilesTop = cardTop + 50
        let pill = Layer(name: "Chosen", kind: .view, properties: [
            .position: .point(Point2(x: cardX + 8, y: tilesTop)), .size: .size(Size2(width: tileWidth, height: 100)),
            .fill: .color(faint(0.24)), .cornerRadius: .number(20),
        ])
        let days = W.forecast.enumerated().map { index, day in
            Layer(name: day.name, kind: .view, properties: [
                .position: .point(Point2(x: cardX + 8 + Double(index) * tileWidth, y: tilesTop)),
                .size: .size(Size2(width: tileWidth, height: 100)),
                .layout: .text("Stack"), .axis: .text("Vertical"), .alignment: .text("Center"), .distribution: .text("Center"),
                .spacing: .number(8),
            ], children: [
                S.text("\(day.name) Name", day.name, size: 15, weight: 600, color: white),
                S.symbol("\(day.name) Symbol", day.symbol, side: 26, color: white),
                S.text("\(day.name) High", "\(day.high)°", size: 17, weight: 600, color: white),
            ])
        }

        let screen = Layer(name: "Screen", kind: .screen, properties: [.fill: .color(ColorValue(hex: "#3A86D6")!)],
                           children: [sky, place, city, temperature, condition, range, stage, card, heading, rule, pill] + days
                               + [S.hint("Tap a day · Drag the sky", symbol: "hand.tap.fill", y: 792, dark: true)])

        var b = Builder(screen: screen)
        let view = b.view(stage.id, at: Point2(x: 1488, y: 96))
        let skyView = b.view(sky.id, at: Point2(x: 1488, y: 1272))
        func scenePort(_ input: String) -> String { SceneUse.portID(input) }
        func objectPort(_ object: String, _ input: String) -> String { SceneUse.portID(object: object, input) }

        // MARK: Orbit: a drag turns the weather round, and springs carry it back with a little sway.

        let pan = b.attach(PatchKind.pan, to: stage.id, at: Point2(x: 48, y: 96))
        let split = b.add("splitPoint", at: Point2(x: 336, y: 96))
        let turnAngle = b.add("transition", at: Point2(x: 624, y: 96), name: "Turn Angle", type: .number,
                              inputs: ["start": .number(0), "end": .number(-0.4)])
        let turnLimit = b.add("clamp", at: Point2(x: 912, y: 96), name: "Turn Limit",
                              inputs: ["min": .number(-60), "max": .number(60)])
        let turn = b.add("spring", at: Point2(x: 1200, y: 96), name: "Turn",
                         inputs: ["response": .number(0.7), "damping": .number(0.55)])
        let tiltAngle = b.add("transition", at: Point2(x: 624, y: 456), name: "Tilt Angle", type: .number,
                              inputs: ["start": .number(6), "end": .number(6.25)])
        let tiltLimit = b.add("clamp", at: Point2(x: 912, y: 456), name: "Tilt Limit",
                              inputs: ["min": .number(-12), "max": .number(40)])
        let tilt = b.add("spring", at: Point2(x: 1200, y: 456), name: "Tilt",
                         inputs: ["target": .number(6), "response": .number(0.7), "damping": .number(0.6)])
        b.connect(pan, "translation", to: split, "point")
        b.connect(split, "x", to: turnAngle, "progress")
        b.connect(turnAngle, "value", to: turnLimit, "value")
        b.connect(turnLimit, "result", to: turn, "held")
        b.connect(pan, "panning", to: turn, "hold")
        b.connect(split, "y", to: tiltAngle, "progress")
        b.connect(tiltAngle, "value", to: tiltLimit, "value")
        b.connect(tiltLimit, "result", to: tilt, "held")
        b.connect(pan, "panning", to: tilt, "hold")
        b.connect(turn, "value", to: view, scenePort("cameraYaw"))
        b.connect(tilt, "value", to: view, scenePort("cameraPitch"))

        // MARK: Weather: a tap on a day hands it to the script, which runs the sky.

        let taps = days.enumerated().map { index, day in
            b.attach(PatchKind.tap, to: day.id, at: Point2(x: 48, y: 1032 + Double(index) * 192))
        }
        let clock = b.add("time", at: Point2(x: 336, y: 840), name: "Clock")
        let forecastJSON = W.forecast.map {
            "{\"condition\": \"\($0.condition)\", \"temperature\": \($0.temperature), \"high\": \($0.high), \"low\": \($0.low)}"
        }.joined(separator: ",\n              ")
        let weather = b.document.graph.add(PatchNode(
            kind: PatchKind.javascript, position: PatchGrid.snap(Point2(x: 624, y: 840)), name: "Weather",
            script: """
            // The weather of the chosen day. Each sky is a set of numbers and colors; every
            // frame they ease toward the chosen sky's, so one sky turns into the next and the
            // light swings round as it does. Rain and snow are emitters whose time is the
            // clock; how much falls eases in and out with the weather. In a storm, lightning
            // flashes: the bolt and the cloud's heart glow, the light jumps, the sky lights.
            // Moving runs the clock, and is off once all is still.
            inputs = { clock: 0, day0: pulse(), day1: pulse(), day2: pulse(), day3: pulse(), day4: pulse() };
            outputs = { moving: false, temperature: "", condition: "", range: "", pillX: \(cardX + 8),
                        skyTop: color("#3A86D6"), skyBottom: color("#A3CBEF"), glow: 0, sunPoint: point(261, 360),
                        rays: 0, haze: 0, skyRain: 0, skySnow: 0, flash: 0, skyClock: 0, cardTint: color("#10203D33"),
                        surroundings: "Daylight", lightYaw: 38, lightPitch: 34, intensity: 3.5, exposure: 1, bloom: 0.9,
                        lightColor: color("#FFFFFF"), sunX: 0, sunY: 0, sunScale: 0, sunGlow: 0, coronaScale: 0,
                        cloudX: 0, cloudY: 0, cloudScale: 0, cloudColor: color("#FFFFFF"), cloudGlow: 0,
                        backX: 0, backY: 0, backScale: 0, backColor: color("#FFFFFF"),
                        frontX: 0, frontY: 0, frontScale: 0, frontColor: color("#FFFFFF"),
                        cloudSX: 0, cloudSY: 0, cloudSZ: 0, backSX: 0, backSY: 0, backSZ: 0, frontSX: 0, frontSY: 0, frontSZ: 0,
                        coverage: 0.5, density: 1, fluffiness: 0.6, drift: 0,
                        boltScale: 0, rainCount: 0, rainSize: 0, snowCount: 0, snowSize: 0, fallTime: 0 };

            const days = [
              \(forecastJSON)
            ];
            // Each sky: where the sun and the three clouds are and how large, their colors,
            // how hard it rains or snows, the sky shader's colors, glow, rays and haze, the
            // card's tint, the bloom, and the light: its direction, strength, color, the
            // surroundings and the exposure.
            const skies = {
              Sunny:           { sunX: 0, sunY: 0.04, sunScale: 1.05, sunGlow: 2.4, cloudX: -1.5, cloudY: -0.2, cloudScale: 0, cloud: "#FFFFFF",
                                 backX: 1.4, backY: -0.6, backScale: 0, back: "#FFFFFF", frontX: -1.4, frontY: -0.6, frontScale: 0, front: "#FFFFFF",
                                 cover: 0.62, dens: 1.2, fluff: 0.65, tall: 0.7, rain: 0, snow: 0, storm: 0, top: "#0D5BD3", bottom: "#76BBFF", glow: 0.9, rays: 0.9, haze: 0.1,
                                 card: "#0B2A5A40", bloom: 0.8, yaw: -40, pitch: 30, intensity: 3.6, exposure: 1.08, lamp: "#FFE9C4", surroundings: "Daylight" },
              "Partly Cloudy": { sunX: 0.46, sunY: 0.26, sunScale: 0.82, sunGlow: 2.2, cloudX: -0.12, cloudY: -0.02, cloudScale: 1.75, cloud: "#FFFFFF",
                                 backX: 0.95, backY: -0.32, backScale: 0.8, back: "#EEF5FF", frontX: -0.82, frontY: -0.5, frontScale: 0.6, front: "#FFFFFF",
                                 cover: 0.62, dens: 1.2, fluff: 0.65, tall: 0.7, rain: 0, snow: 0, storm: 0, top: "#2A76CF", bottom: "#9CC8F2", glow: 0.55, rays: 0.35, haze: 0.35,
                                 card: "#0E2B5238", bloom: 0.6, yaw: 38, pitch: 34, intensity: 3.5, exposure: 1.02, lamp: "#FFF0D2", surroundings: "Daylight" },
              Rain:            { sunX: 0.5, sunY: 0.7, sunScale: 0, sunGlow: 0, cloudX: 0.02, cloudY: 0.1, cloudScale: 1.9, cloud: "#DCE3EC",
                                 backX: 0.78, backY: 0.44, backScale: 1.15, back: "#A9B5C5", frontX: -0.72, frontY: -0.14, frontScale: 0.8, front: "#C9D2DE",
                                 cover: 0.78, dens: 1.5, fluff: 0.5, tall: 0.78, rain: 0.75, snow: 0, storm: 0, top: "#3B485D", bottom: "#7C8BA0", glow: 0, rays: 0, haze: 0.8,
                                 card: "#1A253866", bloom: 0.5, yaw: -10, pitch: 66, intensity: 2.8, exposure: 1.1, lamp: "#DCE6F5", surroundings: "Studio" },
              Thunderstorms:   { sunX: 0.5, sunY: 0.7, sunScale: 0, sunGlow: 0, cloudX: 0.02, cloudY: 0.02, cloudScale: 1.95, cloud: "#83807F",
                                 backX: 0.8, backY: 0.48, backScale: 1.25, back: "#55545A", frontX: -0.72, frontY: -0.12, frontScale: 0.82, front: "#66646A",
                                 cover: 0.86, dens: 2.4, fluff: 0.45, tall: 0.8, rain: 1, snow: 0, storm: 1, top: "#10131D", bottom: "#2B3142", glow: 0, rays: 0, haze: 0.9,
                                 card: "#0A0E1A80", bloom: 0.7, yaw: 18, pitch: 70, intensity: 2.2, exposure: 1.3, lamp: "#A8B8E8", surroundings: "Night" },
              Snow:            { sunX: 0.5, sunY: 0.7, sunScale: 0, sunGlow: 0, cloudX: 0, cloudY: 0.1, cloudScale: 1.9, cloud: "#FAFCFF",
                                 backX: -0.8, backY: 0.46, backScale: 1.05, back: "#D4DEEA", frontX: 0.74, frontY: -0.14, frontScale: 0.76, front: "#F2F6FB",
                                 cover: 0.72, dens: 1.1, fluff: 0.75, tall: 0.75, rain: 0, snow: 1, storm: 0, top: "#5D7696", bottom: "#B2C2D6", glow: 0.1, rays: 0, haze: 0.6,
                                 card: "#21354F55", bloom: 0.6, yaw: -24, pitch: 46, intensity: 3.1, exposure: 1.18, lamp: "#F3F7FF", surroundings: "Studio" },
            };
            const numbers = ["sunX", "sunY", "sunScale", "sunGlow", "cloudX", "cloudY", "cloudScale", "backX", "backY", "backScale",
                             "frontX", "frontY", "frontScale", "cover", "dens", "fluff", "tall", "rain", "snow", "storm", "glow", "rays", "haze", "bloom",
                             "yaw", "pitch", "intensity", "exposure"];
            const colors = ["cloud", "back", "front", "top", "bottom", "lamp", "card"];
            const lift = \(W.lift);
            const raindrops = \(W.raindrops), snowflakes = \(W.snowflakes);

            function rgb(hex) {
              const c = [1, 3, 5].map(i => parseInt(hex.substr(i, 2), 16));
              return c.concat(hex.length > 7 ? [parseInt(hex.substr(7, 2), 16)] : []);
            }
            function hex(c) { return "#" + c.map(v => Math.round(Math.max(0, Math.min(255, v))).toString(16).padStart(2, "0")).join(""); }

            let chosen = 0, now = null, last = null;

            function evaluate(inputs, outputs) {
              [inputs.day0, inputs.day1, inputs.day2, inputs.day3, inputs.day4].forEach((tapped, i) => { if (tapped) chosen = i; });
              const day = days[chosen], sky = skies[day.condition];
              const target = {};
              numbers.forEach(k => target[k] = sky[k]);
              colors.forEach(k => target[k] = rgb(sky[k]));
              if (now === null) { now = JSON.parse(JSON.stringify(target)); now.pill = chosen; }
              const dt = last === null ? 0 : Math.max(0, Math.min(0.1, inputs.clock - last));
              last = inputs.clock;
              // Ease every number and color a share of the way, so they arrive together.
              const share = 1 - Math.exp(-3.4 * dt);
              let still = true;
              numbers.forEach(k => {
                now[k] += (target[k] - now[k]) * share;
                if (Math.abs(target[k] - now[k]) > 0.001) still = false; else now[k] = target[k];
              });
              colors.forEach(k => {
                now[k] = now[k].map((v, c) => v + (target[k][c] - v) * share);
                if (now[k].some((v, c) => Math.abs(target[k][c] - v) > 0.5)) still = false; else now[k] = target[k].slice();
              });
              now.pill += (chosen - now.pill) * (1 - Math.exp(-14 * dt));
              if (Math.abs(chosen - now.pill) > 0.001) still = false; else now.pill = chosen;
              // While anything falls, the clock must run.
              if (now.rain > 0.001 || now.snow > 0.001 || now.storm > 0.001) still = false;

              // Lightning: a double flash every few seconds once the storm has set in, fading
              // out fast. The first comes a little after the storm is chosen, not at once.
              const beat = (inputs.clock + 1.3) % 2.8;
              const pulse = (at, length) => beat > at && beat < at + length ? 1 - (beat - at) / length : 0;
              const flash = now.storm > 0.85 ? Math.max(pulse(0, 0.16), pulse(0.24, 0.22)) : 0;

              outputs.moving = !still;
              outputs.temperature = day.temperature + "°";
              outputs.condition = day.condition;
              outputs.range = "H:" + day.high + "°  L:" + day.low + "°";
              outputs.pillX = \(cardX + 8) + now.pill * \(tileWidth);
              const lit = (c, by) => color(hex(c.map(v => v + (205 - v) * by)));
              outputs.skyTop = lit(now.top, flash * 0.3);
              outputs.skyBottom = lit(now.bottom, flash * 0.2);
              outputs.glow = now.glow;
              outputs.rays = now.rays;
              outputs.haze = now.haze;
              // The sky's own distant rain and snow, behind the emitters, a little.
              outputs.skyRain = now.rain * 0.6;
              outputs.skySnow = now.snow * 0.6;
              outputs.flash = flash;
              outputs.skyClock = inputs.clock;
              outputs.cardTint = color(hex(now.card));
              // Where the sun is on the screen, so the sky glows and shines round it.
              outputs.sunPoint = point(201 + now.sunX * 142, 451 - (lift + now.sunY) * 142);
              outputs.surroundings = sky.surroundings;
              // A flash lights the clouds from low in front, bright and cold.
              outputs.lightYaw = now.yaw;
              outputs.lightPitch = now.pitch + (-30 - now.pitch) * flash;
              outputs.intensity = now.intensity + 3.5 * flash;
              outputs.exposure = now.exposure + 0.15 * flash;
              outputs.bloom = now.bloom;
              outputs.lightColor = color(hex(now.lamp.map(v => v + (235 - v) * flash)));
              outputs.sunX = now.sunX; outputs.sunY = lift + now.sunY; outputs.sunScale = now.sunScale;
              outputs.sunGlow = now.sunGlow;
              outputs.coronaScale = now.sunScale * 1.3;
              outputs.cloudX = now.cloudX; outputs.cloudY = lift + now.cloudY; outputs.cloudScale = now.cloudScale;
              outputs.cloudColor = color(hex(now.cloud));
              // The cloud's heart glows with the flash.
              outputs.cloudGlow = 0.3 * flash;
              outputs.backX = now.backX; outputs.backY = lift + now.backY; outputs.backScale = now.backScale;
              outputs.backColor = color(hex(now.back));
              outputs.frontX = now.frontX; outputs.frontY = lift + now.frontY; outputs.frontScale = now.frontScale;
              outputs.frontColor = color(hex(now.front));
              // Each cloud's box: as wide as the cloud, its height by how tall the weather piles it.
              const box = (scale) => [scale * 1.1, scale * now.tall, scale * 0.75];
              [outputs.cloudSX, outputs.cloudSY, outputs.cloudSZ] = box(now.cloudScale);
              [outputs.backSX, outputs.backSY, outputs.backSZ] = box(now.backScale);
              [outputs.frontSX, outputs.frontSY, outputs.frontSZ] = box(now.frontScale);
              outputs.coverage = now.cover;
              outputs.density = now.dens;
              outputs.fluffiness = now.fluff;
              // The vapor drifts while the clock runs, so a cloud billows as the weather changes.
              outputs.drift = inputs.clock * 0.035;
              outputs.boltScale = flash > 0.3 ? 0.95 : 0;
              // How much falls: more drops, and each fuller, as the rain sets in.
              outputs.rainCount = now.rain > 0.005 ? Math.round(raindrops * Math.min(1, now.rain)) : 0;
              outputs.rainSize = 0.016 * Math.min(1, now.rain * 1.6);
              outputs.snowCount = now.snow > 0.005 ? Math.round(snowflakes * Math.min(1, now.snow)) : 0;
              outputs.snowSize = 0.034 * Math.min(1, now.snow * 1.6);
              outputs.fallTime = inputs.clock;
            }
            """
        ))
        for (index, tap) in taps.enumerated() { b.connect(tap, "tapped", to: weather, "day\(index)") }
        b.connect(clock, "time", to: weather, "clock")
        // A back edge: the script says whether anything still moves, and the clock runs only then.
        b.connect(weather, "moving", to: clock, "running")

        // The scene's own inputs, and each object's.
        let sceneInputs: [(String, String)] = [
            ("surroundings", "environment"), ("lightYaw", "lightYaw"), ("lightPitch", "lightPitch"),
            ("intensity", "lightIntensity"), ("lightColor", "lightColor"), ("exposure", "exposure"), ("bloom", "bloom"),
        ]
        for (output, input) in sceneInputs { b.connect(weather, output, to: view, scenePort(input)) }
        let objectInputs: [(String, String, String)] = [
            ("sunX", W.sun, "x"), ("sunY", W.sun, "y"), ("sunScale", W.sun, "scale"), ("sunGlow", W.sun, "emission"),
            ("sunX", W.corona, "x"), ("sunY", W.corona, "y"), ("coronaScale", W.corona, "scale"),
            ("cloudGlow", W.cloud, "emission"),
            ("cloudX", W.cloud, "x"), ("cloudY", W.cloud, "y"), ("cloudColor", W.cloud, "color"),
            ("backX", W.backCloud, "x"), ("backY", W.backCloud, "y"), ("backColor", W.backCloud, "color"),
            ("frontX", W.frontCloud, "x"), ("frontY", W.frontCloud, "y"), ("frontColor", W.frontCloud, "color"),
        ] + [(W.cloud, "cloud"), (W.backCloud, "back"), (W.frontCloud, "front")].flatMap { id, name in
            [("\(name)SX", id, "scaleX"), ("\(name)SY", id, "scaleY"), ("\(name)SZ", id, "scaleZ"),
             ("coverage", id, "coverage"), ("density", id, "density"), ("fluffiness", id, "fluffiness"), ("drift", id, "drift")]
        } + [
            ("boltScale", W.bolt, "scale"), ("boltScale", W.bolt, "scaleX"),
            ("rainCount", W.rain, "count"), ("rainSize", W.rain, "size"), ("fallTime", W.rain, "time"),
            ("snowCount", W.snow, "count"), ("snowSize", W.snow, "size"), ("fallTime", W.snow, "time"),
        ]
        for (output, object, input) in objectInputs { b.connect(weather, output, to: view, objectPort(object, input)) }
        // The sky, the words and the pill.
        b.connect(weather, "skyTop", to: skyView, ShaderUse.portID("top"))
        b.connect(weather, "skyBottom", to: skyView, ShaderUse.portID("bottom"))
        b.connect(weather, "glow", to: skyView, ShaderUse.portID("glow"))
        b.connect(weather, "sunPoint", to: skyView, ShaderUse.portID("sun"))
        let skyInputs = [("rays", "rays"), ("haze", "haze"), ("skyRain", "rain"), ("skySnow", "snow"), ("flash", "flash"), ("skyClock", "clock")]
        for (output, input) in skyInputs { b.connect(weather, output, to: skyView, ShaderUse.portID(input)) }
        b.connect(weather, "cardTint", to: b.view(card.id, at: Point2(x: 1200, y: 1512)), ShaderUse.portID("tint"))
        b.connect(weather, "skyTop", to: b.property(.fill, of: screen.id, at: Point2(x: 1488, y: 1488)), "value")
        b.connect(weather, "temperature", to: b.property(.text, of: temperature.id, at: Point2(x: 1200, y: 840)), "value")
        b.connect(weather, "condition", to: b.property(.text, of: condition.id, at: Point2(x: 1200, y: 1008)), "value")
        b.connect(weather, "range", to: b.property(.text, of: range.id, at: Point2(x: 1200, y: 1176)), "value")
        b.connect(weather, "pillX", to: b.view(pill.id, at: Point2(x: 1200, y: 1344)), "x")

        b.note("Orbit · A drag turns the weather", around: [pan, split, turnAngle, turnLimit, turn, tiltAngle, tiltLimit, tilt])
        b.note("Weather · A day sets the sky", around: taps + [clock, weather])

        return WeatherScene(
            document: b.document, stage: stage.id, sky: sky.id, days: days.map(\.id), pill: pill.id,
            temperature: temperature.id, condition: condition.id, range: range.id, weather: weather
        )
    }

    /// The sky: a gradient from top to bottom; a warm glow and slow rays round the sun;
    /// soft cloud layers that drift; distant rain streaks and snow, which make the weather
    /// in front of it look heavier; the flash of lightning, brightest in the clouds; and a
    /// vignette. Its time is the script's clock, so it is still whenever the weather is.
    static let skyShader = """
    struct Inputs {
        float4 top = float4(0.17, 0.47, 0.82, 1);
        float4 bottom = float4(0.62, 0.79, 0.95, 1);
        float glow = 0.6;
        float2 sun = float2(261, 360);
        float rays = 0.3;
        float haze = 0.35;
        float rain = 0;
        float snow = 0;
        float flash = 0;
        float clock = 0;
    };

    float hash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }

    float noise(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        return mix(mix(hash(i), hash(i + float2(1, 0)), u.x), mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), u.x), u.y);
    }

    float fbm(float2 p) {
        float v = 0.0, a = 0.5;
        for (int i = 0; i < 5; i++) { v += a * noise(p); p *= 2.03; a *= 0.5; }
        return v;
    }

    float4 shader(Frame frame, Inputs in) {
        float2 p = frame.position;
        float t = clamp(p.y / max(frame.size.y, 1.0), 0.0, 1.0);
        float3 color = mix(in.top.rgb, in.bottom.rgb, smoothstep(0.0, 1.0, t));

        // The sun's glow, and rays turning slowly round it.
        float2 toSun = p - in.sun;
        float d = length(toSun) / 240.0;
        float halo = exp(-d * d * 2.0) * in.glow;
        float angle = atan2(toSun.y, toSun.x);
        float beams = pow(0.5 + 0.5 * sin(angle * 9.0 + in.clock * 0.12), 8.0) * 0.6
                    + pow(0.5 + 0.5 * sin(angle * 5.0 - 1.3 - in.clock * 0.07), 10.0) * 0.5;
        float rays = beams * exp(-d * 1.1) * in.rays;
        color = mix(color, float3(1.0, 0.9, 0.66), clamp(halo * 0.6 + rays * 0.32, 0.0, 1.0));

        // Soft cloud layers, thicker toward the top, drifting.
        float2 q = p / float2(240.0, 120.0) + float2(in.clock * 0.025, 0.0);
        float clouds = smoothstep(0.42, 0.85, fbm(q + fbm(q * 1.7 + 3.1) * 0.7));
        float upper = smoothstep(1.0, 0.1, t);
        color = mix(color, mix(in.bottom.rgb, float3(1.0), 0.3), clouds * in.haze * upper * 0.5);
        color = mix(color, in.top.rgb * 0.7, (1.0 - clouds) * in.haze * upper * 0.12);

        // Lightning lights the sky, brightest in the clouds.
        color += float3(0.72, 0.78, 1.0) * in.flash * (0.18 + 0.65 * clouds * upper);

        // Distant rain: thin streaks falling at a slant, in some columns.
        if (in.rain > 0.001) {
            float2 r = float2(p.x + p.y * 0.1, p.y);
            float column = floor(r.x / 6.0);
            float pick = hash(float2(column, 7.0));
            float speed = 700.0 + 500.0 * hash(float2(column, 3.0));
            float y = fract((r.y - in.clock * speed) / 210.0 + hash(float2(column, 1.0)));
            float across = abs(fract(r.x / 6.0) - 0.5) * 6.0;
            float streak = step(y, 0.12) * (y / 0.12) * smoothstep(0.9, 0.2, across) * step(pick, in.rain * 0.55);
            color = mix(color, float3(0.85, 0.9, 1.0), streak * 0.28);
        }

        // Distant snow: small flakes drifting down and sideways.
        if (in.snow > 0.001) {
            for (int layer = 0; layer < 2; layer++) {
                float size = layer == 0 ? 30.0 : 46.0;
                float2 s = p + float2(sin(in.clock * 0.6 + p.y * 0.01 + float(layer)) * 10.0, -in.clock * (24.0 + 14.0 * float(layer)));
                float2 cell = floor(s / size);
                float2 spot = float2(hash(cell), hash(cell + 5.3)) * 0.7 + 0.15;
                float flake = smoothstep(1.0 + float(layer), 0.2, length((fract(s / size) - spot) * size));
                color = mix(color, float3(1.0), flake * step(hash(cell + 9.1), in.snow * 0.5) * (0.55 + 0.25 * float(layer)));
            }
        }

        // A gentle vignette.
        float2 v = (p / max(frame.size, float2(1.0)) - 0.5) * float2(0.9, 1.1);
        color *= 1.0 - 0.22 * dot(v, v);
        return float4(color, 1);
    }
    """
}
