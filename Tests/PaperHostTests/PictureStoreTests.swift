import CoreGraphics
import Foundation
import ImageIO
import Testing
import PaperEngine
import PaperModel
import UniformTypeIdentifiers
@testable import PaperHost

/// A small PNG of one color, as a document's asset would hold it.
private func png(red: CGFloat = 1, width: Int = 4, height: Int = 4) -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(srgbRed: red, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private func picture() -> CGImage {
    PictureStore.decode(png())!
}

@Suite struct PictureStoreTests {
    @Test func aPictureShownAgainIsDecodedOnce() {
        let store = PictureStore()
        let assets = ["photo.png": png()]
        let first = store.asset(named: "photo.png", in: assets)
        #expect(first?.width == 4)
        // A renderer asks on every frame it draws.
        for _ in 0..<50 { #expect(store.asset(named: "photo.png", in: assets) === first) }
        #expect(store.decodes == 1)
    }

    @Test func anAssetWhoseBytesChangedIsDecodedAgain() {
        let store = PictureStore()
        #expect(store.asset(named: "photo.png", in: ["photo.png": png(width: 4)])?.width == 4)
        // The same name, another picture: replaced in the Inspector, or undone.
        #expect(store.asset(named: "photo.png", in: ["photo.png": png(width: 8)])?.width == 8)
        // Bytes of the same length are still told apart.
        let dark = store.asset(named: "photo.png", in: ["photo.png": png(red: 0, width: 8)])
        #expect(store.decodes == 3)
        #expect(dark != nil)
    }

    @Test func whatIsNotAPictureIsRememberedAsNone() {
        let store = PictureStore()
        let assets = ["notes.txt": Data("not a picture".utf8)]
        #expect(store.asset(named: "notes.txt", in: assets) == nil)
        #expect(store.asset(named: "notes.txt", in: assets) == nil)
        #expect(store.decodes == 1)
        #expect(store.asset(named: "missing.png", in: assets) == nil)
        #expect(store.decodes == 1)
    }

    @Test func thePictureShownLongestAgoIsDroppedFirst() {
        let store = PictureStore()
        let one = picture()
        for index in 0..<PictureStore.mostKept { store.keep(one, named: "fetched:\(index)") }
        // The first is shown again, so the second is now the one shown longest ago.
        #expect(store.kept(named: "fetched:0") != nil)
        store.keep(one, named: "fetched:new")
        #expect(store.kept(named: "fetched:1") == nil)
        #expect(store.kept(named: "fetched:0") != nil)
        #expect(store.kept(named: "fetched:new") != nil)
    }

    @Test func aNameSaysWhereItsPictureIs() {
        let store = PictureStore()
        let assets = ["photo.png": png(), "fetched:asset": png(), "capture:9": png()]
        store.keep(picture(), named: "ai:made")
        store.captured = { $0 == "capture:1" ? picture() : nil }
        #expect(store.picture(named: "photo.png", assets: assets, registry: nil) != nil)
        #expect(store.picture(named: "ai:made", assets: assets, registry: nil) != nil)
        #expect(store.picture(named: "capture:1", assets: assets, registry: nil) != nil)
        // A document cannot stand in for what the host keeps by naming an asset like it.
        #expect(store.picture(named: "fetched:asset", assets: assets, registry: nil) == nil)
        #expect(store.picture(named: "capture:9", assets: assets, registry: nil) == nil)
        #expect(store.picture(named: "ext:nobody/a.png", assets: assets, registry: .standard) == nil)
    }

    @Test func anAnswerThatIsAPictureIsKeptForThePatch() {
        let store = PictureStore()
        let id = UUID()
        let answer = store.settle(
            NetworkResponse(status: 200, body: png(), error: nil, headers: ["content-type": "image/png"]), for: id
        )
        #expect(answer.headers["content-type"] == "image/png")
        #expect(store.kept(named: NetworkRequest.pictureName(for: id)) != nil)
    }

    @Test func anAnswerLabelledAPictureThatIsNotOneReachesThePatchAsText() {
        let store = PictureStore()
        let id = UUID()
        let answer = store.settle(
            NetworkResponse(status: 200, body: Data("<html>".utf8), error: nil, headers: ["content-type": "image/png"]),
            for: id
        )
        #expect(answer.headers["content-type"] == "application/octet-stream")
        #expect(store.kept(named: NetworkRequest.pictureName(for: id)) == nil)
    }

    @Test func aScriptsAnswerIsNeverKept() {
        let store = PictureStore()
        let id = UUID()
        let answer = store.settle(
            NetworkResponse(status: 200, body: png(), error: nil, headers: ["content-type": "image/png"]),
            for: id, keepsPicture: false
        )
        #expect(answer.headers["content-type"] == "image/png")
        #expect(store.kept(named: NetworkRequest.pictureName(for: id)) == nil)
    }
}

@Suite struct ViewportTests {
    @Test func aScreenIsCenteredAndNeverGrowsPastItsSizeUnlessItFills() throws {
        let screen = CGSize(width: 402, height: 874)
        let roomy = CGRect(x: 0, y: 0, width: 1000, height: 2000)
        let inset = try #require(Viewport.fit(screen: screen, in: roomy, fills: false))
        #expect(inset.scale == 1)
        #expect(inset.origin == CGPoint(x: 299, y: 563))
        let filling = try #require(Viewport.fit(screen: screen, in: roomy, fills: true))
        #expect(abs(filling.scale - 2000.0 / 874.0) < 1e-9)
        #expect(abs(filling.origin.y) < 1e-9)
    }

    @Test func aScreenTooLargeIsScaledDownWithAMargin() throws {
        let fit = try #require(Viewport.fit(
            screen: CGSize(width: 400, height: 800), in: CGRect(x: 0, y: 0, width: 232, height: 432), fills: false
        ))
        #expect(fit.scale == 0.5)
        #expect(fit.origin == CGPoint(x: 16, y: 16))
    }

    @Test func nothingFitsInNoRoom() {
        #expect(Viewport.fit(screen: .zero, in: CGRect(x: 0, y: 0, width: 10, height: 10), fills: true) == nil)
        #expect(Viewport.fit(screen: CGSize(width: 10, height: 10), in: CGRect(x: 0, y: 0, width: 20, height: 20), fills: false) == nil)
    }
}
