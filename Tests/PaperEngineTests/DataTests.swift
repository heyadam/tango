import Foundation
import Testing
import PaperModel
@testable import PaperEngine

@Suite struct GestureTests {
    func scene() -> (Runtime, NodeID) {
        let box = Layer(name: "Box", kind: .view, properties: [.size: .size(Size2(width: 100, height: 100))])
        var b = SampleDocuments.Builder(screen: Layer(kind: .screen, children: [box]))
        let touch = b.interaction(on: box.id, at: .zero)
        let taps = b.add("counter", at: .zero, name: "Taps")
        let doubles = b.add("counter", at: .zero, name: "Doubles")
        let holds = b.add("counter", at: .zero, name: "Holds")
        b.connect(touch, "tap", to: taps, "increase")
        b.connect(touch, "doubleTap", to: doubles, "increase")
        b.connect(touch, "longPress", to: holds, "increase")
        let runtime = Runtime(document: b.document)
        runtime.tick(dt: 1 / 60)
        return (runtime, touch)
    }

    func counts(_ runtime: Runtime) -> [Double] {
        ["Taps", "Doubles", "Holds"].map { name in
            let node = runtime.document.graph.nodes.first { $0.name == name }!
            return runtime.outputValue(PortRef(node: node.id, port: "value"))!.numberValue
        }
    }

    func tap(_ runtime: Runtime, hold: Double = 0.03) {
        runtime.send(.touchDown(Point2(x: 50, y: 50)))
        runtime.advance(seconds: hold)
        runtime.send(.touchUp(Point2(x: 50, y: 50)))
        runtime.advance(seconds: 0.05)
    }

    @Test func twoQuickTapsAreADoubleTap() {
        let (runtime, _) = scene()
        tap(runtime)
        tap(runtime)
        #expect(counts(runtime) == [2, 1, 0])
        // Two slow taps are just two taps.
        runtime.advance(seconds: 1)
        tap(runtime)
        runtime.advance(seconds: 0.6)
        tap(runtime)
        #expect(counts(runtime) == [4, 1, 0])
    }

    @Test func holdingStillIsALongPressAndNotATap() {
        let (runtime, _) = scene()
        tap(runtime, hold: 0.8)
        #expect(counts(runtime) == [0, 0, 1])
        // Moving away before the delay is a drag, not a long press.
        runtime.send(.touchDown(Point2(x: 50, y: 50)))
        runtime.advance(seconds: 0.1)
        runtime.send(.touchMoved(Point2(x: 90, y: 90)))
        runtime.advance(seconds: 0.8)
        runtime.send(.touchUp(Point2(x: 90, y: 90)))
        runtime.advance(seconds: 0.1)
        #expect(counts(runtime) == [0, 0, 1])
    }

