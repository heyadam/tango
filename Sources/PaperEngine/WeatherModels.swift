import Foundation
import simd

/// The things of the Weather in 3D example that the scene's own shapes cannot make, made
/// in code as OBJ models a scene view reads like any model file: a puffy cloud, a
/// raindrop and a lightning bolt. (The sun and the snowflakes are the scene's spheres.)
///
/// Each is a signed distance (below zero is inside) built from rounded shapes blended
/// where they meet, turned into triangles by surface nets, with normals from the shape's
/// own slope so it shades smoothly. A scene fits every model into one unit round its
/// middle, so `Fit` says how a model's own units land in the scene.
public enum WeatherModels {
    public static let cloudName = "cloud.obj"
    public static let dropName = "raindrop.obj"
    public static let boltName = "bolt.obj"

    /// The files, by asset name.
    public static var assets: [String: Data] {
        [cloudName: Data(cloud.obj.utf8), dropName: Data(drop.obj.utf8), boltName: Data(bolt.obj.utf8)]
    }

    /// How one of the models lands in a scene when an object showing it has `scale`: its
    /// box is `scale` along its longest side, centered on the object's position.
    public struct Fit: Sendable {
        /// The model's own units to the scene's.
        public let unit: Double
        /// Where the bottom of the model is, below the object's position.
        public let below: Double
        /// How far the model reaches each side of the object's position.
        public let halfWidth: Double
    }

    public static func fit(_ mesh: Mesh, scale: Double) -> Fit {
        let bounds = mesh.box
        let unit = scale / bounds.longest
        return Fit(unit: unit, below: (bounds.middle.y - bounds.low.y) * unit, halfWidth: (bounds.high.x - bounds.low.x) / 2 * unit)
    }

    // MARK: The shapes (y up, x across, z toward the camera)

    typealias P = SIMD3<Double>
    typealias Q = SIMD2<Double>

    static func capsule(_ p: P, _ a: P, _ b: P, radius: Double) -> Double {
        let pa = p - a, ba = b - a
        let h = min(max(dot(pa, ba) / dot(ba, ba), 0), 1)
        return length(pa - ba * h) - radius
    }

    static func ellipsoid(_ p: P, center: P, radii: P) -> Double {
        let q = (p - center) / radii
        let k0 = length(q), k1 = length(q / radii)
        return k1 > 0 ? k0 * (k0 - 1) / k1 : -min(radii.x, radii.y, radii.z)
    }

    /// The smooth minimum: two shapes joined with a fillet `k` wide.
    static func blend(_ a: Double, _ b: Double, _ k: Double) -> Double {
        let h = min(max(0.5 + 0.5 * (b - a) / k, 0), 1)
        return b + (a - b) * h - k * h * (1 - h)
    }

    /// Cuts `b` out of `a` with a rounded edge `k` wide.
    static func carve(_ a: Double, _ b: Double, _ k: Double) -> Double { -blend(-a, b, k) }

    /// A cone with round ends: radius `r1` at the bottom, `r2` at the top, `h` apart along y.
    static func roundCone(_ p: P, r1: Double, r2: Double, h: Double) -> Double {
        let q = SIMD2(length(SIMD2(p.x, p.z)), p.y)
        let b = (r1 - r2) / h, a = (1 - b * b).squareRoot()
        let k = dot(q, SIMD2(-b, a))
        if k < 0 { return length(q) - r1 }
        if k > a * h { return length(q - SIMD2(0, h)) - r2 }
        return dot(q, SIMD2(a, b)) - r1
    }

    static func capsule2(_ p: Q, _ a: Q, _ b: Q, radius: Double) -> Double {
        let pa = p - a, ba = b - a
        let h = min(max(dot(pa, ba) / dot(ba, ba), 0), 1)
        return length(pa - ba * h) - radius
    }

    /// An outline puffed up `thickness` each side of `middle` in z, its edge rounded over
    /// `round`: how a flat outline (the bolt) becomes a soft solid. `front` moves the front
    /// face out, by an amount that fades toward the edge so the outline stays clean.
    static func puff(_ outline: Double, _ z: Double, middle: Double, thickness: Double, round: Double, front: Double = 0) -> Double {
        let off = z - middle
        // Outside the outline: how far from its rim, which runs along z = middle.
        if outline >= 0 { return (outline * outline + off * off).squareRoot() }
        let u = min(-outline / round, 1)
        let depth = thickness * (u * (2 - u)).squareRoot()
        return off > 0 ? off - (depth + front * u) : -off - depth
    }

