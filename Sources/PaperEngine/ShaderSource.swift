import Foundation
import PaperModel
import Synchronization

/// Reads the Metal source of a shader view: which inputs it declares, whether it moves by
/// itself, and the text that is handed to the Metal compiler. Nothing here touches the GPU;
/// compiling and drawing are `PaperRender`'s.
///
///     struct Inputs { float speed = 1; float4 tint = float4(1, 0.5, 0, 1); };
///     float4 shader(Frame frame, Inputs in) { return in.tint; }
///
/// Each member of `Inputs` is a port on the view's patch: `float` and `int` a number,
/// `float2` a point, `float3` and `float4` a color, `bool` a switch. The value after `=`
/// is where it starts.
public enum ShaderSource {
    /// How a declared input is laid out for the GPU.
    public enum Kind: String, Sendable, Hashable {
        case float, float2, float3, float4, int, bool

        public var portType: PortType {
            switch self {
            case .float, .int: .number
            case .float2: .point
            case .float3, .float4: .color
            case .bool: .bool
            }
        }
    }

    public struct Uniform: Sendable, Hashable {
        public let name: String
        public let kind: Kind
        public let defaultValue: Value

        public var port: Port {
            Port(id: ShaderUse.portID(name), name: Script.title(name), type: kind.portType, defaultValue: defaultValue)
        }
    }

    /// What a shader declares, or why it could not be read.
    public struct Interface: Sendable, Hashable {
        public var uniforms: [Uniform] = []
        /// Whether the source reads the time, and so wants a frame every tick.
        public var animates = false
        /// Whether the source reads what is behind the view (`behind`), which takes a
        /// picture of it on every frame that is drawn.
        public var readsBehind = false
        /// Whether the source has an `Inputs` struct of its own.
        public var declaresInputs = false
        public var error: String?
        /// The source as the compiler gets it: comments and starting values blanked out,
        /// every line where it was.
        public var compilable = ""

        public var ports: [Port] { uniforms.map(\.port) }
    }

    private static let cache = Mutex<[String: Interface]>([:])

    public static func interface(of source: String) -> Interface {
        if let known = cache.withLock({ $0[source] }) { return known }
        let found = read(source)
        cache.withLock { cache in
            if cache.count > 200 { cache.removeAll() }
            cache[source] = found
        }
        return found
    }

    /// The inputs of a shader view: those its own code declares, then any that only the
    /// code arriving by cable declares. Where both declare a name, the view's own counts.
    public static func uniforms(of source: String, arriving: String?) -> [Uniform] {
        var result = interface(of: source).uniforms
        guard let arriving else { return result }
        for uniform in interface(of: arriving).uniforms where !result.contains(where: { $0.name == uniform.name }) {
            result.append(uniform)
        }
        return result
    }

    public static func uniforms(of shader: ShaderUse) -> [Uniform] { uniforms(of: shader.source, arriving: shader.arriving) }

    /// The value a shader input has: the cabled one, else the stored one, else the source's.
    public static func value(of uniform: Uniform, stored: [String: Value], driven: [String: Value] = [:]) -> Value {
        let type = uniform.kind.portType
        return driven[uniform.name]?.coerced(to: type) ?? stored[uniform.name]?.coerced(to: type) ?? uniform.defaultValue
    }

    // MARK: Reading

