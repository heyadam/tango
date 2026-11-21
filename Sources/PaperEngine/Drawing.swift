import Foundation
import JavaScriptCore
import PaperModel

/// What a view drawn by an extension looks like this frame: a list of drawing steps, in
/// the view's own points with the origin at its top-left and y down. The engine only
/// writes the list down; the renderer turns it into pixels.
public struct Drawing: Sendable, Hashable {
    public let commands: [DrawCommand]
    /// Different for every drawing made, so two can be told apart without comparing
    /// thousands of steps.
    public let stamp: Int

    public static func == (a: Drawing, b: Drawing) -> Bool { a.stamp == b.stamp }
    public func hash(into hasher: inout Hasher) { hasher.combine(stamp) }

    /// The most steps one drawing may have. What a script draws past it is left out.
    public static let limit = 20_000
    /// The longest one piece of text may be, and the most text a drawing may hold.
    public static let longestText = 2_000
    public static let mostText = 100_000
}

/// One step of a drawing. They follow the HTML canvas, which is what a script writes
/// against: a current path that is built up and then filled, stroked or clipped to.
public enum DrawCommand: Sendable, Hashable {
    public enum Paint: Sendable, Hashable {
        case color(ColorValue)
        case linear(from: Point2, to: Point2, stops: [Stop])
        case radial(from: Point2, radius: Double, to: Point2, toRadius: Double, stops: [Stop])

        /// One color to stand for the paint where a gradient cannot be used.
        public var flat: ColorValue {
            switch self {
            case let .color(color): color
            case let .linear(_, _, stops), let .radial(_, _, _, _, stops): stops.first?.color ?? .black
            }
        }
    }

    public struct Stop: Sendable, Hashable {
        public var at: Double
        public var color: ColorValue
    }

    public struct Shadow: Sendable, Hashable {
        public var color: ColorValue
        public var blur: Double
        public var offset: Point2
    }

    /// How something is painted: with what, how opaque, and the shadow it casts.
    public struct Style: Sendable, Hashable {
        public var paint: Paint
        public var alpha: Double
        public var shadow: Shadow?
    }

    public struct Line: Sendable, Hashable {
        public var width: Double
        /// "butt", "round" or "square".
        public var cap: String
        /// "miter", "round" or "bevel".
        public var join: String
        public var dash: [Double]
    }

    public struct Font: Sendable, Hashable {
        public var size: Double
        public var weight: Double
        /// "left", "center" or "right": where `x` is on the line of text.
        public var align: String
        /// "alphabetic", "top", "middle" or "bottom": where `y` is on it.
        public var baseline: String
    }

    case save, restore
    case translate(Double, Double), scale(Double, Double), rotate(Double)
    case beginPath
    case move(Double, Double), line(Double, Double)
    case quad(Double, Double, Double, Double)
    case curve(Double, Double, Double, Double, Double, Double)
    case arc(x: Double, y: Double, radius: Double, start: Double, end: Double, counterclockwise: Bool)
    case rect(Double, Double, Double, Double)
    case roundRect(Double, Double, Double, Double, radius: Double)
    case ellipse(x: Double, y: Double, radiusX: Double, radiusY: Double)
    case close
    case fill(Style), stroke(Style, Line), clip
    case fillRect(Double, Double, Double, Double, Style)
    case strokeRect(Double, Double, Double, Double, Style, Line)
    case clearRect(Double, Double, Double, Double)
    case text(String, x: Double, y: Double, style: Style, font: Font)
    /// A picture by name, as the renderer's image provider knows it.
    case image(String, Double, Double, Double, Double, alpha: Double)
}

// MARK: - Reading what a script drew

