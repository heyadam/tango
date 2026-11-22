import Foundation
import Network
import Testing
import PaperModel
@testable import PaperLink

private func snapshot(revision: Int, assets: [String: Data] = [:], restartToken: Int = 0, hashes: inout LinkHashes) throws -> LinkSnapshot {
    var document = Document.blank()
    document.screen.name = "Revision \(revision)"
    return try LinkSnapshot.make(
        of: DocumentPackage(document: document, assets: assets), prototype: "p", name: "Test", revision: revision,
        restartToken: restartToken, hashes: &hashes
    )
}

@Suite struct LinkFrameTests {
    @Test func aFrameSplitAtAnyByteStillParses() throws {
        let frame = LinkFrame(.blob(hash: "abc"), payload: Data((0..<300).map { UInt8($0 % 251) }))
        let bytes = try frame.encoded()
        for cut in 0..<bytes.count {
            #expect(LinkFrame.parse(bytes.prefix(cut)) == .incomplete, "cut at \(cut)")
        }
        #expect(LinkFrame.parse(bytes) == .frame(frame, length: bytes.count))
    }

    @Test func twoFramesInOneBufferAreReadInTurn() throws {
        let first = LinkFrame(.need(["a", "b"])), second = LinkFrame(.applied(prototype: "p", revision: 3))
        var bytes = try first.encoded() + second.encoded()
        guard case let .frame(one, length) = LinkFrame.parse(bytes) else { Issue.record("no first frame"); return }
        #expect(one == first)
        bytes.removeFirst(length)
        // What is left starts in the middle of the storage it was cut from.
        #expect(LinkFrame.parse(bytes) == .frame(second, length: bytes.count))
    }

    @Test func whatIsNotAFrameIsRefused() throws {
        #expect(LinkFrame.parse(Data("GET / HTTP/1.1\r\n".utf8)) == .invalid)
        #expect(LinkFrame.parse(Data("TN".utf8)) == .incomplete)
        #expect(LinkFrame.parse(Data("TX".utf8)) == .invalid)
        // A header that says it is enormous is refused before anything is waited for.
        #expect(LinkFrame.parse(Data("TNGO".utf8) + Data([0x7f, 0xff, 0xff, 0xff])) == .invalid)
        // So is a payload.
        let header = try JSONEncoder().encode(LinkMessage.need([]))
        let huge = Data("TNGO".utf8) + Data([0, 0, 0, UInt8(header.count)]) + header + Data([0x7f, 0xff, 0xff, 0xff])
        #expect(LinkFrame.parse(huge) == .invalid)
    }

    @Test func aMessageThisVersionDoesNotKnowIsRefusedNotCrashedOn() {
        let header = Data(#"{"teleport":{"to":"mars"}}"#.utf8)
        let bytes = Data("TNGO".utf8) + Data([0, 0, 0, UInt8(header.count)]) + header + Data([0, 0, 0, 0])
        #expect(LinkFrame.parse(bytes) == .invalid)
    }

    @Test func everyMessageSurvivesTheWire() throws {
        let messages: [LinkMessage] = [
            .hello(.init(kinds: "k", name: "Ada’s iPhone", width: 402, height: 874)),
            .update(.init(prototype: "p", name: "Card", revision: 7, restartToken: 2, startScreen: "s", keeps: false,
                          assets: ["a.png": "h1"], extensions: ["x": ["extension.json": "h2"]])),
            .need(["h1"]), .blob(hash: "h1"), .applied(prototype: "p", revision: 7),
            .refused(prototype: "p", revision: 7, reason: "Too new"), .status(.init(prototype: "p", screen: nil)), .close(prototype: "p"),
        ]
        for message in messages {
            let bytes = try LinkFrame(message, payload: Data([1, 2, 3])).encoded()
            #expect(LinkFrame.parse(bytes) == .frame(LinkFrame(message, payload: Data([1, 2, 3])), length: bytes.count))
        }
    }
}

@Suite struct LinkKeyTests {
    @Test func aKeyIsReadBackFromItsText() throws {
        let key = LinkKey.random()
        #expect(key.bytes.count == 32)
        #expect(LinkKey(text: key.text) == key)
        #expect(LinkKey(text: "  \(key.text)\n") == key)
        #expect(LinkKey.random() != key)
    }

    @Test func textThatIsNotAKeyIsNotOne() {
        #expect(LinkKey(text: "") == nil)
        #expect(LinkKey(text: "https://example.com") == nil)
        #expect(LinkKey(text: "tango-link:") == nil)
        #expect(LinkKey(text: "tango-link:AAAA") == nil)
        #expect(LinkKey(text: "tango-link:" + String(repeating: "A", count: 5000)) == nil)
        #expect(LinkKey(bytes: Data(count: 6)) == nil)
    }

