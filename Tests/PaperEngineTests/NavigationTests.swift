import Foundation
import Testing
import PaperModel
@testable import PaperEngine

/// Which screen shows and how one gives way to another: `Navigation` alone, then the
/// Navigate patches in a running prototype.
@Suite struct NavigationTests {
    let frame = 1.0 / 60.0
    let size = Size2(width: 400, height: 800)

    func settled(_ navigation: inout Navigation) {
        var frames = 0
        while navigation.move != nil, frames < 600 {
            _ = navigation.step(dt: frame)
            frames += 1
        }
    }

    func three() -> (Navigation, [LayerID]) {
        let pages = [LayerID(), LayerID(), LayerID()]
        var navigation = Navigation()
        navigation.settle(pages: pages)
        return (navigation, pages)
    }

    // MARK: The stack

    @Test func itStartsOnTheFirstScreen() {
        let (navigation, pages) = three()
        #expect(navigation.current == pages[0])
        #expect(!navigation.canGoBack)
        #expect(navigation.placement(of: pages[0], in: size) == Navigation.Placement(visible: true))
        #expect(!navigation.placement(of: pages[1], in: size).visible)
    }

    @Test func aPushSlidesInFromTheRightAndTheOldScreenDrifts() {
        var (navigation, pages) = three()
        navigation.go(to: pages[1], style: .push)
        #expect(navigation.placement(of: pages[1], in: size).offset.x == 400)
        #expect(navigation.front == pages[1])
        for _ in 0..<6 { _ = navigation.step(dt: frame) }
        let arriving = navigation.placement(of: pages[1], in: size)
        let leaving = navigation.placement(of: pages[0], in: size)
        #expect(arriving.visible && leaving.visible)
        #expect(arriving.offset.x > 0 && arriving.offset.x < 400)
        #expect(leaving.offset.x < 0 && leaving.offset.x > -400 * Navigation.parallax)
        settled(&navigation)
        #expect(navigation.current == pages[1])
        #expect(navigation.event == .arrived(pages[1]))
        #expect(navigation.placement(of: pages[1], in: size) == Navigation.Placement(visible: true))
        #expect(!navigation.placement(of: pages[0], in: size).visible)
    }

    @Test func goingBackReplaysTheArrivalInReverse() {
        var (navigation, pages) = three()
        navigation.go(to: pages[1], style: .modal)
        settled(&navigation)
        navigation.back()
        #expect(navigation.current == pages[0])
        #expect(navigation.front == pages[1])
        for _ in 0..<6 { _ = navigation.step(dt: frame) }
        let leaving = navigation.placement(of: pages[1], in: size)
        #expect(leaving.offset.y > 0 && leaving.offset.x == 0)
        #expect(navigation.placement(of: pages[0], in: size).offset == .zero)
        settled(&navigation)
        #expect(navigation.event == .wentBack(to: pages[0]))
        #expect(!navigation.canGoBack)
        // Nothing to go back to: nothing happens.
        navigation.back()
        #expect(navigation.move == nil)
    }

    @Test func aFadeChangesOnlyOpacity() {
        var (navigation, pages) = three()
        navigation.go(to: pages[2], style: .fade)
        for _ in 0..<6 { _ = navigation.step(dt: frame) }
        let arriving = navigation.placement(of: pages[2], in: size)
        #expect(arriving.offset == .zero)
        #expect(arriving.opacity > 0 && arriving.opacity < 1)
        #expect(navigation.placement(of: pages[0], in: size).opacity == 1)
    }

    @Test func aSwitchChangesAtOnceAndLeavesNothingToGoBackTo() {
        var (navigation, pages) = three()
        navigation.go(to: pages[2], style: .replace)
        #expect(navigation.current == pages[2])
        #expect(navigation.move == nil)
        #expect(!navigation.canGoBack)
        #expect(navigation.event == .arrived(pages[2]))
        // The event lasts through the frame after the one it happened in, and no longer.
        let wantsAFrame = navigation.step(dt: frame)
        #expect(wantsAFrame)
        #expect(navigation.event == .arrived(pages[2]))
        let wantsAnother = navigation.step(dt: frame)
        #expect(!wantsAnother)
        #expect(navigation.event == nil)
    }

    @Test func aScreenStillArrivingTurnsRoundWhereItIs() {
        var (navigation, pages) = three()
        navigation.go(to: pages[1], style: .push)
        for _ in 0..<8 { _ = navigation.step(dt: frame) }
        let before = navigation.placement(of: pages[1], in: size).offset.x
        navigation.back()
        #expect(navigation.placement(of: pages[1], in: size).offset.x == before)
        #expect(navigation.current == pages[0])
        settled(&navigation)
        #expect(navigation.event == .wentBack(to: pages[0]))
        #expect(navigation.stack.count == 1)
    }

