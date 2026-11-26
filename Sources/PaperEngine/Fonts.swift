import CoreGraphics
import CoreText
import Foundation

/// The typefaces text is set in, for layout to measure and the renderer to draw alike: a
/// text's `fontFamily` (empty for SF Pro), `fontWeight` and `italic` become one `CTFont` here.
///
/// What is shipped and what is fetched:
/// - The system's families (SF Pro and its Rounded, Serif and Mono designs, and the Apple
///   families every Mac and iPhone has, `systemFamilies`) are on every device and are never
///   copied: Apple's licence does not allow it, and nothing needs to.
/// - Google Fonts (open licences: OFL, Apache, UFL, all of which allow carrying a font with
///   a document) ship only as a list of families (`GoogleFonts`). A family's files are
///   fetched from Google when a document first uses it and kept in the document's assets
///   (`GoogleFonts.assetName`); `register(assets:)` makes them known to Core Text, and from
///   then on the family is set like any installed font, offline and on the phone.
public enum FontBook {
    /// The system's typeface. An empty family is this one too.
    public static let systemFamily = "SF Pro"

    /// Apple families on every Mac and every iPhone, so a prototype set in one looks the same
    /// in the Viewer and on the phone. The first four are designs of the system font.
    public static let systemFamilies: [String] = [
        "SF Pro", "SF Pro Rounded", "New York", "SF Mono",
        "Helvetica Neue", "Helvetica", "Avenir Next", "Avenir", "Futura", "Gill Sans", "Optima", "Verdana",
        "Trebuchet MS", "Arial", "Arial Rounded MT Bold", "DIN Alternate", "DIN Condensed",
        "Georgia", "Charter", "Baskerville", "Didot", "Bodoni 72", "Hoefler Text", "Palatino", "Times New Roman",
        "Cochin", "Rockwell", "American Typewriter", "Copperplate",
        "Menlo", "Courier New",
        "Marker Felt", "Noteworthy", "Chalkboard SE", "Bradley Hand", "Snell Roundhand", "Savoye LET", "Zapfino", "Papyrus",
    ]

    /// The designs of the system font, by the family name they are offered under.
    static let designs: [String: String] = [
        "SF Pro Rounded": "NSCTFontUIFontDesignRounded",
        "New York": "NSCTFontUIFontDesignSerif",
        "SF Mono": "NSCTFontUIFontDesignMonospaced",
    ]

    /// Whether a family is the system font or one of its designs.
    public static func isSystemDesign(_ family: String) -> Bool {
        let family = family.trimmingCharacters(in: .whitespaces)
        return family.isEmpty || family == systemFamily || family == "System" || designs[family] != nil
    }

    private static let lock = NSLock()
    /// The faces found for a family, weight and slant; let go when fonts are registered.
    nonisolated(unsafe) private static var faces: [String: CTFontDescriptor?] = [:]
    /// Fonts registered from assets and downloads, by their asset name and length.
    nonisolated(unsafe) private static var registered: [String: Int] = [:]
    /// The families the registered fonts belong to.
    nonisolated(unsafe) private static var registeredFamilies: Set<String> = []
    /// Counts registrations, so anything that kept a face can tell it may be stale.
    nonisolated(unsafe) public private(set) static var generation = 0

    /// The font text is set in. A family that is not here yet (a Google family whose files
    /// have not arrived) is set in the system font at the same weight until they do.
    public static func font(family: String, size: Double, weight: Double, italic: Bool = false) -> CTFont {
        let size = max(size.isFinite ? size : 17, 1)
        let family = family.trimmingCharacters(in: .whitespaces)
        if isSystemDesign(family) { return system(size: size, weight: weight, italic: italic, design: designs[family]) }
        if let face = face(family: family, weight: weight, italic: italic) {
            return CTFontCreateWithFontDescriptor(face, size, nil)
        }
        return system(size: size, weight: weight, italic: italic, design: nil)
    }

    /// Whether `family` can be set as itself on this device now: the system's, an installed
    /// family, or a fetched one that has been registered.
    public static func isAvailable(_ family: String) -> Bool {
        let family = family.trimmingCharacters(in: .whitespaces)
        if isSystemDesign(family) { return true }
        lock.lock()
        let fetched = registeredFamilies.contains(family)
        lock.unlock()
        return fetched || face(family: family, weight: 400, italic: false) != nil
    }

