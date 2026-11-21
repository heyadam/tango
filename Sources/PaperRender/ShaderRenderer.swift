import CoreVideo
import Foundation
import IOSurface
import Metal
import PaperEngine
import PaperModel
import QuartzCore

/// Compiles the Metal source of shader views and keeps what it compiled.
///
/// A person writes one function, `float4 shader(Frame frame, Inputs in)`, and optionally a
/// struct `Inputs`. Everything around it (the vertex stage, `Frame`, `content`) is added
/// here, with a `#line` so the compiler's messages name lines of what the person wrote.
public final class ShaderCompiler {
    /// nil on a Mac with no GPU to ask, where shader views draw what is in them unchanged.
    public static let shared: ShaderCompiler? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return ShaderCompiler(device: device)
    }()

    let device: MTLDevice
    let queue: MTLCommandQueue

    /// One compiled shader: the pipeline and where each input goes in its buffer.
    final class Program {
        let pipeline: MTLRenderPipelineState
        let uniforms: [(uniform: ShaderSource.Uniform, offset: Int)]
        let inputsLength: Int

        init(pipeline: MTLRenderPipelineState, uniforms: [(uniform: ShaderSource.Uniform, offset: Int)], inputsLength: Int) {
            self.pipeline = pipeline
            self.uniforms = uniforms
            self.inputsLength = inputsLength
        }
    }

    private enum Outcome {
        case program(Program)
        case failure(String)
    }

    private var compiled: [String: Outcome] = [:]

    private init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
    }

    /// Why a shader cannot be drawn, in words for the person who wrote it, or nil when it
    /// can. Also nil where there is no GPU to compile with.
    public static func error(in source: String) -> String? {
        if let problem = ShaderSource.interface(of: source).error { return problem }
        guard let shared else { return nil }
        if case let .failure(message) = shared.outcome(for: source) { return message }
        return nil
    }

    /// A texture holding a picture drawn into a bitmap of 32-bit BGRA, as `LayerRenderer` makes them.
    func texture(from context: CGContext) -> MTLTexture? {
        guard let data = context.data, context.width >= 1, context.height >= 1 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: context.width, height: context.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(
            region: MTLRegionMake2D(0, 0, context.width, context.height), mipmapLevel: 0,
            withBytes: data, bytesPerRow: context.bytesPerRow
        )
        return texture
    }

    func program(for source: String) -> Program? {
        if case let .program(program) = outcome(for: source) { return program }
        return nil
    }

    private func outcome(for source: String) -> Outcome {
        if let known = compiled[source] { return known }
        let result = compile(source)
        if compiled.count > 100 { compiled.removeAll() }
        compiled[source] = result
        return result
    }

    private func compile(_ source: String) -> Outcome {
        let interface = ShaderSource.interface(of: source)
        if let problem = interface.error { return .failure(problem) }
        let text = ShaderCompiler.prelude
            + (interface.declaresInputs ? "" : "struct Inputs { float paper_unused; };\n")
            + "#line 1\n" + interface.compilable + "\n" + ShaderCompiler.wrapper
        do {
            let library = try device.makeLibrary(source: text, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "paper_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "paper_fragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            var reflection: MTLRenderPipelineReflection?
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor, options: [.bindingInfo, .bufferTypeInfo], reflection: &reflection)
            var offsets: [String: Int] = [:]
            var length = 16
            for binding in reflection?.fragmentBindings ?? [] where binding.index == 1 {
                guard let buffer = binding as? MTLBufferBinding else { continue }
                length = max(buffer.bufferDataSize, 16)
                for member in buffer.bufferStructType?.members ?? [] { offsets[member.name] = member.offset }
            }
            let placed = interface.uniforms.compactMap { uniform in offsets[uniform.name].map { (uniform: uniform, offset: $0) } }
            return .program(Program(pipeline: pipeline, uniforms: placed, inputsLength: length))
        } catch {
            return .failure(ShaderCompiler.message(from: error, lines: source.split(separator: "\n", omittingEmptySubsequences: false).count))
        }
    }

    /// The first thing the Metal compiler objected to, as "Line 12: …".
    static func message(from error: Error, lines: Int) -> String {
        let text = (error as NSError).localizedDescription
        let pattern = #"program_source:(\d+):\d+: error: ([^\n]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let lineRange = Range(match.range(at: 1), in: text), let messageRange = Range(match.range(at: 2), in: text),
              let line = Int(text[lineRange])
        else { return text.split(separator: "\n").first.map(String.init) ?? "The shader does not compile." }
        // Past the end of what was written: the call into it did not fit.
        if line > lines { return "The shader needs this function: float4 shader(Frame frame, Inputs in). (\(text[messageRange]))" }
        return "Line \(line): \(text[messageRange])"
    }

    static let prelude = """
    #include <metal_stdlib>
    using namespace metal;

    struct Frame {
        float2 position;
        float2 size;
        float2 uv;
        float time;
        float scale;
        texture2d<float> paper_content;
        texture2d<float> paper_behind;
        float paper_margin;
    };

    static inline float4 content(Frame frame, float2 point) {
        constexpr sampler paper_sampler(filter::linear, address::clamp_to_zero);
        float2 uv = point / max(frame.size, float2(0.0001));
        float4 color = frame.paper_content.sample(paper_sampler, float2(uv.x, 1 - uv.y));
        return color.a > 0 ? float4(color.rgb / color.a, color.a) : float4(0);
    }

    // What is drawn behind the view, at a point in the view's own coordinates. A point a
    // little outside the view still has an answer, so glass can bend what is beside it.
    static inline float4 behind(Frame frame, float2 point) {
        constexpr sampler paper_sampler(filter::linear, address::clamp_to_edge);
        float2 whole = frame.size + float2(frame.paper_margin * 2);
        float2 uv = (point + float2(frame.paper_margin)) / max(whole, float2(0.0001));
        // The picture is the other way up from the view, row for row.
        float4 color = frame.paper_behind.sample(paper_sampler, float2(uv.x, 1 - uv.y));
        return color.a > 0 ? float4(color.rgb / color.a, color.a) : float4(0);
    }

    """

    static let wrapper = """
    struct PaperVertex { float4 position [[position]]; float2 uv; };
    struct PaperFrame { float2 size; float time; float scale; float margin; float unused; };

    vertex PaperVertex paper_vertex(uint id [[vertex_id]]) {
        float2 corner = float2((id << 1) & 2, id & 2);
        PaperVertex out;
        out.position = float4(corner.x * 2 - 1, 1 - corner.y * 2, 0, 1);
        out.uv = corner;
        return out;
    }

    fragment float4 paper_fragment(PaperVertex vertex_in [[stage_in]],
                                   constant PaperFrame &paper_frame [[buffer(0)]],
                                   constant Inputs &paper_inputs [[buffer(1)]],
                                   texture2d<float> paper_texture [[texture(0)]],
                                   texture2d<float> paper_behind [[texture(1)]]) {
        Frame frame;
        frame.uv = vertex_in.uv;
        frame.size = paper_frame.size;
        frame.position = vertex_in.uv * paper_frame.size;
        frame.time = paper_frame.time;
        frame.scale = paper_frame.scale;
        frame.paper_content = paper_texture;
        frame.paper_behind = paper_behind;
        frame.paper_margin = paper_frame.margin;
        float4 color = shader(frame, paper_inputs);
        float alpha = saturate(color.a);
        return float4(saturate(color.rgb) * alpha, alpha);
    }
    """

    /// What a shader view draws with while its own source does not compile and it has
    /// nothing earlier to fall back on: the views in it, unchanged.
    static let passThrough = "float4 shader(Frame frame, Inputs in) { return content(frame, frame.position); }"
}

