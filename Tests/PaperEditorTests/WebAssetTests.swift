import AppKit
import Foundation
import Testing
@testable import PaperEditor
import PaperEngine
import PaperHost
import PaperModel
import PaperRender

/// A document keeps the files of the fetched fonts and icons it uses, and lets go of the
/// ones it stops using. A fake Google answers, so nothing leaves the Mac.
@MainActor
@Suite(.serialized) struct WebAssetTests {
    nonisolated static let glyph = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 -960 960 960"><path d="M480-120 120-480l360-360 360 360-360 360Z"/></svg>"#
    static let font = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/fonts/ABeeZee-400.ttf")

    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func add(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
        var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    }

    /// Makes `WebAssets.shared` answer from memory, for the length of `body`.
    static func withFakeGoogle(_ body: (Asked) async throws -> Void) async rethrows {
        let shared = WebAssets.shared
        let (transport, folder) = (shared.transport, shared.folder)
        let asked = Asked()
        let fontData = try? Data(contentsOf: font)
        shared.folder = nil
        shared.transport = { url in
            asked.add(url)
            if url.host == "fonts.googleapis.com" { return Data("src: url(https://fonts.gstatic.com/s/abeezee/x.ttf) format('truetype');".utf8) }
            if url.path.hasSuffix(".ttf") { return fontData ?? Data() }
            return Data(glyph.utf8)
        }
        defer {
            shared.transport = transport
            shared.folder = folder
        }
        try await body(asked)
    }

