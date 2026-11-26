import Foundation
import PaperModel
import simd

/// Triangles a scene view draws: plain arrays, so the shapes are made and tested with no
/// GPU. Every shape made here fits a box one unit across, centered on the origin, y up,
/// with its triangles counter-clockwise seen from outside.
public struct SceneMesh: Sendable, Hashable {
    public var positions: [SIMD3<Float>] = []
    public var normals: [SIMD3<Float>] = []
    public var uvs: [SIMD2<Float>] = []
    public var indices: [UInt32] = []

    public init() {}

    public var triangleCount: Int { indices.count / 3 }

    /// The corners of the box round every point; nil for a mesh with no points.
    public var bounds: (low: SIMD3<Float>, high: SIMD3<Float>)? {
        guard var low = positions.first else { return nil }
        var high = low
        for point in positions {
            low = simd_min(low, point)
            high = simd_max(high, point)
        }
        return (low, high)
    }

    /// Whether every number is one that can be drawn and every index names a point.
    public var isSound: Bool {
        positions.count == normals.count && positions.count == uvs.count && indices.count % 3 == 0
            && indices.allSatisfy { Int($0) < positions.count }
            && positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
            && normals.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
    }

    @discardableResult
    mutating func add(_ position: SIMD3<Float>, _ normal: SIMD3<Float>, _ uv: SIMD2<Float>) -> UInt32 {
        positions.append(position)
        normals.append(normal)
        uvs.append(uv)
        return UInt32(positions.count - 1)
    }

    mutating func triangle(_ a: UInt32, _ b: UInt32, _ c: UInt32) {
        indices += [a, b, c]
    }

    /// Adds a grid of `columns` by `rows` cells whose points `point` gives from (u, v) in
    /// 0...1, as triangles that face the way the points' normals do when u runs to the
    /// right and v upwards seen from outside.
    mutating func grid(columns: Int, rows: Int, _ point: (Float, Float) -> (SIMD3<Float>, SIMD3<Float>)) {
        let first = UInt32(positions.count)
        for row in 0...rows {
            for column in 0...columns {
                let u = Float(column) / Float(columns), v = Float(row) / Float(rows)
                let (position, normal) = point(u, v)
                add(position, normal, SIMD2(u, 1 - v))
            }
        }
        let stride = UInt32(columns + 1)
        for row in 0..<UInt32(rows) {
            for column in 0..<UInt32(columns) {
                let a = first + row * stride + column, b = a + 1, c = a + stride, d = c + 1
                triangle(a, b, d)
                triangle(a, d, c)
            }
        }
    }

    // MARK: Shapes

    /// The mesh of a shape made in code; nil for a model, which comes from a file.
    public static func shape(_ shape: SceneObject.Shape) -> SceneMesh? {
        switch shape {
        case .box: return roundedBox(radius: 0, steps: 1)
        case .roundedBox: return roundedBox(radius: 0.12, steps: 6)
        case .sphere: return capsule(radius: 0.5, height: 1)
        case .capsule: return capsule(radius: 0.25, height: 1)
        case .cylinder: return cylinder(top: 0.5)
        case .cone: return cylinder(top: 0)
        case .torus: return torus()
        case .plane: return plane()
        case .model: return nil
        }
    }

