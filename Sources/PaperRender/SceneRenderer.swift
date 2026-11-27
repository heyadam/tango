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
/// A scene is drawn with depth and four samples a pixel into a picture of light (16-bit
/// floats, so what is brighter than white stays brighter): every object with one
/// physically based material (color, metalness, roughness, and light of its own), lit by
/// one light, by its surroundings, which are a function of direction rather than a picture,
/// so nothing is shipped or loaded for them and a mirror shows them as sharp as the view
/// is large, and by up to four of its own glowing objects. A last pass spills the
/// brightest light round itself (bloom) and tones it into the picture shown.
final class SceneRendering {
    /// nil where there is no GPU, or the pipeline could not be made: scene views are then
    /// ordinary views.
    static let shared: SceneRendering? = ShaderCompiler.shared.flatMap { SceneRendering(compiler: $0) }

    static let samples = 4
    /// What a scene is drawn into before it is toned: light, which can be brighter than white.
    static let lightFormat = MTLPixelFormat.rgba16Float
    /// The most glowing objects that light the others.
    static let mostGlows = 4

    let compiler: ShaderCompiler
    let pipeline: MTLRenderPipelineState
    /// The passes after a scene is drawn: the brightest light picked out at a quarter of the
    /// size, blurred along one direction, and everything toned into the picture shown.
    let bright: MTLRenderPipelineState
    let blur: MTLRenderPipelineState
    let tone: MTLRenderPipelineState
    /// Reads a picture of light between its pixels, and nothing past its edges.
    let clampedSampler: MTLSamplerState
    /// The same with rays: shadows, what a shiny thing mirrors of the others, and the
    /// shade where things meet. nil on a GPU that traces no rays (the iOS Simulator's),
    /// where a scene is drawn without them.
    let traced: MTLRenderPipelineState?
    let depth: MTLDepthStencilState
    let sampler: MTLSamplerState
    /// What an object with no picture of its own is given to read: white.
    let white: MTLTexture
    private var shapes: [SceneObject.Shape: SceneGeometry] = [:]
    /// What reads model files, for every renderer: a file is read once however many
    /// views, screens and windows show it.
    private(set) lazy var models = SceneModels(device: compiler.device)

