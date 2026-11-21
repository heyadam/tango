import Foundation

/// What makes a view a shader view: Metal source that draws it, and the values of the
/// inputs that source declares. The view is drawn as usual (its fill, the views in it) into
/// a picture, and the shader decides every pixel from that picture, the time and its inputs.
public struct ShaderUse: Codable, Hashable, Sendable {
    public var source: String
    /// Values for the inputs the source declares, keyed by name. Missing ones use the
    /// value the source gives.
    public var inputs: [String: Value]

    /// The code that last arrived on the Code input by cable, when it was not the view's
    /// own. It is remembered so that the inputs it declares are ports of the patch, and
    /// cables into them are kept, whether or not the prototype is running. The app writes
    /// it; nothing is drawn from it.
    public var arriving: String?

    public init(source: String, inputs: [String: Value] = [:], arriving: String? = nil) {
        self.source = source
        self.inputs = inputs
        self.arriving = arriving
    }

    /// A shader's inputs are ports on its view's patch. Their ids carry this prefix, so an
    /// input called `opacity` is not taken for the view's own.
    public static let portPrefix = "shader."

    public static func portID(_ name: String) -> String { portPrefix + name }

    /// The input of a shader view's patch that is its code. Clicking it opens the code; a
    /// text cable into it replaces the code while the prototype runs.
    public static let codePort = "shaderCode"

    /// The input a port id on a view's patch names, or nil when it is not a shader input.
    public static func inputName(port id: String) -> String? {
        id.hasPrefix(portPrefix) ? String(id.dropFirst(portPrefix.count)) : nil
    }

    /// How many inputs the source declares: the members of its `Inputs` struct. Only for
    /// finding room for the view's patch; reading the inputs themselves is `ShaderSource`'s.
    public var inputCount: Int {
        Set(ShaderUse.memberNames(in: source) + (arriving.map(ShaderUse.memberNames) ?? [])).count
    }

    private static func memberNames(in source: String) -> [String] {
        let plain = source
            .replacingOccurrences(of: #"//[^\n]*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        guard let open = plain.range(of: #"\bstruct\s+Inputs\s*\{"#, options: .regularExpression),
              let close = plain[open.upperBound...].firstIndex(of: "}") else { return [] }
        return plain[open.upperBound..<close].split(separator: ";").compactMap { member in
            let declaration = member.split(separator: "=").first ?? member
            return declaration.split(whereSeparator: { $0.isWhitespace }).last.map(String.init)
        }
    }

    /// What a new shader view starts with.
    public static let template = """
    // Inputs become ports on this view's patch. The value after = is where each starts.
    // float is a number, float2 a point, float3 and float4 a color, bool a switch.
    struct Inputs {
        float speed = 1;
        float4 tint = float4(0.35, 0.5, 1, 1);
    };

    // Runs for every pixel and returns its color (red, green, blue, alpha).
    //   frame.position  this pixel, in points from the view's top left
    //   frame.size      the view's size in points
    //   frame.uv        position / size, 0 to 1
    //   frame.time      seconds the prototype has run; using it redraws every frame
    //   content(frame, point)  the color of the views inside this one at a point
    float4 shader(Frame frame, Inputs in) {
        float wave = 0.5 + 0.5 * sin(frame.uv.x * 6 + frame.uv.y * 4 + frame.time * in.speed);
        float4 glow = float4(mix(in.tint.rgb, float3(1), wave * 0.6), 1);
        float4 inside = content(frame, frame.position);
        return mix(glow, inside, inside.a);
    }
    """
}

extension Document {
    /// Forgets the code that arrived on a shader view's Code input once no cable goes into
    /// it any more, so the patch is left with the inputs of the view's own code.
    public mutating func forgetUncabledShaderCode() {
        func settle(root: inout Layer, graph: Graph) {
            for layer in root.flattened where layer.shader?.arriving != nil {
                let cabled = graph.viewNode(layer: layer.id).map {
                    graph.connection(into: PortRef(node: $0.id, port: ShaderUse.codePort)) != nil
                } ?? false
                if !cabled { root.update(layer.id) { $0.shader?.arriving = nil } }
            }
        }
        settle(root: &screen, graph: graph)
        for index in components.indices { settle(root: &components[index].root, graph: components[index].graph) }
    }
}