    /// A box whose edges are rounded with `radius`; 0 gives a plain box.
    static func roundedBox(radius: Float, steps: Int) -> SceneMesh {
        var mesh = SceneMesh()
        let half: Float = 0.5, inner = half - radius
        // Along each side of a face: the points where the rounding starts and ends, and
        // some across each rounded corner.
        var stops: [Float] = []
        if radius > 0 {
            for step in 0...steps { stops.append(-half + radius * (1 - cos(Float(step) / Float(steps) * .pi / 2))) }
            for step in 0...steps { stops.append(inner + radius * sin(Float(step) / Float(steps) * .pi / 2)) }
        } else {
            stops = [-half, half]
        }
        // Each face: the axis it faces along, and the two it lies in, right-handed.
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)), (SIMD3(0, 0, -1), SIMD3(-1, 0, 0), SIMD3(0, 1, 0)),
            (SIMD3(1, 0, 0), SIMD3(0, 0, -1), SIMD3(0, 1, 0)), (SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)),
            (SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, -1)), (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),
        ]
        let last = stops.count - 1
        for (out, right, up) in faces {
            mesh.grid(columns: last, rows: last) { u, v in
                let a = stops[Int((u * Float(last)).rounded())], b = stops[Int((v * Float(last)).rounded())]
                let onCube = out * half + right * a + up * b
                guard radius > 0 else { return (onCube, out) }
                let core = simd_clamp(onCube, SIMD3(repeating: -inner), SIMD3(repeating: inner))
                let away = onCube - core
                let normal = simd_length(away) > 1e-6 ? simd_normalize(away) : out
                return (core + normal * radius, normal)
            }
        }
        return mesh
    }

    /// Two half spheres joined by a tube; with the height twice the radius, a sphere.
    static func capsule(radius: Float, height: Float, around: Int = 48, rings: Int = 12) -> SceneMesh {
        var mesh = SceneMesh()
        let straight = max(0, height / 2 - radius)
        // From the bottom pole up to the top: each half sphere, the tube between them being
        // one row whose ends are the two equators.
        var profile: [(y: Float, ring: Float, normal: SIMD2<Float>)] = []
        for step in 0...rings {
            let angle = -Float.pi / 2 + Float(step) / Float(rings) * .pi / 2
            profile.append((sin(angle) * radius - straight, cos(angle) * radius, SIMD2(cos(angle), sin(angle))))
        }
        for step in 0...rings {
            let angle = Float(step) / Float(rings) * .pi / 2
            profile.append((sin(angle) * radius + straight, cos(angle) * radius, SIMD2(cos(angle), sin(angle))))
        }
        let rows = profile.count - 1
        mesh.grid(columns: around, rows: rows) { u, v in
            let stop = profile[Int((v * Float(rows)).rounded())]
            let angle = u * 2 * .pi
            let outward = SIMD3(sin(angle), 0, cos(angle))
            return (outward * stop.ring + SIMD3(0, stop.y, 0), outward * stop.normal.x + SIMD3(0, stop.normal.y, 0))
        }
        return mesh
    }

    /// A cylinder one unit high and across at its foot; `top` is its radius at the top, so
    /// 0 makes a cone.
    static func cylinder(top: Float, around: Int = 48) -> SceneMesh {
        var mesh = SceneMesh()
        let bottom: Float = 0.5
        // The side leans out by as much as the radius changes over the height.
        let lean = bottom - top
        mesh.grid(columns: around, rows: 1) { u, v in
            let angle = u * 2 * .pi
            let outward = SIMD3(sin(angle), 0, cos(angle))
            let radius = bottom + (top - bottom) * v
            return (outward * radius + SIMD3(0, v - 0.5, 0), simd_normalize(outward + SIMD3(0, lean, 0)))
        }
        func cap(y: Float, radius: Float, up: Float) {
            guard radius > 0 else { return }
            let normal = SIMD3<Float>(0, up, 0)
            let center = mesh.add(SIMD3(0, y, 0), normal, SIMD2(0.5, 0.5))
            var rim: [UInt32] = []
            for step in 0...around {
                let angle = Float(step) / Float(around) * 2 * .pi
                rim.append(mesh.add(SIMD3(sin(angle) * radius, y, cos(angle) * radius), normal, SIMD2(0.5 + sin(angle) / 2, 0.5 - cos(angle) / 2)))
            }
            for step in 0..<around {
                if up > 0 { mesh.triangle(center, rim[step], rim[step + 1]) } else { mesh.triangle(center, rim[step + 1], rim[step]) }
            }
        }
        cap(y: 0.5, radius: top, up: 1)
        cap(y: -0.5, radius: bottom, up: -1)
        return mesh
    }

    /// A ring lying flat, one unit across.
    static func torus(ring: Float = 0.35, tube: Float = 0.15, around: Int = 64, across: Int = 24) -> SceneMesh {
        var mesh = SceneMesh()
        mesh.grid(columns: around, rows: across) { u, v in
            let angle = u * 2 * .pi, turn = v * 2 * .pi
            let outward = SIMD3(sin(angle), 0, cos(angle))
            // Round the tube, starting underneath and going up the outside.
            let normal = outward * sin(turn) + SIMD3(0, -cos(turn), 0)
            return (outward * ring + normal * tube, normal)
        }
        return mesh
    }

    /// A flat square one unit across, facing up.
    static func plane() -> SceneMesh {
        var mesh = SceneMesh()
        mesh.grid(columns: 1, rows: 1) { u, v in (SIMD3(u - 0.5, 0, 0.5 - v), SIMD3(0, 1, 0)) }
        return mesh
    }

    // MARK: Fitting

    /// The matrix that moves and scales points so that `bounds` sits centered on the
    /// origin and is one unit along its longest side: how a model of any size is shown.
    public static func fitting(low: SIMD3<Float>, high: SIMD3<Float>) -> simd_float4x4 {
        let size = high - low
        let longest = max(size.x, size.y, size.z)
        guard longest.isFinite, longest > 0 else { return matrix_identity_float4x4 }
        let scale = 1 / longest
        let center = (low + high) / 2
        return SceneMath.scale(scale) * SceneMath.translation(-center)
    }
}