    /// A cumulus: a long round base, flattened underneath, with three puffs of different
    /// sizes rising from it.
    static func cumulus(_ p: P) -> Double {
        var d = capsule(p, P(-0.52, 0, 0), P(0.52, 0, 0), radius: 0.3)
        d = blend(d, ellipsoid(p, center: P(-0.32, 0.17, 0.02), radii: P(0.34, 0.32, 0.32)), 0.1)
        d = blend(d, ellipsoid(p, center: P(0.1, 0.32, -0.02), radii: P(0.44, 0.42, 0.4)), 0.1)
        d = blend(d, ellipsoid(p, center: P(0.52, 0.12, 0.03), radii: P(0.28, 0.27, 0.27)), 0.1)
        // Flatter underneath, as a cloud's base is.
        return carve(d, p.y + 0.2, 0.12)
    }

    /// A raindrop, point up: a round belly drawn up into a tip.
    static func raindrop(_ p: P) -> Double {
        roundCone(p, r1: 0.3, r2: 0.03, h: 0.62)
    }

    /// A lightning bolt: three strokes in a zigzag, thinning toward the tip, puffed up
    /// into a soft, rounded solid.
    static func lightning(_ p: P) -> Double {
        let q = Q(p.x, p.y)
        var outline = capsule2(q, Q(0.16, 0.55), Q(-0.12, 0.06), radius: 0.11)
        outline = min(outline, capsule2(q, Q(-0.14, 0.06), Q(0.14, 0.02), radius: 0.09))
        outline = min(outline, capsule2(q, Q(0.14, 0.02), Q(-0.1, -0.55), radius: 0.05))
        return puff(outline, p.z, middle: 0, thickness: 0.07, round: 0.08)
    }

    public static let cloud = Mesh.surface(of: cumulus, low: P(-0.9, -0.36, -0.48), high: P(0.9, 0.8, 0.48), step: 0.02)
    public static let drop = Mesh.surface(of: raindrop, low: P(-0.36, -0.36, -0.36), high: P(0.36, 0.7, 0.36), step: 0.024)
    public static let bolt = Mesh.surface(of: lightning, low: P(-0.3, -0.68, -0.12), high: P(0.34, 0.7, 0.12), step: 0.014)

    // MARK: Triangles

    public struct Mesh: Sendable {
        var points: [P] = []
        var normals: [P] = []
        var triangles: [SIMD3<Int>] = []

        var box: (low: P, high: P, middle: P, longest: Double) {
            var low = P(repeating: .infinity), high = P(repeating: -.infinity)
            for p in points { low = pointwiseMin(low, p); high = pointwiseMax(high, p) }
            let size = high - low
            return (low, high, (low + high) / 2, max(size.x, size.y, size.z))
        }

        var obj: String {
            func number(_ value: Double) -> String { String(format: "%.3f", value) }
            var lines = ["# Made by Tango for the Weather in 3D example."]
            lines.reserveCapacity(points.count * 2 + triangles.count + 1)
            for p in points { lines.append("v \(number(p.x)) \(number(p.y)) \(number(p.z))") }
            for n in normals { lines.append("vn \(number(n.x)) \(number(n.y)) \(number(n.z))") }
            for t in triangles {
                let a = t.x + 1, b = t.y + 1, c = t.z + 1
                lines.append("f \(a)//\(a) \(b)//\(b) \(c)//\(c)")
            }
            return lines.joined(separator: "\n") + "\n"
        }

        /// Surface nets: a point in every cell the surface passes through, at the middle
        /// of where it crosses the cell's edges, and a quad across every edge it crosses.
        /// `mirrored` samples only x ≥ 0 and adds the mirror image.
        static func surface(of shape: (P) -> Double, low: P, high: P, step: Double, mirrored: Bool = false) -> Mesh {
            let n = SIMD3<Int>(((high - low) / step).rounded(.up)) &+ 1
            func index(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * n.y + j) * n.x + i }
            func place(_ i: Int, _ j: Int, _ k: Int) -> P { low + P(Double(i), Double(j), Double(k)) * step }
            var field = [Double](repeating: 0, count: n.x * n.y * n.z)
            for k in 0..<n.z { for j in 0..<n.y { for i in 0..<n.x { field[index(i, j, k)] = shape(place(i, j, k)) } } }