    static func system(size: Double, weight: Double, italic: Bool, design: String?) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        var traits: [String: Any] = [:]
        let weightTrait = TextMeasurer.weightTrait(weight)
        if weightTrait != 0 { traits[kCTFontWeightTrait as String] = weightTrait }
        if let design { traits["NSCTFontUIFontDesignTrait"] = design }
        if italic { traits[kCTFontSymbolicTrait as String] = CTFontSymbolicTraits.traitItalic.rawValue }
        guard !traits.isEmpty else { return base }
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(base), [kCTFontTraitsAttribute: traits] as CFDictionary
        )
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    /// The face of `family` nearest the weight and slant asked for, or nil when this device
    /// has no such family.
    static func face(family: String, weight: Double, italic: Bool) -> CTFontDescriptor? {
        let target = GoogleFonts.weight(weight)
        let key = "\(family)|\(target)|\(italic)"
        lock.lock()
        if let known = faces[key] {
            lock.unlock()
            return known
        }
        lock.unlock()
        let found = findFace(family: family, weight: target, italic: italic)
        lock.lock()
        if faces.count > 2000 { faces.removeAll() }
        faces[key] = found
        lock.unlock()
        return found
    }

    private static func findFace(family: String, weight: Int, italic: Bool) -> CTFontDescriptor? {
        let asked = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let mandatory: Set<String> = [kCTFontFamilyNameAttribute as String]
        guard let matches = CTFontDescriptorCreateMatchingFontDescriptors(asked, mandatory as CFSet) as? [CTFontDescriptor],
              !matches.isEmpty
        else { return nil }
        func score(_ face: CTFontDescriptor) -> Double {
            let traits = CTFontDescriptorCopyAttribute(face, kCTFontTraitsAttribute) as? [String: Any] ?? [:]
            let symbolic = (traits[kCTFontSymbolicTrait as String] as? UInt32) ?? 0
            let slanted = symbolic & CTFontSymbolicTraits.traitItalic.rawValue != 0
            let faceWeight = GoogleFonts.weight(forTrait: (traits[kCTFontWeightTrait as String] as? Double) ?? 0)
            // Slant matters more than weight, as a browser picks; then the nearest weight,
            // a heavier one winning a tie above 400 and a lighter one below.
            var penalty = slanted == italic ? 0.0 : 10_000
            penalty += Double(abs(faceWeight - weight))
            if faceWeight != weight { penalty += (faceWeight > weight) == (weight >= 400) ? 0 : 0.5 }
            // A condensed or expanded cut of the family loses to its regular width.
            let width = (traits[kCTFontWidthTrait as String] as? Double) ?? 0
            penalty += abs(width) * 1000
            return penalty
        }
        return matches.min { score($0) < score($1) }
    }

    /// Makes the fonts among a document's assets known to Core Text, once each. Call it
    /// whenever the assets may have changed, before laying out or drawing.
    public static func register(assets: [String: Data]) {
        for (name, data) in assets where GoogleFonts.isFontAsset(name) {
            register(data, named: name)
        }
    }

    /// Makes one font file known to Core Text. Registering it again does nothing; a font
    /// already known by its PostScript name (another copy, a newer version) keeps the first.
    @discardableResult
    public static func register(_ data: Data, named name: String) -> Bool {
        lock.lock()
        if registered[name] == data.count {
            lock.unlock()
            return true
        }
        lock.unlock()
        guard data.count < 30_000_000, let provider = CGDataProvider(data: data as CFData), let font = CGFont(provider) else {
            return false
        }
        // False when a font of that PostScript name is already known: the first is kept.
        let fresh = CTFontManagerRegisterGraphicsFont(font, nil)
        let family = (CTFontCreateWithGraphicsFont(font, 12, nil, nil)).familyName
        lock.lock()
        registered[name] = data.count
        registeredFamilies.insert(family)
        if fresh {
            faces.removeAll()
            generation += 1
        }
        lock.unlock()
        return true
    }
}