extension DrawCommand {
    /// Reads the steps a script's canvas wrote down: a JSON array of arrays, each a short
    /// name and its numbers. Anything that is not what it should be is left out; numbers
    /// are made finite, since a drawing with NaN in it cannot be drawn.
    static func read(_ json: String, images: (String) -> String?) -> [DrawCommand] {
        guard let steps = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[Any]] else { return [] }
        var commands: [DrawCommand] = []
        commands.reserveCapacity(steps.count)
        for step in steps.prefix(Drawing.limit) {
            guard let name = step.first as? String else { continue }
            func n(_ index: Int) -> Double {
                guard index < step.count, let number = step[index] as? NSNumber else { return 0 }
                let value = number.doubleValue
                return value.isFinite ? min(max(value, -1e7), 1e7) : 0
            }
            func s(_ index: Int) -> String { index < step.count ? step[index] as? String ?? "" : "" }
            func style(_ index: Int) -> Style {
                var shadow: Shadow?
                if index + 2 < step.count, let given = step[index + 2] as? [Any], given.count == 4,
                   let hex = given[0] as? String, let color = ColorValue(hex: hex), color.alpha > 0 {
                    func part(_ at: Int) -> Double { ((given[at] as? NSNumber)?.doubleValue).flatMap { $0.isFinite ? $0 : nil } ?? 0 }
                    shadow = Shadow(color: color, blur: min(max(part(1), 0), 200), offset: Point2(x: part(2), y: part(3)))
                }
                return Style(paint: paint(index < step.count ? step[index] : "#000000"), alpha: min(max(n(index + 1), 0), 1), shadow: shadow)
            }
            func line(_ index: Int) -> Line {
                let dash = (index + 3 < step.count ? step[index + 3] as? [NSNumber] : nil) ?? []
                return Line(
                    width: min(max(n(index), 0), 1000), cap: s(index + 1), join: s(index + 2),
                    dash: dash.prefix(16).map { max($0.doubleValue.isFinite ? $0.doubleValue : 0, 0) }
                )
            }
            switch name {
            case "sv": commands.append(.save)
            case "rs": commands.append(.restore)
            case "tr": commands.append(.translate(n(1), n(2)))
            case "sc": commands.append(.scale(n(1), n(2)))
            case "ro": commands.append(.rotate(n(1)))
            case "b": commands.append(.beginPath)
            case "m": commands.append(.move(n(1), n(2)))
            case "l": commands.append(.line(n(1), n(2)))
            case "q": commands.append(.quad(n(1), n(2), n(3), n(4)))
            case "c": commands.append(.curve(n(1), n(2), n(3), n(4), n(5), n(6)))
            case "a": commands.append(.arc(x: n(1), y: n(2), radius: max(n(3), 0), start: n(4), end: n(5), counterclockwise: n(6) != 0))
            case "r": commands.append(.rect(n(1), n(2), n(3), n(4)))
            case "rr": commands.append(.roundRect(n(1), n(2), n(3), n(4), radius: max(n(5), 0)))
            case "e": commands.append(.ellipse(x: n(1), y: n(2), radiusX: max(n(3), 0), radiusY: max(n(4), 0)))
            case "z": commands.append(.close)
            case "F": commands.append(.fill(style(1)))
            case "S": commands.append(.stroke(style(1), line(4)))
            case "C": commands.append(.clip)
            case "fr": commands.append(.fillRect(n(1), n(2), n(3), n(4), style(5)))
            case "sr": commands.append(.strokeRect(n(1), n(2), n(3), n(4), style(5), line(8)))
            case "cr": commands.append(.clearRect(n(1), n(2), n(3), n(4)))
            case "t":
                let font = Font(size: min(max(n(7), 1), 2000), weight: n(8), align: s(9), baseline: s(10))
                commands.append(.text(String(s(1).prefix(Drawing.longestText)), x: n(2), y: n(3), style: style(4), font: font))
            case "i":
                if let image = images(s(1)) { commands.append(.image(image, n(2), n(3), n(4), n(5), alpha: min(max(n(6), 0), 1))) }
            default: break
            }
        }
        return commands
    }

    private static func paint(_ value: Any) -> Paint {
        if let hex = value as? String { return .color(ColorValue(hex: hex) ?? .black) }
        guard let spec = value as? [String: Any], let kind = spec["kind"] as? String else { return .color(.black) }
        func n(_ key: String) -> Double { ((spec[key] as? NSNumber)?.doubleValue).flatMap { $0.isFinite ? $0 : nil } ?? 0 }
        let stops: [Stop] = (spec["stops"] as? [[Any]] ?? []).prefix(32).compactMap { stop in
            guard stop.count == 2, let at = (stop[0] as? NSNumber)?.doubleValue, at.isFinite,
                  let hex = stop[1] as? String, let color = ColorValue(hex: hex) else { return nil }
            return Stop(at: min(max(at, 0), 1), color: color)
        }.sorted { $0.at < $1.at }
        guard !stops.isEmpty else { return .color(.black) }
        if kind == "radial" {
            return .radial(
                from: Point2(x: n("x0"), y: n("y0")), radius: max(n("r0"), 0),
                to: Point2(x: n("x1"), y: n("y1")), toRadius: max(n("r1"), 0), stops: stops
            )
        }
        return .linear(from: Point2(x: n("x0"), y: n("y0")), to: Point2(x: n("x1"), y: n("y1")), stops: stops)
    }
}

