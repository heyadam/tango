import CoreGraphics
import Foundation

/// The sets of icons a Symbol view can show. Its `symbol` names one: a plain name is an
/// SF Symbol (`heart.fill`), as it always was; any other set is named before a colon
/// (`lucide:heart`, `material-rounded:favorite.fill`).
///
/// What is shipped and what is fetched:
/// - SF Symbols are the system's, drawn by AppKit and UIKit on each device.
/// - Lucide (ISC) ships whole in `Catalogs/lucide.json`: every icon is drawn here, the same
///   on every device, with nothing to fetch.
/// - Material Symbols (Apache 2.0) ship only as a list of names: a glyph is fetched from
///   Google when a document first uses it and kept in the document's assets (`assetName`),
///   so it then draws offline, on the phone and on any other Mac.
public enum IconSet: String, CaseIterable, Sendable, Hashable {
    case sf
    case lucide
    case material
    case materialRounded = "material-rounded"
    case materialSharp = "material-sharp"

    public var displayName: String {
        switch self {
        case .sf: "SF Symbols"
        case .lucide: "Lucide"
        case .material: "Material Symbols"
        case .materialRounded: "Material Symbols Rounded"
        case .materialSharp: "Material Symbols Sharp"
        }
    }

    /// The set a name for the Icon patch's Set input means: its display name, its prefix,
    /// or a short form ("Material", "Rounded", "SF").
    public static func named(_ text: String) -> IconSet? {
        let key = text.lowercased().trimmingCharacters(in: .whitespaces)
        if let set = IconSet(rawValue: key) { return set }
        if let set = allCases.first(where: { $0.displayName.lowercased() == key }) { return set }
        switch key {
        case "sf symbol", "sf symbols", "system", "": return .sf
        case "material outlined", "material symbols outlined", "outlined": return .material
        case "rounded", "material rounded": return .materialRounded
        case "sharp", "material sharp": return .materialSharp
        default: return nil
        }
    }

    public var isMaterial: Bool { self == .material || self == .materialRounded || self == .materialSharp }
}

/// A `symbol` value taken apart: which set, which icon, and whether it is filled.
public struct IconName: Hashable, Sendable {
    public var set: IconSet
    public var name: String
    public var filled: Bool

    public init(set: IconSet, name: String, filled: Bool = false) {
        self.set = set
        self.name = name
        self.filled = filled
    }

    /// Reads a `symbol` value. A Material name ending `.fill` is the filled glyph, as an SF
    /// Symbol's is; an SF Symbol's `.fill` stays in its name, where the system reads it.
    public init?(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        guard let colon = value.firstIndex(of: ":") else {
            self.init(set: .sf, name: value, filled: value.hasSuffix(".fill"))
            return
        }
        guard let set = IconSet(rawValue: value[..<colon].lowercased()), set != .sf else { return nil }
        var name = value[value.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        var filled = false
        if name.hasSuffix(".fill") {
            filled = true
            name.removeLast(5)
        }
        guard !name.isEmpty else { return nil }
        self.init(set: set, name: name, filled: filled && set.isMaterial)
    }

    /// The `symbol` value: what a Symbol view stores and the Icon patch gives.
    public var value: String {
        switch set {
        case .sf:
            if filled, !name.hasSuffix(".fill") { return name + ".fill" }
            return name
        case .lucide: return "lucide:" + name
        default: return set.rawValue + ":" + name + (filled ? ".fill" : "")
        }
    }

    /// Whether the set this names knows it. SF Symbols are the system's to know.
    public var isKnown: Bool {
        switch set {
        case .sf: true
        case .lucide: LucideIcons.shapes[name] != nil
        default: MaterialSymbols.known.contains(name)
        }
    }
}

/// An icon drawn from vector shapes: what a Symbol view shows for any set but SF Symbols.
public struct VectorGlyph: @unchecked Sendable {
    /// The box the shapes are drawn in (Lucide's 24-point square, Material's 960).
    public var box: CGRect
    /// Lines, drawn `lineWidth` wide (in the box's units) with round ends and joins.
    public var stroked: CGPath?
    public var lineWidth: Double
    /// Shapes filled whole.
    public var filled: CGPath?

    public init(box: CGRect, stroked: CGPath? = nil, lineWidth: Double = 0, filled: CGPath? = nil) {
        self.box = box
        self.stroked = stroked
        self.lineWidth = lineWidth
        self.filled = filled
    }