    @Test func goingWhereItAlreadyIsOrNowhereDoesNothing() {
        var (navigation, pages) = three()
        navigation.go(to: pages[0], style: .push)
        navigation.go(to: LayerID(), style: .push)
        #expect(navigation.move == nil)
        #expect(navigation.stack.count == 1)
    }

    @Test func aScreenThatIsDeletedLeavesTheStack() {
        var (navigation, pages) = three()
        navigation.go(to: pages[1], style: .push)
        settled(&navigation)
        navigation.settle(pages: [pages[0], pages[2]])
        #expect(navigation.current == pages[0])
        navigation.settle(pages: [])
        #expect(navigation.current == nil && !navigation.hasPages)
    }

    // MARK: Swiping back

    @Test func aPushedScreenIsDraggedBackFromTheEdge() {
        var (navigation, pages) = three()
        navigation.go(to: pages[1], style: .push)
        settled(&navigation)
        #expect(navigation.canSwipeBack)
        navigation.dragBack(0.3)
        // It follows the finger and the stack is not changed yet.
        #expect(abs(navigation.placement(of: pages[1], in: size).offset.x - 120) < 0.001)
        #expect(navigation.current == pages[1])
        for _ in 0..<5 { _ = navigation.step(dt: frame) }
        #expect(abs(navigation.placement(of: pages[1], in: size).offset.x - 120) < 0.001)
        navigation.dragBack(0.7)
        navigation.endDragBack(velocity: 0)
        #expect(navigation.current == pages[0])
        settled(&navigation)
        #expect(navigation.event == .wentBack(to: pages[0]))
        #expect(!navigation.canGoBack)
    }

    @Test func letGoTooEarlyItSlidesHomeAndNothingHappened() {
        var (navigation, pages) = three()
        navigation.go(to: pages[1], style: .push)
        settled(&navigation)
        navigation.dragBack(0.2)
        navigation.endDragBack(velocity: 0)
        #expect(navigation.current == pages[1])
        var events: [Navigation.Event] = []
        for _ in 0..<300 where navigation.move != nil || navigation.event != nil {
            _ = navigation.step(dt: frame)
            if let event = navigation.event { events.append(event) }
        }
        #expect(events.isEmpty)
        #expect(navigation.placement(of: pages[1], in: size) == Navigation.Placement(visible: true))
        // A flick goes back however short it was.
        navigation.dragBack(0.1)
        navigation.endDragBack(velocity: 2)
        #expect(navigation.current == pages[0])
    }

    @Test func onlyAPushedScreenSwipesBack() {
        var (navigation, pages) = three()
        #expect(!navigation.canSwipeBack)
        navigation.go(to: pages[2], style: .modal)
        settled(&navigation)
        #expect(!navigation.canSwipeBack)
        navigation.dragBack(0.6)
        #expect(navigation.move == nil)
    }

    // MARK: In a prototype

    struct Flow {
        var runtime: Runtime
        var home: Layer
        var detail: Layer
        var go: NodeID
        var back: NodeID
    }

    /// Two screens: a button on the first pushes the second, a button there goes back.
    func flow(style: Navigation.Style = .push, extra: [PatchNode] = [], cables: [Connection] = []) -> Flow {
        let open = Layer(name: "Open", kind: .view, properties: [
            .position: .point(Point2(x: 100, y: 100)), .size: .size(Size2(width: 200, height: 60)),
        ])
        let close = Layer(name: "Close", kind: .view, properties: [
            .position: .point(Point2(x: 20, y: 700)), .size: .size(Size2(width: 100, height: 60)),
        ])
        var home = Layer.newPage(name: "Home")
        home.children = [open]
        var detail = Layer.newPage(name: "Detail")
        detail.children = [close]
        let tapOpen = PatchNode(kind: PatchKind.tap, layerID: open.id)
        let tapClose = PatchNode(kind: PatchKind.tap, layerID: close.id)
        let go = PatchNode(kind: PatchKind.navigate, inputs: ["style": .text(style.rawValue)], layerID: detail.id)
        let back = PatchNode(kind: PatchKind.navigateBack)
        var graph = Graph(nodes: [tapOpen, tapClose, go, back] + extra)
        graph.connect(from: PortRef(node: tapOpen.id, port: "tapped"), to: PortRef(node: go.id, port: "go"))
        graph.connect(from: PortRef(node: tapClose.id, port: "tapped"), to: PortRef(node: back.id, port: "go"))
        for cable in cables { graph.connect(from: cable.from, to: cable.to) }
        let screen = Layer(name: "Screen", kind: .screen, properties: [.size: .size(size)], children: [home, detail])
        let runtime = Runtime(document: Document(screen: screen, graph: graph))
        runtime.tick(dt: frame)
        return Flow(runtime: runtime, home: home, detail: detail, go: go.id, back: back.id)
    }

