import AppKit
import Foundation
import Testing
import PaperEngine
import PaperHost
import PaperModel
@testable import PaperEditor

/// A picture's pixels as RGBA bytes, whatever it was stored as.
private func bytes(of image: CGImage, width: Int, height: Int) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { buffer in
        let context = CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return pixels
}

/// The share of pixels whose color differs by more than a little.
private func difference(_ a: CGImage, _ b: CGImage) -> Double {
    guard a.width == b.width, a.height == b.height else { return 1 }
    let first = bytes(of: a, width: a.width, height: a.height), second = bytes(of: b, width: a.width, height: a.height)
    var differing = 0
    for pixel in 0..<(a.width * a.height) {
        let at = pixel * 4
        if abs(Int(first[at]) - Int(second[at])) > 24 || abs(Int(first[at + 1]) - Int(second[at + 1])) > 24
            || abs(Int(first[at + 2]) - Int(second[at + 2])) > 24 { differing += 1 }
    }
    return Double(differing) / Double(a.width * a.height)
}

/// The host a phone's player runs a prototype on must draw what the Mac's Viewer draws.
@MainActor @Suite struct PrototypeHostTests {
    @Test func everyGalleryItemIsDrawnAsTheViewerDrawsIt() throws {
        for item in Gallery.items {
            let package = item.package()
            let viewer = try #require(ViewerSnapshot.bitmap(of: package.document, assets: package.assets)?.cgImage, "\(item.id)")
            let host = PrototypeHost(package: package, registry: .standard, sendsRequests: false)
            host.layout(in: CGRect(origin: .zero, size: host.screenSize), fills: true, backingScale: 2)
            host.step(dt: ViewerSnapshot.frameLength)
            let ours = try #require(host.picture(), "\(item.id)")
            #expect(ours.width == viewer.width && ours.height == viewer.height, "\(item.id)")
            #expect(difference(ours, viewer) < 0.002, "\(item.id) differs in \(difference(ours, viewer)) of its pixels")
        }
    }

    @Test func aPointOfTheViewIsFoundOnTheScreen() {
        let host = PrototypeHost(package: Gallery.item("card")!.package(), sendsRequests: false)
        // Twice the size: the screen fills it at a scale of two.
        host.layout(in: CGRect(x: 0, y: 0, width: 804, height: 1748), fills: true, backingScale: 2)
        #expect(host.scale == 2)
        #expect(host.screenPoint(CGPoint(x: 402, y: 874)) == Point2(x: 201, y: 437))
        // Wider than the screen: it stands in the middle, and a point beside it is off the screen.
        host.layout(in: CGRect(x: 0, y: 0, width: 602, height: 874), fills: true, backingScale: 2)
        #expect(host.screenPoint(CGPoint(x: 100, y: 0)) == Point2(x: 0, y: 0))
        #expect(host.screenPoint(CGPoint(x: 0, y: 0)).x == -100)
    }

    @Test func anEditToTheDevicesSizeFitsTheScreenAgain() throws {
        var document = Gallery.item("card")!.make()
        let host = PrototypeHost(package: DocumentPackage(document: document), sendsRequests: false)
        let phone = CGRect(x: 0, y: 0, width: 402, height: 874)
        host.layout(in: phone, fills: true, backingScale: 3)
        #expect(host.scale == 1)
        // On the Mac the device becomes twice as wide and tall; the phone's view does not change.
        document.screen.set(.size, .size(Size2(width: 804, height: 1748)))
        host.update(document: document)
        host.step(dt: 1.0 / 60)
        #expect(host.screenSize == CGSize(width: 804, height: 1748))
        #expect(host.scale == 0.5)
        #expect(host.screenPoint(CGPoint(x: 402, y: 874)) == Point2(x: 804, y: 1748))
    }

    @Test func anEditKeepsStateAndARestartTokenStartsOver() throws {
        var document = Gallery.item("card")!.make()
        let host = PrototypeHost(package: DocumentPackage(document: document), sendsRequests: false)
        host.step(dt: 1.0 / 60)
        let before = host.runtime.frameCount
        document.screen.name = "Renamed"
        host.update(document: document, restartToken: 0)
        #expect(host.runtime.frameCount == before)
        host.update(document: document, restartToken: 1)
        #expect(host.runtime.frameCount < before || host.runtime.time == 0)
    }

    @Test func extensionsADocumentCarriesAreKnownAndDoNotRun() throws {
        let host = PrototypeHost(package: Gallery.item("card")!.package(), sendsRequests: false)
        #expect(host.registry.extensions.members.allSatisfy { !$0.isAvailable })
    }
}
