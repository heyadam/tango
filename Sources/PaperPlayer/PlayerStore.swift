import Foundation
import Network
import Observation
import PaperEngine
import PaperHost
import PaperLink
import PaperModel

/// The player's state: whether it is paired with a Mac, the connection to it, and the
/// prototype the Mac is sending, running. No UIKit: a test on the Mac runs the whole
/// path from a `LinkServer` to the `Runtime` here.
@Observable
public final class PlayerStore {
    /// Where the link to the Mac stands.
    public enum Link: Equatable {
        /// No Mac's code has been scanned.
        case unpaired
        case searching
        case connecting(String)
        case connected(String)
    }

    /// A prototype the Mac is sending.
    public struct Live: Identifiable {
        public let id: String
        public var name: String
        public var revision: Int
        public let host: PrototypeHost
    }

    public private(set) var link = Link.unpaired
    public private(set) var live: Live?
    /// Something the person should know: the Mac's app is a different version, or a
    /// prototype could not be shown.
    public private(set) var notice: String?
    /// Macs found nearby with the link on.
    public private(set) var found: [LinkBrowser.Found] = []

    private let keys: any LinkKeyStore
    private let deviceName: String
    private let screen: CGSize
    private let sendsRequests: Bool
    private var key: LinkKey?
    private var connection: LinkConnection?
    private var inbox = LinkInbox()
    private let browser = LinkBrowser()
    private var searches = false

    public init(keys: any LinkKeyStore, deviceName: String, screen: CGSize, sendsRequests: Bool = true) {
        self.keys = keys
        self.deviceName = deviceName
        self.screen = screen
        self.sendsRequests = sendsRequests
        key = keys.load()
        link = key == nil ? .unpaired : .searching
        browser.onChange = { [weak self] found in
            self?.found = found
            self?.connectToFirstFound()
        }
    }

    public var isPaired: Bool { key != nil }

    // MARK: Pairing

    /// The code a Mac shows was scanned.
    public func pair(with key: LinkKey) {
        keys.save(key)
        self.key = key
        drop()
        link = .searching
        if searches { connectToFirstFound() }
    }

    public func unpair() {
        keys.save(nil)
        key = nil
        drop()
        live = nil
        link = .unpaired
    }

    // MARK: Connecting

    /// Looks for Macs nearby and connects to the first that takes the key. iOS asks the
    /// person about the local network the first time.
    public func startSearching() {
        searches = true
        browser.start()
    }

    public func stopSearching() {
        searches = false
        browser.stop()
    }

    private func connectToFirstFound() {
        guard connection == nil, key != nil, let first = found.first else { return }
        connect(to: first.endpoint, name: first.name)
    }

    /// Connects to a Mac at a known place; tests come this way.
    public func connect(to endpoint: NWEndpoint, name: String) {
        guard let key else { return }
        drop()
        link = .connecting(name)
        let connection = LinkConnection(to: endpoint, key: key)
        self.connection = connection
        connection.onState = { [weak self, weak connection] state in
            guard let self, let connection, self.connection === connection else { return }
            switch state {
            case .connecting: break
            case .ready:
                self.link = .connected(name)
                connection.send(.hello(.init(
                    kinds: PrototypeHost.kinds, name: self.deviceName, width: self.screen.width, height: self.screen.height
                )))
            case .closed:
                self.connection = nil
                self.inbox = LinkInbox()
                self.link = self.key == nil ? .unpaired : .searching
                // The Mac may only have gone to sleep: look again shortly.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, self.searches else { return }
                    self.connectToFirstFound()
                }
            }
        }
        connection.onFrame = { [weak self, weak connection] frame in
            guard let self, let connection, self.connection === connection else { return }
            self.receive(frame, from: connection)
        }
        connection.start()
    }

    private func drop() {
        let old = connection
        connection = nil
        old?.close()
        inbox = LinkInbox()
    }

    // MARK: Messages

    private func receive(_ frame: LinkFrame, from connection: LinkConnection) {
        switch frame.message {
        case let .hello(hello):
            guard hello.link == LinkMessage.version else {
                notice = "This app and tango on \(hello.name) are different versions and cannot talk. Update both."
                return connection.close()
            }
            notice = hello.kinds == PrototypeHost.kinds
                ? nil : "tango on \(hello.name) is a different version from this app. Some things may not look right."
        case let .update(update):
            do {
                let wanted = try inbox.receive(update, payload: frame.payload)
                if !wanted.isEmpty { connection.send(.need(wanted)) }
                showIfReady(to: connection)
            } catch {
                let reason = (error as? Document.LoadError) != nil
                    ? "It was made with a newer tango. Update this app." : "It could not be read."
                notice = "“\(update.name)” was not shown. \(reason)"
                connection.send(.refused(prototype: update.prototype, revision: update.revision, reason: reason))
            }
        case let .blob(hash):
            inbox.receive(blob: frame.payload, hash: hash)
            showIfReady(to: connection)
        case let .close(prototype):
            if live?.id == prototype { live = nil }
        case .need, .applied, .refused, .status:
            // Only a phone says these.
            break
        }
    }

    private func showIfReady(to connection: LinkConnection) {
        guard let (update, package) = inbox.takeReady() else { return }
        let start = update.startScreen.flatMap(UUID.init(uuidString:))
        if let live, live.id == update.prototype {
            // The same prototype, edited: what is running keeps its state.
            live.host.update(
                document: package.document, assets: package.assets, restartToken: update.restartToken, startScreen: start
            )
            self.live?.name = update.name
            self.live?.revision = update.revision
        } else {
            live = Live(
                id: update.prototype, name: update.name, revision: update.revision,
                host: PrototypeHost(
                    package: package, sendsRequests: sendsRequests, startScreen: start, restartToken: update.restartToken
                )
            )
        }
        received?(update, package)
        connection.send(.applied(prototype: update.prototype, revision: update.revision))
    }

    /// Called with every update that was shown; the library keeps those meant to be kept.
    public var received: ((LinkMessage.Update, DocumentPackage) -> Void)?

    /// The person closed the live prototype. It comes back with the Mac's next change.
    public func closeLive() {
        live = nil
    }
}