            func slope(_ p: P) -> P {
                let e = step * 0.5
                let g = P(
                    shape(p + P(e, 0, 0)) - shape(p - P(e, 0, 0)),
                    shape(p + P(0, e, 0)) - shape(p - P(0, e, 0)),
                    shape(p + P(0, 0, e)) - shape(p - P(0, 0, e))
                )
                let l = length(g)
                return l > 1e-12 ? g / l : P(0, 1, 0)
            }

            var mesh = Mesh()
            let cells = SIMD3<Int>(n.x - 1, n.y - 1, n.z - 1)
            var vertex = [Int](repeating: -1, count: cells.x * cells.y * cells.z)
            func cell(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * cells.y + j) * cells.x + i }
            let corners = (0..<8).map { SIMD3<Int>($0 & 1, ($0 >> 1) & 1, ($0 >> 2) & 1) }
            let edges = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
            for k in 0..<cells.z {
                for j in 0..<cells.y {
                    for i in 0..<cells.x {
                        let values = corners.map { field[index(i + $0.x, j + $0.y, k + $0.z)] }
                        guard values.contains(where: { $0 < 0 }), values.contains(where: { $0 >= 0 }) else { continue }
                        var sum = P.zero, count = 0.0
                        for (a, b) in edges where (values[a] < 0) != (values[b] < 0) {
                            let t = values[a] / (values[a] - values[b])
                            let pa = place(i + corners[a].x, j + corners[a].y, k + corners[a].z)
                            let pb = place(i + corners[b].x, j + corners[b].y, k + corners[b].z)
                            sum += pa + (pb - pa) * t
                            count += 1
                        }
                        let point = sum / count
                        vertex[cell(i, j, k)] = mesh.points.count
                        mesh.points.append(point)
                        mesh.normals.append(slope(point))
                    }
                }
            }
            func quad(_ a: Int, _ b: Int, _ c: Int, _ d: Int, outward: Bool) {
                guard a >= 0, b >= 0, c >= 0, d >= 0 else { return }
                if outward {
                    mesh.triangles.append(SIMD3(a, b, c)); mesh.triangles.append(SIMD3(a, c, d))
                } else {
                    mesh.triangles.append(SIMD3(a, c, b)); mesh.triangles.append(SIMD3(a, d, c))
                }
            }
            // Each grid edge the surface crosses is shared by four cells: join their points.
            for k in 0..<n.z {
                for j in 0..<n.y {
                    for i in 0..<n.x {
                        let here = field[index(i, j, k)] < 0
                        if i + 1 < n.x, j > 0, k > 0, j < cells.y, k < cells.z, here != (field[index(i + 1, j, k)] < 0) {
                            quad(vertex[cell(i, j - 1, k - 1)], vertex[cell(i, j, k - 1)], vertex[cell(i, j, k)], vertex[cell(i, j - 1, k)], outward: here)
                        }
                        if j + 1 < n.y, i > 0, k > 0, i < cells.x, k < cells.z, here != (field[index(i, j + 1, k)] < 0) {
                            quad(vertex[cell(i - 1, j, k - 1)], vertex[cell(i - 1, j, k)], vertex[cell(i, j, k)], vertex[cell(i, j, k - 1)], outward: here)
                        }
                        if k + 1 < n.z, i > 0, j > 0, i < cells.x, j < cells.y, here != (field[index(i, j, k + 1)] < 0) {
                            quad(vertex[cell(i - 1, j - 1, k)], vertex[cell(i, j - 1, k)], vertex[cell(i, j, k)], vertex[cell(i - 1, j, k)], outward: here)
                        }
                    }
                }
            }
            guard mirrored else { return mesh }
            // The other side: the same points across x, and each triangle turned round.
            let offset = mesh.points.count
            mesh.points += mesh.points.map { P(-$0.x, $0.y, $0.z) }
            mesh.normals += mesh.normals.map { P(-$0.x, $0.y, $0.z) }
            mesh.triangles += mesh.triangles.map { SIMD3($0.x + offset, $0.z + offset, $0.y + offset) }
            return mesh
        }
    }
}