    private init?(compiler: ShaderCompiler) {
        self.compiler = compiler
        let device = compiler.device
        func make(traced: Bool) throws -> MTLRenderPipelineState {
            let library = try device.makeLibrary(source: "#define TANGO_TRACED \(traced ? 1 : 0)\n" + SceneRendering.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "scene_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "scene_fragment")
            descriptor.colorAttachments[0].pixelFormat = SceneRendering.lightFormat
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
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        func post(_ function: String, _ format: MTLPixelFormat, in library: MTLLibrary) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "post_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: function)
            descriptor.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        do {
            pipeline = try make(traced: false)
            let passes = try device.makeLibrary(source: SceneRendering.postSource, options: nil)
            bright = try post("post_bright", SceneRendering.lightFormat, in: passes)
            blur = try post("post_blur", SceneRendering.lightFormat, in: passes)
            tone = try post("post_tone", .bgra8Unorm, in: passes)
        } catch {
            assertionFailure("The scene shader does not compile: \(error)")
            return nil
        }
        do {
            traced = device.supportsRaytracing ? try make(traced: true) : nil
        } catch {
            assertionFailure("The scene shader does not compile with rays: \(error)")
            traced = nil
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
        let clampedDescriptor = MTLSamplerDescriptor()
        clampedDescriptor.minFilter = .linear
        clampedDescriptor.magFilter = .linear
        clampedDescriptor.sAddressMode = .clampToZero
        clampedDescriptor.tAddressMode = .clampToZero
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        guard let depth = device.makeDepthStencilState(descriptor: depthDescriptor),
              let sampler = device.makeSamplerState(descriptor: samplerDescriptor),
              let clampedSampler = device.makeSamplerState(descriptor: clampedDescriptor),
              let white = device.makeTexture(descriptor: textureDescriptor) else { return nil }
        var pixel: [UInt8] = [255, 255, 255, 255]
        white.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
        self.depth = depth
        self.sampler = sampler
        self.clampedSampler = clampedSampler
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
                    zenith: SIMD3(0.5, 0.5, 0.53), horizon: SIMD3(0.34, 0.34, 0.36), ground: SIMD3(0.14, 0.14, 0.15),
                    lamps: [
                        (SIMD3(-0.5, 0.7, 0.6), SIMD3(5, 5, 5), 30), (SIMD3(0.8, 0.2, 0.5), SIMD3(1.2, 1.2, 1.3), 12),
                        (SIMD3(0, 0.5, -1), SIMD3(2.5, 2.5, 2.5), 20),
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
        /// x: exposure, y: 1 when rays are traced, z: how many glows light the scene.
        var settings = SIMD4<Float>(repeating: 0)
        /// Glowing objects that light the others: where (xyz) and how large (w), and their
        /// light (rgb).
        var glowPlace = (SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 0))
        var glowColor = (SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 0))

        /// Gives the scene its glows: the brightest first, as many as the shader takes.
        mutating func setGlows(_ glows: [(place: SIMD3<Float>, size: Float, light: SIMD3<Float>)]) {
            let kept = glows.sorted { simd_reduce_max($0.light) * $0.size > simd_reduce_max($1.light) * $1.size }
                .prefix(SceneRendering.mostGlows)
            func at(_ index: Int) -> (SIMD4<Float>, SIMD4<Float>) {
                guard index < kept.count else { return (SIMD4(repeating: 0), SIMD4(repeating: 0)) }
                let glow = kept[kept.startIndex + index]
                return (SIMD4(glow.place, glow.size), SIMD4(glow.light, 0))
            }
            (glowPlace.0, glowColor.0) = at(0)
            (glowPlace.1, glowColor.1) = at(1)
            (glowPlace.2, glowColor.2) = at(2)
            (glowPlace.3, glowColor.3) = at(3)
            settings.z = Float(kept.count)
        }

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
        /// Its own light, linear red, green, blue, already times its strength.
        var emission = SIMD4<Float>(repeating: 0)
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
        float4 glowPlace[4];
        float4 glowColor[4];
    };

    struct ObjectUniforms {
        float4x4 model;
        float4x4 normal;
        float4 color;
        float4 material;
        float4 emission;
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

    #if TANGO_TRACED
    using namespace raytracing;

    // What a ray finds out of the thing it hit: the instance's material and how its
    // normals turn, and the normals at the corners of the triangle.
    struct TracedInstance {
        float4x4 normal;
        float4 color;
        float4 material;
        float4 emission;
    };

    struct TracedTriangle {
        packed_float3 n0;
        packed_float3 n1;
        packed_float3 n2;
    };

    // A number from 0 to 1 that differs from pixel to pixel and from ray to ray, and is
    // the same every time: a picture of a scene never changes between two takings.
    static float scene_noise(float2 pixel, float index) {
        float2 moved = pixel + index * float2(5.588238, 3.453712);
        return fract(52.9829189 * fract(dot(moved, float2(0.06711056, 0.00583715))));
    }

    static void scene_frame(float3 normal, thread float3 &across, thread float3 &along) {
        float3 up = abs(normal.y) < 0.99 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0);
        across = normalize(cross(up, normal));
        along = cross(normal, across);
    }

    static bool scene_blocked(instance_acceleration_structure structure, float3 origin, float3 direction, float reach) {
        intersector<triangle_data, instancing> test;
        test.accept_any_intersection(true);
        ray probe;
        probe.origin = origin;
        probe.direction = direction;
        probe.min_distance = 0.0;
        probe.max_distance = reach;
        return test.intersect(probe, structure, 0xFF).type != intersection_type::none;
    }
    #endif

    // The light of the scene's glowing objects on a surface: each a soft ball of light,
    // falling off with the square of the distance from its rim.
    static float3 scene_glows(constant SceneUniforms &scene, float3 world, float3 normal, float wrap) {
        float3 sum = float3(0.0);
        int count = int(scene.settings.z);
        for (int index = 0; index < 4; index++) {
            if (index >= count) { break; }
            float3 toward = scene.glowPlace[index].xyz - world;
            float far = length(toward);
            float size = max(scene.glowPlace[index].w, 0.001);
            float facing = (dot(normal, toward / max(far, 1e-4)) + wrap) / (1.0 + wrap);
            float reach = size * size / (far * far + size * size * 0.25);
            sum += scene.glowColor[index].rgb * saturate(facing) * reach;
        }
        return sum;
    }

    fragment float4 scene_fragment(SceneVertex in [[stage_in]], bool front [[front_facing]],
                                   constant SceneUniforms &scene [[buffer(1)]],
                                   constant ObjectUniforms &object [[buffer(2)]],
    #if TANGO_TRACED
                                   instance_acceleration_structure structure [[buffer(3)]],
                                   const device TracedInstance *instances [[buffer(4)]],
    #endif
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

        float3 toLight = normalize(scene.lightDirection.xyz);
        float lit = saturate(dot(normal, toLight));
        // How much of the light arrives, and how much of its surroundings a surface sees.
        float shade = 1.0;
        float open = 1.0;
        float3 seen = scene_surroundings(scene, reflect(-toEye, normal), roughness);
    #if TANGO_TRACED
        if (scene.settings.y > 0.5) {
            // A ray starts a little off the surface, by more the further away it is seen
            // from, so that at any size it does not land on the surface it left.
            float lift = 0.0015 * max(distance(scene.camera.xyz, in.world), 0.05);
            float3 from = in.world + normal * lift;
            float3 across, along;
            // The light has a size, so a shadow is soft at its edge: several rays to
            // places on it.
            if (lit > 0.0) {
                scene_frame(toLight, across, along);
                // The places wind outwards in a spiral, turned by a different amount at each
                // pixel: grain too fine to see, where the same places everywhere would band.
                // Most of a picture is wholly in the light or wholly out of it. Six of the
                // places, from the middle to the rim, are asked first; only where they
                // disagree, at a shadow's edge, are the other eighteen.
                float arriving = 0.0;
                float start = 2.0 * M_PI_F * scene_noise(in.position.xy, 0.0);
                for (int pass = 0; pass < 2; pass++) {
                    for (int index = 0; index < 24; index++) {
                        bool early = index % 4 == 3;
                        if (early != (pass == 0)) { continue; }
                        float turn = start + float(index) * 2.3999632;
                        float out = sqrt((float(index) + 0.5) / 24.0) * 0.045;
                        float3 toward = normalize(toLight + (across * cos(turn) + along * sin(turn)) * out);
                        arriving += scene_blocked(structure, from, toward, 1000.0) ? 0.0 : 1.0;
                    }
                    if (pass == 0) {
                        if (arriving == 0.0 || arriving == 6.0) {
                            shade = arriving / 6.0;
                            break;
                        }
                    } else {
                        shade = arriving / 24.0;
                    }
                }
            }
            // Where things are close to one another less of the surroundings reaches them.
            scene_frame(normal, across, along);
            float closed = 0.0;
            float begin = 2.0 * M_PI_F * scene_noise(in.position.xy, 11.0);
            // Likewise: where five rays spread over the sky above a point find nothing
            // near, the other eleven are not sent.
            for (int pass = 0; pass < 2; pass++) {
                for (int index = 0; index < 16; index++) {
                    bool early = index % 3 == 1;
                    if (early != (pass == 0)) { continue; }
                    float ring = (float(index) + 0.5) / 16.0;
                    float turn = begin + float(index) * 2.3999632;
                    float3 toward = (across * cos(turn) + along * sin(turn)) * sqrt(ring) + normal * sqrt(1.0 - ring);
                    closed += scene_blocked(structure, from, toward, 0.6) ? 1.0 : 0.0;
                }
                if (pass == 0 && closed == 0.0) { break; }
            }
            open = 1.0 - 0.85 * closed / 16.0;
            // A shiny surface mirrors the other things in the scene, lit as they are.
            if (roughness < 0.5) {
                float3 back = reflect(-toEye, normal);
                intersector<triangle_data, instancing> finder;
                ray probe;
                probe.origin = from;
                probe.direction = back;
                probe.min_distance = 0.0;
                probe.max_distance = 1000.0;
                intersection_result<triangle_data, instancing> hit = finder.intersect(probe, structure, 0xFF);
                if (hit.type != intersection_type::none) {
                    TracedInstance other = instances[hit.instance_id];
                    TracedTriangle corners = *(const device TracedTriangle *)hit.primitive_data;
                    float2 weight = hit.triangle_barycentric_coord;
                    float3 own = float3(corners.n0) * (1.0 - weight.x - weight.y) + float3(corners.n1) * weight.x + float3(corners.n2) * weight.y;
                    float3 there = normalize((other.normal * float4(own, 0.0)).xyz);
                    if (dot(there, back) > 0.0) { there = -there; }
                    float otherMetal = saturate(other.material.x);
                    float otherRough = clamp(other.material.y, 0.045, 1.0);
                    float3 place = from + back * hit.distance;
                    float otherLit = saturate(dot(there, toLight));
                    if (otherLit > 0.0 && scene_blocked(structure, place + there * lift, toLight, 1000.0)) { otherLit = 0.0; }
                    float3 found = other.color.rgb * (1.0 - otherMetal) * (scene_surroundings(scene, there, 1.0) + scene.lightColor.rgb * otherLit / M_PI_F
                            + scene_glows(scene, place, there, 0.0))
                        + mix(float3(0.04), other.color.rgb, otherMetal) * scene_surroundings(scene, reflect(back, there), otherRough)
                        + other.emission.rgb;
                    seen = mix(found, seen, smoothstep(0.25, 0.5, roughness));
                }
            }
        }
    #endif
        // The one light, by Cook and Torrance with the GGX distribution.
        float3 direct = float3(0.0);
        if (lit > 0.0) {
            float3 half_ = normalize(toEye + toLight);
            float a = roughness * roughness, a2 = a * a;
            float nh = saturate(dot(normal, half_));
            float spread = nh * nh * (a2 - 1.0) + 1.0;
            float distribution = a2 / (M_PI_F * spread * spread);
            float visible = 0.5 / (lit * sqrt(facing * facing * (1.0 - a2) + a2) + facing * sqrt(lit * lit * (1.0 - a2) + a2));
            float3 fresnel = mirror + (1.0 - mirror) * pow(1.0 - saturate(dot(toEye, half_)), 5.0);
            direct = (matte / M_PI_F + distribution * visible * fresnel) * scene.lightColor.rgb * lit * shade;
        }

        // The surroundings: what a matte surface gathers, and what a shiny one mirrors,
        // weighed by how much such a surface reflects at this angle (Karis's fit).
        float4 fit = roughness * float4(-1.0, -0.0275, -0.572, 0.022) + float4(1.0, 0.0425, 1.04, -0.04);
        float bend = min(fit.x * fit.x, exp2(-9.28 * facing)) * fit.x + fit.y;
        float2 weigh = float2(-1.04, 1.04) * bend + fit.zw;
        float3 gathered = scene_surroundings(scene, normal, 1.0) * matte * open;
        float3 mirrored = seen * (mirror * weigh.x + weigh.y) * mix(1.0, open, roughness);

        float3 glowing = matte * scene_glows(scene, in.world, normal, 0.0);
        float3 color = (direct + gathered + mirrored + glowing + object.emission.rgb) * scene.settings.x;
        return float4(color, 1.0);
    }
    """

    /// The passes after the scene: the light brighter than white picked out at a smaller
    /// size, blurred, and added back; then everything toned (ACES) and given the sRGB curve.
    /// What is drawn has its light times its coverage (premultiplied), so a glow can spill
    /// onto the clear pixels round a thing, where it is drawn as light over what is behind.
    static let postSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct PostVertex {
        float4 position [[position]];
        float2 uv;
    };

    // One triangle that covers the picture.
    vertex PostVertex post_vertex(uint index [[vertex_id]]) {
        float2 corner = float2((index << 1) & 2, index & 2);
        PostVertex out;
        out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(corner.x, 1.0 - corner.y);
        return out;
    }

    struct PostSettings {
        float2 step;      // one source pixel, as a share of the picture, for the blur
        float bloom;      // how strong the glow is
        float threshold;  // what is picked out: light over this much
    };

    // The light brighter than the threshold, averaged over four by four pixels of the scene
    // (or two by two of a glow, read again at half its size with no threshold).
    fragment float4 post_bright(PostVertex in [[stage_in]], texture2d<float> light [[texture(0)]],
                                sampler pick [[sampler(0)]], constant PostSettings &settings [[buffer(0)]]) {
        float3 sum = float3(0.0);
        for (int x = -1; x <= 1; x += 2) {
            for (int y = -1; y <= 1; y += 2) {
                float3 c = light.sample(pick, in.uv + float2(x, y) * settings.step).rgb;
                float most = max(c.r, max(c.g, c.b));
                sum += c * max(most - settings.threshold, 0.0) / max(most, 1e-4);
            }
        }
        return float4(sum * 0.25, 0.0);
    }

    // A Gaussian blur along one direction, thirteen taps read as seven between pixels.
    fragment float4 post_blur(PostVertex in [[stage_in]], texture2d<float> light [[texture(0)]],
                              sampler pick [[sampler(0)]], constant PostSettings &settings [[buffer(0)]]) {
        const float offsets[4] = { 0.0, 1.4117647, 3.2941176, 5.1764706 };
        const float weights[4] = { 0.1964825502, 0.2969069647, 0.0944703979, 0.0103813624 };
        float3 sum = light.sample(pick, in.uv).rgb * weights[0];
        for (int index = 1; index < 4; index++) {
            sum += light.sample(pick, in.uv + settings.step * offsets[index]).rgb * weights[index];
            sum += light.sample(pick, in.uv - settings.step * offsets[index]).rgb * weights[index];
        }
        return float4(sum, 0.0);
    }

    static float3 post_curve(float3 color) {
        // ACES, fitted (Narkowicz), then the sRGB curve.
        color = saturate((color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14));
        float3 low = color * 12.92;
        float3 high = 1.055 * pow(color, float3(1.0 / 2.4)) - 0.055;
        return mix(low, high, step(float3(0.0031308), color));
    }

    fragment float4 post_tone(PostVertex in [[stage_in]], texture2d<float> light [[texture(0)]],
                              texture2d<float> near [[texture(1)]], texture2d<float> wide [[texture(2)]],
                              sampler pick [[sampler(0)]], constant PostSettings &settings [[buffer(0)]]) {
        float4 drawn = light.sample(pick, in.uv);
        float cover = saturate(drawn.a);
        float3 own = cover > 0.0 ? drawn.rgb / cover : float3(0.0);
        float3 glow = (near.sample(pick, in.uv).rgb * 0.6 + wide.sample(pick, in.uv).rgb * 0.4) * settings.bloom;
        float3 inside = post_curve(own + glow);
        float3 outside = post_curve(glow);
        float spill = saturate(max(outside.r, max(outside.g, outside.b)));
        return float4(inside * cover + outside * (1.0 - cover), cover + spill * (1.0 - cover));
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
    /// For each triangle, the normals at its corners: what a ray reads where it lands.
    let corners: MTLBuffer
    static let cornersStride = 36
    private var built: MTLAccelerationStructure?

    /// The triangles as rays find them, built the first time a scene with them is traced.
    func structure(on queue: MTLCommandQueue) -> MTLAccelerationStructure? {
        if let built { return built }
        let triangles = MTLAccelerationStructureTriangleGeometryDescriptor()
        triangles.vertexBuffer = vertices
        triangles.vertexStride = SceneGeometry.stride
        triangles.vertexFormat = .float3
        triangles.indexBuffer = indices
        triangles.indexType = .uint32
        triangles.triangleCount = indexCount / 3
        triangles.primitiveDataBuffer = corners
        triangles.primitiveDataStride = SceneGeometry.cornersStride
        triangles.primitiveDataElementSize = SceneGeometry.cornersStride
        let descriptor = MTLPrimitiveAccelerationStructureDescriptor()
        descriptor.geometryDescriptors = [triangles]
        built = SceneGeometry.build(descriptor, on: queue)
        return built
    }

    static func build(_ descriptor: MTLAccelerationStructureDescriptor, on queue: MTLCommandQueue) -> MTLAccelerationStructure? {
        let device = queue.device
        let sizes = device.accelerationStructureSizes(descriptor: descriptor)
        guard sizes.accelerationStructureSize > 0,
              let structure = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
              let scratch = device.makeBuffer(length: max(sizes.buildScratchBufferSize, 16), options: .storageModePrivate),
              let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeAccelerationStructureCommandEncoder() else { return nil }
        encoder.build(accelerationStructure: structure, descriptor: descriptor, scratchBuffer: scratch, scratchBufferOffset: 0)
        encoder.endEncoding()
        buffer.commit()
        return structure
    }

    init?(_ mesh: SceneMesh, device: MTLDevice) {
        guard mesh.isSound, !mesh.indices.isEmpty else { return nil }
        var packed = [Float](repeating: 0, count: mesh.positions.count * 8)
        for index in mesh.positions.indices {
            let position = mesh.positions[index], normal = mesh.normals[index], uv = mesh.uvs[index]
            packed.replaceSubrange(index * 8..<index * 8 + 8, with: [position.x, position.y, position.z, normal.x, normal.y, normal.z, uv.x, uv.y])
        }
        var normals = [Float](repeating: 0, count: mesh.indices.count * 3)
        for (place, index) in mesh.indices.enumerated() {
            let normal = mesh.normals[Int(index)]
            normals.replaceSubrange(place * 3..<place * 3 + 3, with: [normal.x, normal.y, normal.z])
        }
        guard let vertices = device.makeBuffer(bytes: packed, length: packed.count * MemoryLayout<Float>.stride),
              let indices = device.makeBuffer(bytes: mesh.indices, length: mesh.indices.count * MemoryLayout<UInt32>.stride),
              let corners = device.makeBuffer(bytes: normals, length: normals.count * MemoryLayout<Float>.stride)
        else { return nil }
        self.vertices = vertices
        self.indices = indices
        self.corners = corners
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
    /// The scene's light, four samples a pixel, and resolved to one.
    private var samples: MTLTexture?
    private var light: MTLTexture?
    private var depth: MTLTexture?
    /// The glow: the brightest light at a quarter of the size and at an eighth, each with a
    /// second texture to blur through, and a black one standing in when there is no bloom.
    private var near: (MTLTexture, MTLTexture)?
    private var wide: (MTLTexture, MTLTexture)?
    private var dark: MTLTexture?
    private var turn = 0
    private var pixels = (width: 0, height: 0)
    /// The most pixels a point a scene is drawn with while rays are traced.
    static let tracedScale: CGFloat = 2
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
        // With rays every pixel costs a few dozen of them, so a traced scene is drawn with at
        // most two pixels a point and shown larger where the screen has three, or the
        // Canvas is zoomed in; four samples a pixel keep its edges clean.
        let traces = rendering.traced != nil && scene.value("rayTracing").boolValue
        let scale = min(max(scale.isFinite ? scale : 1, 0.25), traces ? SceneSurface.tracedScale : 8)
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

        guard let light, let near, let wide, let dark else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = samples
        pass.colorAttachments[0].resolveTexture = light
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        var uniforms = SceneRendering.SceneUniforms(scene, aspect: Float(size.width / max(size.height, 0.0001)))
        var draws: [(part: ScenePart, uniforms: SceneRendering.ObjectUniforms)] = []
        var glows: [(place: SIMD3<Float>, size: Float, light: SIMD3<Float>)] = []
        for object in scene.objects where object.value("visible").boolValue {
            let placement = SceneMath.placement(of: object)
            let strength = SceneRendering.clamp(object.number("emission"), 0, 1000)
            let drawnBefore = draws.count
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
                // Its own light is in the color it is given, or in the color it is.
                let glow = (object.values["emissionColor"].map { SceneRendering.linear($0.colorValue) } ?? color) * strength
                let own = SceneRendering.ObjectUniforms(
                    model: model, normal: model.inverse.transpose,
                    color: SIMD4(color, 1), material: SIMD4(metalness, roughness, 0, 0), emission: SIMD4(glow, 0)
                )
                // A size of nothing has no inverse: there is nothing to draw of it either.
                guard (0..<4).allSatisfy({ column in (0..<4).allSatisfy { own.normal[column][$0].isFinite && own.model[column][$0].isFinite } }) else { continue }
                // A color set on the object replaces the file's, its picture included.
                var part = part
                if object.values["color"] != nil { part.picture = nil }
                draws.append((part, own))
            }
            // A glowing object lights the others, as a ball of light as large as it is.
            if strength > 0, draws.count > drawnBefore, let any = draws.last, any.uniforms.emission != .zero {
                let middle = placement.columns.3
                let size = simd_reduce_max(SceneMath.size(of: object)) * 0.5
                glows.append((SIMD3(middle.x, middle.y, middle.z), max(size, 0.01), SIMD3(any.uniforms.emission.x, any.uniforms.emission.y, any.uniforms.emission.z)))
            }
        }
        uniforms.setGlows(glows)

        let rays = scene.value("rayTracing").boolValue ? trace(draws) : nil
        uniforms.settings.y = rays == nil ? 0 : 1
        guard let buffer = rendering.compiler.queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(rays?.pipeline ?? rendering.pipeline)
        encoder.setDepthStencilState(rendering.depth)
        encoder.setCullMode(.none)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setFragmentSamplerState(rendering.sampler, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SceneRendering.SceneUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SceneRendering.SceneUniforms>.stride, index: 1)
        if let rays {
            encoder.setFragmentAccelerationStructure(rays.structure, bufferIndex: 3)
            encoder.setFragmentBuffer(rays.instances, offset: 0, index: 4)
            encoder.useResources(rays.used, usage: .read, stages: .fragment)
        }
        // The nearest first: what is hidden behind it then fails the depth test before it is
        // shaded, and with rays shading is most of the cost.
        let eye = SIMD3(uniforms.camera.x, uniforms.camera.y, uniforms.camera.z)
        func distance(_ draw: (part: ScenePart, uniforms: SceneRendering.ObjectUniforms)) -> Float {
            let place = draw.uniforms.model.columns.3
            return simd_distance_squared(eye, SIMD3(place.x, place.y, place.z))
        }
        for draw in draws.sorted(by: { distance($0) < distance($1) }) {
            var own = draw.uniforms
            encoder.setVertexBytes(&own, length: MemoryLayout<SceneRendering.ObjectUniforms>.stride, index: 2)
            encoder.setFragmentBytes(&own, length: MemoryLayout<SceneRendering.ObjectUniforms>.stride, index: 2)
            encoder.setFragmentTexture(draw.part.picture ?? rendering.white, index: 0)
            encoder.setVertexBuffer(draw.part.geometry.vertices, offset: 0, index: 0)
            encoder.drawIndexedPrimitives(
                type: .triangle, indexCount: draw.part.geometry.indexCount, indexType: .uint32,
                indexBuffer: draw.part.geometry.indices, indexBufferOffset: 0
            )
        }
        encoder.endEncoding()

        // The glow: the brightest light at a quarter of the size, blurred, then at an eighth,
        // blurred again; then everything toned into the picture shown.
        let bloom = SceneRendering.clamp(scene.number("bloom"), 0, 10)
        func post(_ pipeline: MTLRenderPipelineState, into target: MTLTexture, reading textures: [MTLTexture], step: SIMD2<Float>, threshold: Float = 0) {
            let into = MTLRenderPassDescriptor()
            into.colorAttachments[0].texture = target
            into.colorAttachments[0].loadAction = .dontCare
            into.colorAttachments[0].storeAction = .store
            guard let encoder = buffer.makeRenderCommandEncoder(descriptor: into) else { return }
            var settings = SIMD4<Float>(step.x, step.y, bloom, threshold)
            encoder.setRenderPipelineState(pipeline)
            for (index, texture) in textures.enumerated() { encoder.setFragmentTexture(texture, index: index) }
            encoder.setFragmentSamplerState(rendering.clampedSampler, index: 0)
            encoder.setFragmentBytes(&settings, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        func pixel(_ texture: MTLTexture) -> SIMD2<Float> { SIMD2(1 / Float(texture.width), 1 / Float(texture.height)) }
        if bloom > 0 {
            post(rendering.bright, into: near.0, reading: [light], step: pixel(light), threshold: 1)
            post(rendering.blur, into: near.1, reading: [near.0], step: SIMD2(pixel(near.0).x, 0))
            post(rendering.blur, into: near.0, reading: [near.1], step: SIMD2(0, pixel(near.1).y))
            post(rendering.bright, into: wide.0, reading: [near.0], step: pixel(near.0) * 0.5)
            post(rendering.blur, into: wide.1, reading: [wide.0], step: SIMD2(pixel(wide.0).x, 0))
            post(rendering.blur, into: wide.0, reading: [wide.1], step: SIMD2(0, pixel(wide.1).y))
            post(rendering.tone, into: output.texture, reading: [light, near.0, wide.0], step: .zero)
        } else {
            post(rendering.tone, into: output.texture, reading: [light, dark, dark], step: .zero)
        }
        buffer.commit()
        // Pictures and recordings are taken right after a frame, so the result has to be there.
        buffer.waitUntilCompleted()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        display.contents = output.surface
        CATransaction.commit()
        shown = (scene, size, scale, models)
    }

    /// What the shader needs to send rays through the scene: every part as an instance of
    /// its triangles, and beside it what each instance is made of. nil when rays are not
    /// traced here, or there is nothing to hit.
    private func trace(_ draws: [(part: ScenePart, uniforms: SceneRendering.ObjectUniforms)]) -> (
        pipeline: MTLRenderPipelineState, structure: MTLAccelerationStructure, instances: MTLBuffer, used: [MTLResource]
    )? {
        guard let pipeline = rendering.traced, !draws.isEmpty else { return nil }
        let queue = rendering.compiler.queue
        var structures: [MTLAccelerationStructure] = []
        var places: [ObjectIdentifier: Int] = [:]
        var instances: [MTLAccelerationStructureInstanceDescriptor] = []
        var materials: [SceneSurface.TracedInstance] = []
        for draw in draws {
            guard let structure = draw.part.geometry.structure(on: queue) else { return nil }
            let key = ObjectIdentifier(draw.part.geometry)
            let place = places[key] ?? structures.count
            if places[key] == nil {
                places[key] = place
                structures.append(structure)
            }
            var instance = MTLAccelerationStructureInstanceDescriptor()
            let model = draw.uniforms.model
            func column(_ value: SIMD4<Float>) -> MTLPackedFloat3 { MTLPackedFloat3Make(value.x, value.y, value.z) }
            instance.transformationMatrix = MTLPackedFloat4x3(columns: (
                column(model.columns.0), column(model.columns.1), column(model.columns.2), column(model.columns.3)
            ))
            instance.mask = 0xFF
            instance.options = .opaque
            instance.accelerationStructureIndex = UInt32(place)
            instances.append(instance)
            materials.append(TracedInstance(
                normal: draw.uniforms.normal, color: draw.uniforms.color, material: draw.uniforms.material, emission: draw.uniforms.emission
            ))
        }
        let device = queue.device
        guard let made = device.makeBuffer(bytes: materials, length: materials.count * MemoryLayout<TracedInstance>.stride) else { return nil }
        // Where things stand changes less often than how they are seen: while only the
        // camera, the light or a color moves, the structure over them is the last one built.
        let standing = draws.map { Standing(geometry: ObjectIdentifier($0.part.geometry), model: $0.uniforms.model) }
        let whole: MTLAccelerationStructure
        if let built, built.standing == standing {
            whole = built.structure
        } else {
            guard let described = device.makeBuffer(bytes: instances, length: instances.count * MemoryLayout<MTLAccelerationStructureInstanceDescriptor>.stride) else { return nil }
            let descriptor = MTLInstanceAccelerationStructureDescriptor()
            descriptor.instancedAccelerationStructures = structures
            descriptor.instanceCount = instances.count
            descriptor.instanceDescriptorBuffer = described
            guard let fresh = SceneGeometry.build(descriptor, on: queue) else { return nil }
            built = (standing, fresh)
            whole = fresh
        }
        return (pipeline, whole, made, structures + draws.map(\.part.geometry.corners))
    }

    /// One thing as rays find it: which triangles, and where.
    private struct Standing: Equatable {
        var geometry: ObjectIdentifier
        var model: simd_float4x4
    }

    /// The structure rays were last sent through, and what stood in it.
    private var built: (standing: [Standing], structure: MTLAccelerationStructure)?

    /// Must match `TracedInstance` in the source.
    struct TracedInstance {
        var normal: simd_float4x4
        var color: SIMD4<Float>
        var material: SIMD4<Float>
        var emission: SIMD4<Float>
    }

    private func resize(width: Int, height: Int) -> Bool {
        if pixels == (width, height), outputs.count == 2 { return true }
        let device = rendering.compiler.device
        guard let first = SceneSurface.makeOutput(width: width, height: height, device: device),
              let second = SceneSurface.makeOutput(width: width, height: height, device: device) else { return false }
        let color = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: SceneRendering.lightFormat, width: width, height: height, mipmapped: false)
        color.textureType = .type2DMultisample
        color.sampleCount = SceneRendering.samples
        color.usage = .renderTarget
        color.storageMode = .private
        func plain(_ width: Int, _ height: Int) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: SceneRendering.lightFormat, width: max(width, 1), height: max(height, 1), mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            return device.makeTexture(descriptor: descriptor)
        }
        let deep = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        deep.textureType = .type2DMultisample
        deep.sampleCount = SceneRendering.samples
        deep.usage = .renderTarget
        deep.storageMode = .private
        guard let samples = device.makeTexture(descriptor: color), let depth = device.makeTexture(descriptor: deep),
              let light = plain(width, height),
              let near0 = plain((width + 3) / 4, (height + 3) / 4), let near1 = plain((width + 3) / 4, (height + 3) / 4),
              let wide0 = plain((width + 7) / 8, (height + 7) / 8), let wide1 = plain((width + 7) / 8, (height + 7) / 8),
              let dark = SceneSurface.black(device: device) else { return false }
        outputs = [first, second]
        self.light = light
        near = (near0, near1)
        wide = (wide0, wide1)
        self.dark = dark
        self.samples = samples
        self.depth = depth
        pixels = (width, height)
        return true
    }

    /// One pixel of no light, read where there is no glow.
    static func black(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: SceneRendering.lightFormat, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var nothing = [UInt16](repeating: 0, count: 4)
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &nothing, bytesPerRow: 8)
        return texture
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
