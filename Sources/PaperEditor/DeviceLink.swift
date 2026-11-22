import Foundation
import Network
import Observation
import PaperHost
import PaperLink
import PaperModel

/// Sends the front document's prototype to the phones paired with this Mac, as it is
/// edited. The phone's player runs it with the same engine; this only says what the
/// prototype is now (`LinkMessage.update`), to each phone as fast as that phone shows it.
///
/// Off until the person turns it on: unlike the agent port it listens on the network, and
/// macOS asks about that. A phone gets nothing without the key the QR code holds.
@Observable
public final class DeviceLink {
    public static let shared = DeviceLink(keys: KeychainLinkKeyStore(), advertises: true, remembers: true)
    static let enabledKey = "deviceLinkEnabled"

    /// What a window hands over: its prototype as the Viewer would run it.
    public struct Source: Sendable {
        public var prototype: String
        public var name: String
        public var package: DocumentPackage
        public var restartToken: Int
        public var startScreen: LayerID?
        /// Off while a component is edited: the document is then a preview, not the file.
        public var keeps: Bool

        public init(prototype: String, name: String, package: DocumentPackage, restartToken: Int = 0, startScreen: LayerID? = nil, keeps: Bool = true) {
            self.prototype = prototype
            self.name = name
            self.package = package
            self.restartToken = restartToken
            self.startScreen = startScreen
            self.keeps = keeps
        }
    }

    /// A phone that is connected.
    public struct Phone: Identifiable, Equatable {
        public let id: Int
        public var name: String
        /// The revision it last said it shows.
        public var shows: Int?
        /// Why it could not show the last one, or that its app is another version.
        public var notice: String?
    }