// MARK: - Running a view's script

/// One view kind's script, ready to draw. Drawing keeps nothing between calls that the
/// script does not keep itself, so every view of the kind shares it.
final class DrawScript {
    private let context: JSContext
    private var draw: JSValue?
    private var begin: JSValue?
    private var take: JSValue?
    private let inputKeys: [String]
    private let extensionID: String
    private let report: Script.Instance.Report?
    private(set) var everyFrame = false
    private(set) var error: String?

    init(source: String, inputs: [Port], extensionID: String, report: Script.Instance.Report?) {
        self.extensionID = extensionID
        self.report = report
        inputKeys = inputs.map(\.id)
        context = JSContext()
        var failure: String?
        context.exceptionHandler = { _, exception in failure = Script.Instance.describe(exception) }
        context.evaluateScript(Script.Instance.prelude)
        // Text is measured the way it will be drawn.
        let measure: @convention(block) (String, Double, Double) -> Double = { text, size, weight in
            guard size.isFinite, size > 0 else { return 0 }
            return TextMeasurer.measure(String(text.prefix(Drawing.longestText)), fontSize: min(size, 2000), weight: weight, maxWidth: nil).width
        }
        context.setObject(measure, forKeyedSubscript: "__measure" as NSString)
        if let functions = context.evaluateScript(DrawScript.canvasPrelude), functions.isArray {
            begin = functions.objectAtIndexedSubscript(0)
            take = functions.objectAtIndexedSubscript(1)
        }
        Script.limit(context)
        let started = Date()
        context.evaluateScript(source)
        if Date().timeIntervalSince(started) >= Script.timeLimit { failure = Script.tooLong }
        let function = context.objectForKeyedSubscript("draw")
        draw = function?.isObject == true ? function : nil
        everyFrame = context.objectForKeyedSubscript("everyFrame")?.toBool() ?? false
        if failure == nil, draw == nil { failure = "The script needs a function named draw." }
        error = failure
        if let failure { report?(failure, true) }
        context.exceptionHandler = { _, exception in report?(Script.Instance.describe(exception), true) }
    }

