import CoreVideo
import Foundation
import IOSurface
import Metal
import PaperEngine
import PaperModel
import QuartzCore
import simd

/// What draws scene views: the pipeline, the shapes as the GPU holds them, and the looks
/// of the surroundings. One for the device, made the first time a scene is drawn.
///
/// A scene is drawn with depth and four samples a pixel: every object with one physically
/// based material (color, metalness, roughness), lit by one light and by its surroundings,
/// which are a function of direction rather than a picture, so nothing is shipped or loaded
/// for them and a mirror shows them as sharp as the view is large.
final class SceneRendering {
    /// nil where there is no GPU, or the pipeline could not be made: scene views are then
    /// ordinary views.
    static let shared: SceneRendering? = ShaderCompiler.shared.flatMap { SceneRendering(compiler: $0) }

    static let samples = 4

    let compiler: ShaderCompiler
    let pipeline: MTLRenderPipelineState
    let depth: MTLDepthStencilState
    let sampler: MTLSamplerState
    /// What an object with no picture of its own is given to read: white.
    let white: MTLTexture
    private var shapes: [SceneObject.Shape: SceneGeometry] = [:]

    private init?(compiler: ShaderCompiler) {
        self.compiler = compiler
        let device = compiler.device
        do {
            let library = try device.makeLibrary(source: SceneRendering.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "scene_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "scene_fragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.depthAttachmentPixelFormat = .depth32Float
            descriptor.rasterSampleCount = SceneRendering.samples
            let vertex = MTLVertexDescriptor()
            vertex.attributes[0].format = .float3
            vertex.attributes[0].offset = 0
            vertex.attributes[1].format = .float3
            vertex.attributes[1].offset = 12
            vertex.attributes[2].format = .float2
            vertex.attributes[2].offset = 24
            vertex.layouts[0].stride = SceneGeometry.stride
            descriptor.vertexDescriptor = vertex
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            assertionFailure("The scene shader does not compile: \(error)")
            return nil
        }
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .repeat
        samplerDescriptor.tAddressMode = .repeat
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        guard let depth = device.makeDepthStencilState(descriptor: depthDescriptor),
              let sampler = device.makeSamplerState(descriptor: samplerDescriptor),
              let white = device.makeTexture(descriptor: textureDescriptor) else { return nil }
        var pixel: [UInt8] = [255, 255, 255, 255]
        white.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
        self.depth = depth
        self.sampler = sampler
        self.white = white
    }

    /// A shape made in code, as the GPU holds it; made once.
    func geometry(for shape: SceneObject.Shape) -> SceneGeometry? {
        if let known = shapes[shape] { return known }
        guard let mesh = SceneMesh.shape(shape), let made = SceneGeometry(mesh, device: compiler.device) else { return nil }
        shapes[shape] = made
        return made
    }

    // MARK: Surroundings

    /// What stands round a scene: a sky that runs from the horizon to overhead, a ground,
    /// and up to three lamps, each a soft glow round a direction.
    struct Surroundings {
        var zenith: SIMD3<Float>, horizon: SIMD3<Float>, ground: SIMD3<Float>
        /// Direction, color and how tight the glow is (larger is smaller and sharper).
        var lamps: [(direction: SIMD3<Float>, color: SIMD3<Float>, tightness: Float)]

        static func named(_ name: String) -> Surroundings {
            switch name.lowercased() {
            case "daylight":
                return Surroundings(
                    zenith: SIMD3(0.22, 0.42, 0.9), horizon: SIMD3(0.75, 0.85, 1), ground: SIMD3(0.3, 0.28, 0.25),
                    lamps: [(SIMD3(0.4, 0.8, 0.4), SIMD3(10, 9.5, 8.5), 200)]
                )
            case "sunset":
                return Surroundings(
                    zenith: SIMD3(0.15, 0.2, 0.45), horizon: SIMD3(1, 0.5, 0.25), ground: SIMD3(0.12, 0.08, 0.08),
                    lamps: [(SIMD3(0.7, 0.12, 0.5), SIMD3(12, 6, 2.5), 120), (SIMD3(-0.6, 0.5, -0.4), SIMD3(0.5, 0.6, 1.2), 10)]
                )
            case "night":
                return Surroundings(
                    zenith: SIMD3(0.01, 0.015, 0.04), horizon: SIMD3(0.04, 0.05, 0.09), ground: SIMD3(0.01, 0.01, 0.015),
                    lamps: [(SIMD3(-0.4, 0.6, 0.5), SIMD3(1.2, 1.4, 2), 150), (SIMD3(0.8, 0.1, -0.3), SIMD3(1.5, 0.8, 0.3), 25)]
                )
            default:
                // A studio: a large soft light above and to the left, a fill and a rim.
                return Surroundings(
                    zenith: SIMD3(0.72, 0.72, 0.76), horizon: SIMD3(0.5, 0.5, 0.52), ground: SIMD3(0.22, 0.22, 0.23),
                    lamps: [
                        (SIMD3(-0.5, 0.7, 0.6), SIMD3(6, 6, 6), 30), (SIMD3(0.8, 0.2, 0.5), SIMD3(2, 2, 2.1), 12),
                        (SIMD3(0, 0.5, -1), SIMD3(3, 3, 3), 20),
                    ]
                )
            }
        }
    }

    // MARK: What the shader is given

    /// Must match `SceneUniforms` in the source.
    struct SceneUniforms {
        var viewProjection = matrix_identity_float4x4
        var camera = SIMD4<Float>(repeating: 0)
        var lightDirection = SIMD4<Float>(repeating: 0)
        var lightColor = SIMD4<Float>(repeating: 0)
        var zenith = SIMD4<Float>(repeating: 0)
        var horizon = SIMD4<Float>(repeating: 0)
        var ground = SIMD4<Float>(repeating: 0)
        var lampDirection = (SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 0))
        var lampColor = (SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 0))
        /// x: exposure.
        var settings = SIMD4<Float>(repeating: 0)