    /// Draws the glyph in one color, fitted into `width` × `height` pixels and centered,
    /// with y down as views are. Nil for a size that is no picture.
    public func image(width: Int, height: Int, color: CGColor) -> CGImage? {
        guard width > 0, height > 0, width <= 8192, height <= 8192, box.width > 0, box.height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        let scale = min(Double(width) / box.width, Double(height) / box.height)
        context.translateBy(x: 0, y: Double(height))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: (Double(width) - box.width * scale) / 2, y: (Double(height) - box.height * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.setFillColor(color)
        context.setStrokeColor(color)
        if let filled {
            context.addPath(filled)
            context.fillPath()
        }
        if let stroked, lineWidth > 0 {
            context.setLineWidth(lineWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(stroked)
            context.strokePath()
        }
        return context.makeImage()
    }
}

/// The catalogs in `Catalogs/`, read once when first asked for.
enum Catalogs {
    static func json(_ name: String) -> [String: Any] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Catalogs"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }
}

/// Every Lucide icon, shipped with the app (`scripts/update-catalogs.py`).
public enum LucideIcons {
    nonisolated(unsafe) private static let catalog = Catalogs.json("lucide")

    /// Each icon's shapes, as the catalog writes them.
    static let shapes: [String: [String]] = catalog["icons"] as? [String: [String]] ?? [:]
    /// Words each icon is also found by.
    public static let tags: [String: String] = catalog["tags"] as? [String: String] ?? [:]
    /// Every icon's name, in order.
    public static let names: [String] = shapes.keys.sorted()
    /// The version of `lucide-static` the catalog was made from.
    public static var version: String { catalog["version"] as? String ?? "" }

    /// Lucide draws its lines 2 wide in a 24-point box at a regular weight. A Symbol view's
    /// weight thickens or thins them: 100 is half a point, 900 four and a half.
    public static func lineWidth(forWeight weight: Double) -> Double {
        guard weight.isFinite else { return 2 }
        return min(max(weight / 200, 0.5), 4.5)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var paths: [String: (stroked: CGPath?, filled: CGPath?)] = [:]

    /// The icon `name` drawn at a weight, or nil when Lucide has no such icon.
    public static func glyph(_ name: String, weight: Double = 400) -> VectorGlyph? {
        lock.lock()
        defer { lock.unlock() }
        let built: (stroked: CGPath?, filled: CGPath?)
        if let known = paths[name] {
            built = known
        } else {
            guard let shapes = shapes[name] else { return nil }
            built = build(shapes)
            paths[name] = built
        }
        return VectorGlyph(
            box: CGRect(x: 0, y: 0, width: 24, height: 24),
            stroked: built.stroked, lineWidth: lineWidth(forWeight: weight), filled: built.filled
        )
    }

    static func build(_ shapes: [String]) -> (stroked: CGPath?, filled: CGPath?) {
        let stroked = CGMutablePath(), filled = CGMutablePath()
        for shape in shapes {
            guard let kind = shape.first else { continue }
            let rest = shape.dropFirst(2)
            let n = SVGPath.numbers(rest)
            switch kind {
            case "p":
                if let path = SVGPath.parse(String(rest)) { stroked.addPath(path) }
            case "c", "C":
                guard n.count >= 3 else { continue }
                let circle = CGRect(x: n[0] - n[2], y: n[1] - n[2], width: n[2] * 2, height: n[2] * 2)
                stroked.addEllipse(in: circle)
                if kind == "C" { filled.addEllipse(in: circle) }
            case "r":
                guard n.count >= 4 else { continue }
                let rect = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
                let rx = min(max(n.count > 4 ? n[4] : 0, 0), rect.width / 2)
                let ry = min(max(n.count > 5 ? n[5] : rx, 0), rect.height / 2)
                if rx > 0, ry > 0 {
                    stroked.addRoundedRect(in: rect, cornerWidth: rx, cornerHeight: ry)
                } else {
                    stroked.addRect(rect)
                }
            case "l":
                guard n.count >= 4 else { continue }
                stroked.move(to: CGPoint(x: n[0], y: n[1]))
                stroked.addLine(to: CGPoint(x: n[2], y: n[3]))
            case "e":
                guard n.count >= 4 else { continue }
                stroked.addEllipse(in: CGRect(x: n[0] - n[2], y: n[1] - n[3], width: n[2] * 2, height: n[3] * 2))
            case "o", "g":
                guard n.count >= 4 else { continue }
                stroked.move(to: CGPoint(x: n[0], y: n[1]))
                for index in stride(from: 2, to: n.count - 1, by: 2) {
                    stroked.addLine(to: CGPoint(x: n[index], y: n[index + 1]))
                }
                if kind == "g" { stroked.closeSubpath() }
            default: continue
            }
        }
        return (stroked.isEmpty ? nil : stroked, filled.isEmpty ? nil : filled)
    }
}

/// Google's Material Symbols. The list of names ships with the app; each glyph is fetched
/// from Google's servers when first used (`url`) and kept in the document (`assetName`).
public enum MaterialSymbols {
    nonisolated(unsafe) private static let catalog = Catalogs.json("material-symbols")

    /// Every icon: its name, its categories and a few words it is also found by, most used first.
    public static let icons: [(name: String, categories: String, tags: String)] =
        (catalog["icons"] as? [[String]] ?? []).compactMap { $0.count >= 3 ? ($0[0], $0[1], $0[2]) : nil }
    public static let known: Set<String> = Set(icons.map(\.name))

    /// The weights a glyph is drawn at: Material's from 100 to 700.
    public static func weight(_ weight: Double) -> Int {
        guard weight.isFinite else { return 400 }
        return Int((min(max(weight, 100), 700) / 100).rounded()) * 100
    }

    /// How Google names a glyph's style: `default`, `fill1`, `wght700`, `wght700fill1`.
    public static func variant(filled: Bool, weight: Double) -> String {
        let weight = Self.weight(weight)
        let parts = (weight == 400 ? "" : "wght\(weight)") + (filled ? "fill1" : "")
        return parts.isEmpty ? "default" : parts
    }

    /// A name Google could have: lowercase letters, digits and underscores.
    public static func isWellFormed(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.utf8.allSatisfy {
            ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5F
        }
    }

    /// The asset a glyph is kept as in a document:
    /// `web.material-rounded.favorite.wght700fill1.svg`. Nil for a name Material does not have.
    public static func assetName(_ icon: IconName, weight: Double) -> String? {
        guard icon.set.isMaterial, isWellFormed(icon.name) else { return nil }
        return "\(WebAssetNames.prefix)\(icon.set.rawValue).\(icon.name).\(variant(filled: icon.filled, weight: weight)).svg"
    }

    /// Where Google serves a glyph, as SVG.
    public static func url(_ icon: IconName, weight: Double) -> URL? {
        guard icon.set.isMaterial, isWellFormed(icon.name) else { return nil }
        let family = switch icon.set {
        case .materialRounded: "materialsymbolsrounded"
        case .materialSharp: "materialsymbolssharp"
        default: "materialsymbolsoutlined"
        }
        return URL(string: "https://fonts.gstatic.com/s/i/short-term/release/\(family)/\(icon.name)/\(variant(filled: icon.filled, weight: weight))/24px.svg")
    }

    /// A glyph read from the SVG Google serves: the `viewBox` and every path, filled.
    public static func glyph(svg data: Data) -> VectorGlyph? {
        guard data.count < 200_000, let text = String(data: data, encoding: .utf8), text.contains("<svg") else { return nil }
        var box = CGRect(x: 0, y: -960, width: 960, height: 960)
        if let viewBox = attribute("viewBox", in: Substring(text)) {
            let n = SVGPath.numbers(Substring(viewBox))
            if n.count == 4, n[2] > 0, n[3] > 0 { box = CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) }
        }
        let filled = CGMutablePath()
        var rest = Substring(text)
        while let range = rest.range(of: "<path") {
            rest = rest[range.upperBound...]
            guard let end = rest.firstIndex(of: ">") else { break }
            if let d = attribute("d", in: rest[..<end]), let path = SVGPath.parse(d) { filled.addPath(path) }
            rest = rest[end...]
        }
        return filled.isEmpty ? nil : VectorGlyph(box: box, filled: filled)
    }

    private static func attribute(_ name: String, in text: Substring) -> String? {
        guard let range = text.range(of: " \(name)=\"") ?? text.range(of: "\n\(name)=\"") else { return nil }
        let after = text[range.upperBound...]
        guard let close = after.firstIndex(of: "\"") else { return nil }
        return String(after[..<close])
    }
}

/// What a document keeps of what was fetched from the web: assets whose names start with
/// `web.`, which the editor adds and removes as the document uses them.
public enum WebAssetNames {
    public static let prefix = "web."

    public static func isWebAsset(_ name: String) -> Bool { name.hasPrefix(prefix) }
}
