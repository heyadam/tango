import Foundation
import Network
import Observation

/// One HTTP request, read from the bytes a connection has delivered so far.
nonisolated struct HTTPRequest: Equatable {
    var method: String
    var path: String
    /// Header names are lowercased.
    var headers: [String: String]
    var body: Data

    enum Parsed: Equatable {
        /// More bytes are needed.
        case incomplete
        case invalid
        /// A whole request, and how many bytes it took.
        case request(HTTPRequest, length: Int)
    }

    static let headerLimit = 64 * 1024
    static let bodyLimit = 32 * 1024 * 1024

    static func parse(_ data: Data) -> Parsed {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: separator) else {
            return data.count > headerLimit ? .invalid : .incomplete
        }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count == 3, start[2].hasPrefix("HTTP/1.") else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var length = 0
        if let stated = headers["content-length"] {
            guard let count = Int(stated), count >= 0, count <= bodyLimit else { return .invalid }
            length = count
        } else if headers["transfer-encoding"] != nil {
            return .invalid
        }
        let bodyStart = end.upperBound
        guard data.endIndex - bodyStart >= length else { return .incomplete }
        let path = String(start[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        let request = HTTPRequest(
            method: String(start[0]), path: path, headers: headers,
            body: Data(data[bodyStart..<bodyStart + length])
        )
        return .request(request, length: bodyStart + length - data.startIndex)
    }

    /// Whether the headers have arrived, the body has not, and the client is waiting to be
    /// told to send it (`Expect: 100-continue`).
    static func awaitsContinue(_ data: Data) -> Bool {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return false }
        return head.lowercased().components(separatedBy: "\r\n").contains {
            $0.hasPrefix("expect:") && $0.contains("100-continue")
        }
    }

    /// Whether `value` (a Host header, or the host part of an Origin) names this Mac itself.
    static func isLoopback(_ value: String) -> Bool {
        var host = value.lowercased()
        if let scheme = host.range(of: "://") { host = String(host[scheme.upperBound...]) }
        if host.hasPrefix("[") {
            host = String(host.prefix { $0 != "]" }) + "]"
        } else if let colon = host.lastIndex(of: ":") {
            host = String(host[..<colon])
        }
        return ["127.0.0.1", "localhost", "[::1]"].contains(host)
    }

    /// A web page in a browser can reach a local port; it cannot fake these two headers.
    /// Refusing anything that did not set out for this Mac by name stops DNS rebinding.
    /// And a browser says where a page came from (`Origin`) on every request a page can
    /// make here, which a coding agent never does: so anything with an Origin is a web
    /// page, including one served by some other program on this Mac, and is refused.
    var comesFromThisMac: Bool {
        guard let host = headers["host"], Self.isLoopback(host) else { return false }
        return headers["origin"] == nil
    }
}

nonisolated struct HTTPResponse: Equatable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    var encoded: Data {
        let reasons = [200: "OK", 202: "Accepted", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed"]
        var text = "HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\n"
        var all = headers
        all["Content-Length"] = "\(body.count)"
        for (name, value) in all.sorted(by: { $0.key < $1.key }) { text += "\(name): \(value)\r\n" }
        return Data((text + "\r\n").utf8) + body
    }
}

/// Carries MCP over HTTP on this Mac only: `POST /mcp` with one JSON-RPC message, answered
/// with JSON. There is no stream from the server, so `GET` is refused, as the protocol allows.
public final class AgentListener {
    public static let path = "/mcp"

    public enum State: Equatable {
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    private let server: AgentServer
    private var listener: NWListener?
    public private(set) var state = State.starting
    public var onState: ((State) -> Void)?

    public init(server: AgentServer) {
        self.server = server
    }

    /// Starts listening on 127.0.0.1. Port 0 lets the system pick one.
    public func start(port: UInt16) {
        stop()
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                MainActor.assumeIsolated {
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready: self.set(.listening(port: listener.port?.rawValue ?? port))
                    case let .failed(error): self.set(.failed(error.localizedDescription))
                    case let .waiting(error): self.set(.failed(error.localizedDescription))
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated {
                    connection.start(queue: .main)
                    self?.read(connection, buffer: Data())
                }
            }
            self.listener = listener
            set(.starting)
            listener.start(queue: .main)
        } catch {
            set(.failed(error.localizedDescription))
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func set(_ new: State) {
        state = new
        onState?(new)
    }

    private func read(_ connection: NWConnection, buffer: Data, toldToContinue: Bool = false) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, finished, error in
            MainActor.assumeIsolated {
                guard let self, error == nil else { return connection.cancel() }
                var buffer = buffer
                var toldToContinue = toldToContinue
                if let data { buffer.append(data) }
                while true {
                    switch HTTPRequest.parse(buffer) {
                    case .incomplete:
                        if finished { return connection.cancel() }
                        // curl asks before sending a large body, and waits a second for the answer.
                        if !toldToContinue, HTTPRequest.awaitsContinue(buffer) {
                            toldToContinue = true
                            connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                        }
                        return self.read(connection, buffer: buffer, toldToContinue: toldToContinue)
                    case .invalid:
                        connection.send(content: HTTPResponse(status: 400).encoded, completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                        return
                    case let .request(request, length):
                        toldToContinue = false
                        buffer = Data(buffer.dropFirst(length))
                        connection.send(content: self.respond(to: request).encoded, completion: .contentProcessed { _ in })
                    }
                }
            }
        }
    }

    func respond(to request: HTTPRequest) -> HTTPResponse {
        guard request.comesFromThisMac else { return HTTPResponse(status: 403) }
        guard request.path == Self.path else { return HTTPResponse(status: 404) }
        guard request.method == "POST" else { return HTTPResponse(status: 405, headers: ["Allow": "POST"]) }
        guard let answer = server.handle(request.body) else { return HTTPResponse(status: 202) }
        return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: answer)
    }
}

/// The app's one agent server: on unless switched off in Settings.
@Observable
public final class AgentService {
    public static let shared = AgentService()
    public static let firstPort: UInt16 = 47821
    private static let enabledKey = "agentServerEnabled"

    public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? start() : stop()
        }
    }
    public private(set) var state: AgentListener.State?
    @ObservationIgnored private var listener: AgentListener?
    @ObservationIgnored private var attempt: UInt16 = 0

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    public var port: UInt16? {
        if case let .listening(port) = state { return port }
        return nil
    }

    public var address: String? {
        port.map { "http://127.0.0.1:\($0)\(AgentListener.path)" }
    }

    /// Call once when the app launches.
    public func startIfEnabled() {
        if isEnabled, listener == nil { start() }
    }

    private func start() {
        attempt = 0
        listen()
    }

    private func listen() {
        let listener = AgentListener(server: AgentServer())
        listener.onState = { [weak self] state in
            guard let self else { return }
            // Another copy of the app, or anything else, may hold the port: try the next few.
            if case .failed = state, self.attempt < 9 {
                self.attempt += 1
                self.listen()
            } else {
                self.state = state
            }
        }
        self.listener = listener
        listener.start(port: Self.firstPort + attempt)
    }

    private func stop() {
        listener?.onState = nil
        listener?.stop()
        listener = nil
        state = nil
    }
}