    private static func read(_ source: String) -> Interface {
        var result = Interface()
        var text = blankingComments(Array(source))
        let plain = String(text)

        if let body = inputsBody(in: text) {
            result.declaresInputs = true
            var names: Set<String> = []
            var start = body.lowerBound
            for index in body where text[index] == ";" {
                let member = start..<index
                start = index + 1
                let declaration = String(text[member]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !declaration.isEmpty else { continue }
                guard let uniform = uniform(from: declaration) else {
                    result.error = result.error ?? "Inputs cannot hold \"\(declaration.split(separator: "\n").first ?? "")\". "
                        + "Use float, float2, float3, float4, int or bool, one per line, with a starting value after =."
                    continue
                }
                if !names.insert(uniform.name).inserted {
                    result.error = result.error ?? "Inputs has two members named \(uniform.name)."
                    continue
                }
                result.uniforms.append(uniform)
                // The compiler does not get the starting value.
                if let equals = member.first(where: { text[$0] == "=" }) {
                    for position in equals..<index where text[position] != "\n" { text[position] = " " }
                }
            }
            if result.error == nil, result.uniforms.isEmpty {
                result.error = "Inputs is empty. Give it a member, or leave the struct out."
            }
        }
        if result.error == nil, plain.range(of: #"\bshader\s*\("#, options: .regularExpression) == nil {
            result.error = "The shader needs a function: float4 shader(Frame frame, Inputs in)."
        }
        result.animates = plain.range(of: #"\btime\b"#, options: .regularExpression) != nil
        result.readsBehind = plain.range(of: #"\bbehind\s*\("#, options: .regularExpression) != nil
        result.compilable = String(text)
        return result
    }

    /// The source with every comment turned into spaces, so positions and lines stay.
    private static func blankingComments(_ text: [Character]) -> [Character] {
        var result = text
        var index = 0
        while index < text.count {
            if text[index] == "/", index + 1 < text.count, text[index + 1] == "/" {
                while index < text.count, text[index] != "\n" {
                    result[index] = " "
                    index += 1
                }
            } else if text[index] == "/", index + 1 < text.count, text[index + 1] == "*" {
                while index < text.count, !(text[index] == "*" && index + 1 < text.count && text[index + 1] == "/") {
                    if text[index] != "\n" { result[index] = " " }
                    index += 1
                }
                for end in index..<min(index + 2, text.count) { result[end] = " " }
                index += 2
            } else {
                index += 1
            }
        }
        return result
    }

    /// Where the members of `struct Inputs { … }` are.
    private static func inputsBody(in text: [Character]) -> Range<Int>? {
        let plain = String(text)
        guard let match = plain.range(of: #"\bstruct\s+Inputs\s*\{"#, options: .regularExpression) else { return nil }
        let open = plain.distance(from: plain.startIndex, to: match.upperBound)
        guard let close = text[open...].firstIndex(of: "}") else { return nil }
        return open..<close
    }

    private static func uniform(from declaration: String) -> Uniform? {
        let pattern = #"^(float[234]?|int|bool)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:=\s*([\s\S]+))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: declaration, range: NSRange(declaration.startIndex..., in: declaration)),
              let kindRange = Range(match.range(at: 1), in: declaration),
              let nameRange = Range(match.range(at: 2), in: declaration),
              let kind = Kind(rawValue: String(declaration[kindRange]))
        else { return nil }
        let start = Range(match.range(at: 3), in: declaration).map { String(declaration[$0]) }
        guard let value = startingValue(start, as: kind) else { return nil }
        return Uniform(name: String(declaration[nameRange]), kind: kind, defaultValue: value)
    }

    /// The value written after `=`: a number, true or false, or `floatN(…)`.
    private static func startingValue(_ text: String?, as kind: Kind) -> Value? {
        func number(_ text: String) -> Double? {
            var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasSuffix("f") || trimmed.hasSuffix("F") { trimmed.removeLast() }
            guard let value = Double(trimmed), value.isFinite else { return nil }
            return value
        }
        var parts: [Double] = []
        if let text {
            var inner = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let open = inner.firstIndex(of: "("), inner.hasSuffix(")") {
                guard Kind(rawValue: String(inner[..<open]).trimmingCharacters(in: .whitespaces)) != nil else { return nil }
                inner = String(inner[inner.index(after: open)..<inner.index(before: inner.endIndex)])
            }
            if kind == .bool, inner == "true" || inner == "false" { return .bool(inner == "true") }
            for piece in inner.split(separator: ",") {
                guard let value = number(String(piece)) else { return nil }
                parts.append(value)
            }
            guard !parts.isEmpty else { return nil }
        }
        func part(_ index: Int, or fallback: Double) -> Double {
            if parts.count == 1 { return parts[0] }
            return index < parts.count ? parts[index] : fallback
        }
        switch kind {
        case .float: return .number(part(0, or: 0))
        case .int: return .number(part(0, or: 0).rounded())
        case .bool: return .bool(part(0, or: 0) != 0)
        case .float2: return .point(Point2(x: part(0, or: 0), y: part(1, or: 0)))
        case .float3, .float4:
            if parts.isEmpty { return .color(.white) }
            return .color(ColorValue(
                red: part(0, or: 0), green: part(1, or: 0), blue: part(2, or: 0),
                alpha: kind == .float3 || parts.count < 4 ? 1 : parts[3]
            ))
        }
    }
}
