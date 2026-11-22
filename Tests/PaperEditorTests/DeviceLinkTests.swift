import CoreImage
import Foundation
import Network
import Testing
import PaperEngine
import PaperHost
import PaperLink
import PaperModel
import PaperPlayer
@testable import PaperEditor

/// The whole path with real sockets on this Mac: the editor's `DeviceLink`, TLS with the
/// key over loopback, the player's `PlayerStore`, and the `Runtime` it runs.
@MainActor @Suite(.serialized) struct DeviceLinkTests {
    private func wait(_ what: String, seconds: Double = 60, until done: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !done() {
            guard Date() < end else {
                Issue.record("Timed out waiting for \(what)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func pair() async throws -> (mac: DeviceLink, phone: PlayerStore) {
        let mac = DeviceLink(keys: MemoryLinkKeyStore(), advertises: false)
        mac.helloWait = 600
        mac.isEnabled = true
        try await wait("the Mac to listen") { mac.port != nil }
        let key = try #require(mac.key)
        let phone = PlayerStore(
            keys: MemoryLinkKeyStore(key), deviceName: "Test iPhone", screen: CGSize(width: 402, height: 874), sendsRequests: false
        )
        phone.connect(to: .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: mac.port!)!), name: "Mac")
        try await wait("the phone to say hello") { mac.phones.count == 1 }
        #expect(mac.phones.first?.name == "Test iPhone")
        #expect(mac.phones.first?.notice == nil)
        return (mac, phone)
    }

    @Test func aPrototypeReachesThePhoneAndEditsFollowWithItsStateKept() async throws {
        let (mac, phone) = try await pair()
        var document = Gallery.item("card")!.make()
        mac.publish(.init(prototype: "doc", name: "Card", package: DocumentPackage(document: document)))
        try await wait("the prototype") { phone.live != nil }
        let host = try #require(phone.live?.host)
        #expect(phone.live?.name == "Card")
        #expect(host.runtime.document == document)

        // The prototype has run a while, with a finger down, when an edit arrives.
        host.send(.touchBegan(id: 0, Point2(x: 200, y: 400)))
        for _ in 0..<30 { host.step(dt: 1.0 / 60) }
        let frames = host.runtime.frameCount
        document.screen.name = "Edited"
        mac.publish(.init(prototype: "doc", name: "Card", package: DocumentPackage(document: document)))
        try await wait("the edit") { host.runtime.document.screen.name == "Edited" }
        // The same host, not a new one, and it did not start over.
        #expect(phone.live?.host === host)
        #expect(host.runtime.frameCount >= frames)
        host.send(.touchEnded(id: 0, Point2(x: 200, y: 400)))
        host.step(dt: 1.0 / 60)

        // Restart on the Mac starts it over on the phone.
        mac.publish(.init(prototype: "doc", name: "Card", package: DocumentPackage(document: document), restartToken: 1))
        try await wait("the restart") { host.runtime.frameCount < frames }
        try await wait("the Mac to hear it was shown") { mac.phones.first?.shows == phone.live?.revision }
        mac.isEnabled = false
    }

    @Test func aDragSendsTheLastDocumentAndNotEveryOneBetween() async throws {
        let (mac, phone) = try await pair()
        let video = Data((0..<200_000).map { UInt8($0 % 253) })
        var document = Gallery.item("card")!.make()
        var crossed = 0
        phone.received = { update, package in
            crossed += 1
            #expect(package.assets["clip.mov"] == video)
        }
        // Sixty documents in a row, as a drag makes them.
        for step in 1...60 {
            document.screen.name = "Step \(step)"
            mac.publish(.init(prototype: "doc", name: "Drag", package: DocumentPackage(document: document, assets: ["clip.mov": video])))
        }
        try await wait("the last step") { phone.live?.host.runtime.document.screen.name == "Step 60" }
        // Far fewer updates than documents: the ones between were never sent.
        #expect(crossed < 60)
        #expect(phone.live?.host.assets["clip.mov"] == video)
        mac.isEnabled = false
    }

    @Test func anotherDocumentReplacesThePrototypeAndAClosedOneGoes() async throws {
        let (mac, phone) = try await pair()
        mac.publish(.init(prototype: "one", name: "One", package: Gallery.item("card")!.package()))
        try await wait("the first") { phone.live?.id == "one" }
        let first = phone.live?.host
        mac.publish(.init(prototype: "two", name: "Two", package: Gallery.item("kit")!.package(), keeps: false))
        try await wait("the second") { phone.live?.id == "two" }
        #expect(phone.live?.host !== first)
        mac.withdraw(prototype: "two")
        try await wait("it to close") { phone.live == nil }
        // It does not come back: nothing of it was left waiting to be sent.
        try await Task.sleep(for: .milliseconds(300))
        #expect(phone.live == nil)
        mac.isEnabled = false
    }

    @Test func aPhoneWithAnotherKeyGetsNothing() async throws {
        let mac = DeviceLink(keys: MemoryLinkKeyStore(), advertises: false)
        mac.isEnabled = true
        try await wait("the Mac to listen") { mac.port != nil }
        mac.publish(.init(prototype: "doc", name: "Secret", package: Gallery.item("card")!.package()))
        let stranger = PlayerStore(
            keys: MemoryLinkKeyStore(.random()), deviceName: "Stranger", screen: .zero, sendsRequests: false
        )
        stranger.connect(to: .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: mac.port!)!), name: "Mac")
        try await wait("the handshake to fail") { stranger.link == .searching }
        #expect(mac.phones.isEmpty)
        #expect(stranger.live == nil)
        mac.isEnabled = false
    }

    @Test func aNewKeyTurnsAwayThePhonesPairedWithTheOld() async throws {
        let (mac, phone) = try await pair()
        let old = mac.key
        mac.newKey()
        #expect(mac.key != old)
        try await wait("the phone to be dropped") { mac.phones.isEmpty && phone.link == .searching }
        // Coming back with the old key, it is turned away.
        try await wait("the Mac to listen again") { mac.port != nil }
        phone.connect(to: .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: mac.port!)!), name: "Mac")
        try await wait("the handshake to fail") { phone.link == .searching }
        #expect(mac.phones.isEmpty)
        mac.isEnabled = false
    }

    @Test func offMeansNothingListensAndNoKeyIsMade() {
        let mac = DeviceLink(keys: MemoryLinkKeyStore(), advertises: false)
        mac.publish(.init(prototype: "doc", name: "Card", package: Gallery.item("card")!.package()))
        #expect(mac.state == .stopped)
        #expect(mac.key == nil)
    }
}

