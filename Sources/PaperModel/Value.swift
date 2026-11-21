import Foundation

/// A 2D point in logical points. Origin is the top-left of the parent, y grows downward.
public struct Point2: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }

    public static let zero = Point2()

    public static func + (a: Point2, b: Point2) -> Point2 { Point2(x: a.x + b.x, y: a.y + b.y) }
    public static func - (a: Point2, b: Point2) -> Point2 { Point2(x: a.x - b.x, y: a.y - b.y) }
    public static func * (a: Point2, s: Double) -> Point2 { Point2(x: a.x * s, y: a.y * s) }

    public var length: Double { (x * x + y * y).squareRoot() }
}

public struct Size2: Codable, Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double = 0, height: Double = 0) {
        self.width = width
        self.height = height
    }

    public static let zero = Size2()
}

/// An sRGB color with components in 0...1.
public struct ColorValue: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(white: Double, alpha: Double = 1) {
        self.init(red: white, green: white, blue: white, alpha: alpha)
    }

    /// Parses `#RRGGBB` or `#RRGGBBAA`. Returns nil for anything else.
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let raw = UInt64(text, radix: 16) else { return nil }
        let hasAlpha = text.count == 8
        let r = Double((raw >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((raw >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((raw >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(raw & 0xFF) / 255 : 1
        self.init(red: r, green: g, blue: b, alpha: a)
    }

    public var hex: String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        let rgb = String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
        return alpha >= 0.999 ? rgb : rgb + String(format: "%02X", byte(alpha))
    }

    public static let black = ColorValue(white: 0)
    public static let white = ColorValue(white: 1)
    public static let clear = ColorValue(white: 0, alpha: 0)
}

/// The type a port carries.
public enum PortType: String, Codable, Sendable, CaseIterable {
    case number
    case bool
    case pulse
    case text
    case color
    case point
    case size
    /// An ordered list of values, such as the items a Loop Over Array repeats.
    case array
    /// Data as it arrives from a request: an object, an array, or a plain value.
    case json

    public var displayName: String {
        switch self {
        case .number: "Number"
        case .bool: "Boolean"
        case .pulse: "Pulse"
        case .text: "Text"
        case .color: "Color"
        case .point: "Point"
        case .size: "Size"
        case .array: "Array"
        case .json: "JSON"
        }
    }
}

/// A value travelling along a cable or stored as a literal on an unconnected input.
public enum Value: Hashable, Sendable {
    case number(Double)
    case bool(Bool)
    /// An event signal. `true` only during the frame the event happens.
    case pulse(Bool)
    case text(String)
    case color(ColorValue)
    case point(Point2)
    case size(Size2)
    case array([Value])
    /// A JSON object: named values.
    case object([String: Value])

    public var type: PortType {
        switch self {
        case .number: .number
        case .bool: .bool
        case .pulse: .pulse
        case .text: .text
        case .color: .color
        case .point: .point
        case .size: .size
        case .array: .array
        case .object: .json
        }
    }

    public static func defaultValue(for type: PortType) -> Value {
        switch type {
        case .number: .number(0)
        case .bool: .bool(false)
        case .pulse: .pulse(false)
        case .text: .text("")
        case .color: .color(.black)
        case .point: .point(.zero)
        case .size: .size(.zero)
        case .array: .array([])
        case .json: .object([:])
        }
    }

    // MARK: Coercion

    /// Whether a cable may run from an output of type `from` into an input of type `to`.
    ///
    /// A boolean cannot feed a pulse input directly: turning a lasting state into an event is
    /// an explicit step (the Pulse patch).
    public static func canConnect(from: PortType, to: PortType) -> Bool {
        if from == to { return true }
        // A JSON port carries whatever the data holds, so any value may go in, and what
        // comes out may turn out to be an array.
        if to == .json, from != .pulse { return true }
        if from == .json, to == .array { return true }
        switch (from, to) {
        case (.number, .bool), (.bool, .number),
             (.pulse, .bool), (.pulse, .number),
             (.number, .point), (.number, .size),
             (.point, .size), (.size, .point),
             (.number, .text), (.bool, .text):
            return true
        default:
            return false
        }
    }

    /// Converts to `target` following the same table as `canConnect`. Returns nil when the
    /// conversion is not allowed.
    public func coerced(to target: PortType) -> Value? {
        if type == target { return self }
        if target == .json, type != .pulse { return self }
        switch (self, target) {
        case (.object, .array): return .array([])
        case let (.number(n), .bool): return .bool(n != 0)
        case let (.bool(b), .number): return .number(b ? 1 : 0)
        case let (.pulse(p), .bool): return .bool(p)
        case let (.pulse(p), .number): return .number(p ? 1 : 0)
        case let (.number(n), .point): return .point(Point2(x: n, y: n))
        case let (.number(n), .size): return .size(Size2(width: n, height: n))
        case let (.point(p), .size): return .size(Size2(width: p.x, height: p.y))
        case let (.size(s), .point): return .point(Point2(x: s.width, y: s.height))
        case let (.number(n), .text): return .text(Value.format(n))
        case let (.bool(b), .text): return .text(b ? "true" : "false")
        default: return nil
        }
    }

    /// The closest value of `target`, for data whose type is only known when it arrives
    /// (array items). Unlike `coerced`, text is read as a number, boolean or color.
    public func converted(to target: PortType) -> Value {
        if let direct = coerced(to: target) { return direct }
        if target == .text, case .object = self { return .text(summary) }
        if case let .text(text) = self {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            switch target {
            case .number: if let number = Double(trimmed), number.isFinite { return .number(number) }
            case .bool: return .bool(["true", "yes", "on", "1"].contains(trimmed.lowercased()))
            case .color: if let color = ColorValue(hex: trimmed) { return .color(color) }
            default: break
            }
        }
        if target == .array, case .array = self { return self }
        if target == .text, type != .array { return .text(summary) }
        return Value.defaultValue(for: target)
    }

    // MARK: Accessors (with coercion; fall back to a neutral value)

    public var numberValue: Double {
        if case let .number(n)? = coerced(to: .number) { return n }
        return 0
    }

    public var boolValue: Bool {
        if case let .bool(b)? = coerced(to: .bool) { return b }
        return false
    }

    /// Whether every number in it is finite, so it can be drawn and written as JSON.
    public var isFinite: Bool {
        switch self {
        case .number(let n): n.isFinite
        case .point(let p): p.x.isFinite && p.y.isFinite
        case .size(let s): s.width.isFinite && s.height.isFinite
        case .color(let c): c.red.isFinite && c.green.isFinite && c.blue.isFinite && c.alpha.isFinite
        case .array(let items): items.allSatisfy(\.isFinite)
        case .object(let fields): fields.values.allSatisfy(\.isFinite)
        case .bool, .pulse, .text: true
        }
    }

    public var pulseValue: Bool {
        if case let .pulse(p) = self { return p }
        return false
    }

    public var textValue: String {
        if case let .text(t)? = coerced(to: .text) { return t }
        return ""
    }

    public var colorValue: ColorValue {
        if case let .color(c) = self { return c }
        return .black
    }

    public var pointValue: Point2 {
        if case let .point(p)? = coerced(to: .point) { return p }
        return .zero
    }

    public var arrayValue: [Value] {
        if case let .array(items) = self { return items }
        return []
    }

    public var sizeValue: Size2 {
        if case let .size(s)? = coerced(to: .size) { return s }
        return .zero
    }

    // MARK: Interpolation

    /// Linear interpolation, unclamped so spring overshoot carries through.
    /// Types without a meaningful midpoint switch at `t >= 0.5`.
    public static func lerp(_ a: Value, _ b: Value, _ t: Double) -> Value {
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        switch (a, b) {
        case let (.number(x), .number(y)):
            return .number(mix(x, y))
        case let (.point(p), .point(q)):
            return .point(Point2(x: mix(p.x, q.x), y: mix(p.y, q.y)))
        case let (.size(s), .size(u)):
            return .size(Size2(width: mix(s.width, u.width), height: mix(s.height, u.height)))
        case let (.color(c), .color(d)):
            return .color(ColorValue(
                red: mix(c.red, d.red),
                green: mix(c.green, d.green),
                blue: mix(c.blue, d.blue),
                alpha: mix(c.alpha, d.alpha)
            ))
        default:
            return t >= 0.5 ? b : a
        }
    }

    // MARK: Display

    public static func format(_ n: Double) -> String {
        if n.isNaN || n.isInfinite { return "0" }
        if n == n.rounded(), abs(n) < 1e9 { return String(Int(n)) }
        var text = String(format: "%.2f", n)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Short text for showing a live value on a port.
    public var summary: String {
        switch self {
        case let .number(n): Value.format(n)
        case let .bool(b): b ? "On" : "Off"
        case let .pulse(p): p ? "Pulse" : "–"
        case let .text(t): t
        case let .color(c): c.hex
        case let .point(p): "\(Value.format(p.x)), \(Value.format(p.y))"
        case let .size(s): "\(Value.format(s.width)) × \(Value.format(s.height))"
        case let .array(items): items.count == 1 ? "1 item" : "\(items.count) items"
        case let .object(fields): fields.count == 1 ? "{1 key}" : "{\(fields.count) keys}"
        }
    }
}

// MARK: - JSON data

extension Double {
    /// This number, or the nearest finite one: infinity becomes the largest number there
    /// is (keeping its sign) and not-a-number becomes 0. For arithmetic that can overflow,
    /// whose result must still be drawn and saved.
    public var clampedFinite: Double {
        if isNaN { return 0 }
        return Swift.min(Swift.max(self, -Double.greatestFiniteMagnitude), Double.greatestFiniteMagnitude)
    }

    /// This number as a whole one. Unlike `Int(_:)`, which stops the program on a number
    /// that is too large or not a number at all, this gives the nearest whole number there is.
    public var whole: Int {
        guard isFinite else { return 0 }
        return Int(Swift.min(Swift.max(rounded(), -1e15), 1e15))
    }
}

extension Value {
    /// Reads JSON text into values: objects, arrays, text, numbers and booleans. nil when
    /// the text is not JSON.
    public static func parseJSON(_ data: Data) -> Value? {
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return fromJSON(parsed)
    }

    public static func parseJSON(_ text: String) -> Value? { parseJSON(Data(text.utf8)) }

    private static func fromJSON(_ any: Any) -> Value {
        switch any {
        case let dictionary as [String: Any]:
            return .object(dictionary.mapValues(fromJSON))
        case let list as [Any]:
            return .array(list.map(fromJSON))
        case let string as String:
            return .text(string)
        case let number as NSNumber:
            // JSON true/false arrive as a boolean-typed NSNumber.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            // A number too large for a Double ("1e309") is read as infinity.
            return .number(number.doubleValue.clampedFinite)
        default:
            return .text("")
        }
    }

    /// The value at a path such as `items.0.name`: object keys and array positions
    /// separated by dots. An empty path is the value itself.
    public func value(atPath path: String) -> Value? {
        var current = self
        for part in path.split(separator: ".").map(String.init) {
            switch current {
            case let .object(fields):
                guard let next = fields[part] else { return nil }
                current = next
            case let .array(items):
                guard let index = Int(part), items.indices.contains(index) else { return nil }
                current = items[index]
            default:
                return nil
            }
        }
        return current
    }
}

// MARK: - Codable

extension Value: Codable {
    private enum CodingKeys: String, CodingKey { case type, value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(PortType.self, forKey: .type)
        switch type {
        case .number: self = .number(try container.decode(Double.self, forKey: .value))
        case .bool: self = .bool(try container.decode(Bool.self, forKey: .value))
        case .pulse: self = .pulse(false)
        case .text: self = .text(try container.decode(String.self, forKey: .value))
        case .color: self = .color(try container.decode(ColorValue.self, forKey: .value))
        case .point: self = .point(try container.decode(Point2.self, forKey: .value))
        case .size: self = .size(try container.decode(Size2.self, forKey: .value))
        case .array: self = .array(try container.decode([Value].self, forKey: .value))
        case .json: self = .object(try container.decode([String: Value].self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        switch self {
        case let .number(n): try container.encode(n, forKey: .value)
        case let .bool(b): try container.encode(b, forKey: .value)
        case .pulse: break
        case let .text(t): try container.encode(t, forKey: .value)
        case let .color(c): try container.encode(c, forKey: .value)
        case let .point(p): try container.encode(p, forKey: .value)
        case let .size(s): try container.encode(s, forKey: .value)
        case let .array(items): try container.encode(items, forKey: .value)
        case let .object(fields): try container.encode(fields, forKey: .value)
        }
    }
}