    static func until(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aMaterialIconAndAGoogleFontAreKeptWhileUsedAndLetGoAfter() async throws {
        try await Self.withFakeGoogle { asked in
            var document = Document()
            var symbol = Layer.new(.symbol)
            symbol.properties[.symbol] = .text("material-sharp:bolt.fill")
            var text = Layer.new(.text)
            text.properties[.fontFamily] = .text("ABeeZee")
            document.screen.children += [symbol, text]
            let store = DocumentStore(package: DocumentPackage(document: document))
            store.keepsWebAssets = true
            let icon = "web.material-sharp.bolt.fill1.svg", font = "web.font.ABeeZee.400.ttf"
            await Self.until { store.assets[icon] != nil && store.assets[font] != nil }
            #expect(store.assets[icon] == Data(Self.glyph.utf8))
            #expect(store.assets[font]?.isEmpty == false)
            #expect(asked.all.contains { $0.absoluteString == "https://fonts.gstatic.com/s/i/short-term/release/materialsymbolssharp/bolt/fill1/24px.svg" })
            #expect(asked.all.contains { $0.host == "fonts.googleapis.com" })
            #expect(FontBook.isAvailable("ABeeZee"))

            // The document now names neither: both are let go; a picture of its own stays.
            store.assets["photo.png"] = Data([1])
            store.setProperty(.symbol, of: symbol.id, to: .text("lucide:zap"))
            store.setProperty(.fontFamily, of: text.id, to: .text("New York"))
            await Self.until { store.assets[icon] == nil && store.assets[font] == nil }
            #expect(store.assets.keys.sorted() == ["photo.png"])
        }
    }

    @Test func aDocumentKeepsWhatItCameWithUntilItIsSeenToStopUsingIt() async throws {
        try await Self.withFakeGoogle { _ in
            // A glyph a script chose, which nothing stored names.
            let carried = "web.material.star.default.svg"
            let store = DocumentStore(package: DocumentPackage(document: Document(), assets: [carried: Data(Self.glyph.utf8)]))
            store.keepsWebAssets = true
            store.apply("Edit") { $0.screen.children.append(Layer.new(.view)) }
            try? await Task.sleep(for: .milliseconds(50))
            #expect(store.assets[carried] != nil)
        }
    }

    @Test func anIconPatchIsKeptAtTheWeightOfTheViewItFeeds() async throws {
        try await Self.withFakeGoogle { _ in
            var document = Document()
            var symbol = Layer.new(.symbol)
            symbol.properties[.fontWeight] = .number(700)
            document.screen.children.append(symbol)
            document.normalize()
            let icon = document.graph.add(PatchNode(kind: PatchKind.icon, inputs: ["set": .text("Material Symbols"), "name": .text("home")]))
            let view = document.graph.nodes.first { $0.layerID == symbol.id }!
            document.graph.connect(from: PortRef(node: icon, port: "symbol"), to: PortRef(node: view.id, port: "symbol"))
            let store = DocumentStore(package: DocumentPackage(document: document))
            store.keepsWebAssets = true
            await Self.until { store.assets["web.material.home.wght700.svg"] != nil }
            #expect(store.assets["web.material.home.wght700.svg"] != nil)
            #expect(store.assets["web.material.home.default.svg"] == nil)
        }
    }

    @Test func whatTheViewerDrewIsKeptThoughNothingStoredNamesIt() async throws {
        try await Self.withFakeGoogle { _ in
            let store = DocumentStore(package: DocumentPackage(document: Document()))
            store.keepsWebAssets = true
            let name = "web.material.home.default.svg"
            _ = WebAssets.shared.glyph(IconName(set: .material, name: "home"), weight: 400, assets: [:], fetches: true)
            await Self.until { WebAssets.shared.data(named: name) != nil }
            let viewer = ObjectIdentifier(NSObject())
            store.setDrawnWebAssets([name], by: viewer)
            await Self.until { store.assets[name] != nil }
            #expect(store.assets[name] != nil)
            // Once that renderer draws something else, it is let go.
            store.setDrawnWebAssets([], by: viewer)
            await Self.until { store.assets[name] == nil }
            #expect(store.assets[name] == nil)
            // A store that only makes pictures keeps nothing.
            let pictures = DocumentStore(package: DocumentPackage(document: Document()))
            pictures.setDrawnWebAssets([name], by: viewer)
            #expect(pictures.assets.isEmpty)
        }
    }

    @Test func aRendererSaysWhatItDrewEachTimeThatChanges() {
        var document = Document()
        var symbol = Layer.new(.symbol)
        symbol.properties[.symbol] = .text("material:home")
        var text = Layer.new(.text)
        text.properties[.fontFamily] = .text("Inter")
        text.properties[.fontWeight] = .number(600)
        document.screen.children += [symbol, text]
        let renderer = LayerRenderer()
        var reports: [Set<String>] = []
        WebAssetClient(assets: { [:] }, fetches: false, drawn: { reports.append($1) }).attach(to: renderer)
        renderer.render(ResolvedLayer(document.screen).laidOut())
        renderer.render(ResolvedLayer(document.screen).laidOut())
        #expect(reports == [["web.material.home.default.svg", "web.font.Inter.600.ttf"]])
        document.screen.children.removeAll()
        renderer.render(ResolvedLayer(document.screen).laidOut())
        #expect(reports.last == [])
    }

    @Test func aCanvasForAPictureAsksNobody() async throws {
        try await Self.withFakeGoogle { asked in
            var document = Document()
            var symbol = Layer.new(.symbol)
            symbol.properties[.symbol] = .text("material:anchor")
            document.screen.children.append(symbol)
            let store = DocumentStore(package: DocumentPackage(document: document))
            let canvas = CanvasView(store: store)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
            canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            window.contentView = canvas
            canvas.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
            #expect(asked.all.isEmpty)
            #expect(store.drawnWebAssetNames.contains("web.material.anchor.default.svg"))
        }
    }

    @Test func onlyGooglesFontServersAreEverAsked() async {
        for address in ["https://evil.example/x.svg", "http://fonts.gstatic.com/x", "https://fonts.gstatic.com.evil.example/x"] {
            await #expect(throws: (any Error).self) { try await WebAssets.fetchFromGoogle(URL(string: address)!) }
        }
    }

    @Test func aSymbolViewDrawsLucideAtOnceAndMaterialFromTheDocument() {
        var document = Document()
        var lucide = Layer.new(.symbol)
        lucide.properties[.symbol] = .text("lucide:heart")
        var material = Layer.new(.symbol)
        material.properties[.symbol] = .text("material:home")
        document.screen.children += [lucide, material]
        let renderer = LayerRenderer()
        WebAssetClient(assets: { ["web.material.home.default.svg": Data(Self.glyph.utf8)] }, fetches: false).attach(to: renderer)
        renderer.render(ResolvedLayer(document.screen).laidOut())
        let drawn = renderer.rootLayer.sublayers?.first?.sublayers?.first?.sublayers ?? []
        #expect(drawn.count == 2)
        #expect(drawn.allSatisfy { $0.contents != nil })
    }
}