extension CTFont {
    var familyName: String { CTFontCopyFamilyName(self) as String }
}

/// Every family on Google Fonts, shipped as a list (`Catalogs/google-fonts.json`). A
/// family's files are fetched when first used: `cssURL` says where, and the files are kept
/// in a document as `assetName`.
public enum GoogleFonts {
    public struct Family: Sendable, Hashable {
        public var name: String
        /// Sans Serif, Serif, Display, Handwriting or Monospace.
        public var category: String
        /// The styles it has, as Google names them: `400`, `700`, `400i`.
        public var styles: [String]
    }

    nonisolated(unsafe) private static let catalog = Catalogs.json("google-fonts")

    /// Every family, the most used first.
    public static let families: [Family] = (catalog["families"] as? [[String]] ?? []).compactMap { entry in
        guard entry.count >= 3 else { return nil }
        return Family(name: entry[0], category: entry[1], styles: entry[2].split(separator: " ").map(String.init))
    }
    private static let byName: [String: Family] = Dictionary(families.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })

    /// The family a name means, whatever its case.
    public static func family(_ name: String) -> Family? {
        byName[name.trimmingCharacters(in: .whitespaces).lowercased()]
    }

    /// A weight from 100 to 900 in hundreds, as CSS and Google name them.
    public static func weight(_ weight: Double) -> Int {
        guard weight.isFinite else { return 400 }
        return Int((min(max(weight, 100), 900) / 100).rounded()) * 100
    }

    /// The CSS weight a Core Text weight trait stands for, by the steps `TextMeasurer` uses.
    static func weight(forTrait trait: Double) -> Int {
        let steps: [(Double, Int)] = [(-0.8, 100), (-0.6, 200), (-0.4, 300), (0, 400), (0.23, 500), (0.3, 600), (0.4, 700), (0.56, 800), (0.62, 900)]
        return steps.min { abs($0.0 - trait) < abs($1.0 - trait) }!.1
    }

    /// The style of `family` a text with this weight and slant is set in: the one asked for
    /// if it has it, else the nearest of the right slant (as a browser falls back).
    public static func style(of family: Family, weight: Double, italic: Bool) -> String? {
        let target = Self.weight(weight)
        let slanted = family.styles.filter { $0.hasSuffix("i") == italic }
        let candidates = slanted.isEmpty ? family.styles : slanted
        return candidates.min { a, b in
            let wa = Int(a.trimmingCharacters(in: .letters)) ?? 400, wb = Int(b.trimmingCharacters(in: .letters)) ?? 400
            return abs(wa - target) != abs(wb - target) ? abs(wa - target) < abs(wb - target) : wa > wb
        }
    }

    /// What a document keeps a style of a family as: `web.font.Open_Sans.700i.ttf`.
    public static func assetName(family: Family, style: String) -> String {
        let name = family.name.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return "\(WebAssetNames.prefix)font.\(String(name)).\(style).ttf"
    }

    public static func isFontAsset(_ name: String) -> Bool {
        name.hasPrefix(WebAssetNames.prefix + "font.") && name.hasSuffix(".ttf")
    }

    /// The stylesheet that names the file of one style. Asked for without a browser's name,
    /// Google answers with TrueType, which Core Text reads on every device.
    public static func cssURL(family: Family, style: String) -> URL? {
        let italic = style.hasSuffix("i") ? 1 : 0
        let weight = style.trimmingCharacters(in: .letters)
        var components = URLComponents(string: "https://fonts.googleapis.com/css2")
        components?.queryItems = [URLQueryItem(name: "family", value: "\(family.name):ital,wght@\(italic),\(weight)")]
        return components?.url
    }

    /// The font file a stylesheet from `cssURL` names, on Google's own servers only.
    public static func fontURL(inCSS css: String) -> URL? {
        guard let start = css.range(of: "url(") else { return nil }
        let rest = css[start.upperBound...]
        guard let end = rest.firstIndex(of: ")") else { return nil }
        let address = rest[..<end].trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
        guard let url = URL(string: address), url.scheme == "https", url.host == "fonts.gstatic.com" else { return nil }
        return url
    }
}
