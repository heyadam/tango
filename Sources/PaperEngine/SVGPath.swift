import CoreGraphics
import Foundation

/// Reads the path data of SVG (`d="M2 9.5a5.5 5.5 0 0 1 …"`) into a `CGPath`: every
/// command, absolute and relative, with numbers written as tightly as SVG allows them
/// (`9.591-3.676.56.56`, arc flags run together as `011`). What Lucide's icons and
/// Material Symbols' glyphs are drawn with.
public enum SVGPath {
    /// The path `d` describes, or nil when it is not path data. A path cut short by a
    /// mistake keeps what came before it, as a browser draws it.
    public static func parse(_ d: String) -> CGPath? {
        var reader = Reader(Array(d.utf8))
        let path = CGMutablePath()
        var current = CGPoint.zero
        var start = CGPoint.zero
        // The control point a smooth curve reflects, and which kind of curve left it.
        var lastCubic: CGPoint?
        var lastQuad: CGPoint?
        var command: UInt8 = 0
        var drewAnything = false

        while true {
            reader.skipSeparators()
            guard let next = reader.peek else { break }
            if Reader.isCommand(next) {
                command = next
                reader.index += 1
            } else if command == 0 {
                return nil
            } else if command == UInt8(ascii: "M") {
                // Numbers after a move are lines.
                command = UInt8(ascii: "L")
            } else if command == UInt8(ascii: "m") {
                command = UInt8(ascii: "l")
            } else if command == UInt8(ascii: "Z") || command == UInt8(ascii: "z") {
                return drewAnything ? path : nil
            }
            let relative = command >= UInt8(ascii: "a")
            func point(_ x: Double, _ y: Double) -> CGPoint {
                relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            var cubic: CGPoint?
            var quad: CGPoint?
            switch command | 0x20 {
            case UInt8(ascii: "m"):
                guard let x = reader.number(), let y = reader.number() else { return finish(path, drewAnything) }
                current = point(x, y)
                start = current
                path.move(to: current)
            case UInt8(ascii: "l"):
                guard let x = reader.number(), let y = reader.number() else { return finish(path, drewAnything) }
                current = point(x, y)
                ensureStarted(path, at: start)
                path.addLine(to: current)
            case UInt8(ascii: "h"):
                guard let x = reader.number() else { return finish(path, drewAnything) }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                ensureStarted(path, at: start)
                path.addLine(to: current)
            case UInt8(ascii: "v"):
                guard let y = reader.number() else { return finish(path, drewAnything) }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                ensureStarted(path, at: start)
                path.addLine(to: current)
            case UInt8(ascii: "c"):
                guard let x1 = reader.number(), let y1 = reader.number(), let x2 = reader.number(),
                      let y2 = reader.number(), let x = reader.number(), let y = reader.number()
                else { return finish(path, drewAnything) }
                let one = point(x1, y1), two = point(x2, y2), end = point(x, y)
                ensureStarted(path, at: start)
                path.addCurve(to: end, control1: one, control2: two)
                cubic = two
                current = end
            case UInt8(ascii: "s"):
                guard let x2 = reader.number(), let y2 = reader.number(), let x = reader.number(), let y = reader.number()
                else { return finish(path, drewAnything) }
                let one = lastCubic.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let two = point(x2, y2), end = point(x, y)
                ensureStarted(path, at: start)
                path.addCurve(to: end, control1: one, control2: two)
                cubic = two
                current = end
            case UInt8(ascii: "q"):
                guard let x1 = reader.number(), let y1 = reader.number(), let x = reader.number(), let y = reader.number()
                else { return finish(path, drewAnything) }
                let control = point(x1, y1), end = point(x, y)
                ensureStarted(path, at: start)
                path.addQuadCurve(to: end, control: control)
                quad = control
                current = end
            case UInt8(ascii: "t"):
                guard let x = reader.number(), let y = reader.number() else { return finish(path, drewAnything) }
                let control = lastQuad.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let end = point(x, y)
                ensureStarted(path, at: start)
                path.addQuadCurve(to: end, control: control)
                quad = control
                current = end
            case UInt8(ascii: "a"):
                guard let rx = reader.number(), let ry = reader.number(), let rotation = reader.number(),
                      let large = reader.flag(), let sweep = reader.flag(),
                      let x = reader.number(), let y = reader.number()
                else { return finish(path, drewAnything) }
                let end = point(x, y)
                ensureStarted(path, at: start)
                addArc(to: path, from: current, to: end, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = end
            case UInt8(ascii: "z"):
                path.closeSubpath()
                current = start
            default:
                return finish(path, drewAnything)
            }
            drewAnything = true
            lastCubic = cubic
            lastQuad = quad
        }
        return finish(path, drewAnything)
    }

    private static func finish(_ path: CGMutablePath, _ drewAnything: Bool) -> CGPath? {
        drewAnything && !path.isEmpty ? path : nil
    }

    /// A line or curve with no point to start from (after a close) starts where the
    /// last subpath did.
    private static func ensureStarted(_ path: CGMutablePath, at start: CGPoint) {
        if path.isEmpty { path.move(to: start) }
    }

    /// An SVG arc, from its end points to its center (SVG 1.1, F.6.5), drawn as a turn of
    /// a unit circle stretched and turned into place.
    static func addArc(
        to path: CGMutablePath, from p0: CGPoint, to p1: CGPoint,
        rx: Double, ry: Double, rotation: Double, large: Bool, sweep: Bool
    ) {
        var rx = abs(rx), ry = abs(ry)
        guard p0 != p1 else { return }
        guard rx > 0, ry > 0 else { return path.addLine(to: p1) }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy
        // Radii too small to reach are scaled up until they just do.
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var factor = denominator == 0 ? 0 : (max(numerator, 0) / denominator).squareRoot()
        if large == sweep { factor = -factor }
        let cx1 = factor * rx * y1 / ry
        let cy1 = -factor * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2

        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        let transform = CGAffineTransform(translationX: cx, y: cy).rotated(by: phi).scaledBy(x: rx, y: ry)
        path.addArc(center: .zero, radius: 1, startAngle: theta, endAngle: theta + delta, clockwise: delta < 0, transform: transform)
    }

    /// The numbers of a `points` list (`"3 6 9 12 15 6"`, or with commas).
    public static func numbers(_ text: Substring) -> [Double] {
        var reader = Reader(Array(text.utf8))
        var numbers: [Double] = []
        while let number = reader.number() { numbers.append(number) }
        return numbers
    }

    struct Reader {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

        static func isCommand(_ byte: UInt8) -> Bool {
            switch byte | 0x20 {
            case UInt8(ascii: "m"), UInt8(ascii: "l"), UInt8(ascii: "h"), UInt8(ascii: "v"), UInt8(ascii: "c"),
                 UInt8(ascii: "s"), UInt8(ascii: "q"), UInt8(ascii: "t"), UInt8(ascii: "a"), UInt8(ascii: "z"):
                // `e` is part of a number, never a command; it is not among these.
                return true
            default: return false
            }
        }

        mutating func skipSeparators() {
            while let byte = peek, byte == 0x20 || byte == 0x2C || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                index += 1
            }
        }

        /// An arc's flag: one character, 0 or 1, which may touch the next number.
        mutating func flag() -> Bool? {
            skipSeparators()
            guard let byte = peek, byte == UInt8(ascii: "0") || byte == UInt8(ascii: "1") else { return nil }
            index += 1
            return byte == UInt8(ascii: "1")
        }

        mutating func number() -> Double? {
            skipSeparators()
            let begin = index
            if let sign = peek, sign == UInt8(ascii: "-") || sign == UInt8(ascii: "+") { index += 1 }
            var digits = false, dot = false
            while let byte = peek {
                if byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
                    digits = true
                } else if byte == UInt8(ascii: "."), !dot {
                    dot = true
                } else {
                    break
                }
                index += 1
            }
            guard digits else {
                index = begin
                return nil
            }
            if let e = peek, e == UInt8(ascii: "e") || e == UInt8(ascii: "E") {
                let mark = index
                index += 1
                if let sign = peek, sign == UInt8(ascii: "-") || sign == UInt8(ascii: "+") { index += 1 }
                var exponent = false
                while let byte = peek, byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
                    exponent = true
                    index += 1
                }
                if !exponent { index = mark }
            }
            guard let text = String(bytes: bytes[begin..<index], encoding: .ascii), let value = Double(text), value.isFinite else {
                index = begin
                return nil
            }
            return value
        }
    }
}
