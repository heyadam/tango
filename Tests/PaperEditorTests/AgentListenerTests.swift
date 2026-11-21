import Foundation
import Testing
@testable import PaperEditor

@MainActor
@Suite struct AgentListenerTests {
    private func post(_ body: String, host: String = "127.0.0.1:47821", extra: String = "") -> Data {
        Data("POST /mcp HTTP/1.1\r\nHost: \(host)\r\nContent-Type: application/json\r\n\(extra)Content-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
    }

    @Test func aRequestIsReadOnceAllOfItHasArrived() throws {
        let whole = post(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        #expect(HTTPRequest.parse(whole.prefix(20)) == .incomplete)
        #expect(HTTPRequest.parse(whole.dropLast(3)) == .incomplete)
        guard case let .request(request, length) = HTTPRequest.parse(whole + Data("POST".utf8)) else {
            Issue.record("not parsed")
            return
        }
        #expect(length == whole.count)
        #expect(request.method == "POST" && request.path == "/mcp")
        #expect(request.headers["content-type"] == "application/json")
        #expect(String(decoding: request.body, as: UTF8.self).contains("ping"))

        // A slice that does not start at index 0, as a connection's buffer does after the first request.
        let two = whole + whole
        #expect(HTTPRequest.parse(two.dropFirst(whole.count)) == .request(request, length: whole.count))

        // curl asks before sending a big body; only then, and only until the body is here.
        let asking = Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n".utf8)
        #expect(HTTPRequest.awaitsContinue(asking))
        #expect(!HTTPRequest.awaitsContinue(whole.dropLast(3)))
        #expect(!HTTPRequest.awaitsContinue(asking.prefix(30)))

        #expect(HTTPRequest.parse(Data("hello\r\n\r\n".utf8)) == .invalid)
        #expect(HTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: -4\r\n\r\n".utf8)) == .invalid)
        #expect(HTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) == .invalid)
    }

    @Test func onlyRequestsMeantForThisMacAreAnswered() throws {
        let listener = AgentListener(server: AgentServer(documents: OpenDocuments()))
        func status(_ data: Data) -> Int {
            guard case let .request(request, _) = HTTPRequest.parse(data) else { return 0 }
            return listener.respond(to: request).status
        }
        let ping = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        #expect(status(post(ping)) == 200)
        #expect(status(post(ping, host: "localhost:47821")) == 200)
        // A web page, even one served from this Mac, is not a coding agent.
        #expect(status(post(ping, extra: "Origin: http://localhost:3000\r\n")) == 403)
        #expect(status(post(ping, extra: "Origin: null\r\n")) == 403)
        // A page on the web that resolved its own name to 127.0.0.1.
        #expect(status(post(ping, host: "evil.example:47821")) == 403)
        #expect(status(post(ping, extra: "Origin: https://evil.example\r\n")) == 403)
        #expect(status(post(ping, host: "127.0.0.1.evil.example")) == 403)

        #expect(status(post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)) == 202)
        #expect(status(Data("GET /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)) == 405)
        #expect(status(Data("POST /other HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\n\r\n".utf8)) == 404)
    }

    @Test func aRealClientCanTalkToItOverHTTP() async throws {
        let store = DocumentStore()
        let documents = OpenDocuments()
        documents.open(store, name: "Untitled")
        let listener = AgentListener(server: AgentServer(documents: documents))
        defer { listener.stop() }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.onState = { state in
                switch state {
                case let .listening(port): continuation.resume(returning: port)
                case let .failed(problem): continuation.resume(throwing: CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: problem]))
                case .starting: break
                }
            }
            listener.start(port: 0)
        }
        listener.onState = nil

        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/mcp")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        func send(_ message: [String: Any]) async throws -> [String: Any] {
            request.httpBody = try JSONSerialization.data(withJSONObject: message)
            let (data, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        let hello = try await send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
        #expect((hello["result"] as? [String: Any])?["serverInfo"] != nil)
        // The same connection is used again for the next request.
        _ = try await send(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": [
            "name": "edit_document",
            "arguments": ["operations": [["op": "add_view", "kind": "ellipse", "name": "Dot"]]],
        ]])
        #expect(store.document.screen.children.first?.name == "Dot")
    }
}