    func tap(_ runtime: Runtime, _ x: Double, _ y: Double) {
        runtime.send(.touchBegan(id: 0, Point2(x: x, y: y)))
        runtime.tick(dt: frame)
        runtime.send(.touchEnded(id: 0, Point2(x: x, y: y)))
        runtime.tick(dt: frame)
    }

    func rest(_ runtime: Runtime) {
        var frames = 0
        while runtime.needsAnotherFrame, frames < 600 {
            runtime.tick(dt: frame)
            frames += 1
        }
    }

    func out(_ runtime: Runtime, _ node: NodeID, _ port: String) -> Value {
        runtime.outputValue(PortRef(node: node, port: port)) ?? .number(.nan)
    }

    @Test func onlyTheFirstScreenIsThereAtTheStartAndItFillsTheDevice() {
        let made = flow()
        #expect(made.runtime.resolved.children.map(\.id) == [made.home.id])
        #expect(made.runtime.resolved.children[0].frame == CGRect(x: 0, y: 0, width: 400, height: 800))
        rest(made.runtime)
        #expect(!made.runtime.needsAnotherFrame)
    }

    @Test func aTapPushesTheNextScreenAndATapThereGoesBack() {
        let made = flow()
        let runtime = made.runtime
        tap(runtime, 150, 120)
        for _ in 0..<4 { runtime.tick(dt: frame) }
        // Both are there while one gives way, the arriving one on top.
        #expect(runtime.resolved.children.map(\.id) == [made.home.id, made.detail.id])
        #expect(runtime.resolved.children[1].frame.minX > 0)
        #expect(runtime.resolved.children[0].frame.minX < 0)
        #expect(out(runtime, made.go, "progress").numberValue > 0)
        var arrived = 0
        for _ in 0..<300 where runtime.needsAnotherFrame {
            runtime.tick(dt: frame)
            if out(runtime, made.go, "arrived").pulseValue { arrived += 1 }
        }
        #expect(arrived == 1)
        #expect(!runtime.needsAnotherFrame)
        #expect(runtime.resolved.children.map(\.id) == [made.detail.id])
        #expect(runtime.resolved.children[0].frame == CGRect(x: 0, y: 0, width: 400, height: 800))
        #expect(out(runtime, made.go, "showing").boolValue)
        #expect(out(runtime, made.back, "canGoBack").boolValue)

        tap(runtime, 60, 720)
        for _ in 0..<4 { runtime.tick(dt: frame) }
        // Going back, the leaving screen stays on top of the one it uncovers.
        #expect(runtime.resolved.children.map(\.id) == [made.home.id, made.detail.id])
        rest(runtime)
        #expect(runtime.resolved.children.map(\.id) == [made.home.id])
        #expect(!out(runtime, made.back, "canGoBack").boolValue)
        #expect(out(runtime, made.go, "progress").numberValue == 0)
    }