    /// Calls the script's `draw` and returns what it drew, or nil when it cannot draw.
    func run(inputs: [Value], size: Size2, time: Double) -> [DrawCommand]? {
        guard let draw, let begin, let take else { return nil }
        let arguments = JSValue(newObjectIn: context)!
        for (key, value) in zip(inputKeys, inputs) {
            arguments.setObject(Script.Instance.object(from: value, in: context), forKeyedSubscript: key as NSString)
        }
        let started = Date()
        guard let canvas = begin.call(withArguments: [size.width, size.height]) else { return nil }
        draw.call(withArguments: [canvas, arguments, ["width": size.width, "height": size.height], time])
        let cutOff = Date().timeIntervalSince(started) >= Script.timeLimit
        let written = cutOff ? nil : take.call(withArguments: [])?.toString()
        guard !cutOff, let written, Date().timeIntervalSince(started) < Script.timeLimit * 2 else {
            // As with a patch: one that ran out of time is not run again.
            error = Script.tooLong
            self.draw = nil
            report?(Script.tooLong, true)
            return nil
        }
        let id = extensionID
        return DrawCommand.read(written) { name in
            // A picture is one of the extension's own files, and is named so that the
            // renderer finds it there and nowhere else.
            ExtensionManifest.isPath(name) ? "ext:\(id)/\(name)" : nil
        }
    }

