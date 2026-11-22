import CryptoKit
import Foundation
import Network

/// The link's sockets: a connection that carries frames, the Mac's listener and the
/// phone's browser. Thin on purpose: what a frame is, and what to send when, are
/// `LinkFrame`, `LinkOutbox` and `LinkInbox`, which need no socket to test.
///
/// Every callback arrives on the main queue.
public enum LinkTransport {
    /// The Bonjour service a Mac with the link on advertises.
    public static let service = "_tango._tcp"

    /// TLS keyed with the pairing key (a pre-shared key, TLS 1.2), over TCP. A side
    /// without the key cannot finish the handshake, so it neither reads nor is read.
    public static func parameters(key: LinkKey) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let secret = key.bytes.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("tango".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, secret as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        )
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        // Every connection proves it has the key: a session is never taken up again from
        // a ticket, which would let a later connection in on an earlier one's proof.
        sec_protocol_options_set_tls_resumption_enabled(tls.securityProtocolOptions, false)
        sec_protocol_options_set_tls_tickets_enabled(tls.securityProtocolOptions, false)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        // Near each other is enough: no shared Wi-Fi network is needed.
        parameters.includePeerToPeer = true
        return parameters
    }
}

/// One end of the link. Frames in, frames out.
@MainActor
public final class LinkConnection {
    public enum State: Equatable, Sendable {
        case connecting
        case ready
        /// Over, with the reason when it was not asked for.
        case closed(String?)
    }

    private let connection: NWConnection
    private var buffer = Data()
    public private(set) var state = State.connecting
    public var onState: ((State) -> Void)?
    public var onFrame: ((LinkFrame) -> Void)?

    public init(_ connection: NWConnection) {
        self.connection = connection
    }

    public convenience init(to endpoint: NWEndpoint, key: LinkKey) {
        self.init(NWConnection(to: endpoint, using: LinkTransport.parameters(key: key)))
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.set(.ready)
                    self.read()
                case let .failed(error): self.finish(error.localizedDescription)
                case let .waiting(error): self.finish(error.localizedDescription)
                case .cancelled: self.finish(nil)
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func set(_ new: State) {
        guard state != new else { return }
        state = new
        onState?(new)
    }

    private func finish(_ reason: String?) {
        if case .closed = state { return }
        set(.closed(reason))
        connection.cancel()
    }

    public func close() {
        finish(nil)
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data { self.buffer.append(data) }
                while true {
                    switch LinkFrame.parse(self.buffer) {
                    case .incomplete:
                        if isComplete || error != nil { return self.finish(error?.localizedDescription) }
                        return self.read()
                    case .invalid:
                        return self.finish("The other side sent something that is not tango's.")
                    case let .frame(frame, length):
                        self.buffer.removeFirst(length)
                        self.buffer = Data(self.buffer)
                        self.onFrame?(frame)
                        if case .closed = self.state { return }
                    }
                }
            }
        }
    }

    public func send(_ frame: LinkFrame) {
        guard state == .ready, let data = try? frame.encoded() else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            MainActor.assumeIsolated { self?.finish(error.localizedDescription) }
        })
    }

    public func send(_ message: LinkMessage) {
        send(LinkFrame(message))
    }
}

/// The Mac's side: listens for paired phones.
@MainActor
public final class LinkServer {
    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    private var listener: NWListener?
    public private(set) var state = State.stopped
    public var onState: ((State) -> Void)?
    /// A phone with the key connected. It is not started yet: set its callbacks, then `start()`.
    public var onConnection: ((LinkConnection) -> Void)?

    public init() {}

    /// `advertises` puts the Mac on the local network under `name` for phones to find. Off
    /// in tests, which connect by port and must not make macOS ask about the network.
    public func start(key: LinkKey, name: String, advertises: Bool, port: UInt16 = 0) {
        stop()
        set(.starting)
        do {
            let parameters = LinkTransport.parameters(key: key)
            if !advertises {
                parameters.includePeerToPeer = false
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
                parameters.allowLocalEndpointReuse = true
            }
            let listener = try advertises && port != 0
                ? NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any)
                : NWListener(using: parameters)
            if advertises { listener.service = NWListener.Service(name: name, type: LinkTransport.service) }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                MainActor.assumeIsolated {
                    guard let self, self.listener === listener else { return }
                    switch state {
                    case .ready: self.set(.listening(port: listener?.port?.rawValue ?? 0))
                    case let .failed(error): self.set(.failed(error.localizedDescription))
                    case let .waiting(error): self.set(.failed(error.localizedDescription))
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated {
                    guard let self else { return connection.cancel() }
                    self.onConnection?(LinkConnection(connection))
                }
            }
            self.listener = listener
            listener.start(queue: .main)
        } catch {
            set(.failed(error.localizedDescription))
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        set(.stopped)
    }

    private func set(_ new: State) {
        guard state != new else { return }
        state = new
        onState?(new)
    }
}

/// The phone's side: finds Macs with the link on.
@MainActor
public final class LinkBrowser {
    public struct Found: Identifiable, Equatable, Sendable {
        public let name: String
        public let endpoint: NWEndpoint
        public var id: String { name }
    }

    private var browser: NWBrowser?
    public private(set) var found: [Found] = []
    public var onChange: (([Found]) -> Void)?

    public init() {}

    public func start() {
        stop()
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: LinkTransport.service, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.found = results.compactMap { result in
                    guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                    return Found(name: name, endpoint: result.endpoint)
                }.sorted { $0.name < $1.name }
                self.onChange?(self.found)
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        found = []
    }
}
