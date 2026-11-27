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
        public static let sun = "sun", cloud = "cloud", backCloud = "back", frontCloud = "front", bolt = "bolt"
        public static let drops = (0..<18).map { "drop\($0)" }
        public static let flakes = (0..<12).map { "flake\($0)" }

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
        /// Where a falling drop or flake is gone: it shrinks to nothing on its way here, just
        /// above the forecast card, so nothing reaches the glass.
        public static let fallsTo = -1.12
        /// How far above `fallsTo` a drop or flake starts to shrink.
        public static let fades = 0.42
        /// Where one waits while it is not falling: above the picture.
        public static let parked = 6.0
        /// How far up the middle of the scene view the weather stands.
        public static let lift = 0.3
    }

    /// A weather app with the weather itself in three dimensions, drawn by a scene view
    /// with real light: a sun, puffy clouds, glossy raindrops, snowflakes and a lightning
    /// bolt (`WeatherModels` makes the cloud, the drop and the bolt in code). A tap on a
    /// day of the forecast changes the weather: one script eases everything from one sky
    /// to the next (the sun sinking away, clouds gathering and darkening, the light, the
    /// sky's colors) and runs the rain and snow, asking for frames only while something
    /// moves. The sky behind is a shader that the same script drives: drifting cloud
    /// layers, sun rays, distant rain and snow, and the flash of lightning. A drag turns the
    /// scene round and it springs back.
    public static func weatherScene() -> WeatherScene {
        typealias S = ExampleStyle
        typealias W = WeatherScene
        typealias Library = ComponentLibrary
        let white = ColorValue.white
        func faint(_ alpha: Double) -> ColorValue { ColorValue(white: 1, alpha: alpha) }
        let width = S.device.width

        // MARK: The scene

        let cloudScale = 1.75
        let drops = W.drops.enumerated().map { index, id in
            SceneObject(id: id, name: "Drop \(index + 1)", shape: .model, model: WeatherModels.dropName, values: [
                "x": .number(dropX[index]), "y": .number(W.parked), "z": .number(dropZ[index]), "scale": .number(0),
                "color": .color(ColorValue(hex: "#62B6FF")!), "roughness": .number(0.05),
            ])
        }
        let flakes = W.flakes.enumerated().map { index, id in
            SceneObject(id: id, name: "Flake \(index + 1)", shape: .sphere, values: [
                "x": .number(dropX[index] * 0.9), "y": .number(W.parked), "z": .number(dropZ[index]), "scale": .number(0),
                "color": .color(white), "roughness": .number(0.65),
            ])
        }
        let scene = SceneUse(objects: [
            SceneObject(id: W.sun, name: "Sun", shape: .sphere, values: [
                "x": .number(0.42), "y": .number(W.lift + 0.32), "z": .number(-0.5), "scale": .number(0.9),
                "color": .color(ColorValue(hex: "#FFB21C")!), "roughness": .number(0.22),
            ]),
            SceneObject(id: W.backCloud, name: "Far Cloud", shape: .model, model: WeatherModels.cloudName, values: [
                "x": .number(0.8), "y": .number(W.lift - 0.34), "z": .number(-0.7), "scale": .number(0.85),
                "color": .color(white), "roughness": .number(0.9),
            ]),
            SceneObject(id: W.cloud, name: "Cloud", shape: .model, model: WeatherModels.cloudName, values: [
                "x": .number(-0.2), "y": .number(W.lift), "scale": .number(cloudScale),
                "color": .color(white), "roughness": .number(0.95),
            ]),
            SceneObject(id: W.frontCloud, name: "Near Cloud", shape: .model, model: WeatherModels.cloudName, values: [
                "x": .number(-0.78), "y": .number(W.lift - 0.5), "z": .number(0.55), "scale": .number(0.62),
                "color": .color(white), "roughness": .number(0.95),
            ]),
            SceneObject(id: W.bolt, name: "Bolt", shape: .model, model: WeatherModels.boltName, values: [
                "x": .number(0.08), "y": .number(W.lift - 0.5), "z": .number(0.35), "scale": .number(0),
                "color": .color(ColorValue(hex: "#FFE25A")!), "roughness": .number(0.15),
            ]),
        ] + drops + flakes, values: [
            "cameraPitch": .number(6), "cameraDistance": .number(4.2), "environment": .text("Daylight"),
            "lightYaw": .number(-35), "lightPitch": .number(40), "lightIntensity": .number(3.2),
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
        let fit = WeatherModels.fit(WeatherModels.cloud, scale: 1)
        let forecastJSON = W.forecast.map {
            "{\"condition\": \"\($0.condition)\", \"temperature\": \($0.temperature), \"high\": \($0.high), \"low\": \($0.low)}"
        }.joined(separator: ",\n              ")
        let objectOutputs = W.drops.flatMap { ["\($0): \(W.parked)", "\($0)Size: 0"] }
            + W.flakes.flatMap { ["\($0): \(W.parked)", "\($0)X: 0", "\($0)Size: 0"] }
        let weather = b.document.graph.add(PatchNode(
            kind: PatchKind.javascript, position: PatchGrid.snap(Point2(x: 624, y: 840)), name: "Weather",
            script: """
            // The weather of the chosen day. Each sky is a set of numbers and colors; every
            // frame they ease toward the chosen sky's, so one sky turns into the next and the
            // light swings round as it does. Rain and snow start inside the cloud, fall, and
            // shrink away above the card; a drop starts again only while it rains hard
            // enough for it. In a storm, lightning flashes: the bolt shows, the light jumps
            // up under the clouds and the sky lights. Moving runs the clock, and is off
            // once all is still.
            inputs = { clock: 0, day0: pulse(), day1: pulse(), day2: pulse(), day3: pulse(), day4: pulse() };
            outputs = { moving: false, temperature: "", condition: "", range: "", pillX: \(cardX + 8),
                        skyTop: color("#3A86D6"), skyBottom: color("#A3CBEF"), glow: 0, sunPoint: point(261, 360),
                        rays: 0, haze: 0, skyRain: 0, skySnow: 0, flash: 0, skyClock: 0, cardTint: color("#10203D33"),
                        surroundings: "Daylight", lightYaw: -35, lightPitch: 40, intensity: 3.2, exposure: 1,
                        lightColor: color("#FFFFFF"), sunX: 0, sunY: 0, sunScale: 0, cloudX: 0, cloudY: 0,
                        cloudScale: 0, cloudColor: color("#FFFFFF"), backX: 0, backY: 0, backScale: 0,
                        backColor: color("#FFFFFF"), frontX: 0, frontY: 0, frontScale: 0, frontColor: color("#FFFFFF"),
                        boltScale: 0, boltY: 0,
                        \(objectOutputs.joined(separator: ", ")) };

            const days = [
              \(forecastJSON)
            ];
            // Each sky: where the sun and the three clouds are and how large, their colors,
            // how hard it rains or snows, the sky shader's colors, glow, rays and haze, the
            // card's tint, and the light: its direction, strength, color, the surroundings
            // and the exposure.
            const skies = {
              Sunny:           { sunX: 0, sunY: 0.06, sunScale: 1.2, cloudX: -1.4, cloudY: -0.2, cloudScale: 0, cloud: "#FFFFFF",
                                 backX: 1.3, backY: -0.6, backScale: 0, back: "#FFFFFF", frontX: -1.3, frontY: -0.6, frontScale: 0, front: "#FFFFFF",
                                 rain: 0, snow: 0, storm: 0, top: "#0F5FD6", bottom: "#78BDFF", glow: 1.15, rays: 1, haze: 0.12,
                                 card: "#0B2A5A40", yaw: -42, pitch: 28, intensity: 3.8, exposure: 1.12, lamp: "#FFE7BE", surroundings: "Daylight" },
              "Partly Cloudy": { sunX: 0.44, sunY: 0.34, sunScale: 0.9, cloudX: -0.12, cloudY: -0.02, cloudScale: 1.75, cloud: "#FFFFFF",
                                 backX: 0.95, backY: -0.32, backScale: 0.8, back: "#EAF3FF", frontX: -0.82, frontY: -0.5, frontScale: 0.6, front: "#FFFFFF",
                                 rain: 0, snow: 0, storm: 0, top: "#2C78D0", bottom: "#9DC9F2", glow: 0.75, rays: 0.45, haze: 0.4,
                                 card: "#0E2B5238", yaw: 38, pitch: 34, intensity: 3.5, exposure: 1.05, lamp: "#FFF0D2", surroundings: "Daylight" },
              Rain:            { sunX: 0.5, sunY: 0.7, sunScale: 0, cloudX: 0.02, cloudY: 0.1, cloudScale: 1.9, cloud: "#E3E9F0",
                                 backX: 0.78, backY: 0.44, backScale: 1.15, back: "#AEB9C8", frontX: -0.72, frontY: -0.14, frontScale: 0.8, front: "#D3DBE5",
                                 rain: 0.85, snow: 0, storm: 0, top: "#3E4B60", bottom: "#7F8EA3", glow: 0, rays: 0, haze: 0.9,
                                 card: "#1A253866", yaw: -8, pitch: 68, intensity: 2.7, exposure: 1.08, lamp: "#DCE6F5", surroundings: "Studio" },
              Thunderstorms:   { sunX: 0.5, sunY: 0.7, sunScale: 0, cloudX: 0.02, cloudY: 0.12, cloudScale: 2.02, cloud: "#757A88",
                                 backX: 0.8, backY: 0.48, backScale: 1.25, back: "#4A4E5C", frontX: -0.72, frontY: -0.12, frontScale: 0.82, front: "#5A5F6E",
                                 rain: 1, snow: 0, storm: 1, top: "#11141F", bottom: "#2E3446", glow: 0, rays: 0, haze: 1,
                                 card: "#0A0E1A80", yaw: 18, pitch: 72, intensity: 2.2, exposure: 1.3, lamp: "#A8B8E8", surroundings: "Night" },
              Snow:            { sunX: 0.5, sunY: 0.7, sunScale: 0, cloudX: 0, cloudY: 0.1, cloudScale: 1.9, cloud: "#FAFCFF",
                                 backX: -0.8, backY: 0.46, backScale: 1.05, back: "#D6E0EC", frontX: 0.74, frontY: -0.14, frontScale: 0.76, front: "#F2F6FB",
                                 rain: 0, snow: 1, storm: 0, top: "#5F7898", bottom: "#B4C4D8", glow: 0.15, rays: 0, haze: 0.7,
                                 card: "#21354F55", yaw: -24, pitch: 46, intensity: 3.1, exposure: 1.2, lamp: "#F3F7FF", surroundings: "Studio" },
            };
            const numbers = ["sunX", "sunY", "sunScale", "cloudX", "cloudY", "cloudScale", "backX", "backY", "backScale",
                             "frontX", "frontY", "frontScale", "rain", "snow", "storm", "glow", "rays", "haze",
                             "yaw", "pitch", "intensity", "exposure"];
            const colors = ["cloud", "back", "front", "top", "bottom", "lamp", "card"];

            // Where each drop falls, and how near.
            const dropX = [\(dropX.map { "\($0)" }.joined(separator: ", "))];
            const dropZ = [\(dropZ.map { "\($0)" }.joined(separator: ", "))];
            const below = \(fit.below);   // the cloud's base, below its middle, per unit of scale
            const fallsTo = \(W.fallsTo), fades = \(W.fades), parked = \(W.parked);
            // The weather stands a little above the middle of the scene view.
            const lift = \(W.lift);

            function rgb(hex) {
              const c = [1, 3, 5].map(i => parseInt(hex.substr(i, 2), 16));
              return c.concat(hex.length > 7 ? [parseInt(hex.substr(7, 2), 16)] : []);
            }
            function hex(c) { return "#" + c.map(v => Math.round(Math.max(0, Math.min(255, v))).toString(16).padStart(2, "0")).join(""); }

            let chosen = 0, now = null, last = null;
            let drops = dropX.map(() => ({ y: parked, wait: -1 }));
            let flakes = dropX.slice(0, \(W.flakes.count)).map(() => ({ y: parked, wait: -1 }));

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
              const share = 1 - Math.exp(-3.6 * dt);
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

              // Rain and snow start inside the cloud's base, fall, and shrink away above the card.
              const base = lift + now.cloudY - below * now.cloudScale * 0.6;
              function fall(items, amount, speed) {
                items.forEach((item, i) => {
                  const wanted = amount > (i + 0.5) / items.length * 0.95;
                  if (item.y === parked) {
                    if (!wanted) return;
                    if (item.wait < 0) item.wait = (i * 0.37) % 1;
                    item.wait -= dt * speed / (base - fallsTo);
                    if (item.wait <= 0) { item.y = base; item.wait = -1; }
                  } else {
                    item.y -= speed * dt;
                    if (item.y < fallsTo) item.y = wanted ? base + (item.y - fallsTo) : parked;
                  }
                  if (item.y !== parked || item.wait >= 0) still = false;
                });
              }
              function size(y, full) {
                if (y === parked) return 0;
                const t = Math.max(0, Math.min(1, (y - fallsTo) / fades));
                return full * t * t * (3 - 2 * t);
              }
              fall(drops, now.rain, 2.5 + 0.9 * now.storm);
              fall(flakes, now.snow, 0.5);

              // Lightning: a double flash every few seconds while it storms, fading out fast.
              const beat = inputs.clock % 2.8;
              const pulse = (at, length) => beat > at && beat < at + length ? 1 - (beat - at) / length : 0;
              const flash = now.storm > 0.5 ? Math.max(pulse(0, 0.16), pulse(0.24, 0.22)) : 0;
              if (now.storm > 0.001) still = false;

              outputs.moving = !still;
              outputs.temperature = day.temperature + "°";
              outputs.condition = day.condition;
              outputs.range = "H:" + day.high + "°  L:" + day.low + "°";
              outputs.pillX = \(cardX + 8) + now.pill * \(tileWidth);
              const lit = (c, by) => color(hex(c.map(v => v + (205 - v) * by)));
              outputs.skyTop = lit(now.top, flash * 0.35);
              outputs.skyBottom = lit(now.bottom, flash * 0.25);
              outputs.glow = now.glow;
              outputs.rays = now.rays;
              outputs.haze = now.haze;
              outputs.skyRain = now.rain;
              outputs.skySnow = now.snow;
              outputs.flash = flash;
              outputs.skyClock = inputs.clock;
              outputs.cardTint = color(hex(now.card));
              // Where the sun is on the screen, so the sky glows and shines round it.
              outputs.sunPoint = point(201 + now.sunX * 142, 451 - (lift + now.sunY) * 142);
              outputs.surroundings = sky.surroundings;
              // A flash lights the clouds from low in front, bright and cold.
              outputs.lightYaw = now.yaw;
              outputs.lightPitch = now.pitch + (-30 - now.pitch) * flash;
              outputs.intensity = now.intensity + 7 * flash;
              outputs.exposure = now.exposure + 0.35 * flash;
              outputs.lightColor = color(hex(now.lamp.map(v => v + (235 - v) * flash)));
              outputs.sunX = now.sunX; outputs.sunY = lift + now.sunY; outputs.sunScale = now.sunScale;
              outputs.cloudX = now.cloudX; outputs.cloudY = lift + now.cloudY; outputs.cloudScale = now.cloudScale;
              outputs.cloudColor = color(hex(now.cloud));
              outputs.backX = now.backX; outputs.backY = lift + now.backY; outputs.backScale = now.backScale;
              outputs.backColor = color(hex(now.back));
              outputs.frontX = now.frontX; outputs.frontY = lift + now.frontY; outputs.frontScale = now.frontScale;
              outputs.frontColor = color(hex(now.front));
              outputs.boltScale = 0.95 * (flash > 0.3 ? 1 : 0);
              outputs.boltY = lift - 0.72;
              drops.forEach((d, i) => { outputs["drop" + i] = d.y; outputs["drop" + i + "Size"] = size(d.y, 0.17); });
              flakes.forEach((f, i) => {
                outputs["flake" + i] = f.y;
                outputs["flake" + i + "X"] = dropX[i] * 0.95 + 0.08 * Math.sin(inputs.clock * 1.3 + i * 1.7);
                outputs["flake" + i + "Size"] = size(f.y, 0.1 + 0.05 * ((i * 7) % 3));
              });
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
            ("intensity", "lightIntensity"), ("lightColor", "lightColor"), ("exposure", "exposure"),
        ]
        for (output, input) in sceneInputs { b.connect(weather, output, to: view, scenePort(input)) }
        let objectInputs: [(String, String, String)] = [
            ("sunX", W.sun, "x"), ("sunY", W.sun, "y"), ("sunScale", W.sun, "scale"),
            ("cloudX", W.cloud, "x"), ("cloudY", W.cloud, "y"), ("cloudScale", W.cloud, "scale"), ("cloudColor", W.cloud, "color"),
            ("backX", W.backCloud, "x"), ("backY", W.backCloud, "y"), ("backScale", W.backCloud, "scale"), ("backColor", W.backCloud, "color"),
            ("frontX", W.frontCloud, "x"), ("frontY", W.frontCloud, "y"), ("frontScale", W.frontCloud, "scale"), ("frontColor", W.frontCloud, "color"),
            ("boltScale", W.bolt, "scale"), ("boltY", W.bolt, "y"),
        ] + W.drops.flatMap { [($0, $0, "y"), ($0 + "Size", $0, "scale")] }
            + W.flakes.flatMap { [($0, $0, "y"), ($0 + "X", $0, "x"), ($0 + "Size", $0, "scale")] }
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

    /// Where the drops and flakes fall across the cloud, and how near.
    private static let dropX = [-0.7, -0.5, -0.32, -0.12, 0.06, 0.24, 0.42, 0.6, 0.76, -0.2, 0.33, -0.6, 0.15, 0.68, -0.42, 0.5, -0.02, 0.86]
    private static let dropZ = [0.05, -0.1, 0.14, -0.05, 0.12, -0.12, 0.02, 0.15, -0.08, 0.2, -0.15, 0.18, -0.02, 0.1, 0.25, 0.22, 0.28, -0.04]

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
