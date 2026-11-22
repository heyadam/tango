import AppKit
import Foundation
import Testing
import PaperEngine
import PaperHost
import PaperModel
@testable import PaperEditor

/// The host a phone's player runs a prototype on: where its screen goes, and what an edit keeps.
@MainActor @Suite struct PrototypeHostTests {
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
