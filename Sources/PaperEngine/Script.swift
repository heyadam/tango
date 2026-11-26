import Foundation
import JavaScriptCore
import PaperModel

// JavaScriptCore's own limit on how long a script may run. It is part of the framework's
// C interface but not of the headers Swift sees.
@_silgen_name("JSContextGroupSetExecutionTimeLimit")
private func JSContextGroupSetExecutionTimeLimit(
    _ group: JSContextGroupRef, _ limit: Double,
    _ callback: (@convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool)?, _ context: UnsafeMutableRawPointer?
)
import Synchronization

/// A web request a script asked for with `paper.fetch`. The token is the script's own
/// name for it, by which the answer finds its way back.
public struct ScriptRequest: Sendable, Hashable {
    public var token: Int
    public var url: String
    public var method: String
    public var headers: [String: String]
    public var body: String
    /// Seconds to wait for an answer; 0 leaves it to whoever makes the request.
    public var timeout: Double
    /// A service a built-in patch asks the host to reach for it (`NetworkRequest.service`).
    /// Scripts cannot set it.
    public var service: String? = nil
}

/// The answer to a script's request.
public struct ScriptReply: Sendable, Hashable {
    public var token: Int
    public var response: NetworkResponse
    /// The request's id, which names a picture the host kept from the answer
    /// (`NetworkRequest.pictureName(for:)`).
    public var id: UUID = UUID()
}

/// JavaScript patches: a script declares its inputs and outputs and a function that
/// turns one into the other, and from then on it is a patch like any other.
///
///     inputs = { a: 0, b: 0 };
///     outputs = { result: 0 };
///     function evaluate(inputs, outputs, time) { outputs.result = inputs.a + inputs.b; }
///
/// A port's type comes from its starting value: a number, text, true/false, `point(x, y)`,
/// `size(w, h)`, `color("#RRGGBB")`, `pulse()`, or an array or object for JSON. Setting
/// `everyFrame = true` runs the script on every frame instead of only when an input changes.
public enum Script {
    public static let template = """
    // Inputs and outputs: a name and a starting value for each.
    // The starting value sets the type: a number, "text", true/false,
    // point(x, y), size(w, h), color("#RRGGBB"), pulse(), or [] / {} for JSON.
    inputs = { a: 0, b: 0 };
    outputs = { result: 0 };

    // Set to true to run on every frame, not only when an input changes.
    everyFrame = false;

    function evaluate(inputs, outputs, time) {
      outputs.result = inputs.a + inputs.b;
    }
    """

    /// What a script declares, or why it could not be read.
    public struct Interface: Sendable, Hashable {
        public var ports = NodePorts()
        public var everyFrame = false
        public var error: String?
    }

    private static let cache = Mutex<[String: Interface]>([:])

    /// The ports a script declares. Scripts are run once to find out, and the answer kept.
    public static func interface(of source: String) -> Interface {
        if let known = cache.withLock({ $0[source] }) { return known }
        let instance = Instance(source: source)
        let found = instance.interface
        cache.withLock { cache in
            if cache.count > 200 { cache.removeAll() }
            cache[source] = found
        }
        return found
    }

