import Foundation
import PaperEngine
import PaperModel
import PaperRender

/// The icons and fonts a prototype uses that are fetched from the web rather than shipped:
/// Material Symbols' glyphs and Google Fonts' files. Each is fetched once, from Google's own
/// servers only, and kept in a cache on this device; the editor copies what a document uses
/// into its assets (`web.…`), so from then on it draws with nothing fetched, on any device.
///
/// A host's renderer asks here (`glyph`, `wantFont`); what arrives later is announced with
/// `didArrive`, and the host draws (and, for a font, lays out) again.
public final class WebAssets {
    public static let shared = WebAssets()

    /// Posted on the main actor with the asset's name as `object` when a fetch has arrived.
    public static let didArrive = Notification.Name("TangoWebAssetDidArrive")

    /// Fetches one address. Replaced in tests, which must not reach the web.
    public typealias Transport = @Sendable (URL) async throws -> Data
    public var transport: Transport = WebAssets.fetchFromGoogle

    /// Where fetched files are kept on this device; nil keeps them in memory only.
    public var folder: URL?

    public init(folder: URL? = WebAssets.defaultFolder) {
        self.folder = folder
    }

    public nonisolated static var defaultFolder: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Tango/Web", isDirectory: true)
    }

    // MARK: Files

    private var memory: [String: Data] = [:]
    private var inFlight: Set<String> = []
    /// Names whose fetch failed, and when: not asked for again for a minute.
    private var failed: [String: Date] = [:]
    private static let retryAfter: TimeInterval = 60

    /// A fetched file, from memory or this device's cache.
    public func data(named name: String) -> Data? {
        if let known = memory[name] { return known }
        guard WebAssetNames.isWebAsset(name), !name.contains("/"), let folder,
              let data = try? Data(contentsOf: folder.appendingPathComponent(name))
        else { return nil }
        memory[name] = data
        return data
    }

    /// Whether `name` is being fetched now.
    public func isFetching(_ name: String) -> Bool { inFlight.contains(name) }

    /// Fetches `url` into `name` unless it is here, on its way, or failed a moment ago.
    /// `convert` turns what came back into the file to keep (a stylesheet into its font).
    func fetch(_ name: String, from url: URL, convert: (@Sendable (Data, @escaping Transport) async throws -> Data)? = nil) {
        guard data(named: name) == nil, !inFlight.contains(name) else { return }
        if let when = failed[name], Date().timeIntervalSince(when) < Self.retryAfter { return }
        inFlight.insert(name)
        let transport = transport
        Task { [weak self] in
            var result: Data?
            do {
                let fetched = try await transport(url)
                result = try await convert?(fetched, transport) ?? fetched
            } catch {
                result = nil
            }
            self?.arrived(name, result)
        }
    }

    private func arrived(_ name: String, _ data: Data?) {
        inFlight.remove(name)
        guard let data, !data.isEmpty else {
            failed[name] = Date()
            return
        }
        if GoogleFonts.isFontAsset(name), !FontBook.register(data, named: name) {
            failed[name] = Date()
            return
        }
        memory[name] = data
        if let folder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: folder.appendingPathComponent(name), options: .atomic)
        }
        NotificationCenter.default.post(name: Self.didArrive, object: name)
    }

    // MARK: Icons

    private var glyphs: [String: VectorGlyph] = [:]

    /// The asset a Material Symbols glyph is kept as, and the glyph: from the document's
    /// assets, this device's cache, or (with `fetches`) fetched and nil until it arrives.
    public func glyph(_ icon: IconName, weight: Double, assets: [String: Data], fetches: Bool) -> VectorGlyph? {
        guard let name = MaterialSymbols.assetName(icon, weight: weight) else { return nil }
        if let known = glyphs[name] { return known }
        guard let data = assets[name] ?? data(named: name) else {
            if fetches, MaterialSymbols.known.contains(icon.name), let url = MaterialSymbols.url(icon, weight: weight) {
                fetch(name, from: url)
            }
            return nil
        }
        guard let glyph = MaterialSymbols.glyph(svg: data) else { return nil }
        if glyphs.count > 1000 { glyphs.removeAll() }
        glyphs[name] = glyph
        return glyph
    }

    // MARK: Fonts

    /// Makes sure the style of a Google family that text with this weight and slant is set
    /// in is registered: from the document's assets, this device's cache, or (with
    /// `fetches`) fetched. Returns the asset's name, or nil for a family that is not on
    /// Google Fonts (the system's, one installed here).
    @discardableResult
    public func wantFont(family name: String, weight: Double, italic: Bool, assets: [String: Data], fetches: Bool) -> String? {
        guard !FontBook.isSystemDesign(name), let family = GoogleFonts.family(name),
              let style = GoogleFonts.style(of: family, weight: weight, italic: italic)
        else { return nil }
        let asset = GoogleFonts.assetName(family: family, style: style)
        if let data = assets[asset] ?? data(named: asset) {
            FontBook.register(data, named: asset)
        } else if fetches, let css = GoogleFonts.cssURL(family: family, style: style) {
            fetch(asset, from: css) { stylesheet, transport in
                guard let text = String(data: stylesheet, encoding: .utf8), let file = GoogleFonts.fontURL(inCSS: text) else {
                    throw URLError(.cannotDecodeContentData)
                }
                return try await transport(file)
            }
        }
        return asset
    }

    // MARK: Sending

    /// Google's servers, and nothing else: an address anywhere else is refused, so no
    /// document can use this to reach another host.
    public nonisolated static let fetchFromGoogle: Transport = { url in
        guard url.scheme == "https", let host = url.host, ["fonts.gstatic.com", "fonts.googleapis.com"].contains(host) else {
            throw URLError(.unsupportedURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("tango", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 30_000_000 else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

/// What a host that draws a prototype hands its renderer for icons and fonts that are
/// fetched: the document's assets come first, then the device's cache, then (when the host
/// may, `fetches`) Google. `drawn` hears the whole set of such assets each renderer drew
/// last, so the editor can keep exactly those.
public struct WebAssetClient {
    public var assets: () -> [String: Data]
    public var fetches: () -> Bool
    public var drawn: ((ObjectIdentifier, Set<String>) -> Void)?

    public init(
        assets: @escaping () -> [String: Data], fetches: @escaping () -> Bool,
        drawn: ((ObjectIdentifier, Set<String>) -> Void)? = nil
    ) {
        self.assets = assets
        self.fetches = fetches
        self.drawn = drawn
    }

    public init(assets: @escaping () -> [String: Data], fetches: Bool, drawn: ((ObjectIdentifier, Set<String>) -> Void)? = nil) {
        self.init(assets: assets, fetches: { fetches }, drawn: drawn)
    }

    /// Sets `renderer` to find Material glyphs and Google fonts through `WebAssets.shared`.
    public func attach(to renderer: LayerRenderer) {
        let client = self
        renderer.iconProvider = { icon, weight in
            WebAssets.shared.glyph(icon, weight: weight, assets: client.assets(), fetches: client.fetches())
        }
        renderer.onFont = { family, weight, italic in
            WebAssets.shared.wantFont(family: family, weight: weight, italic: italic, assets: client.assets(), fetches: client.fetches())
        }
        if let drawn {
            let id = ObjectIdentifier(renderer)
            renderer.onDrawnWebAssets = { drawn(id, $0) }
        }
    }
}