    /// The `canvas` a view's script draws on: the part of the HTML canvas that draws.
    /// Nothing is drawn here; every call is written down for the renderer.
    static let canvasPrelude = """
    (function () {
      var ops = [], limit = \(Drawing.limit), letters = 0;
      function push(op) { if (ops.length < limit) ops.push(op); }
      function num(value) { value = Number(value); return isFinite(value) ? value : 0; }
      var named = {
        black: "#000000", white: "#FFFFFF", red: "#FF3B30", green: "#34C759", blue: "#007AFF", yellow: "#FFCC00",
        orange: "#FF9500", purple: "#AF52DE", pink: "#FF2D55", gray: "#8E8E93", grey: "#8E8E93",
        clear: "#00000000", transparent: "#00000000"
      };
      function two(value) { value = Math.max(0, Math.min(255, Math.round(num(value)))); return (value < 16 ? "0" : "") + value.toString(16); }
      function paint(value) {
        if (value && typeof value === "object") {
          if (value.__spec) return value.__spec;
          return typeof value.hex === "string" ? value.hex : "#000000";
        }
        var text = String(value).trim().toLowerCase();
        if (named[text]) return named[text];
        if (text.charAt(0) === "#") {
          var digits = text.slice(1);
          if (digits.length === 3 || digits.length === 4) digits = digits.split("").map(function (c) { return c + c; }).join("");
          return "#" + digits;
        }
        var match = /^rgba?\\(([^)]*)\\)$/.exec(text);
        if (match) {
          var parts = match[1].split(/[\\s,\\/]+/).filter(Boolean).map(Number);
          var alpha = parts.length > 3 ? num(parts[3]) : 1;
          return "#" + two(parts[0]) + two(parts[1]) + two(parts[2]) + (alpha < 1 ? two(alpha * 255) : "");
        }
        return "#000000";
      }
      function Gradient(spec) { this.__spec = spec; }
      Gradient.prototype.addColorStop = function (at, color) {
        var stop = paint(color);
        if (typeof stop === "string" && this.__spec.stops.length < 32) this.__spec.stops.push([num(at), stop]);
      };
      function fresh() {
        return {
          fillStyle: "#000000", strokeStyle: "#000000", lineWidth: 1, lineCap: "butt", lineJoin: "miter",
          globalAlpha: 1, font: "13px sans-serif", textAlign: "left", textBaseline: "alphabetic",
          shadowColor: "#00000000", shadowBlur: 0, shadowOffsetX: 0, shadowOffsetY: 0, dash: []
        };
      }
      var keys = Object.keys(fresh());
      function fontOf(canvas) {
        var text = String(canvas.font);
        var size = /(\\d+(\\.\\d+)?)\\s*px/.exec(text), weight = /\\b(bold|[1-9]00)\\b/.exec(text);
        return [size ? num(size[1]) : 13, weight ? (weight[1] === "bold" ? 700 : num(weight[1])) : 400];
      }
      function shadowOf(canvas) {
        var color = paint(canvas.shadowColor);
        return typeof color === "string" ? [color, num(canvas.shadowBlur), num(canvas.shadowOffsetX), num(canvas.shadowOffsetY)] : null;
      }
      function Canvas(width, height) {
        var start = fresh();
        for (var i = 0; i < keys.length; i++) this[keys[i]] = start[keys[i]];
        this.width = width;
        this.height = height;
        this.__stack = [];
      }
      var p = Canvas.prototype;
      p.save = function () {
        var kept = {};
        for (var i = 0; i < keys.length; i++) kept[keys[i]] = this[keys[i]];
        kept.dash = this.dash.slice();
        if (this.__stack.length < 64) { this.__stack.push(kept); push(["sv"]); }
      };
      p.restore = function () {
        var kept = this.__stack.pop();
        if (!kept) return;
        for (var i = 0; i < keys.length; i++) this[keys[i]] = kept[keys[i]];
        push(["rs"]);
      };
      p.translate = function (x, y) { push(["tr", num(x), num(y)]); };
      p.scale = function (x, y) { push(["sc", num(x), num(y === undefined ? x : y)]); };
      p.rotate = function (angle) { push(["ro", num(angle)]); };
      p.beginPath = function () { push(["b"]); };
      p.moveTo = function (x, y) { push(["m", num(x), num(y)]); };
      p.lineTo = function (x, y) { push(["l", num(x), num(y)]); };
      p.quadraticCurveTo = function (cx, cy, x, y) { push(["q", num(cx), num(cy), num(x), num(y)]); };
      p.bezierCurveTo = function (ax, ay, bx, by, x, y) { push(["c", num(ax), num(ay), num(bx), num(by), num(x), num(y)]); };
      p.arc = function (x, y, radius, start, end, counterclockwise) {
        push(["a", num(x), num(y), num(radius), num(start), num(end), counterclockwise ? 1 : 0]);
      };
      p.rect = function (x, y, w, h) { push(["r", num(x), num(y), num(w), num(h)]); };
      p.roundRect = function (x, y, w, h, radius) { push(["rr", num(x), num(y), num(w), num(h), num(radius)]); };
      p.ellipse = function (x, y, rx, ry) { push(["e", num(x), num(y), num(rx), num(ry)]); };
      p.closePath = function () { push(["z"]); };
      p.setLineDash = function (dash) { this.dash = Array.isArray(dash) ? dash.slice(0, 16).map(num) : []; };
      p.fill = function () { push(["F", paint(this.fillStyle), num(this.globalAlpha), shadowOf(this)]); };
      p.stroke = function () {
        push(["S", paint(this.strokeStyle), num(this.globalAlpha), shadowOf(this), num(this.lineWidth), String(this.lineCap), String(this.lineJoin), this.dash]);
      };
      p.clip = function () { push(["C"]); };
      p.fillRect = function (x, y, w, h) { push(["fr", num(x), num(y), num(w), num(h), paint(this.fillStyle), num(this.globalAlpha), shadowOf(this)]); };
      p.strokeRect = function (x, y, w, h) {
        push(["sr", num(x), num(y), num(w), num(h), paint(this.strokeStyle), num(this.globalAlpha), shadowOf(this), num(this.lineWidth), String(this.lineCap), String(this.lineJoin), this.dash]);
      };
      p.clearRect = function (x, y, w, h) { push(["cr", num(x), num(y), num(w), num(h)]); };
      p.fillText = function (text, x, y) {
        var font = fontOf(this);
        // One piece of text is kept to a length that can be drawn, and a drawing to an
        // amount of text that can be.
        text = String(text).slice(0, \(Drawing.longestText));
        if (letters + text.length > \(Drawing.mostText)) return;
        letters += text.length;
        push(["t", text, num(x), num(y), paint(this.fillStyle), num(this.globalAlpha), shadowOf(this), font[0], font[1], String(this.textAlign), String(this.textBaseline)]);
      };
      p.measureText = function (text) {
        var font = fontOf(this);
        return { width: __measure(String(text).slice(0, \(Drawing.longestText)), font[0], font[1]) };
      };
      p.drawImage = function (name, x, y, w, h) { push(["i", String(name), num(x), num(y), num(w), num(h), num(this.globalAlpha)]); };
      p.createLinearGradient = function (x0, y0, x1, y1) {
        return new Gradient({ kind: "linear", x0: num(x0), y0: num(y0), x1: num(x1), y1: num(y1), stops: [] });
      };
      p.createRadialGradient = function (x0, y0, r0, x1, y1, r1) {
        return new Gradient({ kind: "radial", x0: num(x0), y0: num(y0), r0: num(r0), x1: num(x1), y1: num(y1), r1: num(r1), stops: [] });
      };
      return [
        function (width, height) { ops = []; letters = 0; return new Canvas(width, height); },
        function () { var taken = JSON.stringify(ops); ops = []; return taken; }
      ];
    })()
    """
}

