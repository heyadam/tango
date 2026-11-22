import Foundation
import PaperEngine
import PaperHost
import PaperModel

/// Makes the web requests extension scripts ask for, and decides what each may reach and
/// carry. A script only ever describes a request; this is the one place that sends one, and
/// the one place a key's value is handled.
///
/// The rules, which `prepare` applies and nothing else relaxes:
/// - A request goes only to a host the extension's manifest lists under `network`, over
///   https (plain http only to this Mac itself).
/// - A key is named by the script as a placeholder and filled in here, in a header or in
///   the address after the `?`, and only when the request goes to a host declared for that
///   key. It is never put in a body, where a service could be asked to hand it back.
/// - Redirects are not followed, no cookies are kept or sent, and nothing is cached.
/// - Whatever comes back has the key removed before the script sees it.
public nonisolated enum ExtensionNetwork {
    /// A request that is ready to send, and the keys that went into it.
    public struct Prepared: Sendable {
        public var request: URLRequest
        public var keys: [String]
    }

    /// Why a request was not sent, in words for the extension's author and its user.
    public struct Refusal: Error, Hashable, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    public typealias KeyLookup = @Sendable (ExtensionManifest.Secret) -> String?
    public typealias Transport = @Sendable (URLRequest) async -> NetworkResponse

    public static let methods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]
    /// Headers a script may not set: they belong to the connection, or would let it pose
    /// as a browser or carry cookies.
    static let forbiddenHeaders = PrototypeNetwork.forbiddenHeaders
    public static let longestWait = 120.0
    public static let usualWait = 30.0
    public static let largestBody = 5_000_000
    public static let largestAnswer = 10_000_000

    // MARK: Deciding

    /// Checks `request` against the extension's manifest and fills in its keys.
    public static func prepare(
        _ request: NetworkRequest, for manifest: ExtensionManifest, key: KeyLookup
    ) -> Result<Prepared, Refusal> {
        do {
            return .success(try checked(request, manifest, key))
        } catch let refusal as Refusal {
            return .failure(refusal)
        } catch {
            return .failure(Refusal("The request could not be made."))
        }
    }

    private static func checked(_ request: NetworkRequest, _ manifest: ExtensionManifest, _ key: KeyLookup) throws -> Prepared {
        let open = Script.secretOpen, close = Script.secretClose

        // The address. A script may have run its placeholder through encodeURIComponent.
        var address = request.url
        for (encoded, plain) in [("%E2%9F%A6key%3A", open), ("%E2%9F%A6key:", open), ("%E2%9F%A7", close)] {
            address = address.replacingOccurrences(of: encoded, with: plain, options: .caseInsensitive)
        }
        guard !address.isEmpty, address.count <= 8000,
              !address.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value == 0x7F || $0 == "\\" }) else {
            throw Refusal("That is not a web address.")
        }
        if let hash = address.firstIndex(of: "#") { address = String(address[..<hash]) }
        var base = address, query: String?
        if let mark = address.firstIndex(of: "?") {
            base = String(address[..<mark])
            query = String(address[address.index(after: mark)...])
        }
        guard !base.contains(open), !base.contains(close) else {
            throw Refusal("A key can go in a header or after the ? of the address, nowhere else in it.")
        }

        // Which keys the request names, and whether it may carry each.
        guard let parts = URLComponents(string: base), let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased(), !host.isEmpty, parts.user == nil, parts.password == nil else {
            throw Refusal("That is not a web address.")
        }
        let local = ExtensionManifest.isLoopback(host)
        guard scheme == "https" || (scheme == "http" && local) else {
            throw Refusal("Requests go over https. \(scheme):// is not allowed.")
        }
        guard manifest.allows(host: host) else {
            throw Refusal("\(manifest.name) did not say it would contact \(host). Its manifest lists: \(manifest.network.isEmpty ? "no hosts" : manifest.network.joined(separator: ", ")).")
        }

        var used: [String] = []
        func filled(_ text: String, encode: Bool) throws -> String {
            var result = "", rest = Substring(text)
            while let start = rest.range(of: open) {
                result += rest[..<start.lowerBound]
                guard let end = rest[start.upperBound...].range(of: close) else {
                    throw Refusal("The request names a key in a way that cannot be read.")
                }
                let id = String(rest[start.upperBound..<end.lowerBound])
                guard let secret = manifest.secret(id) else {
                    throw Refusal("\(manifest.name) declares no key named \"\(id)\".")
                }
                guard scheme == "https", secret.hosts.contains(host) else {
                    throw Refusal("The key \(secret.name) is only sent to \(secret.hosts.joined(separator: ", ")); this request goes to \(host).")
                }
                guard let value = key(secret), !value.isEmpty else {
                    throw Refusal("\(manifest.name) needs the key \(secret.name). Enter it in Extensions.")
                }
                guard !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                    throw Refusal("The key \(secret.name) holds characters a request cannot carry. Enter it again.")
                }
                used.append(value)
                result += encode ? (value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "") : value
                rest = rest[end.upperBound...]
            }
            guard !rest.contains(close) else { throw Refusal("The request names a key in a way that cannot be read.") }
            return result + rest
        }

        var final = base
        if let query { final += "?" + (try filled(query, encode: true)) }
        // The request is made from the very address that is checked, so the two cannot
        // be read differently.
        guard let url = URLComponents(string: final)?.url, url.host?.lowercased() == host, url.scheme?.lowercased() == scheme else {
            throw Refusal("That is not a web address.")
        }

        let method = request.method.uppercased()
        guard methods.contains(method) else { throw Refusal("\(request.method) is not a method a request can use.") }

        var outgoing = URLRequest(url: url)
        outgoing.httpMethod = method
        outgoing.httpShouldHandleCookies = false
        outgoing.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let wait = request.timeout > 0 ? request.timeout : usualWait
        outgoing.timeoutInterval = min(max(wait, 1), longestWait)

        for (name, value) in request.headers.sorted(by: { $0.key < $1.key }) {
            guard name.range(of: #"^[A-Za-z0-9!#$%&'*+.^_`|~-]+$"#, options: .regularExpression) != nil else {
                throw Refusal("\"\(name.prefix(40))\" is not a header name.")
            }
            let lowered = name.lowercased()
            guard !forbiddenHeaders.contains(lowered), !lowered.hasPrefix("proxy-"), !lowered.hasPrefix("sec-") else { continue }
            let text = try filled(value, encode: false)
            guard !text.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\t" || $0.value == 0x7F }) else {
                throw Refusal("The header \(name) holds a line break.")
            }
            outgoing.setValue(text, forHTTPHeaderField: name)
        }
        outgoing.setValue("Tango", forHTTPHeaderField: "User-Agent")
        // A program on this Mac that takes requests from other programs (this app's own
        // agent server is one) can tell by this that the request is not one of those.
        if local { outgoing.setValue("null", forHTTPHeaderField: "Origin") }

        guard !request.body.contains(open) else {
            throw Refusal("A key can go in a header or after the ? of the address, not in the body of a request.")
        }
        if method != "GET", method != "HEAD", !request.body.isEmpty {
            let body = Data(request.body.utf8)
            guard body.count <= largestBody else { throw Refusal("The request is too large to send.") }
            outgoing.httpBody = body
        }
        return Prepared(request: outgoing, keys: used)
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    // MARK: Cleaning what comes back

    /// Removes every key from an answer: as it is, and in the forms a service is likely
    /// to hand it back in. A script therefore cannot learn a key by asking for an echo.
    public static func scrub(_ response: NetworkResponse, of keys: [String]) -> NetworkResponse {
        var forms: [String] = []
        for key in Set(keys) where !key.isEmpty {
            forms.append(key)
            if let encoded = key.addingPercentEncoding(withAllowedCharacters: unreserved), encoded != key { forms.append(encoded) }
            let data = Data(key.utf8)
            let base64 = data.base64EncodedString()
            forms.append(base64)
            forms.append(base64.replacingOccurrences(of: "=", with: ""))
            forms.append(base64.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""))
            // "Bearer <key>" and "user:<key>" as Basic authorization would carry them.
            forms.append(Data("Bearer \(key)".utf8).base64EncodedString())
            forms.append(Data(":\(key)".utf8).base64EncodedString())
            forms.append(data.map { String(format: "%02x", $0) }.joined())
        }
        guard !forms.isEmpty else { return response }
        // Longest first, so a form that contains another is taken whole.
        forms = Array(Set(forms)).sorted { $0.count > $1.count }
        func clean(_ text: String) -> String {
            forms.reduce(text) { $0.replacingOccurrences(of: $1, with: removed, options: $1.allSatisfy(\.isHexDigit) ? .caseInsensitive : []) }
        }
        var result = response
        if !response.body.isEmpty {
            // As text when it is text, so a key split by nothing but its own bytes is found.
            if let text = String(data: response.body, encoding: .utf8) {
                let cleaned = clean(text)
                if cleaned != text { result.body = Data(cleaned.utf8) }
            } else {
                var body = response.body
                for form in forms {
                    let needle = Data(form.utf8)
                    while let found = body.range(of: needle) { body.replaceSubrange(found, with: Data(removed.utf8)) }
                }
                result.body = body
            }
        }
        result.error = response.error.map(clean)
        result.headers = response.headers.mapValues(clean)
        return result
    }

    static let removed = "[key]"

    // MARK: Sending

    /// Checks, sends and cleans. Whatever goes wrong is an answer with an error, never a throw.
    public static func perform(
        _ request: NetworkRequest, for manifest: ExtensionManifest, key: KeyLookup, transport: Transport = send
    ) async -> NetworkResponse {
        switch prepare(request, for: manifest, key: key) {
        case let .failure(refusal):
            return NetworkResponse(status: 0, error: refusal.message)
        case let .success(prepared):
            return scrub(await transport(prepared.request), of: prepared.keys)
        }
    }

    /// Sends over the network with nothing kept between requests.
    public static let send: Transport = { request in
        await withCheckedContinuation { continuation in
            let transfer = Transfer(continuation)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            // The request's own timeout only counts the wait between pieces of an answer.
            // This one counts the whole of it.
            configuration.timeoutIntervalForResource = request.timeoutInterval
            let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: nil)
            session.dataTask(with: request).resume()
            session.finishTasksAndInvalidate()
        }
    }

    /// One request in flight. It takes the answer as it comes, stops when it is too large,
    /// and does not follow the server anywhere else.
    private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private var continuation: CheckedContinuation<NetworkResponse, Never>?
        private var body = Data()
        private var answer: HTTPURLResponse?
        private var tooLarge = false

        init(_ continuation: CheckedContinuation<NetworkResponse, Never>) {
            self.continuation = continuation
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            // The redirect itself is the answer: a key in a header is not carried elsewhere.
            completionHandler(nil)
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            answer = response as? HTTPURLResponse
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            body.append(data)
            if body.count > ExtensionNetwork.largestAnswer {
                tooLarge = true
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            var headers: [String: String] = [:]
            for (name, value) in answer?.allHeaderFields ?? [:] {
                guard let name = name as? String, let value = value as? String, name.lowercased() != "set-cookie" else { continue }
                headers[name.lowercased()] = value
            }
            var failure = error?.localizedDescription
            if tooLarge { failure = "The answer was too large." }
            continuation?.resume(returning: NetworkResponse(
                status: answer?.statusCode ?? 0, body: tooLarge ? Data() : body, error: failure, headers: headers
            ))
            continuation = nil
        }
    }
}