    @Test func aKeyStoreKeepsAndForgets() {
        let store = MemoryLinkKeyStore()
        #expect(store.load() == nil)
        let key = LinkKey.random()
        store.save(key)
        #expect(store.load() == key)
        store.save(nil)
        #expect(store.load() == nil)
    }
}

@Suite struct LinkOutboxTests {
    @Test func onlyTheLatestDocumentWaitsAndOneIsOnItsWay() throws {
        var hashes = LinkHashes()
        var outbox = LinkOutbox()
        outbox.offer(try snapshot(revision: 1, hashes: &hashes))
        guard case .update(let first)? = outbox.next()?.message else { Issue.record("nothing sent"); return }
        #expect(first.revision == 1)
        // A drag: many documents while the phone is still showing the first.
        for revision in 2...60 { outbox.offer(try snapshot(revision: revision, hashes: &hashes)) }
        #expect(outbox.next() == nil)
        // An answer for something else changes nothing.
        outbox.answered(revision: 40)
        #expect(outbox.next() == nil)
        outbox.answered(revision: 1)
        guard case .update(let second)? = outbox.next()?.message else { Issue.record("nothing sent"); return }
        #expect(second.revision == 60)
        outbox.answered(revision: 60)
        #expect(outbox.next() == nil)
    }

    @Test func aRestartIsNotLostWithTheUpdatesThatAreSkipped() throws {
        var hashes = LinkHashes()
        var outbox = LinkOutbox()
        outbox.offer(try snapshot(revision: 1, hashes: &hashes))
        _ = outbox.next()
        // Restart was pressed at revision 2; edits followed before the phone answered.
        outbox.offer(try snapshot(revision: 2, restartToken: 1, hashes: &hashes))
        outbox.offer(try snapshot(revision: 3, restartToken: 1, hashes: &hashes))
        outbox.answered(revision: 1)
        guard case .update(let sent)? = outbox.next()?.message else { Issue.record("nothing sent"); return }
        #expect(sent.revision == 3)
        #expect(sent.restartToken == 1)
    }

    @Test func aLostConnectionSendsWhatWasOnItsWayAgain() throws {
        var hashes = LinkHashes()
        var outbox = LinkOutbox()
        outbox.offer(try snapshot(revision: 1, hashes: &hashes))
        _ = outbox.next()
        outbox.reset()
        guard case .update(let again)? = outbox.next()?.message else { Issue.record("nothing sent"); return }
        #expect(again.revision == 1)
    }

    @Test func aVideoCrossesOnceAndIsHashedOnce() throws {
        let video = Data((0..<50_000).map { UInt8($0 % 256) })
        var hashes = LinkHashes()
        var outbox = LinkOutbox()
        var inbox = LinkInbox()
        var crossed = 0

        for revision in 1...5 {
            outbox.offer(try snapshot(revision: revision, assets: ["clip.mov": video], hashes: &hashes))
            let sent = outbox.next()
            let frame = try #require(sent)
            guard case let .update(update) = frame.message else { Issue.record("not an update"); return }
            let wanted = try inbox.receive(update, payload: frame.payload)
            for blob in outbox.blobs(for: wanted) {
                guard case let .blob(hash) = blob.message else { continue }
                crossed += 1
                inbox.receive(blob: blob.payload, hash: hash)
            }
            let taken = inbox.takeReady()
            let ready = try #require(taken)
            #expect(ready.package.assets["clip.mov"] == video)
            #expect(ready.package.document.screen.name == "Revision \(revision)")
            outbox.answered(revision: revision)
        }
        #expect(crossed == 1)
        #expect(hashes.hashed == 1)
    }

    @Test func anUpdateWaitsForItsFilesAndAForgedFileIsDropped() throws {
        var hashes = LinkHashes()
        var inbox = LinkInbox()
        let snap = try snapshot(revision: 1, assets: ["a.png": Data("real".utf8)], hashes: &hashes)
        let wanted = try inbox.receive(snap.update, payload: snap.document)
        #expect(wanted.count == 1)
        #expect(inbox.takeReady() == nil)
        // Bytes that are not what the hash says.
        inbox.receive(blob: Data("forged".utf8), hash: wanted[0])
        #expect(inbox.takeReady() == nil)
        // A file nobody asked for.
        inbox.receive(blob: Data("extra".utf8), hash: LinkCoding.hash(Data("extra".utf8)))
        #expect(inbox.blobs.isEmpty)
        inbox.receive(blob: Data("real".utf8), hash: wanted[0])
        #expect(inbox.takeReady()?.package.assets["a.png"] == Data("real".utf8))
    }

