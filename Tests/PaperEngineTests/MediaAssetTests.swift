import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import PaperEngine
import PaperModel

/// Icons, fonts and photos from outside the app: reading their shapes, naming them, and the
/// Unsplash patch's requests. Nothing here reaches the network.
@Suite struct MediaAssetTests {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")

    // MARK: SVG paths

    @Test func pathDataWrittenAsTightlyAsSVGAllowsIsRead() throws {
        // Lucide's heart: numbers that run together, arc flags beside them.
        let path = try #require(SVGPath.parse(
            "M2 9.5a5.5 5.5 0 0 1 9.591-3.676.56.56 0 0 0 .818 0A5.49 5.49 0 0 1 22 9.5c0 2.29-1.5 4-3 5.5l-5.492 5.313a2 2 0 0 1-3 .019L5 15c-1.5-1.5-3-3.2-3-5.5"
        ))
        let box = path.boundingBoxOfPath
        #expect(abs(box.minX - 2) < 0.01)
        #expect(abs(box.maxX - 22) < 0.01)
        #expect(box.minY > 3 && box.minY < 4.5)
        #expect(box.maxY > 20 && box.maxY < 21.5)
    }

    @Test func everyCommandAbsoluteAndRelativeLandsWhereItShould() throws {
        let path = try #require(SVGPath.parse("M10 10h10v10H10zm5 5l2 0 0 2-2 0z M0 0q5 5 10 0t10 0 M0 30 c 1 1 2 2 3 3 s 4 4 5 5"))
        let box = path.boundingBoxOfPath
        #expect(box.minX == 0)
        #expect(box.maxX == 20)
        #expect(box.maxY == 38)
        // A half circle by arc: from (0,0) to (10,0) bulges 5 below or above.
        let below = try #require(SVGPath.parse("M0 0A5 5 0 0 0 10 0")).boundingBoxOfPath
        #expect(abs(below.width - 10) < 0.001 && abs(below.height - 5) < 0.001)
        // Radii too small to reach are scaled up.
        let scaled = try #require(SVGPath.parse("M0 0a1 1 0 0 1 10 0")).boundingBoxOfPath
        #expect(abs(scaled.height - 5) < 0.001)
        // Exponents.
        #expect(SVGPath.parse("M1e1 0L2e1 1e-1")?.boundingBoxOfPath.maxX == 20)
    }

    @Test func whatIsNotPathDataIsNothing() {
        #expect(SVGPath.parse("") == nil)
        #expect(SVGPath.parse("hello") == nil)
        #expect(SVGPath.parse("10 10") == nil)
        // A path cut short keeps what came before.
        #expect(SVGPath.parse("M0 0L10 10L5") != nil)
    }

    // MARK: Icons

    @Test func everyLucideIconIsDrawnInsideItsBox() throws {
        #expect(LucideIcons.names.count > 1500)
        for name in LucideIcons.names {
            let glyph = try #require(LucideIcons.glyph(name), "\(name)")
            let box = (glyph.stroked ?? glyph.filled)!.boundingBoxOfPath
            #expect(box.minX >= -0.5 && box.minY >= -0.5 && box.maxX <= 24.5 && box.maxY <= 24.5, "\(name): \(box)")
        }
        #expect(LucideIcons.glyph("no-such-icon") == nil)
    }

    @Test func aLucideIconIsLinesAsWideAsItsWeight() throws {
        let regular = try #require(LucideIcons.glyph("heart", weight: 400))
        #expect(regular.lineWidth == 2)
        #expect(LucideIcons.glyph("heart", weight: 100)?.lineWidth == 0.5)
        #expect(LucideIcons.glyph("heart", weight: .nan)?.lineWidth == 2)
        // Its dots are filled.
        #expect(LucideIcons.glyph("ellipsis")?.filled != nil || LucideIcons.glyph("ellipsis")?.stroked != nil)
        let picture = try #require(regular.image(width: 48, height: 48, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1)))
        #expect(picture.width == 48)
        #expect(regular.image(width: 0, height: 48, color: CGColor(gray: 0, alpha: 1)) == nil)
    }

    @Test func aSymbolValueNamesItsSet() {
        #expect(IconName("heart.fill") == IconName(set: .sf, name: "heart.fill", filled: true))
        #expect(IconName("lucide:heart") == IconName(set: .lucide, name: "heart"))
        #expect(IconName("material-rounded:favorite.fill") == IconName(set: .materialRounded, name: "favorite", filled: true))
        #expect(IconName("material:home")?.value == "material:home")
        #expect(IconName("material-sharp:star.fill")?.value == "material-sharp:star.fill")
        #expect(IconName("nope:heart") == nil)
        #expect(IconName("lucide:") == nil)
        #expect(IconName("") == nil)
        #expect(IconName("lucide:heart")?.isKnown == true)
        #expect(IconName("material:home")?.isKnown == true)
        #expect(IconName("material:not_an_icon_at_all")?.isKnown == false)
    }

    @Test func theIconPatchNamesAnIconHowEverItIsWritten() {
        #expect(IconName.forPatch(set: "Lucide", name: "Arrow Right", filled: false)?.value == "lucide:arrow-right")
        #expect(IconName.forPatch(set: "Material Symbols Rounded", name: "shopping-cart", filled: true)?.value == "material-rounded:shopping_cart.fill")
        #expect(IconName.forPatch(set: "Rounded", name: "home", filled: false)?.value == "material-rounded:home")
        #expect(IconName.forPatch(set: "SF Symbols", name: "heart", filled: true)?.value == "heart.fill")
        #expect(IconName.forPatch(set: "Lucide", name: "material:home", filled: false)?.value == "material:home")
        #expect(IconName.forPatch(set: "Lucide", name: "  ", filled: false) == nil)
    }

    @Test func aMaterialGlyphIsNamedFetchedAndReadAsGoogleServesIt() throws {
        let icon = IconName(set: .materialRounded, name: "favorite", filled: true)
        #expect(MaterialSymbols.variant(filled: false, weight: 400) == "default")
        #expect(MaterialSymbols.variant(filled: true, weight: 700) == "wght700fill1")
        #expect(MaterialSymbols.variant(filled: false, weight: 900) == "wght700")
        #expect(MaterialSymbols.assetName(icon, weight: 400) == "web.material-rounded.favorite.fill1.svg")
        #expect(MaterialSymbols.url(icon, weight: 300)?.absoluteString
            == "https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsrounded/favorite/wght300fill1/24px.svg")
        // A name that could reach anywhere else is never an address or a file.
        #expect(MaterialSymbols.url(IconName(set: .material, name: "../x"), weight: 400) == nil)
        #expect(MaterialSymbols.assetName(IconName(set: .material, name: "a/b"), weight: 400) == nil)

        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" height="24" viewBox="0 -960 960 960" width="24"><path d="M480-120 120-480l360-360 360 360-360 360Z"/></svg>"#
        let glyph = try #require(MaterialSymbols.glyph(svg: Data(svg.utf8)))
        #expect(glyph.box == CGRect(x: 0, y: -960, width: 960, height: 960))
        #expect(glyph.filled?.boundingBoxOfPath == CGRect(x: 120, y: -840, width: 720, height: 720))
        #expect(MaterialSymbols.glyph(svg: Data("not svg".utf8)) == nil)
        #expect(MaterialSymbols.known.count > 3000)
    }

    // MARK: Fonts

    @Test func theSystemsDesignsAreTheirOwnFaces() {
        let names = ["", "SF Pro Rounded", "New York", "SF Mono"].map {
            CTFontCopyPostScriptName(FontBook.font(family: $0, size: 17, weight: 400)) as String
        }
        #expect(Set(names).count == 4)
        let bold = FontBook.font(family: "", size: 17, weight: 700)
        #expect(CTFontGetSymbolicTraits(bold).contains(.traitBold))
        let italic = FontBook.font(family: "Georgia", size: 17, weight: 400, italic: true)
        #expect(CTFontGetSymbolicTraits(italic).contains(.traitItalic))
        #expect(FontBook.isAvailable("Georgia"))
        #expect(FontBook.isSystemDesign("SF Pro"))
    }

    @Test func aGoogleFamilyIsSetInTheSystemFontUntilItsFileIsRegistered() throws {
        let family = try #require(GoogleFonts.family("abeezee"))
        #expect(family.name == "ABeeZee")
        let before = FontBook.font(family: "ABeeZee", size: 17, weight: 400)
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("fonts/ABeeZee-400.ttf"))
        let asset = GoogleFonts.assetName(family: family, style: "400")
        #expect(asset == "web.font.ABeeZee.400.ttf")
        let measuredBefore = TextMeasurer.measure("Hello there", fontSize: 17, weight: 400, family: "ABeeZee", maxWidth: nil)
        FontBook.register(assets: [asset: data, "photo.png": Data([1, 2])])
        let after = FontBook.font(family: "ABeeZee", size: 17, weight: 400)
        #expect(CTFontCopyFamilyName(after) as String == "ABeeZee")
        #expect(FontBook.isAvailable("ABeeZee"))
        _ = before
        let measured = TextMeasurer.measure("Hello there", fontSize: 17, weight: 400, family: "ABeeZee", maxWidth: nil)
        #expect(measured != measuredBefore)
        // A weight it does not have is set in the nearest it has.
        #expect(CTFontCopyFamilyName(FontBook.font(family: "ABeeZee", size: 17, weight: 800)) as String == "ABeeZee")
        // Registering again changes nothing; a file that is not a font is refused.
        let generation = FontBook.generation
        FontBook.register(assets: [asset: data])
        #expect(FontBook.generation == generation)
        #expect(!FontBook.register(Data("no".utf8), named: "web.font.Nope.400.ttf"))
    }

    @Test func aGoogleStyleIsTheNearestOfTheRightSlant() throws {
        let inter = try #require(GoogleFonts.family("Inter"))
        #expect(GoogleFonts.style(of: inter, weight: 600, italic: false) == "600")
        #expect(GoogleFonts.style(of: inter, weight: 650, italic: true) == "700i")
        let abeezee = try #require(GoogleFonts.family("ABeeZee"))
        #expect(GoogleFonts.style(of: abeezee, weight: 900, italic: false) == "400")
        let lobster = try #require(GoogleFonts.family("Lobster"))
        #expect(GoogleFonts.style(of: lobster, weight: 400, italic: true) == "400")
        #expect(GoogleFonts.cssURL(family: inter, style: "700i")?.absoluteString
            == "https://fonts.googleapis.com/css2?family=Inter:ital,wght@1,700")
        #expect(GoogleFonts.assetName(family: try #require(GoogleFonts.family("Open Sans")), style: "700i") == "web.font.Open_Sans.700i.ttf")
        #expect(GoogleFonts.families.count > 1500)
    }

    @Test func aStylesheetSendsToGooglesFontServerOnly() {
        #expect(GoogleFonts.fontURL(inCSS: "src: url(https://fonts.gstatic.com/s/inter/v20/x.ttf) format('truetype');")?.host == "fonts.gstatic.com")
        #expect(GoogleFonts.fontURL(inCSS: "src: url(https://evil.example/x.ttf)") == nil)
        #expect(GoogleFonts.fontURL(inCSS: "src: url(http://fonts.gstatic.com/x.ttf)") == nil)
        #expect(GoogleFonts.fontURL(inCSS: "nothing") == nil)
    }

    @Test func aTextsFontIsLaidOutInItsFamily() {
        var layer = Layer.new(.text)
        layer.properties[.text] = .text("Wide words in a mono face")
        layer.properties[.widthMode] = .text("Auto")
        let system = ResolvedLayer(layer).laidOut().size.width
        layer.properties[.fontFamily] = .text("SF Mono")
        let mono = ResolvedLayer(layer).laidOut().size.width
        #expect(mono > system)
        #expect(LayerProperty.properties(for: LayerKind.text).contains(.fontFamily))
        #expect(LayerProperty.properties(for: LayerKind.textField).contains(.italic))
    }

    @Test func theFontPatchSaysWhereAFamilyComesFrom() {
        var document = Document()
        let font = document.graph.add(PatchNode(kind: PatchKind.font, inputs: ["family": .text("playfair display")]))
        let system = document.graph.add(PatchNode(kind: PatchKind.font, inputs: ["family": .text("avenir next")]))
        let runtime = Runtime(document: document)
        runtime.advance(seconds: 0.1)
        #expect(runtime.outputValue(PortRef(node: font, port: "font")) == .text("Playfair Display"))
        #expect(runtime.outputValue(PortRef(node: font, port: "source")) == .text("Google Fonts"))
        #expect(runtime.outputValue(PortRef(node: system, port: "font")) == .text("Avenir Next"))
        #expect(runtime.outputValue(PortRef(node: system, port: "source")) == .text("System"))
    }

    @Test func theIconPatchFeedsASymbolView() {
        var document = Document()
        let symbol = Layer(name: "Like", kind: .symbol)
        document.screen.children.append(symbol)
        document.normalize()
        let icon = document.graph.add(PatchNode(kind: PatchKind.icon, inputs: [
            "set": .text("Material Symbols Rounded"), "name": .text("favorite"), "filled": .bool(true),
        ]))
        let view = document.graph.nodes.first { $0.layerID == symbol.id }!
        document.graph.connect(from: PortRef(node: icon, port: "symbol"), to: PortRef(node: view.id, port: LayerProperty.symbol.rawValue))
        let runtime = Runtime(document: document)
        runtime.advance(seconds: 0.1)
        #expect(runtime.resolved.find(symbol.id)?.value(.symbol) == .text("material-rounded:favorite.fill"))
        #expect(runtime.outputValue(PortRef(node: icon, port: "known")) == .bool(true))
    }

    // MARK: Unsplash

    static let listing = #"""
    {"total": 2, "results": [
      {"id": "a1", "color": "#336699", "description": null, "alt_description": "a red boat",
       "urls": {"small": "https://images.unsplash.com/photo-a1?w=400", "regular": "https://images.unsplash.com/photo-a1?w=1080", "full": "https://images.unsplash.com/photo-a1"},
       "links": {"download_location": "https://api.unsplash.com/photos/a1/download"},
       "user": {"name": "Ada Lens", "links": {"html": "https://unsplash.com/@ada"}}},
      {"id": "b2", "color": "#000000", "description": "Night",
       "urls": {"regular": "https://evil.example/b2.jpg"},
       "links": {"download_location": "https://evil.example/download"},
       "user": {"name": "Bo", "links": {"html": "https://unsplash.com/@bo"}}}
    ]}
    """#

    @Test func anUnsplashPhotoIsSearchedFetchedCreditedAndReported() throws {
        var document = Document()
        let photo = document.graph.add(PatchNode(kind: PatchKind.unsplashPhoto, inputs: ["query": .text("boats & sea"), "orientation": .text("Portrait")]))
        let runtime = Runtime(document: document)
        var sent: [NetworkRequest] = []
        runtime.requestHandler = { sent.append($0) }
        runtime.advance(seconds: 0.1)
        let search = try #require(sent.first)
        #expect(sent.count == 1)
        #expect(search.service == Unsplash.service)
        #expect(search.url == "https://api.unsplash.com/search/photos?content_filter=high&orientation=portrait&query=boats%20%26%20sea&per_page=30")
        #expect(runtime.outputValue(PortRef(node: photo, port: "loading")) == .bool(true))

        runtime.complete(search.id, with: NetworkResponse(status: 200, body: Data(Self.listing.utf8)))
        runtime.advance(seconds: 0.1)
        // The picture, from Unsplash's picture server, with no key; and the use reported.
        let picture = try #require(sent.first { $0.url.hasPrefix("https://images.unsplash.com/") })
        #expect(picture.url == "https://images.unsplash.com/photo-a1?w=1080")
        #expect(picture.service == nil)
        #expect(sent.contains { $0.url == "https://api.unsplash.com/photos/a1/download" && $0.service == Unsplash.service })
        #expect(runtime.outputValue(PortRef(node: photo, port: "photographer")) == .text("Ada Lens"))
        #expect(runtime.outputValue(PortRef(node: photo, port: "profile")) == .text("https://unsplash.com/@ada?utm_source=tango&utm_medium=referral"))
        #expect(runtime.outputValue(PortRef(node: photo, port: "description")) == .text("a red boat"))
        #expect(runtime.outputValue(PortRef(node: photo, port: "color")) == .color(ColorValue(hex: "#336699")!))
        #expect(runtime.outputValue(PortRef(node: photo, port: "count")) == .number(2))

        runtime.complete(picture.id, with: NetworkResponse(status: 200, body: Data([0xFF, 0xD8]), headers: ["content-type": "image/jpeg"]))
        runtime.advance(seconds: 0.1)
        #expect(runtime.outputValue(PortRef(node: photo, port: "image")) == .text(NetworkRequest.pictureName(for: picture.id)))
        #expect(runtime.outputValue(PortRef(node: photo, port: "loading")) == .bool(false))

        // The second photo names a picture server that is not Unsplash's: nothing is fetched.
        let before = sent.count
        document.graph.nodes[document.graph.nodes.firstIndex { $0.id == photo }!].inputs["index"] = .number(1)
        runtime.update(document: document)
        runtime.advance(seconds: 0.1)
        #expect(!sent[before...].contains { $0.url.contains("evil.example") })
        #expect(runtime.outputValue(PortRef(node: photo, port: "photographer")) == .text("Bo"))
    }

    @Test func noSearchIsRandomAndAFailureIsSaid() throws {
        var document = Document()
        let photo = document.graph.add(PatchNode(kind: PatchKind.unsplashPhoto))
        let runtime = Runtime(document: document)
        var sent: [NetworkRequest] = []
        runtime.requestHandler = { sent.append($0) }
        runtime.advance(seconds: 0.1)
        #expect(sent.first?.url == "https://api.unsplash.com/photos/random?content_filter=high&count=30")
        runtime.complete(sent[0].id, with: NetworkResponse(status: 401, body: Data()))
        runtime.advance(seconds: 0.1)
        #expect(runtime.outputValue(PortRef(node: photo, port: "error"))?.textValue.contains("access key") == true)
        #expect(runtime.outputValue(PortRef(node: photo, port: "loading")) == .bool(false))
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func aLoopOfPhotosIsOneSearch() throws {
        var document = Document()
        let photo = document.graph.add(PatchNode(kind: PatchKind.unsplashPhoto, inputs: ["query": .text("c++ code")]))
        let loop = document.graph.add(PatchNode(kind: "loop", inputs: ["count": .number(3)]))
        document.graph.connect(from: PortRef(node: loop, port: "index"), to: PortRef(node: photo, port: "index"))
        let runtime = Runtime(document: document)
        var sent: [NetworkRequest] = []
        runtime.requestHandler = { sent.append($0) }
        runtime.advance(seconds: 0.1)
        #expect(sent.count == 1)
        // A `+` is sent encoded, not read as a space.
        #expect(sent.first?.url.contains("query=c%2B%2B%20code") == true)
        runtime.complete(sent[0].id, with: NetworkResponse(status: 200, body: Data(Self.listing.utf8)))
        runtime.advance(seconds: 0.1)
        let photographers = runtime.outputValues(PortRef(node: photo, port: "photographer"))
        #expect(photographers == [.text("Ada Lens"), .text("Bo"), .text("Ada Lens")])
        // One picture for the photo two rows show, and none from a server that is not Unsplash's.
        #expect(sent.filter { $0.url.hasPrefix("https://images.unsplash.com/") }.count == 1)
        #expect(sent.filter { $0.url.contains("search/photos") }.count == 1)
    }

    @Test func aPhotoThatFailsIsNotAskedForAgain() throws {
        var document = Document()
        let photo = document.graph.add(PatchNode(kind: PatchKind.unsplashPhoto, inputs: ["query": .text("boat")]))
        let runtime = Runtime(document: document)
        var sent: [NetworkRequest] = []
        runtime.requestHandler = { sent.append($0) }
        runtime.advance(seconds: 0.1)
        runtime.complete(sent[0].id, with: NetworkResponse(status: 200, body: Data(Self.listing.utf8)))
        runtime.advance(seconds: 0.1)
        let picture = try #require(sent.first { $0.url.hasPrefix("https://images.unsplash.com/") })
        runtime.complete(picture.id, with: NetworkResponse(status: 0, error: "offline"))
        runtime.advance(seconds: 0.5)
        #expect(sent.filter { $0.url.hasPrefix("https://images.unsplash.com/") }.count == 1)
        #expect(runtime.outputValue(PortRef(node: photo, port: "error")) == .text("offline"))
        #expect(runtime.outputValue(PortRef(node: photo, port: "loading")) == .bool(false))
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func aDocumentsFontIsRegisteredOnlyAsTheGoogleFamilyItsNameSays() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("fonts/ABeeZee-400.ttf"))
        // ABeeZee's file under Inter's name, or under a family Google does not have.
        #expect(!FontBook.register(data, named: "web.font.Inter.400.ttf"))
        #expect(!FontBook.register(data, named: "web.font.Georgia.400.ttf"))
        #expect(!FontBook.register(data, named: "web.font..ttf"))
        #expect(GoogleFonts.family(ofAsset: "web.font.Open_Sans.700i.ttf")?.name == "Open Sans")
        #expect(FontBook.register(data, named: "web.font.ABeeZee.400.ttf"))
    }

    @Test func theKeyGoesToUnsplashsAPIAndNowhereElse() {
        let good = NetworkRequest(url: "https://api.unsplash.com/search/photos?query=x")
        #expect(Unsplash.signed(good, key: "abc")?.headers["Authorization"] == "Client-ID abc")
        for address in ["https://images.unsplash.com/x", "http://api.unsplash.com/x", "https://api.unsplash.com.evil.example/x",
                        "https://api.unsplash.com:8443/x", "https://evil.example/?api.unsplash.com"] {
            #expect(Unsplash.signed(NetworkRequest(url: address), key: "abc") == nil, "\(address)")
        }
        #expect(Unsplash.signed(NetworkRequest(url: "https://api.unsplash.com/x", method: "POST"), key: "abc") == nil)
        #expect(Unsplash.signed(good, key: "abc\nX-Evil: 1") == nil)
    }
}