/// The geometry of looking at a scene: where the camera is, how an object is placed. Pure
/// functions on numbers, so a test can say where a point lands on the screen.
public enum SceneMath {
    /// Makes a number one a matrix can hold: finite and within `limit`.
    static func finite(_ value: Double, _ fallback: Float = 0, limit: Float = 1e6) -> Float {
        guard value.isFinite else { return fallback }
        return min(max(Float(value), -limit), limit)
    }

    public static func translation(_ by: SIMD3<Float>) -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4(by.x, by.y, by.z, 1)
        return matrix
    }

    public static func scale(_ by: Float) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4(by, by, by, 1))
    }

    public static func rotation(degrees: Float, axis: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(simd_quatf(angle: degrees * .pi / 180, axis: axis))
    }

    /// A direction from the middle of the scene, by the angles the camera and the light
    /// are given in: yaw 0 is in front (+z), 90 to the right (+x); pitch is above the horizon.
    public static func direction(yaw: Double, pitch: Double) -> SIMD3<Float> {
        let yaw = finite(yaw) * .pi / 180, pitch = min(max(finite(pitch), -89), 89) * .pi / 180
        return SIMD3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
    }

    /// Where the camera stands.
    public static func cameraPosition(of scene: SceneUse) -> SIMD3<Float> {
        let distance = min(max(finite(scene.number("cameraDistance"), 3), 0.05), 1000)
        return direction(yaw: scene.number("cameraYaw"), pitch: scene.number("cameraPitch")) * distance
    }

    /// From the scene's space to the camera's: the camera looks at the middle of the scene.
    public static func view(of scene: SceneUse) -> simd_float4x4 {
        let eye = cameraPosition(of: scene)
        let forward = simd_normalize(-eye)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
        let up = simd_cross(right, forward)
        return simd_float4x4(rows: [
            SIMD4(right.x, right.y, right.z, -simd_dot(right, eye)),
            SIMD4(up.x, up.y, up.z, -simd_dot(up, eye)),
            SIMD4(-forward.x, -forward.y, -forward.z, simd_dot(forward, eye)),
            SIMD4(0, 0, 0, 1),
        ])
    }

    /// The perspective for a view `aspect` times as wide as it is high. The field of view
    /// is across the view's shorter side, so a tall view shows as much as a wide one.
    public static func projection(of scene: SceneUse, aspect: Float) -> simd_float4x4 {
        let aspect = aspect.isFinite && aspect > 0 ? aspect : 1
        let field = min(max(finite(scene.number("fieldOfView"), 35), 5), 150) * .pi / 180
        let half = tan(field / 2)
        // The tangent of half the vertical angle.
        let vertical = aspect >= 1 ? half : half / aspect
        let near: Float = 0.05, far: Float = 2000
        return simd_float4x4(rows: [
            SIMD4(1 / (vertical * aspect), 0, 0, 0),
            SIMD4(0, 1 / vertical, 0, 0),
            SIMD4(0, 0, far / (near - far), near * far / (near - far)),
            SIMD4(0, 0, -1, 0),
        ])
    }

    /// From an object's own space to the scene's: scaled, turned (round z, then x, then y)
    /// and moved.
    public static func placement(of object: SceneObject) -> simd_float4x4 {
        let move = SIMD3(finite(object.number("x")), finite(object.number("y")), finite(object.number("z")))
        let size = min(max(finite(object.number("scale"), 1), 0), 1e4)
        return translation(move)
            * rotation(degrees: finite(object.number("rotationY")), axis: SIMD3(0, 1, 0))
            * rotation(degrees: finite(object.number("rotationX")), axis: SIMD3(1, 0, 0))
            * rotation(degrees: finite(object.number("rotationZ")), axis: SIMD3(0, 0, 1))
            * scale(size)
    }

    /// Where a point of the scene shows in a view of `size` points, from its top left; nil
    /// for a point behind the camera.
    public static func screenPoint(_ point: SIMD3<Float>, in scene: SceneUse, size: Size2) -> Point2? {
        let aspect = Float(size.width / max(size.height, 1e-6))
        let clip = projection(of: scene, aspect: aspect) * view(of: scene) * SIMD4(point.x, point.y, point.z, 1)
        guard clip.w > 0 else { return nil }
        return Point2(
            x: Double((clip.x / clip.w + 1) / 2) * size.width,
            y: Double((1 - clip.y / clip.w) / 2) * size.height
        )
    }
}