@MainActor @Suite struct DeviceLinkCodeTests {
    @Test func theCodeAPhoneScansHoldsTheKey() throws {
        let key = LinkKey.random()
        let code = try #require(DeviceLinkPanel.code(for: key.text))
        // Read it back as a camera would, enlarged: a detector wants more than a pixel a module.
        let image = CIImage(cgImage: code).transformed(by: CGAffineTransform(scaleX: 8, y: 8)).samplingNearest()
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let read = detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(read == [key.text])
        #expect(LinkKey(text: read.first ?? "") == key)
    }
}

extension DeviceLinkTests {
    @Test func aConnectionThatNeverSaysHelloIsDropped() async throws {
        let mac = DeviceLink(keys: MemoryLinkKeyStore(), advertises: false)
        mac.helloWait = 0.2
        mac.isEnabled = true
        try await wait("the Mac to listen") { mac.port != nil }
        // It has the key, so the handshake succeeds; then it says nothing.
        let silent = LinkConnection(
            to: .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: mac.port!)!), key: try #require(mac.key)
        )
        var closed = false
        silent.onState = { if case .closed = $0 { closed = true } }
        silent.start()
        try await wait("it to be dropped") { closed }
        #expect(mac.phones.isEmpty)
        mac.isEnabled = false
    }
}