    public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            if remembers { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
            isEnabled ? listen() : stop()
        }
    }

    public private(set) var state = LinkServer.State.stopped
    /// Why the prototype is not reaching phones, in words for the person.
    public private(set) var problem: String?
    /// The most connections held at once, phones and those still shaking hands.
    static let mostPeers = 16
    /// How long a connection has to say hello before it is dropped. Longer in tests, where
    /// other tests hold the main thread for seconds at a time.
    var helloWait = 10.0
    public private(set) var phones: [Phone] = []
    /// The key phones pair with; made the first time the link is turned on.
    public private(set) var key: LinkKey?

    private let keys: any LinkKeyStore
    private let advertises: Bool
    private let remembers: Bool
    private let fixedPort: UInt16
    private let server = LinkServer()
    private var peers: [Int: (connection: LinkConnection, outbox: LinkOutbox)] = [:]
    private var nextPeer = 1

    /// The newest prototype handed over, and the snapshot made of it.
    private var source: Source?
    private var snapshot: LinkSnapshot?
    private var revision = 0
    private var hashes = LinkHashes()
    private var isBuilding = false
    private var needsBuild = false

    /// `port` is where it listens when it does not advertise; 0 lets the system choose.
    public init(keys: any LinkKeyStore, advertises: Bool, remembers: Bool = false, port: UInt16 = 0) {
        self.fixedPort = port
        self.keys = keys
        self.advertises = advertises
        self.remembers = remembers
        isEnabled = remembers && UserDefaults.standard.bool(forKey: Self.enabledKey)
        key = keys.load()
        server.onState = { [weak self] state in
            guard let self else { return }
            self.state = state
            // A listener that failed (the Mac slept, the network went) is started again.
            if case .failed = state, self.isEnabled {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, self.isEnabled, case .failed = self.state else { return }
                    self.listen()
                }
            }
        }
        server.onConnection = { [weak self] connection in self?.accept(connection) }
    }

    /// Called once when the app starts.
    public func startIfEnabled() {
        if isEnabled { listen() }
    }

    private func listen() {
        problem = nil
        // A key the keychain would not hand over is not replaced: that would silently
        // unpair every phone. New Code does it on purpose.
        if key == nil, keys.isUnreadable {
            problem = "tango could not read its pairing key from the keychain. Allow it when macOS asks, or make a New Code and pair again."
            return
        }
        if key == nil {
            let made = LinkKey.random()
            keys.save(made)
            key = made
        }
        guard let key else { return }
        server.start(key: key, name: Host.current().localizedName ?? "Mac", advertises: advertises, port: fixedPort)
    }

    private func stop() {
        server.stop()
        for peer in peers.values { peer.connection.close() }
        peers = [:]
        phones = []
    }

    /// Makes another key: every phone has to scan the new code.
    public func newKey() {
        let key = LinkKey.random()
        keys.save(key)
        self.key = key
        if isEnabled {
            stop()
            listen()
        }
    }

    // MARK: Phones

    private func accept(_ connection: LinkConnection) {
        // Anything can open a connection; only one with the key gets past the handshake.
        // So they are few, and one that has not said hello in time is dropped.
        guard peers.count < Self.mostPeers else { return connection.close() }
        let id = nextPeer
        nextPeer += 1
        peers[id] = (connection, LinkOutbox())
        DispatchQueue.main.asyncAfter(deadline: .now() + helloWait) { [weak self] in
            guard let self, let peer = self.peers[id], !self.phones.contains(where: { $0.id == id }) else { return }
            peer.connection.close()
        }
        connection.onState = { [weak self, weak connection] state in
            guard let self else { return }
            switch state {
            case .connecting: break
            case .ready:
                connection?.send(.hello(.init(kinds: PrototypeHost.kinds, name: Host.current().localizedName ?? "Mac")))
            case .closed:
                self.peers[id] = nil
                self.phones.removeAll { $0.id == id }
            }
        }
        connection.onFrame = { [weak self] frame in self?.receive(frame, from: id) }
        connection.start()
    }

    private func receive(_ frame: LinkFrame, from id: Int) {
        guard let peer = peers[id] else { return }
        switch frame.message {
        case let .hello(hello):
            guard hello.link == LinkMessage.version else { return peer.connection.close() }
            phones.removeAll { $0.id == id }
            phones.append(Phone(
                id: id, name: hello.name,
                notice: hello.kinds == PrototypeHost.kinds ? nil : "Its app is a different version from this tango."
            ))
            // It gets the prototype as it is now.
            if let snapshot {
                peers[id]?.outbox.offer(snapshot)
                pump(id)
            } else {
                build()
            }
        case let .need(wanted):
            for blob in peers[id]?.outbox.blobs(for: wanted) ?? [] { peer.connection.send(blob) }
        case let .applied(_, revision):
            peers[id]?.outbox.answered(revision: revision)
            update(id) { $0.shows = revision; if $0.notice?.hasPrefix("Its app") != true { $0.notice = nil } }
            pump(id)
        case let .refused(_, revision, reason):
            peers[id]?.outbox.answered(revision: revision)
            update(id) { $0.notice = reason }
            pump(id)
        case .status, .update, .blob, .close:
            break
        }
    }

    private func update(_ id: Int, _ change: (inout Phone) -> Void) {
        guard let index = phones.firstIndex(where: { $0.id == id }) else { return }
        change(&phones[index])
    }

    /// Sends a phone its next update if it is ready for one. Only phones that have said
    /// hello are sent anything.
    private func pump(_ id: Int) {
        guard phones.contains(where: { $0.id == id }), let frame = peers[id]?.outbox.next() else { return }
        peers[id]?.connection.send(frame)
    }

    // MARK: The prototype

    /// The front window's prototype changed. Cheap while no phone is connected: the
    /// document is only kept, and made ready to send when one is.
    public func publish(_ source: Source) {
        guard isEnabled else { return }
        if let old = self.source, old.prototype != source.prototype { close(old.prototype) }
        self.source = source
        snapshot = nil
        build()
    }

    /// The prototype's window closed.
    public func withdraw(prototype: String) {
        guard source?.prototype == prototype else { return }
        close(prototype)
        source = nil
        snapshot = nil
    }

    /// Tells every phone a prototype is over, and takes back what of it had not gone out:
    /// an update left waiting would bring it back.
    private func close(_ prototype: String) {
        for id in peers.keys {
            peers[id]?.outbox.forget()
            peers[id]?.connection.send(.close(prototype: prototype))
        }
    }

    /// Encodes, compresses and hashes off the main actor, one at a time: a change that
    /// arrives meanwhile is built next, and the ones between are never built.
    private func build() {
        guard !phones.isEmpty, let source else { return }
        guard !isBuilding else {
            needsBuild = true
            return
        }
        isBuilding = true
        needsBuild = false
        revision += 1
        let revision = revision
        var hashes = hashes
        Task.detached(priority: .userInitiated) { [weak self] in
            var made: LinkSnapshot?
            var failure: String?
            do {
                made = try LinkSnapshot.make(
                    of: source.package, prototype: source.prototype, name: source.name, revision: revision,
                    restartToken: source.restartToken, startScreen: source.startScreen?.uuidString, keeps: source.keeps, hashes: &hashes
                )
            } catch LinkError.tooLarge {
                failure = "“\(source.name)” has a file too large to send to an iPhone."
            } catch {
                failure = "“\(source.name)” could not be sent to an iPhone."
            }
            let kept = hashes
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isBuilding = false
                self.hashes = kept
                self.problem = failure
                if let made, self.source?.prototype == made.update.prototype {
                    self.snapshot = made
                    for id in self.peers.keys {
                        self.peers[id]?.outbox.offer(made)
                        self.pump(id)
                    }
                }
                if self.needsBuild { self.build() }
            }
        }
    }

    /// The port in use; for tests, which connect to it directly.
    var port: UInt16? {
        if case let .listening(port) = state { return port }
        return nil
    }
}
