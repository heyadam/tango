import Foundation
import PaperEngine
import PaperModel

/// Sends the requests a prototype's Network Request patches ask for. The runtime does no
/// I/O: whatever hosts it (the Mac's Viewer, the player on a phone) hands them here.
public nonisolated enum PrototypeNetwork {
    /// Headers a prototype or a script may not set: they belong to the connection, or would
    /// let it pose as a browser or carry cookies.
    public static let forbiddenHeaders: Set<String> = [
        "host", "content-length", "connection", "cookie", "cookie2", "origin", "transfer-encoding",
        "upgrade", "te", "trailer", "keep-alive", "expect", "proxy-authorization", "proxy-connection", "user-agent",
    ]

    /// What a Network Request patch's request becomes. Headers that belong to the connection
    /// are dropped, a body goes with every method but GET, and a request to this device
    /// carries `Origin: null`, which the app's agent port refuses: a document must not drive
    /// the app.
    public static func urlRequest(for request: NetworkRequest, url: URL) -> URLRequest {
        var outgoing = URLRequest(url: url, timeoutInterval: 20)
        outgoing.httpMethod = request.method
        var hasContentType = false
        for (name, value) in request.headers {
            let lowered = name.lowercased()
            guard !forbiddenHeaders.contains(lowered), !lowered.hasPrefix("proxy-"), !lowered.hasPrefix("sec-") else { continue }
            // A line break would start a header of its own.
            guard !(name + value).unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { continue }
            if lowered == "content-type" { hasContentType = true }
            outgoing.setValue(value, forHTTPHeaderField: name)
        }
        if request.method != "GET", !request.body.isEmpty {
            outgoing.httpBody = Data(request.body.utf8)
            if !hasContentType { outgoing.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        }
        return guarded(outgoing)
    }

    /// A request to this device carries `Origin: null`, which the app's agent port refuses.
    /// Applied to the first request and again to every redirect, since an answer from
    /// anywhere can send a POST on to 127.0.0.1 with its body.
    public static func guarded(_ request: URLRequest) -> URLRequest {
        var request = request
        if ExtensionManifest.isLoopback(request.url?.host ?? "") {
            request.setValue("null", forHTTPHeaderField: "Origin")
        }
        return request
    }

    /// Where Network Request patches' requests go: like the shared session, but every
    /// redirect is checked again (`guarded`).
    public static let session = URLSession(configuration: .default, delegate: RedirectGuard(), delegateQueue: nil)

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(PrototypeNetwork.guarded(request))
        }
    }

    /// Sends a patch's request and reports the answer on the main actor. What is not a web
    /// address is answered at once, with nothing sent.
    @MainActor
    public static func send(_ request: NetworkRequest, report: @escaping @MainActor @Sendable (NetworkResponse) -> Void) {
        guard let url = URL(string: request.url), url.scheme != nil else {
            report(NetworkResponse(status: 0, error: "That is not a web address."))
            return
        }
        session.dataTask(with: urlRequest(for: request, url: url)) { data, response, error in
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (name, value) in http?.allHeaderFields ?? [:] {
                if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
            }
            let answer = NetworkResponse(
                status: http?.statusCode ?? 0,
                body: data ?? Data(),
                error: error?.localizedDescription,
                headers: headers
            )
            Task { @MainActor in report(answer) }
        }.resume()
    }
}
