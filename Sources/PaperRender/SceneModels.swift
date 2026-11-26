import Foundation
import Metal
import MetalKit
import ModelIO
import PaperEngine
import PaperModel
import simd

/// Reads model files (USDZ and the other USD kinds, OBJ) for scene views, through Model
/// I/O, and keeps what it read. A model of any size is fitted into one unit, centered, so
/// it shows without tuning. Each mesh in the file is a part with the color, metalness and
/// roughness its material gives, and the picture of its color when the file carries one.
///
/// A file comes from a document, which may come from anywhere: it is refused when it is
/// larger than `mostBytes` or has more than `mostTriangles` triangles, and a file that
/// cannot be read draws nothing. Reading itself is Model I/O's.
final class SceneModels {
    static let mostBytes = 256 * 1024 * 1024
    static let mostTriangles = 4_000_000
    /// The most points all the parts of a model hold together.
    static let mostPoints = 8_000_000
    /// The extensions of the files a scene can show.
    static let extensions: Set<String> = ["usdz", "usd", "usda", "usdc", "obj"]

    struct Model {
        var parts: [ScenePart] = []
        /// Why nothing of it is drawn, in words for the person, or nil.
        var problem: String?
    }

    private let device: MTLDevice
    private var models: [URL: Model] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    /// The model in a file, read the first time it is asked for.
    func model(at url: URL) -> Model {
        if let known = models[url] { return known }
        let read = load(url)
        // Models are large: only a handful are kept.
        if models.count >= 12 { models.removeAll() }
        models[url] = read
        return read
    }

    private func load(_ url: URL) -> Model {
        guard SceneModels.extensions.contains(url.pathExtension.lowercased()) else {
            return Model(problem: "A scene shows USDZ, USD and OBJ files.")
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { return Model(problem: "The file is empty or missing.") }
        guard size <= SceneModels.mostBytes else { return Model(problem: "The file is too large for a scene.") }
        guard MDLAsset.canImportFileExtension(url.pathExtension.lowercased()) else {
            return Model(problem: "This kind of file cannot be read here.")
        }
        let asset = MDLAsset(url: url, vertexDescriptor: nil, bufferAllocator: nil)
        asset.loadTextures()
        let meshes = (asset.childObjects(of: MDLMesh.self) as? [MDLMesh]) ?? []
        guard !meshes.isEmpty else { return Model(problem: "There is nothing in the file a scene can draw.") }

        let layout = MDLVertexDescriptor()
        layout.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        layout.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0)
        layout.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: 24, bufferIndex: 0)
        layout.layouts[0] = MDLVertexBufferLayout(stride: SceneGeometry.stride)