    @Test func thePhoneCannotAskForFilesOfItsOwnChoosing() throws {
        var hashes = LinkHashes()
        var outbox = LinkOutbox()
        outbox.offer(try snapshot(revision: 1, assets: ["a.png": Data("x".utf8)], hashes: &hashes))
        _ = outbox.next()
        #expect(outbox.blobs(for: ["../../etc/passwd", "0000"]).isEmpty)
    }

    @Test func aDocumentFromANewerAppIsRefused() throws {
        var inbox = LinkInbox()
        let json = Data(#"{"version": 99, "screen": {}}"#.utf8)
        let payload = try (json as NSData).compressed(using: .zlib) as Data
        #expect(throws: (any Error).self) {
            _ = try inbox.receive(.init(prototype: "p", name: "n", revision: 1), payload: payload)
        }
        #expect(throws: (any Error).self) {
            _ = try inbox.receive(.init(prototype: "p", name: "n", revision: 1), payload: Data("not compressed".utf8))
        }
    }

    @Test func extensionsADocumentCarriesTravelWithIt() throws {
        var hashes = LinkHashes()
        var package = DocumentPackage(document: .blank())
        package.extensions = ["com.example.charts": ["extension.json": Data("{}".utf8), "bar.js": Data("x".utf8)]]
        let snap = try LinkSnapshot.make(of: package, prototype: "p", name: "n", revision: 1, hashes: &hashes)
        var inbox = LinkInbox()
        for hash in try inbox.receive(snap.update, payload: snap.document) {
            inbox.receive(blob: try #require(snap.blobs[hash]), hash: hash)
        }
        #expect(inbox.takeReady()?.package.extensions == package.extensions)
    }
}

/// The one test with real sockets: TLS with the key, over loopback, not advertised.
@MainActor @Suite struct LinkSocketTests {
    private func listening(_ server: LinkServer, key: LinkKey) async -> UInt16 {
        await withCheckedContinuation { continuation in
            var resumed = false
            server.onState = { state in
                guard !resumed else { return }
                if case let .listening(port) = state { resumed = true; continuation.resume(returning: port) }
                if case .failed = state { resumed = true; continuation.resume(returning: 0) }
            }
            server.start(key: key, name: "Test", advertises: false)
        }
    }

    @Test func aPhoneWithTheKeyTalksAndOneWithoutDoesNot() async throws {
        let key = LinkKey.random()
        let server = LinkServer()
        var accepted: [LinkConnection] = []
        var heard: [LinkFrame] = []
        server.onConnection = { connection in
            accepted.append(connection)
            connection.onFrame = { frame in
                heard.append(frame)
                connection.send(LinkFrame(.applied(prototype: "echo", revision: 1), payload: frame.payload))
            }
            connection.start()
        }
        let port = await listening(server, key: key)
        try #require(port != 0)
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)

        // The right key: a frame goes there and one comes back.
        let phone = LinkConnection(to: endpoint, key: key)
        let answer: LinkFrame? = await withCheckedContinuation { continuation in
            var resumed = false
            phone.onFrame = { frame in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: frame)
            }
            phone.onState = { state in
                if state == .ready { phone.send(LinkFrame(.need(["x"]), payload: Data("hello".utf8))) }
                if case .closed = state, !resumed { resumed = true; continuation.resume(returning: nil) }
            }
            phone.start()
        }
        #expect(answer == LinkFrame(.applied(prototype: "echo", revision: 1), payload: Data("hello".utf8)))
        #expect(heard == [LinkFrame(.need(["x"]), payload: Data("hello".utf8))])

        // Another key: the handshake fails, and nothing is heard.
        let stranger = LinkConnection(to: endpoint, key: .random())
        let closed: Bool = await withCheckedContinuation { continuation in
            var resumed = false
            stranger.onState = { state in
                guard !resumed else { return }
                if state == .ready {
                    stranger.send(LinkFrame(.need(["intruder"])))
                    // Give a frame time to be heard if the handshake wrongly succeeded.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        guard !resumed else { return }
                        resumed = true
                        continuation.resume(returning: false)
                    }
                }
                if case .closed = state { resumed = true; continuation.resume(returning: true) }
            }
            stranger.start()
        }
        #expect(closed)
        #expect(heard.count == 1)
        phone.close()
        server.stop()
    }
}