    @Test func aFingerAtTheLeftEdgeSwipesAPushedScreenBack() {
        let made = flow()
        let runtime = made.runtime
        tap(runtime, 150, 120)
        rest(runtime)
        #expect(runtime.navigation.current == made.detail.id)
        // Down at the edge, across most of the screen, and up.
        runtime.send(.touchBegan(id: 0, Point2(x: 6, y: 400)))
        runtime.tick(dt: frame)
        for x in stride(from: 40.0, through: 280, by: 40) {
            runtime.send(.touchChanged(id: 0, Point2(x: x, y: 400)))
            runtime.tick(dt: frame)
        }
        // Both screens are there, the pushed one where the finger is.
        #expect(runtime.resolved.children.map(\.id) == [made.home.id, made.detail.id])
        #expect(abs(runtime.resolved.children[1].frame.minX - 274) < 1)
        runtime.send(.touchEnded(id: 0, Point2(x: 280, y: 400)))
        rest(runtime)
        #expect(runtime.navigation.current == made.home.id)
        #expect(runtime.resolved.children.map(\.id) == [made.home.id])

        // Away from the edge a drag is the screen's own.
        tap(runtime, 150, 120)
        rest(runtime)
        runtime.send(.touchBegan(id: 0, Point2(x: 120, y: 400)))
        runtime.tick(dt: frame)
        runtime.send(.touchChanged(id: 0, Point2(x: 380, y: 400)))
        runtime.tick(dt: frame)
        runtime.send(.touchEnded(id: 0, Point2(x: 380, y: 400)))
        rest(runtime)
        #expect(runtime.navigation.current == made.detail.id)
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func aButtonOnAScreenThatIsNotShowingCannotBeTapped() {
        let made = flow()
        // Where Close is on the second screen: nothing is there on the first.
        tap(made.runtime, 60, 720)
        rest(made.runtime)
        #expect(made.runtime.navigation.current == made.home.id)
    }

    @Test func restartGoesBackToTheFirstScreen() {
        let made = flow(style: .replace)
        tap(made.runtime, 150, 120)
        rest(made.runtime)
        #expect(made.runtime.resolved.children.map(\.id) == [made.detail.id])
        made.runtime.restart()
        made.runtime.tick(dt: frame)
        #expect(made.runtime.resolved.children.map(\.id) == [made.home.id])
    }

    @Test func aCableOnAScreenStillWins() {
        // A Value patch holds the second screen's opacity at a half, through a fade.
        let value = PatchNode(kind: "value", inputs: ["value": .number(0.5)], valueType: .number)
        var made = flow(style: .fade)
        let document = made.runtime.document
        var graph = document.graph
        graph.add(value)
        let view = graph.viewNode(layer: made.detail.id)!
        graph.connect(from: PortRef(node: value.id, port: "value"), to: PortRef(node: view.id, port: "opacity"))
        made.runtime = Runtime(document: Document(screen: document.screen, graph: graph))
        made.runtime.tick(dt: frame)
        tap(made.runtime, 150, 120)
        for _ in 0..<3 { made.runtime.tick(dt: frame) }
        #expect(made.runtime.resolved.children.last?.opacity == 0.5)
        rest(made.runtime)
        #expect(made.runtime.resolved.children.last?.opacity == 0.5)
    }

    @Test func aDocumentWithoutScreensIsLeftAlone() {
        let card = Layer(name: "Card", kind: .view, properties: [.position: .point(Point2(x: 40, y: 50))])
        let runtime = Runtime(document: Document(screen: Layer(name: "Screen", kind: .screen, children: [card])))
        runtime.tick(dt: frame)
        #expect(!runtime.navigation.hasPages)
        #expect(runtime.resolved.children[0].frame.origin == CGPoint(x: 40, y: 50))
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func theGalleryExamplePushesPresentsAndGoesBack() {
        let made = SampleDocuments.screenFlow()
        let runtime = Runtime(document: made.document)
        runtime.tick(dt: frame)
        func tapOn(_ layer: LayerID) {
            let box = runtime.resolved.find(layer)!.frame
            tap(runtime, box.midX, box.midY)
            rest(runtime)
        }
        #expect(runtime.navigation.current == made.inbox)
        tapOn(made.row)
        #expect(runtime.navigation.current == made.message)
        tapOn(made.back)
        #expect(runtime.navigation.current == made.inbox)
        tapOn(made.write)
        #expect(runtime.navigation.current == made.compose)
        #expect(runtime.navigation.stack.last?.style == .modal)
        tapOn(made.close)
        #expect(runtime.navigation.current == made.inbox)
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func morphMovesAViewNamedTheSameAndCrossfadesTheRest() throws {
        let card = Layer(name: "Card", kind: .view, properties: [
            .position: .point(Point2(x: 20, y: 100)), .size: .size(Size2(width: 100, height: 60)),
            .fill: .color(ColorValue(red: 1, green: 0, blue: 0)), .cornerRadius: .number(10),
        ])
        let caption = Layer(name: "Caption", kind: .view, properties: [
            .position: .point(Point2(x: 20, y: 400)), .size: .size(Size2(width: 100, height: 20)), .fill: .color(.black),
        ])
        var list = Layer.newPage(name: "List")
        list.children = [card, caption]
        let big = Layer(name: "Card", kind: .view, properties: [
            .position: .point(Point2(x: 0, y: 0)), .size: .size(Size2(width: 400, height: 300)),
            .fill: .color(ColorValue(red: 0, green: 0, blue: 1)), .cornerRadius: .number(30),
        ])
        let close = Layer(name: "Close", kind: .view, properties: [
            .position: .point(Point2(x: 20, y: 700)), .size: .size(Size2(width: 60, height: 40)), .fill: .color(.black),
        ])
        var detail = Layer.newPage(name: "Detail")
        detail.children = [big, close]
        let onCard = PatchNode(kind: PatchKind.tap, layerID: card.id)
        let go = PatchNode(kind: PatchKind.navigate, inputs: ["style": .text("Morph")], layerID: detail.id)
        var graph = Graph(nodes: [onCard, go])
        graph.connect(from: PortRef(node: onCard.id, port: "tapped"), to: PortRef(node: go.id, port: "go"))
        let screen = Layer(name: "Device", kind: .screen, properties: [.size: .size(size)], children: [list, detail])
        let runtime = Runtime(document: Document(screen: screen, graph: graph))
        runtime.tick(dt: frame)
        tap(runtime, 50, 120)
        // Part way: the card is between its two frames, on the screen arriving, and drawn
        // once; what the screens do not share is part faded.
        var shown = 0.0
        for _ in 0..<60 where shown < 0.35 {
            runtime.tick(dt: frame)
            shown = runtime.navigation.move?.shown ?? 1
        }
        let moving = try #require(runtime.resolved.find(big.id))
        #expect(moving.frame.width > 100 && moving.frame.width < 400)
        #expect(moving.frame.minX > 0 && moving.frame.minX < 20)
        #expect(moving.value(.cornerRadius).numberValue > 10 && moving.value(.cornerRadius).numberValue < 30)
        #expect(runtime.resolved.find(card.id)?.opacity == 0)
        let fadingIn = try #require(runtime.resolved.find(close.id)?.opacity)
        let fadingOut = try #require(runtime.resolved.find(caption.id)?.opacity)
        #expect(fadingIn > 0 && fadingIn < 1 && fadingOut > 0 && fadingOut < 1)
        #expect(abs(fadingIn + fadingOut - 1) < 0.0001)
        // Both screens stay where they rest; the arriving one on top.
        #expect(runtime.resolved.children.map(\.id) == [list.id, detail.id])
        #expect(runtime.resolved.children.allSatisfy { $0.frame.origin == .zero })
        // At the end only the detail is there, as designed.
        rest(runtime)
        #expect(runtime.resolved.children.map(\.id) == [detail.id])
        #expect(runtime.resolved.find(big.id)?.frame == CGRect(x: 0, y: 0, width: 400, height: 300))
        #expect(runtime.resolved.find(big.id)?.value(.fill) == .color(ColorValue(red: 0, green: 0, blue: 1)))
    }

    @Test func theCardToScreenExampleOpensAndCloses() throws {
        let made = SampleDocuments.morphingCard()
        let runtime = Runtime(document: made.document)
        runtime.tick(dt: frame)
        let card = try #require(runtime.resolved.find(made.card)).frame
        tap(runtime, card.midX, card.midY)
        runtime.tick(dt: frame)
        // The detail's card starts where the feed's card is.
        let starting = try #require(runtime.resolved.find(made.bigCard)).frame
        #expect(abs(starting.width - card.width) < 60)
        rest(runtime)
        #expect(runtime.navigation.current == made.detail)
        let close = try #require(runtime.resolved.find(made.close)).frame
        tap(runtime, close.midX, close.midY)
        rest(runtime)
        #expect(runtime.navigation.current == made.feed)
        #expect(runtime.resolved.find(made.card)?.frame == card)
    }

    // MARK: The model

    @Test func onlyAViewDirectlyInTheRootCanBeAScreen() throws {
        var inner = Layer.newPage(name: "Inner")
        inner.children = []
        var page = Layer.newPage(name: "Page")
        page.children = [inner]
        var text = Layer(name: "Label", kind: .text)
        text.page = true
        let document = Document(screen: Layer(name: "Screen", kind: .screen, children: [page, text]))
        #expect(document.screen.pages.map(\.name) == ["Page"])
        #expect(document.screen.children[0].children[0].page == nil)
        #expect(document.screen.children[1].page == nil)
        // It is saved, and a document without screens saves nothing new.
        let data = try JSONEncoder().encode(document)
        #expect(try JSONDecoder().decode(Document.self, from: data) == document)
        let plain = try JSONEncoder().encode(Document(screen: Layer(name: "Screen", kind: .screen, children: [text])))
        #expect(!String(decoding: plain, as: UTF8.self).contains("\"page\""))
    }
}