        var read: [(mesh: SceneMesh, transform: simd_float4x4, material: MDLMaterial?)] = []
        var triangles = 0
        var points = 0
        for mesh in meshes {
            let named = (mesh.vertexDescriptor.attributes as? [MDLVertexAttribute])?.map(\.name) ?? []
            if !named.contains(MDLVertexAttributeNormal) {
                mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)
            }
            mesh.vertexDescriptor = layout
            guard let buffer = mesh.vertexBuffers.first, mesh.vertexCount > 0 else { continue }
            let count = mesh.vertexCount
            guard buffer.length >= count * SceneGeometry.stride else { continue }
            var base = SceneMesh()
            let bytes = buffer.map().bytes
            base.positions.reserveCapacity(count)
            for index in 0..<count {
                let numbers = bytes.advanced(by: index * SceneGeometry.stride).assumingMemoryBound(to: Float.self)
                var normal = SIMD3(numbers[3], numbers[4], numbers[5])
                let length = simd_length(normal)
                normal = length.isFinite && length > 1e-6 ? normal / length : SIMD3(0, 1, 0)
                // A picture's rows run downwards and a model's coordinates upwards.
                base.add(SIMD3(numbers[0], numbers[1], numbers[2]), normal, SIMD2(numbers[6], 1 - numbers[7]))
            }
            let transform = MDLTransform.globalTransform(with: mesh, atTime: 0)
            for case let submesh as MDLSubmesh in mesh.submeshes ?? [] where submesh.geometryType == .triangles {
                let indices = submesh.indexBuffer(asIndexType: .uint32)
                let indexCount = submesh.indexCount - submesh.indexCount % 3
                guard indexCount > 0, indices.length >= indexCount * 4 else { continue }
                triangles += indexCount / 3
                guard triangles <= SceneModels.mostTriangles else { return Model(problem: "The model has too many triangles for a scene.") }
                // A part holds only the points its own triangles use: a mesh cut into many
                // parts is not copied whole into each.
                let numbers = UnsafeBufferPointer(start: indices.map().bytes.assumingMemoryBound(to: UInt32.self), count: indexCount)
                guard numbers.allSatisfy({ Int($0) < count }) else { continue }
                var part = SceneMesh()
                var moved: [UInt32: UInt32] = [:]
                part.indices.reserveCapacity(indexCount)
                for index in numbers {
                    if let known = moved[index] {
                        part.indices.append(known)
                    } else {
                        let place = Int(index)
                        let new = part.add(base.positions[place], base.normals[place], base.uvs[place])
                        moved[index] = new
                        part.indices.append(new)
                    }
                }
                points += part.positions.count
                guard points <= SceneModels.mostPoints else { return Model(problem: "The model has too many points for a scene.") }
                guard part.isSound else { continue }
                read.append((part, transform, submesh.material))
            }
        }
        guard !read.isEmpty else { return Model(problem: "There is nothing in the file a scene can draw.") }

        // Fit the whole of it into one unit, wherever and however large the file has it.
        var low = SIMD3<Float>(repeating: .infinity), high = SIMD3<Float>(repeating: -.infinity)
        for item in read {
            guard let bounds = item.mesh.bounds else { continue }
            for corner in 0..<8 {
                let point = SIMD4(
                    corner & 1 == 0 ? bounds.low.x : bounds.high.x, corner & 2 == 0 ? bounds.low.y : bounds.high.y,
                    corner & 4 == 0 ? bounds.low.z : bounds.high.z, 1
                )
                let placed = item.transform * point
                low = simd_min(low, SIMD3(placed.x, placed.y, placed.z))
                high = simd_max(high, SIMD3(placed.x, placed.y, placed.z))
            }
        }
        guard low.x.isFinite, high.x.isFinite, low.y.isFinite, high.y.isFinite, low.z.isFinite, high.z.isFinite else {
            return Model(problem: "The model's size cannot be read.")
        }
        let fit = SceneMesh.fitting(low: low, high: high)

        let loader = MTKTextureLoader(device: device)
        var pictures: [ObjectIdentifier: MTLTexture] = [:]
        var parts: [ScenePart] = []
        for item in read {
            guard let geometry = SceneGeometry(item.mesh, device: device) else { continue }
            var part = ScenePart(geometry: geometry, transform: fit * item.transform)
            if let material = item.material {
                if let color = material.property(with: .baseColor) {
                    if let texture = color.textureSamplerValue?.texture {
                        let key = ObjectIdentifier(texture)
                        if pictures[key] == nil {
                            pictures[key] = try? loader.newTexture(texture: texture, options: [
                                .SRGB: true, .generateMipmaps: true, .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                            ])
                        }
                        part.picture = pictures[key]
                        part.color = part.picture == nil ? nil : SIMD3(1, 1, 1)
                    } else if color.type == .float3 || color.type == .float4 || color.type == .color {
                        // A file's colors are light, not the sRGB a person picks.
                        let value = color.type == .float3 ? SIMD4(color.float3Value, 1) : color.float4Value
                        if value.x.isFinite, value.y.isFinite, value.z.isFinite {
                            part.color = simd_clamp(SIMD3(value.x, value.y, value.z), SIMD3(repeating: 0), SIMD3(repeating: 1))
                        }
                    }
                }
                if let metallic = material.property(with: .metallic), metallic.type == .float, metallic.floatValue.isFinite {
                    part.metalness = min(max(metallic.floatValue, 0), 1)
                }
                if let roughness = material.property(with: .roughness), roughness.type == .float, roughness.floatValue.isFinite {
                    part.roughness = min(max(roughness.floatValue, 0), 1)
                }
            }
            parts.append(part)
        }
        return parts.isEmpty ? Model(problem: "There is nothing in the file a scene can draw.") : Model(parts: parts)
    }
}