/// The pictures of one shader view: what is in it, drawn by Core Animation into a texture,
/// and the shader's result, which the view's layer on screen shows.
final class ShaderSurface {
    /// Shown by the view's own layer. Its contents are the shader's result.
    let display = CALayer()
    /// Where the views inside go. It is not on screen: it is drawn into `contentTexture`.
    let content = CALayer()
    private let root = CALayer()

    private let compiler: ShaderCompiler
    private var renderer: CARenderer?
    private var contentTexture: MTLTexture?
    /// Two results, drawn into in turn: a layer shows a new picture when it is given
    /// another surface, not when the one it has changes.
    private var outputs: [(surface: IOSurface, texture: MTLTexture)] = []
    private var turn = 0
    private var pixels = (width: 0, height: 0)
    /// The last shader that compiled, kept drawing while the source is being changed.
    private var working: ShaderCompiler.Program?

    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    /// The most pixels a shader view is drawn with along one side.
    static let limit = 4096.0

    init(compiler: ShaderCompiler) {
        self.compiler = compiler
        root.isGeometryFlipped = true
        root.anchorPoint = .zero
        content.anchorPoint = .zero
        root.addSublayer(content)
        display.anchorPoint = .zero
        display.contentsGravity = .resize
        display.masksToBounds = true
        display.cornerCurve = .continuous
    }