        init(_ scene: SceneUse, aspect: Float) {
            viewProjection = SceneMath.projection(of: scene, aspect: aspect) * SceneMath.view(of: scene)
            let eye = SceneMath.cameraPosition(of: scene)
            camera = SIMD4(eye.x, eye.y, eye.z, 1)
            let toLight = SceneMath.direction(yaw: scene.number("lightYaw"), pitch: scene.number("lightPitch"))
            lightDirection = SIMD4(toLight.x, toLight.y, toLight.z, 0)
            let strength = SceneRendering.clamp(scene.number("lightIntensity"), 0, 1000)
            let tint = SceneRendering.linear(scene.value("lightColor").colorValue)
            lightColor = SIMD4(tint.x * strength, tint.y * strength, tint.z * strength, 0)
            let around = Surroundings.named(scene.value("environment").textValue)
            zenith = SIMD4(around.zenith, 0)
            horizon = SIMD4(around.horizon, 0)
            ground = SIMD4(around.ground, 0)
            func lamp(_ index: Int) -> (SIMD4<Float>, SIMD4<Float>) {
                guard index < around.lamps.count else { return (SIMD4(0, 1, 0, 1), SIMD4(repeating: 0)) }
                let lamp = around.lamps[index]
                return (SIMD4(simd_normalize(lamp.direction), lamp.tightness), SIMD4(lamp.color, 0))
            }
            (lampDirection.0, lampColor.0) = lamp(0)
            (lampDirection.1, lampColor.1) = lamp(1)
            (lampDirection.2, lampColor.2) = lamp(2)
            settings = SIMD4(SceneRendering.clamp(scene.number("exposure"), 0, 1000), 0, 0, 0)
        }
    }

    /// Must match `ObjectUniforms` in the source.
    struct ObjectUniforms {
        var model: simd_float4x4
        /// Takes normals from the object's space to the scene's.
        var normal: simd_float4x4
        /// Linear red, green, blue.
        var color: SIMD4<Float>
        /// x: metalness, y: roughness.
        var material: SIMD4<Float>
    }

    static func clamp(_ value: Double, _ low: Float, _ high: Float) -> Float {
        guard value.isFinite else { return low }
        return min(max(Float(value), low), high)
    }

    /// A stored color (sRGB) as the light it stands for.
    static func linear(_ color: ColorValue) -> SIMD3<Float> {
        func channel(_ value: Double) -> Float {
            let value = clamp(value, 0, 1)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return SIMD3(channel(color.red), channel(color.green), channel(color.blue))
    }

    // MARK: The shader

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct SceneUniforms {
        float4x4 viewProjection;
        float4 camera;
        float4 lightDirection;
        float4 lightColor;
        float4 zenith;
        float4 horizon;
        float4 ground;
        float4 lampDirection[3];
        float4 lampColor[3];
        float4 settings;
    };

    struct ObjectUniforms {
        float4x4 model;
        float4x4 normal;
        float4 color;
        float4 material;
    };

    struct SceneVertexIn {
        float3 position [[attribute(0)]];
        float3 normal [[attribute(1)]];
        float2 uv [[attribute(2)]];
    };

    struct SceneVertex {
        float4 position [[position]];
        float3 world;
        float3 normal;
        float2 uv;
    };

    vertex SceneVertex scene_vertex(SceneVertexIn in [[stage_in]],
                                    constant SceneUniforms &scene [[buffer(1)]],
                                    constant ObjectUniforms &object [[buffer(2)]]) {
        SceneVertex out;
        float4 world = object.model * float4(in.position, 1.0);
        out.position = scene.viewProjection * world;
        out.world = world.xyz;
        out.normal = (object.normal * float4(in.normal, 0.0)).xyz;
        out.uv = in.uv;
        return out;
    }

    // The light that comes from a direction: sky above, ground below, and the lamps. A rough
    // surface gathers light from all round its direction, so for it everything is blurred:
    // the horizon softens and each lamp spreads out and dims by as much as it spreads.
    static float3 scene_surroundings(constant SceneUniforms &scene, float3 direction, float roughness) {
        float up = direction.y;
        float soft = mix(0.02, 1.0, roughness);
        float3 sky = mix(scene.horizon.rgb, scene.zenith.rgb, pow(saturate(up), mix(0.45, 1.0, roughness)));
        float3 floor = mix(scene.horizon.rgb, scene.ground.rgb, pow(saturate(-up), mix(0.35, 1.0, roughness)));
        float3 color = mix(floor, sky, smoothstep(-soft, soft, up));
        for (int index = 0; index < 3; index++) {
            float tight = max(scene.lampDirection[index].w, 1.0);
            float wide = tight / (1.0 + tight * roughness * roughness * 0.5);
            float toward = dot(direction, scene.lampDirection[index].xyz);
            color += scene.lampColor[index].rgb * (wide / tight) * exp(wide * (toward - 1.0));
        }
        return color;
    }

    static float3 scene_tone(float3 color) {
        // ACES, fitted (Narkowicz), then the sRGB curve.
        color = saturate((color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14));
        float3 low = color * 12.92;
        float3 high = 1.055 * pow(color, float3(1.0 / 2.4)) - 0.055;
        return mix(low, high, step(float3(0.0031308), color));
    }

    fragment float4 scene_fragment(SceneVertex in [[stage_in]], bool front [[front_facing]],
                                   constant SceneUniforms &scene [[buffer(1)]],
                                   constant ObjectUniforms &object [[buffer(2)]],
                                   texture2d<float> picture [[texture(0)]],
                                   sampler pictureSampler [[sampler(0)]]) {
        float3 normal = normalize(in.normal);
        if (!front) { normal = -normal; }
        float3 toEye = normalize(scene.camera.xyz - in.world);
        float3 base = object.color.rgb * picture.sample(pictureSampler, in.uv).rgb;
        float metalness = saturate(object.material.x);
        float roughness = clamp(object.material.y, 0.045, 1.0);
        float3 mirror = mix(float3(0.04), base, metalness);
        float3 matte = base * (1.0 - metalness);
        float facing = max(dot(normal, toEye), 1e-4);

        // The one light, by Cook and Torrance with the GGX distribution.
        float3 toLight = normalize(scene.lightDirection.xyz);
        float lit = saturate(dot(normal, toLight));
        float3 direct = float3(0.0);
        if (lit > 0.0) {
            float3 half_ = normalize(toEye + toLight);
            float a = roughness * roughness, a2 = a * a;
            float nh = saturate(dot(normal, half_));
            float spread = nh * nh * (a2 - 1.0) + 1.0;
            float distribution = a2 / (M_PI_F * spread * spread);
            float visible = 0.5 / (lit * sqrt(facing * facing * (1.0 - a2) + a2) + facing * sqrt(lit * lit * (1.0 - a2) + a2));
            float3 fresnel = mirror + (1.0 - mirror) * pow(1.0 - saturate(dot(toEye, half_)), 5.0);
            direct = (matte / M_PI_F + distribution * visible * fresnel) * scene.lightColor.rgb * lit;
        }

        // The surroundings: what a matte surface gathers, and what a shiny one mirrors,
        // weighed by how much such a surface reflects at this angle (Karis's fit).
        float4 fit = roughness * float4(-1.0, -0.0275, -0.572, 0.022) + float4(1.0, 0.0425, 1.04, -0.04);
        float bend = min(fit.x * fit.x, exp2(-9.28 * facing)) * fit.x + fit.y;
        float2 weigh = float2(-1.04, 1.04) * bend + fit.zw;
        float3 gathered = scene_surroundings(scene, normal, 1.0) * matte;
        float3 mirrored = scene_surroundings(scene, reflect(-toEye, normal), roughness) * (mirror * weigh.x + weigh.y);

        float3 color = (direct + gathered + mirrored) * scene.settings.x;
        return float4(scene_tone(color), 1.0);
    }
    """
}

/// A mesh as the GPU holds it: points with their normals and picture coordinates, and the
/// triangles between them.
final class SceneGeometry {
    /// Three numbers of position, three of normal, two of picture coordinates.
    static let stride = 32

    let vertices: MTLBuffer
    let indices: MTLBuffer
    let indexCount: Int

    init?(_ mesh: SceneMesh, device: MTLDevice) {
        guard mesh.isSound, !mesh.indices.isEmpty else { return nil }
        var packed = [Float](repeating: 0, count: mesh.positions.count * 8)
        for index in mesh.positions.indices {
            let position = mesh.positions[index], normal = mesh.normals[index], uv = mesh.uvs[index]
            packed.replaceSubrange(index * 8..<index * 8 + 8, with: [position.x, position.y, position.z, normal.x, normal.y, normal.z, uv.x, uv.y])
        }
        guard let vertices = device.makeBuffer(bytes: packed, length: packed.count * MemoryLayout<Float>.stride),
              let indices = device.makeBuffer(bytes: mesh.indices, length: mesh.indices.count * MemoryLayout<UInt32>.stride)
        else { return nil }
        self.vertices = vertices
        self.indices = indices
        indexCount = mesh.indices.count
    }
}

/// One thing to draw: a mesh, where it stands in its object, and what it is made of. A
/// shape is one part; a model file has one for each mesh in it.
struct ScenePart {
    var geometry: SceneGeometry
    /// From the mesh's space to the object's.
    var transform = matrix_identity_float4x4
    /// What the file says the part is made of; nil for a shape, which has only the object's.
    var color: SIMD3<Float>?
    var metalness: Float?
    var roughness: Float?
    var picture: MTLTexture?
}

/// The picture of one scene view: what the view's layer shows under the views inside it.
final class SceneSurface {
    /// Shows the scene. Its contents are the last picture drawn.
    let display = CALayer()

    private let rendering: SceneRendering
    /// Two results, drawn into in turn, as a shader view's are.
    private var outputs: [(surface: IOSurface, texture: MTLTexture)] = []
    private var samples: MTLTexture?
    private var depth: MTLTexture?
    private var turn = 0
    private var pixels = (width: 0, height: 0)
    /// What the picture on show was drawn from, so the same scene is not drawn twice.
    private var shown: (scene: SceneUse, size: CGSize, scale: CGFloat, models: Int)?

    init(rendering: SceneRendering) {
        self.rendering = rendering
        display.anchorPoint = .zero
        display.contentsGravity = .resize
        display.masksToBounds = true
    }

    /// Draws the scene for a view of `size` points. `parts` gives what a model is made of;
    /// `models` changes when what it would give does.
    func draw(_ scene: SceneUse, size: CGSize, scale: CGFloat, models: Int = 0, parts: (SceneObject) -> [ScenePart] = { _ in [] }) {
        let scale = min(max(scale.isFinite ? scale : 1, 0.25), 8)
        if let shown, shown.scene == scene, shown.size == size, shown.scale == scale, shown.models == models { return }
        var width = (size.width * scale).rounded(.up), height = (size.height * scale).rounded(.up)
        guard width.isFinite, height.isFinite, width >= 1, height >= 1 else {
            display.contents = nil
            shown = nil
            return
        }
        width = min(width, ShaderSurface.limit)
        height = min(height, ShaderSurface.limit)
        guard resize(width: Int(width), height: Int(height)), let samples, let depth, outputs.count == 2 else { return }
        turn = 1 - turn
        let output = outputs[turn]

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = samples
        pass.colorAttachments[0].resolveTexture = output.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        guard let buffer = rendering.compiler.queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(rendering.pipeline)
        encoder.setDepthStencilState(rendering.depth)
        encoder.setCullMode(.none)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setFragmentSamplerState(rendering.sampler, index: 0)
        var uniforms = SceneRendering.SceneUniforms(scene, aspect: Float(size.width / max(size.height, 0.0001)))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SceneRendering.SceneUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SceneRendering.SceneUniforms>.stride, index: 1)

        for object in scene.objects where object.value("visible").boolValue {
            let placement = SceneMath.placement(of: object)
            let made: [ScenePart]
            if object.shape == .model {
                made = parts(object)
            } else {
                made = rendering.geometry(for: object.shape).map { [ScenePart(geometry: $0)] } ?? []
            }
            for part in made {
                let model = placement * part.transform
                // What is set on the object wins over what a file says; a shape has only the object's.
                let color = object.values["color"].map { SceneRendering.linear($0.colorValue) }
                    ?? part.color ?? SceneRendering.linear(object.value("color").colorValue)
                let metalness = object.values["metalness"].map { SceneRendering.clamp($0.numberValue, 0, 1) }
                    ?? part.metalness ?? SceneRendering.clamp(object.number("metalness"), 0, 1)
                let roughness = object.values["roughness"].map { SceneRendering.clamp($0.numberValue, 0, 1) }
                    ?? part.roughness ?? SceneRendering.clamp(object.number("roughness"), 0, 1)
                var own = SceneRendering.ObjectUniforms(
                    model: model, normal: model.inverse.transpose,
                    color: SIMD4(color, 1), material: SIMD4(metalness, roughness, 0, 0)
                )
                // A size of nothing has no inverse: there is nothing to draw of it either.
                guard (0..<4).allSatisfy({ column in (0..<4).allSatisfy { own.normal[column][$0].isFinite } }) else { continue }
                encoder.setVertexBytes(&own, length: MemoryLayout<SceneRendering.ObjectUniforms>.stride, index: 2)
                encoder.setFragmentBytes(&own, length: MemoryLayout<SceneRendering.ObjectUniforms>.stride, index: 2)
                encoder.setFragmentTexture(part.picture ?? rendering.white, index: 0)
                encoder.setVertexBuffer(part.geometry.vertices, offset: 0, index: 0)
                encoder.drawIndexedPrimitives(
                    type: .triangle, indexCount: part.geometry.indexCount, indexType: .uint32,
                    indexBuffer: part.geometry.indices, indexBufferOffset: 0
                )
            }
        }
        encoder.endEncoding()
        buffer.commit()
        // Pictures and recordings are taken right after a frame, so the result has to be there.
        buffer.waitUntilCompleted()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        display.contents = output.surface
        CATransaction.commit()
        shown = (scene, size, scale, models)
    }

    private func resize(width: Int, height: Int) -> Bool {
        if pixels == (width, height), outputs.count == 2 { return true }
        let device = rendering.compiler.device
        guard let first = SceneSurface.makeOutput(width: width, height: height, device: device),
              let second = SceneSurface.makeOutput(width: width, height: height, device: device) else { return false }
        let color = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        color.textureType = .type2DMultisample
        color.sampleCount = SceneRendering.samples
        color.usage = .renderTarget
        color.storageMode = .private
        let deep = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        deep.textureType = .type2DMultisample
        deep.sampleCount = SceneRendering.samples
        deep.usage = .renderTarget
        deep.storageMode = .private
        guard let samples = device.makeTexture(descriptor: color), let depth = device.makeTexture(descriptor: deep) else { return false }
        outputs = [first, second]
        self.samples = samples
        self.depth = depth
        pixels = (width, height)
        return true
    }

    /// A texture a layer can show: it is backed by an IOSurface, as a shader view's result is.
    static func makeOutput(width: Int, height: Int, device: MTLDevice) -> (surface: IOSurface, texture: MTLTexture)? {
        guard let surface = IOSurface(properties: [
            .width: width, .height: height, .bytesPerElement: 4, .pixelFormat: kCVPixelFormatType_32BGRA,
        ]) else { return nil }
        if let space = ShaderSurface.colorSpace.copyPropertyList() {
            IOSurfaceSetValue(unsafeBitCast(surface, to: IOSurfaceRef.self), kIOSurfaceColorSpace, space)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(
            descriptor: descriptor, iosurface: unsafeBitCast(surface, to: IOSurfaceRef.self), plane: 0
        ) else { return nil }
        return (surface, texture)
    }
}