    @Test func aPagingScrollStopsOnPages() {
        let content = Layer(name: "Pages", kind: .view, properties: [.size: .size(Size2(width: 1170, height: 844))])
        var b = SampleDocuments.Builder(screen: Layer(kind: .screen, children: [content]))
        let scroll = b.bound("scroll", to: content.id, at: .zero, inputs: [
            "axis": .text("Horizontal"), "min": .number(-780), "max": .number(0), "page": .number(390),
        ])
        let runtime = Runtime(document: b.document)
        runtime.tick(dt: 1 / 60)
        func offset() -> Double { runtime.outputValue(PortRef(node: scroll, port: "offset"))!.numberValue }

        // A short, slow drag springs back to the page it started on.
        runtime.send(.touchDown(Point2(x: 300, y: 400)))
        runtime.advance(seconds: 0.05)
        runtime.send(.touchMoved(Point2(x: 220, y: 400)))
        runtime.advance(seconds: 0.4)
        runtime.send(.touchUp(Point2(x: 220, y: 400)))
        runtime.advance(seconds: 2)
        #expect(offset() == 0)

        // Dragging past halfway lands on the next page.
        runtime.send(.touchDown(Point2(x: 300, y: 400)))
        runtime.advance(seconds: 0.05)
        runtime.send(.touchMoved(Point2(x: 60, y: 400)))
        runtime.advance(seconds: 0.4)
        runtime.send(.touchUp(Point2(x: 60, y: 400)))
        runtime.advance(seconds: 2)
        #expect(offset() == -390)
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func aGridFillsRowsOfEqualCells() {
        let cells = (0..<5).map { index in
            Layer(name: "Cell \(index)", kind: .view, properties: [
                .size: .size(Size2(width: 10, height: index == 1 ? 60 : 40)), .widthMode: .text("Grow"),
            ])
        }
        let grid = Layer(kind: .view, properties: [
            .size: .size(Size2(width: 320, height: 10)), .layout: .text("Grid"), .columns: .number(3),
            .spacing: .number(10), .paddingHorizontal: .number(10), .paddingVertical: .number(10), .heightMode: .text("Auto"),
        ], children: cells)
        let tree = ResolvedLayer(grid).laidOut()
        let frames = cells.map { tree.find($0.id)!.frame }
        #expect(frames[0] == CGRect(x: 10, y: 10, width: 93.33333333333333, height: 40))
        #expect(frames[2].minX == 10 + 2 * (93.33333333333333 + 10))
        // The second row starts below the tallest cell of the first.
        #expect(frames[3].origin == CGPoint(x: 10, y: 80))
        #expect(tree.size.height == 10 + 60 + 10 + 40 + 10)
    }
}

@Suite struct DataTests {
    @Test func jsonBecomesValuesAndPathsReachIntoIt() {
        let json = Value.parseJSON(#"{"items":[{"name":"Ada","age":36,"admin":true},{"name":"Grace"}],"count":2}"#)!
        #expect(json.value(atPath: "items.0.name") == .text("Ada"))
        #expect(json.value(atPath: "items.0.age") == .number(36))
        #expect(json.value(atPath: "items.0.admin") == .bool(true))
        #expect(json.value(atPath: "items")?.arrayValue.count == 2)
        #expect(json.value(atPath: "items.5.name") == nil)
        #expect(Value.parseJSON("not json") == nil)
        #expect(Value.canConnect(from: .json, to: .array) && Value.canConnect(from: .text, to: .json))
        #expect(!Value.canConnect(from: .json, to: .number))
    }

    func rows(_ runtime: Runtime) -> [ResolvedLayer] {
        var found: [ResolvedLayer] = []
        func walk(_ layer: ResolvedLayer) {
            if layer.name == "Row" { found.append(layer) }
            layer.children.forEach(walk)
        }
        walk(runtime.resolved)
        return found
    }

    func titles(_ runtime: Runtime) -> [String] {
        // The title is inside the row, beside whatever else the row shows.
        func title(in layer: ResolvedLayer) -> ResolvedLayer? {
            layer.name == "Title" ? layer : layer.children.lazy.compactMap(title).first
        }
        return rows(runtime).map { title(in: $0)!.value(.text).textValue }
    }

    @Test func aListFromARequestShowsLoadingThenRowsAndSelectsOne() {
        let example = SampleDocuments.liveList()
        let runtime = Runtime(document: example.document)
        var sent: [NetworkRequest] = []
        runtime.requestHandler = { sent.append($0) }
        runtime.advance(seconds: 0.1)
        func layer(_ id: LayerID) -> ResolvedLayer { runtime.resolved.find(id)! }

        // Loading: the request went out, no rows yet.
        #expect(sent.map(\.url) == [SampleDocuments.LiveList.url])
        #expect(sent[0].method == "GET")
        #expect(layer(example.loading).opacity == 1)
        #expect(layer(example.problem).opacity == 0)
        #expect(rows(runtime).isEmpty)
        #expect(!runtime.needsAnotherFrame)

        // Success: one row per item, laid out as a list.
        let body = #"[{"name":"Leanne Graham","username":"Bret"},{"name":"Ervin Howell","username":"Antonette"},{"name":"Clementine Bauch","username":"Samantha"}]"#
        runtime.complete(sent[0].id, with: NetworkResponse(status: 200, body: Data(body.utf8)))
        #expect(runtime.needsAnotherFrame)
        runtime.advance(seconds: 0.2)
        #expect(layer(example.loading).opacity == 0)
        #expect(titles(runtime) == ["Leanne Graham", "Ervin Howell", "Clementine Bauch"])
        #expect(rows(runtime).map(\.frame.minY) == [0, 52, 104])
        #expect(layer(example.selected).value(.text).textValue == "")

        // Tapping the second row selects that person.
        runtime.send(.touchDown(Point2(x: 100, y: 150 + 52 + 26)))
        runtime.tick(dt: 1 / 60)
        runtime.send(.touchUp(Point2(x: 100, y: 150 + 52 + 26)))
        runtime.advance(seconds: 0.3)
        #expect(layer(example.selected).value(.text).textValue == "Ervin Howell")
    }

    @Test func aFailedRequestShowsTheErrorAndCanBeRetried() {
        let example = SampleDocuments.liveList()
        let runtime = Runtime(document: example.document)
        var sent: [NetworkRequest] = []
        runtime.requestHandler = { sent.append($0) }
        runtime.advance(seconds: 0.1)
        func layer(_ id: LayerID) -> ResolvedLayer { runtime.resolved.find(id)! }

        runtime.complete(sent[0].id, with: NetworkResponse(status: 0, error: "The Internet connection appears to be offline."))
        runtime.advance(seconds: 0.2)
        #expect(layer(example.loading).opacity == 0)
        #expect(layer(example.problem).opacity == 1)
        #expect(layer(example.problem).children[0].value(.text).textValue == "The Internet connection appears to be offline.")
        #expect(rows(runtime).isEmpty)

        // A server error is a failure too.
        // Try Again sends the request again and goes back to loading.
        let button = layer(example.retry)
        let origin = layer(example.problem).frame.origin
        let point = Point2(x: origin.x + button.frame.midX, y: origin.y + button.frame.midY)
        runtime.send(.touchDown(point))
        runtime.tick(dt: 1 / 60)
        runtime.send(.touchUp(point))
        runtime.advance(seconds: 0.2)
        #expect(sent.count == 2)
        #expect(layer(example.loading).opacity == 1)
        #expect(layer(example.problem).opacity == 0)

        runtime.complete(sent[1].id, with: NetworkResponse(status: 500, body: Data("oops".utf8)))
        runtime.advance(seconds: 0.2)
        #expect(layer(example.problem).children[0].value(.text).textValue == "The server answered 500.")
        // An answer nobody is waiting for is ignored.
        runtime.complete(sent[0].id, with: NetworkResponse(status: 200, body: Data("[]".utf8)))
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func commentsAreSavedWithTheGraph() throws {
        let document = SampleDocuments.liveList().document
        #expect(document.graph.comments.count == 2)
        #expect(try Document.decode(from: document.encoded()) == document)
    }
}

@Suite struct NetworkRequestPatchTests {
    @Test func headersAndQueryAreReadAsLinesOrJSON() {
        let lines = NetworkRequest.forPatch(
            url: "https://api.example.com/search?lang=en", method: "post", body: #"{"q":1}"#,
            headers: "Authorization: Bearer abc:def\nAccept: application/json\n\nnot a header",
            query: "q=red shoes&page=2\nsort"
        )
        #expect(lines.method == "POST")
        #expect(lines.body == #"{"q":1}"#)
        #expect(lines.headers == ["Authorization": "Bearer abc:def", "Accept": "application/json"])
        #expect(lines.url == "https://api.example.com/search?lang=en&q=red%20shoes&page=2&sort=")

        let json = NetworkRequest.forPatch(
            url: "https://api.example.com/items", method: "GET", body: "ignored",
            headers: #"{"X-Count": 3, "X-Name": "Ada"}"#, query: #"{"limit": 10, "tag": "a&b"}"#
        )
        #expect(json.headers == ["X-Count": "3", "X-Name": "Ada"])
        #expect(json.url == "https://api.example.com/items?limit=10&tag=a%26b")
        // A GET sends no body, and a method the patch does not offer is a GET.
        #expect(json.body == "")
        #expect(NetworkRequest.forPatch(url: "https://a.b", method: "TRACE", body: "", headers: "", query: "").method == "GET")
        for method in ["PUT", "PATCH", "DELETE"] {
            #expect(NetworkRequest.forPatch(url: "https://a.b", method: method, body: "x", headers: "", query: "").method == method)
        }
    }

    @Test func aQueryAddedToAnAddressLeavesWhatItHadAlone() {
        // `%2B` stays a plus sign the server reads as one, and a typed `+` is encoded.
        let request = NetworkRequest.forPatch(
            url: "https://x.example/?q=1%2B1", method: "GET", body: "", headers: "", query: #"{"lang": "c++", "tag": "a=b;c"}"#
        )
        #expect(request.url == "https://x.example/?q=1%2B1&lang=c%2B%2B&tag=a%3Db%3Bc")
    }

    @Test func anAnswerThatIsNotAPictureClearsTheImage() {
        var document = Document()
        let request = document.graph.add(PatchNode(kind: "networkRequest", inputs: ["url": .text("https://example.com/a")]))
        let runtime = Runtime(document: document)
        var sent: [NetworkRequest] = []
        runtime.requestHandler = { sent.append($0) }
        runtime.advance(seconds: 0.1)
        runtime.complete(sent[0].id, with: NetworkResponse(status: 200, body: Data([1]), headers: ["content-type": "image/png"]))
        runtime.advance(seconds: 0.1)
        #expect(runtime.outputValue(PortRef(node: request, port: "image")) != .text(""))
        runtime.restart()
        sent = []
        runtime.advance(seconds: 0.1)
        runtime.complete(sent[0].id, with: NetworkResponse(status: 500, body: Data()))
        runtime.advance(seconds: 0.1)
        #expect(runtime.outputValue(PortRef(node: request, port: "image")) == .text(""))
    }

    @Test func aPictureThatComesBackIsNamedForAnImageView() {
        var document = Document()
        let image = Layer(name: "Photo", kind: .image)
        document.screen.children.append(image)
        document.normalize()
        let request = document.graph.add(PatchNode(kind: "networkRequest", inputs: [
            "url": .text("https://example.com/cat.jpg"),
            "headers": .text("Accept: image/*"),
            "query": .text("w=200"),
        ]))
        let view = document.graph.nodes.first { $0.layerID == image.id }!
        document.graph.connect(
            from: PortRef(node: request, port: "image"), to: PortRef(node: view.id, port: LayerProperty.image.rawValue)
        )
        let runtime = Runtime(document: document)
        var sent: [NetworkRequest] = []
        runtime.requestHandler = { sent.append($0) }
        runtime.advance(seconds: 0.1)
        #expect(sent.count == 1)
        #expect(sent[0].url == "https://example.com/cat.jpg?w=200")
        #expect(sent[0].headers == ["Accept": "image/*"])

        runtime.complete(sent[0].id, with: NetworkResponse(status: 200, body: Data([0xFF, 0xD8, 0xFF]), headers: ["content-type": "image/jpeg"]))
        runtime.advance(seconds: 0.1)
        let name = NetworkRequest.pictureName(for: sent[0].id)
        #expect(runtime.outputValue(PortRef(node: request, port: "image")) == .text(name))
        #expect(runtime.outputValue(PortRef(node: request, port: "text")) == .text(""))
        #expect(runtime.resolved.find(image.id)?.value(.image) == .text(name))
        #expect(!runtime.needsAnotherFrame)
    }
}