    /// The label for a port named `someName` in a script: "Some Name".
    public static func title(_ key: String) -> String {
        var words = ""
        for character in key {
            if character.isUppercase, !words.isEmpty, words.last != " " { words.append(" ") }
            words.append(character == "_" ? " " : character)
        }
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// One running copy of a script. Each loop index of a patch has its own, so a script
    /// can keep state in its own variables.
    final class Instance: @unchecked Sendable {
        private let context: JSContext
        private var evaluate: JSValue?
        private let outputsObject: JSValue?
        private(set) var interface = Interface()
        private var inputKeys: [String] = []
        private var outputKeys: [String] = []

        /// Called with what goes wrong while the script runs, and with what it logs.
        /// Without one, a script that throws is silent, as a JavaScript patch is.
        private let report: Report?
        typealias Report = @Sendable (_ message: String, _ isError: Bool) -> Void
        /// The two functions behind `paper`, for a script that has it: one hands over the
        /// requests and log lines since the last run, the other settles a request.
        private var host: (take: JSValue, settle: JSValue)?

        static let prelude = """
        function point(x, y) { return { x: x || 0, y: y || 0, __type: "point" }; }
        function size(width, height) { return { width: width || 0, height: height || 0, __type: "size" }; }
        function color(hex) { return { hex: hex || "#000000", __type: "color" }; }
        function pulse(on) { return { on: !!on, __type: "pulse" }; }
        var inputs = {}, outputs = {}, everyFrame = false;
        """

        static func describe(_ exception: JSValue?) -> String {
            let line = exception?.objectForKeyedSubscript("line")
            let where_ = line?.isNumber == true ? " (line \(line!.toInt32()))" : ""
            return (exception?.toString() ?? "The script failed.") + where_
        }

        /// A script that declares its own ports: a JavaScript patch.
        convenience init(source: String) {
            self.init(source: source, declared: nil, report: nil)
        }

        /// A script whose ports are declared elsewhere, as an extension's manifest does.
        /// The script finds them already in `inputs` and `outputs`.
        /// Such a script also has `paper`, through which it asks for web requests.
        convenience init(source: String, ports: NodePorts, report: Report? = nil) {
            self.init(source: source, declared: ports, report: report)
        }

        private init(source: String, declared: NodePorts?, report: Report?) {
            self.report = report
            context = JSContext()
            var failure: String?
            context.exceptionHandler = { _, exception in failure = Instance.describe(exception) }
            context.evaluateScript(Instance.prelude)
            if let declared {
                for (name, ports) in [("inputs", declared.inputs), ("outputs", declared.outputs)] {
                    let object = JSValue(newObjectIn: context)!
                    for port in ports {
                        object.setObject(Instance.object(from: port.defaultValue, in: context), forKeyedSubscript: port.id as NSString)
                    }
                    context.setObject(object, forKeyedSubscript: name as NSString)
                }
                if let functions = context.evaluateScript(Instance.hostPrelude), functions.isArray,
                   let take = functions.objectAtIndexedSubscript(0), let settle = functions.objectAtIndexedSubscript(1) {
                    host = (take, settle)
                }
            }
            // A script that never ends would stop the whole app, which runs it between
            // frames. JavaScriptCore ends one that runs past the limit.
            JSContextGroupSetExecutionTimeLimit(JSContextGetGroup(context.jsGlobalContextRef), Script.timeLimit, nil, nil)
            let started = Date()
            context.evaluateScript(source)
            if Date().timeIntervalSince(started) >= Script.timeLimit { failure = Script.tooLong }

            let declaredInputs = context.objectForKeyedSubscript("inputs")
            let declaredOutputs = context.objectForKeyedSubscript("outputs")
            let function = context.objectForKeyedSubscript("evaluate")
            evaluate = function?.isObject == true ? function : nil
            outputsObject = declaredOutputs?.isObject == true ? declaredOutputs : JSValue(newObjectIn: context)

            func ports(_ object: JSValue?) -> ([String], [Port]) {
                guard let object, object.isObject,
                      let keys = context.objectForKeyedSubscript("Object")?
                        .invokeMethod("keys", withArguments: [object])?.toArray() as? [String]
                else { return ([], []) }
                let ports = keys.map { key -> Port in
                    let value = Instance.value(from: object.objectForKeyedSubscript(key))
                    return Port(id: key, name: Script.title(key), type: value.type, defaultValue: value)
                }
                return (keys, ports)
            }
            if let declared {
                inputKeys = declared.inputs.map(\.id)
                outputKeys = declared.outputs.map(\.id)
                interface.ports = declared
            } else {
                let (inKeys, inPorts) = ports(declaredInputs)
                let (outKeys, outPorts) = ports(declaredOutputs)
                inputKeys = inKeys
                outputKeys = outKeys
                interface.ports = NodePorts(inputs: inPorts, outputs: outPorts)
            }
            interface.everyFrame = context.objectForKeyedSubscript("everyFrame")?.toBool() ?? false
            if failure == nil, evaluate == nil { failure = "The script needs a function named evaluate." }
            interface.error = failure
            if let failure { report?(failure, true) }
            context.exceptionHandler = { _, exception in report?(Instance.describe(exception), true) }
        }

        /// Runs the script's function. Outputs it does not set keep their previous values.
        func run(inputs: [Value], outputs: [Value], time: Double) -> [Value] {
            step(inputs: inputs, outputs: outputs, time: time).outputs
        }

        /// One turn of the script: answers that arrived are handed to whatever awaited
        /// them, then its function runs. What was awaiting an answer carries on inside
        /// this call and nowhere else, so it writes the same outputs the function does,
        /// and a pulse it sets lasts the one frame a pulse should.
        func step(inputs: [Value], outputs: [Value], time: Double, replies: [ScriptReply] = []) -> (outputs: [Value], requests: [ScriptRequest]) {
            guard let evaluate, let outputsObject else { return (outputs, []) }
            let arguments = JSValue(newObjectIn: context)!
            for (key, value) in zip(inputKeys, inputs) {
                arguments.setObject(Instance.object(from: value, in: context), forKeyedSubscript: key as NSString)
            }
            for (key, value) in zip(outputKeys, outputs) {
                // Pulses start each run off; everything else starts where it was.
                let start = value.type == .pulse ? Value.pulse(false) : value
                outputsObject.setObject(Instance.object(from: start, in: context), forKeyedSubscript: key as NSString)
            }

            // Each entry into the script has the time limit to itself. One that was cut
            // off leaves the script in no state to go on: it is not entered again.
            var cutOff = false
            func enter(_ body: () -> Void) {
                guard !cutOff else { return }
                let started = Date()
                body()
                if Date().timeIntervalSince(started) >= Script.timeLimit { cutOff = true }
            }
            if let host {
                for reply in replies {
                    let response = reply.response
                    let text = String(decoding: response.body, as: UTF8.self)
                    enter {
                        host.settle.call(withArguments: [
                            reply.token, response.status, response.headers, text, response.error as Any? ?? NSNull(),
                        ])
                    }
                }
            }
            enter { evaluate.call(withArguments: [arguments, outputsObject, time]) }
            var taken: String?
            if let host { enter { taken = host.take.call(withArguments: [])?.toString() } }
            if cutOff {
                // Running it again every frame would freeze the prototype a quarter second
                // at a time, so it stays off until the script changes.
                interface.error = Script.tooLong
                self.evaluate = nil
                self.host = nil
                report?(Script.tooLong, true)
                return (outputs, [])
            }

            var requests: [ScriptRequest] = []
            if let taken, let parsed = try? JSONSerialization.jsonObject(with: Data(taken.utf8)) as? [String: Any] {
                for line in parsed["logs"] as? [String] ?? [] { report?(line, false) }
                for item in parsed["requests"] as? [[String: Any]] ?? [] {
                    guard let token = item["token"] as? Int, let url = item["url"] as? String else { continue }
                    requests.append(ScriptRequest(
                        token: token, url: url, method: item["method"] as? String ?? "GET",
                        headers: item["headers"] as? [String: String] ?? [:], body: item["body"] as? String ?? "",
                        timeout: (item["timeout"] as? Double).flatMap { $0.isFinite ? $0 : nil } ?? 0
                    ))
                }
            }
            let produced = zip(outputKeys, interface.ports.outputs).enumerated().map { index, pair in
                let produced = Instance.value(from: outputsObject.objectForKeyedSubscript(pair.0))
                return produced.coerced(to: pair.1.type) ?? produced.converted(to: pair.1.type, fallback: outputs[index])
            }
            return (produced, requests)
        }

        /// `paper`, for scripts that come from an extension. A request is only written
        /// down here; the runtime's host makes it, and its answer settles the promise.
        static let hostPrelude = """
        (function () {
          var pending = {}, waiting = 0, next = 1, outbox = [], logs = [];
          var paper = {};
          function failed(message) { return { ok: false, status: 0, headers: {}, text: "", json: null, error: message }; }
          paper.fetch = function (url, options) {
            options = options || {};
            if (waiting >= \(Script.mostRequests)) return Promise.resolve(failed("Too many requests are waiting for an answer."));
            var headers = {}, given = options.headers || {};
            for (var name in given) headers[String(name)] = String(given[name]);
            var body = options.body;
            if (body !== undefined && body !== null && typeof body !== "string") {
              body = JSON.stringify(body);
              var typed = false;
              for (var known in headers) if (known.toLowerCase() === "content-type") typed = true;
              if (!typed) headers["Content-Type"] = "application/json";
            }
            var none = body === undefined || body === null;
            var token = next++;
            waiting++;
            outbox.push({
              token: token, url: String(url), method: String(options.method || (none ? "GET" : "POST")).toUpperCase(),
              headers: headers, body: none ? "" : body, timeout: Number(options.timeout) || 0
            });
            return new Promise(function (resolve) { pending[token] = resolve; });
          };
          paper.secret = function (id) { return "\(Script.secretOpen)" + String(id) + "\(Script.secretClose)"; };
          paper.log = function () {
            if (logs.length >= 50) return;
            logs.push(Array.prototype.map.call(arguments, function (item) {
              try { return typeof item === "string" ? item : JSON.stringify(item); } catch (error) { return String(item); }
            }).join(" "));
          };
          Object.freeze(paper);
          Object.defineProperty(globalThis, "paper", { value: paper, writable: false, configurable: false });
          return [
            function () {
              var taken = JSON.stringify({ requests: outbox, logs: logs });
              outbox = []; logs = [];
              return taken;
            },
            function (token, status, headers, text, error) {
              var resolve = pending[token];
              if (!resolve) return;
              delete pending[token];
              waiting--;
              var ok = !error && status >= 200 && status < 300, parsed = false, json = null;
              var reply = {
                ok: ok, status: status, headers: headers || {}, text: text,
                error: ok ? "" : (error || "The server answered " + status + ".")
              };
              // Read as JSON the first time it is asked for: a script that only wants
              // the text does not pay for reading a long answer twice.
              Object.defineProperty(reply, "json", { enumerable: true, get: function () {
                if (!parsed) { parsed = true; try { json = JSON.parse(text); } catch (ignored) {} }
                return json;
              } });
              resolve(reply);
            }
          ];
        })()
        """

        // MARK: Converting values

        static func value(from js: JSValue?) -> Value {
            guard let js, !js.isUndefined, !js.isNull else { return .number(0) }
            if js.isBoolean { return .bool(js.toBool()) }
            if js.isNumber { return .number(js.toDouble().isFinite ? js.toDouble() : 0) }
            if js.isString { return .text(js.toString() ?? "") }
            if js.isArray {
                let count = Int(js.objectForKeyedSubscript("length")?.toInt32() ?? 0)
                return .array((0..<count).map { value(from: js.objectAtIndexedSubscript($0)) })
            }
            if js.isObject {
                func number(_ key: String) -> Double {
                    let read = js.objectForKeyedSubscript(key)?.toDouble() ?? 0
                    return read.isFinite ? read : 0
                }
                switch js.objectForKeyedSubscript("__type")?.toString() {
                case "point": return .point(Point2(x: number("x"), y: number("y")))
                case "size": return .size(Size2(width: number("width"), height: number("height")))
                case "color":
                    return .color(ColorValue(hex: js.objectForKeyedSubscript("hex")?.toString() ?? "") ?? .black)
                case "pulse": return .pulse(js.objectForKeyedSubscript("on")?.toBool() ?? false)
                default:
                    var fields: [String: Value] = [:]
                    let keys = js.context.objectForKeyedSubscript("Object")?
                        .invokeMethod("keys", withArguments: [js])?.toArray() as? [String] ?? []
                    for key in keys { fields[key] = value(from: js.objectForKeyedSubscript(key)) }
                    return .object(fields)
                }
            }
            return .number(0)
        }

        static func object(from value: Value, in context: JSContext) -> Any {
            switch value {
            case let .number(number): return number
            case let .bool(flag): return flag
            case let .pulse(on): return on
            case let .text(text): return text
            case let .color(color): return ["hex": color.hex, "__type": "color"]
            case let .point(point): return ["x": point.x, "y": point.y, "__type": "point"]
            case let .size(size): return ["width": size.width, "height": size.height, "__type": "size"]
            case let .array(items): return items.map { object(from: $0, in: context) }
            case let .object(fields): return fields.mapValues { object(from: $0, in: context) }
            }
        }
    }

    /// Puts the time limit on a context: JavaScriptCore ends a script that runs past it.
    static func limit(_ context: JSContext) {
        JSContextGroupSetExecutionTimeLimit(JSContextGetGroup(context.jsGlobalContextRef), Script.timeLimit, nil, nil)
    }

    /// How long one run of a script may take, in seconds.
    static let timeLimit = 0.25
    static let tooLong = "The script ran too long and was stopped. Check its loops."
    /// How many requests one running script may have waiting for an answer.
    static let mostRequests = 8
    /// What `paper.secret("id")` gives a script in place of a key: these around the id.
    /// Whoever makes the request puts the key there, if this request may carry it.
    public static let secretOpen = "\u{27E6}key:"
    public static let secretClose = "\u{27E7}"

    static let definition = PatchDefinition(
        kind: PatchKind.javascript,
        name: "JavaScript",
        category: .utility,
        summary: "A patch you write: a script declares its inputs and outputs and a function that computes one from the other."
    ) { ctx in
        guard let source = ctx.script else { return }
        let instance = ctx.state(as: Instance.self) ?? Instance(source: source)
        ctx.state = instance
        ctx.outputs = instance.run(inputs: ctx.inputs, outputs: ctx.outputs, time: ctx.time)
        ctx.wantsNextFrame = instance.interface.everyFrame && instance.interface.error == nil
    }
}

extension Value {
    /// Like `converted(to:)`, but keeps `fallback` when nothing sensible can be made.
    func converted(to target: PortType, fallback: Value) -> Value {
        // A script may hand back true for a pulse output.
        if target == .pulse, case let .bool(on) = self { return .pulse(on) }
        let converted = converted(to: target)
        return converted.type == target || target == .json ? converted : fallback
    }
}