/// Draws the views that extensions draw: after layout, each one whose inputs or size
/// changed (or that asks to be drawn every frame) has its script run, and what it drew is
/// put on the resolved tree. A view that did not change keeps the drawing it had.
public final class ViewPainter {
    private struct Painted {
        var inputs: [Value]
        var size: Size2
        var source: String
        var drawing: Drawing
    }

    private var scripts: [String: DrawScript] = [:]
    private var sources: [String: String] = [:]
    private var painted: [ResolvedLayer.Hit: Painted] = [:]
    private var stamp = 0

    public init() {}

    /// Forgets every drawing and script, as when the prototype starts over.
    public func reset() {
        scripts = [:]
        sources = [:]
        painted = [:]
    }

    /// Gives every extension view in `tree` its drawing. Returns whether any of them
    /// wants to be drawn again next frame.
    @discardableResult
    public func paint(_ tree: inout ResolvedLayer, registry: PatchRegistry, time: Double) -> Bool {
        var seen: Set<ResolvedLayer.Hit> = []
        let moving = paint(&tree, registry, time, &seen)
        if painted.count > seen.count { painted = painted.filter { seen.contains($0.key) } }
        return moving
    }

    private func paint(_ layer: inout ResolvedLayer, _ registry: PatchRegistry, _ time: Double, _ seen: inout Set<ResolvedLayer.Hit>) -> Bool {
        var moving = false
        if let custom = layer.custom, let view = registry.view(custom.kind), view.isAvailable, let source = view.script {
            let key = ResolvedLayer.Hit(layer: layer.id, instance: layer.instance)
            seen.insert(key)
            // An extension that was updated has a new script: it is loaded afresh.
            if sources[custom.kind] != source {
                sources[custom.kind] = source
                let name = view.name, id = view.origin.id
                scripts[custom.kind] = DrawScript(source: source, inputs: view.inputs, extensionID: id) { message, isError in
                    ExtensionLog.shared.note(message, from: name, in: id, isError: isError)
                }
            }
            if let script = scripts[custom.kind] {
                let inputs = view.inputs.map { port in custom.values[port.id]?.coerced(to: port.type) ?? port.defaultValue }
                let size = layer.size
                let known = painted[key]
                if let known, !script.everyFrame, known.inputs == inputs, known.size == size, known.source == source {
                    layer.drawing = known.drawing
                } else if let commands = script.run(inputs: inputs, size: size, time: time) {
                    stamp += 1
                    let drawing = Drawing(commands: commands, stamp: stamp)
                    painted[key] = Painted(inputs: inputs, size: size, source: source, drawing: drawing)
                    layer.drawing = drawing
                } else {
                    // A script that failed leaves what it last drew.
                    layer.drawing = known?.drawing
                }
                if script.everyFrame, script.error == nil { moving = true }
            }
        }
        for index in layer.children.indices where paint(&layer.children[index], registry, time, &seen) { moving = true }
        return moving
    }
}