    /// Draws what is in `content` and runs the shader over it. `size` is in points.
    /// `behind` is a picture of what is behind the view, reaching `margin` points past it
    /// on every side, for a shader that reads it.
    func draw(_ shader: ResolvedShader, size: CGSize, scale: CGFloat, behind: MTLTexture? = nil, margin: CGFloat = 0) {
        let scale = min(max(scale.isFinite ? scale : 1, 0.25), 8)
        var width = (size.width * scale).rounded(.up), height = (size.height * scale).rounded(.up)
        guard width.isFinite, height.isFinite, width >= 1, height >= 1 else {
            display.contents = nil
            return
        }
        width = min(width, ShaderSurface.limit)
        height = min(height, ShaderSurface.limit)
        guard resize(width: Int(width), height: Int(height)), let renderer, let contentTexture, outputs.count == 2 else { return }
        turn = 1 - turn
        let output = outputs[turn]

        if let program = compiler.program(for: shader.source) { working = program }
        guard let program = working ?? compiler.program(for: ShaderCompiler.passThrough) else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        content.bounds = CGRect(origin: .zero, size: size)
        content.setAffineTransform(CGAffineTransform(scaleX: width / max(size.width, 0.0001), y: height / max(size.height, 0.0001)))
        CATransaction.commit()
        CATransaction.flush()

        // Core Animation draws on the same queue, so its picture is ready when ours reads it.
        clear(contentTexture)
        renderer.bounds = root.bounds
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(root.bounds)
        renderer.render()
        renderer.endFrame()

        var frame: [Float] = [Float(size.width), Float(size.height), Float(shader.time), Float(width / max(size.width, 0.0001)), Float(margin), 0]
        var inputs = [UInt8](repeating: 0, count: program.inputsLength)
        for (uniform, offset) in program.uniforms {
            ShaderSurface.write(ShaderSource.value(of: uniform, stored: shader.values), as: uniform.kind, into: &inputs, at: offset)
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let buffer = compiler.queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(program.pipeline)
        encoder.setFragmentBytes(&frame, length: frame.count * MemoryLayout<Float>.stride, index: 0)
        encoder.setFragmentBytes(&inputs, length: inputs.count, index: 1)
        encoder.setFragmentTexture(contentTexture, index: 0)
        // A shader that reads nothing behind it is still given a texture to name.
        encoder.setFragmentTexture(behind ?? contentTexture, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.commit()
        // Pictures and recordings are taken right after a frame, so the result has to be there.
        buffer.waitUntilCompleted()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        display.contents = output.surface
        CATransaction.commit()
    }

    private func clear(_ texture: MTLTexture) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let buffer = compiler.queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        buffer.commit()
    }

    private func resize(width: Int, height: Int) -> Bool {
        if pixels == (width, height), renderer != nil { return true }
        guard let made = makeTexture(width: width, height: height), let first = makeTexture(width: width, height: height),
              let second = makeTexture(width: width, height: height) else { return false }
        contentTexture = made.texture
        outputs = [first, second]
        pixels = (width, height)
        let renderer = CARenderer(mtlTexture: made.texture, options: [
            kCARendererColorSpace: ShaderSurface.colorSpace,
            kCARendererMetalCommandQueue: compiler.queue,
        ])
        renderer.layer = root
        self.renderer = renderer
        return true
    }

    private func makeTexture(width: Int, height: Int) -> (surface: IOSurface, texture: MTLTexture)? {
        guard let surface = IOSurface(properties: [
            .width: width, .height: height, .bytesPerElement: 4, .pixelFormat: kCVPixelFormatType_32BGRA,
        ]) else { return nil }
        if let space = ShaderSurface.colorSpace.copyPropertyList() {
            IOSurfaceSetValue(unsafeBitCast(surface, to: IOSurfaceRef.self), kIOSurfaceColorSpace, space)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = compiler.device.makeTexture(
            descriptor: descriptor, iosurface: unsafeBitCast(surface, to: IOSurfaceRef.self), plane: 0
        ) else { return nil }
        return (surface, texture)
    }

    private static func write(_ value: Value, as kind: ShaderSource.Kind, into bytes: inout [UInt8], at offset: Int) {
        func put(_ numbers: [Double]) {
            for (index, number) in numbers.enumerated() {
                var float = Float(number.isFinite ? number : 0)
                let start = offset + index * 4
                guard start + 4 <= bytes.count else { return }
                withUnsafeBytes(of: &float) { bytes.replaceSubrange(start..<start + 4, with: $0) }
            }
        }
        switch kind {
        case .float: put([value.numberValue])
        case .float2: put([value.pointValue.x, value.pointValue.y])
        case .float3:
            let color = value.colorValue
            put([color.red, color.green, color.blue])
        case .float4:
            let color = value.colorValue
            put([color.red, color.green, color.blue, color.alpha])
        case .int:
            var whole = Int32(value.numberValue.whole)
            guard offset + 4 <= bytes.count else { return }
            withUnsafeBytes(of: &whole) { bytes.replaceSubrange(offset..<offset + 4, with: $0) }
        case .bool:
            guard offset < bytes.count else { return }
            bytes[offset] = value.boolValue ? 1 : 0
        }
    }
}
