import Foundation
import Testing
import PaperModel
@testable import PaperEngine

/// The gesture patches as a prototype has them: touches into the runtime, outputs read
/// from the patches (spec 7.2). The rules themselves are held by `GestureArenaTests`.
@Suite struct GesturePatchTests {
    let frame = 1.0 / 60.0

    func out(_ runtime: Runtime, _ node: NodeID, _ port: String) -> Value {
        runtime.outputValue(PortRef(node: node, port: port)) ?? .number(.nan)
    }

    /// A card in the middle of the screen with patches attached to it.
    func card(_ patches: [PatchNode], on layer: Layer? = nil) -> (Runtime, [NodeID]) {
        let card = layer ?? Self.cardLayer
        let nodes = patches.map { patch -> PatchNode in
            var node = patch
            node.layerID = card.id
            return node
        }
        let runtime = Runtime(document: Document(screen: Layer(name: "Screen", kind: .screen, children: [card]), graph: Graph(nodes: nodes)))
        runtime.tick(dt: frame)
        return (runtime, nodes.map(\.id))
    }

    static let cardLayer = Layer(name: "Card", kind: .view, properties: [
        .position: .point(Point2(x: 45, y: 300)), .size: .size(Size2(width: 300, height: 200)),
    ])

    func patch(_ kind: String, _ inputs: [String: Value] = [:]) -> PatchNode {
        PatchNode(kind: kind, position: .zero, inputs: inputs)
    }

    func tap(_ runtime: Runtime, _ x: Double, _ y: Double, finger: Int = 0) {
        runtime.send(.touchBegan(id: finger, Point2(x: x, y: y)))
        runtime.tick(dt: frame)
        runtime.send(.touchEnded(id: finger, Point2(x: x, y: y)))
        runtime.tick(dt: frame)
    }

    /// Moves fingers from where they are to new places over some frames, all together.
    func move(_ runtime: Runtime, _ paths: [Int: (from: Point2, to: Point2)], frames: Int = 10) {
        for step in 1...frames {
            let t = Double(step) / Double(frames)
            for (id, path) in paths.sorted(by: { $0.key < $1.key }) {
                runtime.send(.touchChanged(id: id, path.from + (path.to - path.from) * t))
            }
            runtime.tick(dt: frame)
        }
    }

    // MARK: Tap and Long Press

    @Test func aTapPatchPulsesOnATapAndSaysWhere() {
        let (runtime, nodes) = card([patch(PatchKind.tap)])
        tap(runtime, 100, 350)
        #expect(out(runtime, nodes[0], "tapped").pulseValue)
        #expect(out(runtime, nodes[0], "position").pointValue == Point2(x: 100, y: 350))
        runtime.tick(dt: frame)
        #expect(!out(runtime, nodes[0], "tapped").pulseValue)
        #expect(!runtime.needsAnotherFrame)
        // Beside the card is not on it.
        tap(runtime, 100, 700)
        #expect(!out(runtime, nodes[0], "tapped").pulseValue)
    }

    @Test func aTapAndADoubleTapOnOneViewAreToldApart() {
        let (runtime, nodes) = card([patch(PatchKind.tap), patch(PatchKind.tap, ["taps": .number(2)])])
        var singles = 0, doubles = 0
        func run(_ frames: Int) {
            for _ in 0..<frames {
                runtime.tick(dt: frame)
                if out(runtime, nodes[0], "tapped").pulseValue { singles += 1 }
                if out(runtime, nodes[1], "tapped").pulseValue { doubles += 1 }
            }
        }
        // One tap: the single, once the time for a second has passed, and then it rests.
        runtime.send(.touchDown(Point2(x: 100, y: 350)))
        run(1)
        runtime.send(.touchUp(Point2(x: 100, y: 350)))
        run(1)
        #expect(singles == 0)
        #expect(runtime.needsAnotherFrame)
        run(40)
        #expect(singles == 1 && doubles == 0)
        #expect(!runtime.needsAnotherFrame)

        // Two: the double, and no single at all.
        for _ in 0..<2 {
            runtime.send(.touchDown(Point2(x: 100, y: 350)))
            run(2)
            runtime.send(.touchUp(Point2(x: 100, y: 350)))
            run(3)
        }
        run(40)
        #expect(singles == 1 && doubles == 1)
    }

    @Test func aTwoFingerTapIsNotAOneFingerTap() {
        let (runtime, nodes) = card([patch(PatchKind.tap), patch(PatchKind.tap, ["fingers": .number(2)])])
        runtime.send(.touchBegan(id: 0, Point2(x: 100, y: 350)))
        runtime.send(.touchBegan(id: 1, Point2(x: 200, y: 350)))
        runtime.tick(dt: frame)
        runtime.send(.touchEnded(id: 0, Point2(x: 100, y: 350)))
        runtime.send(.touchEnded(id: 1, Point2(x: 200, y: 350)))
        runtime.tick(dt: frame)
        #expect(out(runtime, nodes[1], "tapped").pulseValue)
        #expect(!out(runtime, nodes[0], "tapped").pulseValue)
    }

    @Test func aLongPressIsOnFromItsDurationUntilTheFingerLifts() {
        let (runtime, nodes) = card([patch(PatchKind.longPress, ["duration": .number(0.25)]), patch(PatchKind.tap)])
        runtime.send(.touchDown(Point2(x: 100, y: 350)))
        runtime.advance(seconds: 0.2)
        #expect(!out(runtime, nodes[0], "pressing").boolValue)
        var began = 0
        for _ in 0..<12 {
            runtime.tick(dt: frame)
            if out(runtime, nodes[0], "began").pulseValue { began += 1 }
        }
        #expect(began == 1)
        #expect(out(runtime, nodes[0], "pressing").boolValue)
        runtime.send(.touchMoved(Point2(x: 160, y: 350)))
        runtime.tick(dt: frame)
        #expect(out(runtime, nodes[0], "pressing").boolValue)
        #expect(out(runtime, nodes[0], "position").pointValue == Point2(x: 160, y: 350))
        runtime.send(.touchUp(Point2(x: 160, y: 350)))
        runtime.tick(dt: frame)
        #expect(out(runtime, nodes[0], "ended").pulseValue)
        #expect(!out(runtime, nodes[0], "pressing").boolValue)
        #expect(!out(runtime, nodes[1], "tapped").pulseValue)
        runtime.advance(seconds: 0.1)
        #expect(!runtime.needsAnotherFrame)
    }

    // MARK: Pan, Pinch, Rotation

    @Test func aPanCountsFromWhereItBeganAndKeepsWhatItMeasured() {
        let (runtime, nodes) = card([patch(PatchKind.pan)])
        let pan = nodes[0]
        runtime.send(.touchDown(Point2(x: 100, y: 350)))
        runtime.tick(dt: frame)
        runtime.send(.touchMoved(Point2(x: 106, y: 350)))
        runtime.tick(dt: frame)
        #expect(!out(runtime, pan, "panning").boolValue)
        runtime.send(.touchMoved(Point2(x: 112, y: 350)))
        runtime.tick(dt: frame)
        #expect(out(runtime, pan, "panning").boolValue)
        #expect(out(runtime, pan, "began").pulseValue)
        #expect(out(runtime, pan, "translation").pointValue == Point2(x: 2, y: 0))
        move(runtime, [0: (Point2(x: 112, y: 350), Point2(x: 212, y: 390))])
        #expect(out(runtime, pan, "translation").pointValue == Point2(x: 102, y: 40))
        #expect(out(runtime, pan, "position").pointValue == Point2(x: 212, y: 390))
        #expect(out(runtime, pan, "velocity").pointValue.x > 300)
        runtime.send(.touchUp(Point2(x: 212, y: 390)))
        runtime.tick(dt: frame)
        #expect(out(runtime, pan, "ended").pulseValue)
        #expect(!out(runtime, pan, "panning").boolValue)
        runtime.advance(seconds: 0.2)
        // What it measured stays, speed included, for a spring to settle from.
        #expect(out(runtime, pan, "translation").pointValue == Point2(x: 102, y: 40))
        #expect(out(runtime, pan, "velocity").pointValue.x > 300)
        #expect(!runtime.needsAnotherFrame)

        // A finger that only rests on it changes nothing of that.
        tap(runtime, 100, 350)
        #expect(out(runtime, pan, "translation").pointValue == Point2(x: 102, y: 40))
    }

    @Test func twoFingersPinchAndTurnAndTheirValuesStay() {
        let (runtime, nodes) = card([patch(PatchKind.pinch), patch(PatchKind.rotation)])
        let (pinch, rotation) = (nodes[0], nodes[1])
        let middle = Point2(x: 195, y: 400)
        runtime.send(.touchBegan(id: 0, Point2(x: 145, y: 400)))
        runtime.send(.touchBegan(id: 1, Point2(x: 245, y: 400)))
        runtime.tick(dt: frame)
        #expect(!out(runtime, pinch, "pinching").boolValue)
        // Spread to 150 apart: a pinch, and no turn.
        move(runtime, [0: (Point2(x: 145, y: 400), Point2(x: 120, y: 400)), 1: (Point2(x: 245, y: 400), Point2(x: 270, y: 400))])
        #expect(out(runtime, pinch, "pinching").boolValue)
        #expect(abs(out(runtime, pinch, "scale").numberValue - 150.0 / 108) < 0.001)
        #expect(out(runtime, pinch, "center").pointValue == middle)
        #expect(out(runtime, pinch, "velocity").numberValue > 0)
        #expect(!out(runtime, rotation, "rotating").boolValue)
        // Then a quarter turn clockwise, the same distance apart.
        for step in 1...30 {
            let angle = Double(step) / 30 * .pi / 2
            let arm = Point2(x: cos(angle) * 75, y: sin(angle) * 75)
            runtime.send(.touchChanged(id: 0, middle - arm))
            runtime.send(.touchChanged(id: 1, middle + arm))
            runtime.tick(dt: frame)
        }
        #expect(out(runtime, rotation, "rotating").boolValue)
        #expect(abs(out(runtime, rotation, "rotation").numberValue - 85) < 0.001)
        #expect(out(runtime, rotation, "velocity").numberValue > 0)
        #expect(abs(out(runtime, pinch, "scale").numberValue - 150.0 / 108) < 0.001)

        runtime.send(.touchEnded(id: 1, Point2(x: 195, y: 475)))
        runtime.tick(dt: frame)
        #expect(out(runtime, pinch, "ended").pulseValue && out(runtime, rotation, "ended").pulseValue)
        #expect(!out(runtime, pinch, "pinching").boolValue)
        runtime.send(.touchEnded(id: 0, Point2(x: 195, y: 325)))
        runtime.advance(seconds: 0.2)
        #expect(abs(out(runtime, pinch, "scale").numberValue - 150.0 / 108) < 0.001)
        #expect(abs(out(runtime, rotation, "rotation").numberValue - 85) < 0.001)
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func aPinchNeedsBothFingersOnTheView() {
        let (runtime, nodes) = card([patch(PatchKind.pinch)])
        runtime.send(.touchBegan(id: 0, Point2(x: 145, y: 400)))
        runtime.send(.touchBegan(id: 1, Point2(x: 245, y: 700)))
        runtime.tick(dt: frame)
        move(runtime, [0: (Point2(x: 145, y: 400), Point2(x: 100, y: 320)), 1: (Point2(x: 245, y: 700), Point2(x: 300, y: 780))])
        #expect(!out(runtime, nodes[0], "pinching").boolValue)
        #expect(out(runtime, nodes[0], "scale").numberValue == 1)
    }

    // MARK: Views in views, and scroll views

    @Test func aGestureOnAViewHearsTouchesOnTheViewsInsideItButAnInteractionDoesNot() {
        let button = Layer(name: "Button", kind: .view, properties: [
            .position: .point(Point2(x: 20, y: 20)), .size: .size(Size2(width: 100, height: 60)),
        ])
        var card = Self.cardLayer
        card.children = [button]
        let press = PatchNode(kind: PatchKind.interaction, position: .zero, layerID: button.id)
        let outer = PatchNode(kind: PatchKind.interaction, position: .zero, layerID: card.id)
        let pan = PatchNode(kind: PatchKind.pan, position: .zero, layerID: card.id)
        let runtime = Runtime(document: Document(
            screen: Layer(name: "Screen", kind: .screen, children: [card]), graph: Graph(nodes: [press, outer, pan])
        ))
        runtime.tick(dt: frame)
        // On the button: its own Interaction, and the card's Pan around it.
        runtime.send(.touchDown(Point2(x: 100, y: 350)))
        runtime.tick(dt: frame)
        #expect(out(runtime, press.id, "down").boolValue)
        #expect(!out(runtime, outer.id, "down").boolValue)
        move(runtime, [0: (Point2(x: 100, y: 350), Point2(x: 180, y: 350))])
        #expect(out(runtime, pan.id, "panning").boolValue)
        // A raw touch goes on beside a gesture.
        #expect(out(runtime, press.id, "down").boolValue)
        #expect(out(runtime, press.id, "drag").pointValue == Point2(x: 80, y: 0))
    }

    /// A list of rows; the third has the patches given.
    func list(_ patches: [PatchNode]) -> (Runtime, scroll: NodeID, nodes: [NodeID]) {
        var list = Layer.new(.scrollView, name: "List")
        list.set(.size, .size(Size2(width: 300, height: 400)))
        list.children = (0..<10).map { index in
            Layer(name: "Row \(index)", kind: .view, properties: [.size: .size(Size2(width: 300, height: 100))])
        }
        let row = list.children[2].id
        let nodes = patches.map { patch -> PatchNode in
            var node = patch
            node.layerID = row
            return node
        }
        var document = Document(screen: Layer(kind: .screen, children: [list]))
        for node in nodes { document.graph.add(node) }
        let runtime = Runtime(document: document)
        runtime.tick(dt: frame)
        return (runtime, document.graph.viewNode(layer: list.id)!.id, nodes.map(\.id))
    }

    @Test func aScrollViewThatBeginsScrollingCancelsTheTouchOfWhatIsInside() {
        let (runtime, scroll, nodes) = list([patch(PatchKind.interaction), patch(PatchKind.tap), patch(PatchKind.swipe)])
        let (press, tapped, swipe) = (nodes[0], nodes[1], nodes[2])
        // A tap on the row is a tap, list or no list.
        tap(runtime, 150, 250)
        #expect(out(runtime, press, "tap").pulseValue)
        #expect(out(runtime, tapped, "tapped").pulseValue)
        runtime.advance(seconds: 0.5)

        runtime.send(.touchDown(Point2(x: 150, y: 250)))
        runtime.tick(dt: frame)
        #expect(out(runtime, press, "down").boolValue)
        var pulses = 0
        for step in 1...8 {
            runtime.send(.touchMoved(Point2(x: 150, y: 250 - Double(step) * 15)))
            runtime.tick(dt: frame)
            for port in ["up", "down"] where out(runtime, swipe, port).pulseValue { pulses += 1 }
        }
        // The list has the touch now: the row is let go of, as on iPhone.
        #expect(out(runtime, scroll, "dragging").boolValue)
        #expect(out(runtime, scroll, "offset").numberValue == -110)
        #expect(!out(runtime, press, "down").boolValue)
        runtime.send(.touchUp(Point2(x: 150, y: 130)))
        runtime.tick(dt: frame)
        for port in ["up", "down"] where out(runtime, swipe, port).pulseValue { pulses += 1 }
        #expect(!out(runtime, press, "tap").pulseValue)
        #expect(!out(runtime, tapped, "tapped").pulseValue)
        #expect(pulses == 0)
        runtime.advance(seconds: 6)
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func aDragAcrossTheListIsLeftToTheRow() {
        let (runtime, scroll, nodes) = list([patch(PatchKind.interaction)])
        runtime.send(.touchDown(Point2(x: 220, y: 250)))
        runtime.tick(dt: frame)
        move(runtime, [0: (Point2(x: 220, y: 250), Point2(x: 100, y: 262))])
        #expect(out(runtime, nodes[0], "down").boolValue)
        #expect(out(runtime, nodes[0], "drag").pointValue == Point2(x: -120, y: 12))
        #expect(!out(runtime, scroll, "dragging").boolValue)
        #expect(out(runtime, scroll, "offset").numberValue == 0)
    }

    @Test func aSidewaysPanOnARowSharesAVerticalListByDirection() {
        var (runtime, scroll, nodes) = list([patch(PatchKind.pan, ["direction": .text("Horizontal")])])
        runtime.send(.touchDown(Point2(x: 220, y: 250)))
        runtime.tick(dt: frame)
        move(runtime, [0: (Point2(x: 220, y: 250), Point2(x: 100, y: 262))])
        #expect(out(runtime, nodes[0], "panning").boolValue)
        #expect(!out(runtime, scroll, "dragging").boolValue)

        (runtime, scroll, nodes) = list([patch(PatchKind.pan, ["direction": .text("Horizontal")])])
        runtime.send(.touchDown(Point2(x: 220, y: 250)))
        runtime.tick(dt: frame)
        move(runtime, [0: (Point2(x: 220, y: 250), Point2(x: 226, y: 150))])
        #expect(!out(runtime, nodes[0], "panning").boolValue)
        #expect(out(runtime, scroll, "dragging").boolValue)
        #expect(out(runtime, scroll, "offset").numberValue < -80)
    }

    @Test func aLongPressOnARowKeepsTheListStill() {
        let (runtime, scroll, nodes) = list([patch(PatchKind.longPress, ["duration": .number(0.3)])])
        runtime.send(.touchDown(Point2(x: 150, y: 250)))
        runtime.advance(seconds: 0.4)
        move(runtime, [0: (Point2(x: 150, y: 250), Point2(x: 150, y: 150))])
        #expect(out(runtime, nodes[0], "pressing").boolValue)
        #expect(out(runtime, scroll, "offset").numberValue == 0)
    }

    // MARK: Repeated views, cancelled touches, numbers that are not numbers

    @Test func eachCopyOfARepeatedViewHasItsOwnGestures() {
        var b = SampleDocuments.Builder(screen: Layer(kind: .screen, children: [
            Layer(name: "Dot", kind: .view, properties: [.size: .size(Size2(width: 60, height: 60))]),
        ]))
        let dot = b.document.screen.children[0].id
        let loop = b.add("loop", at: .zero, inputs: ["count": .number(3)])
        let times = b.add("multiply", at: .zero, inputs: ["b": .number(100)])
        let x = b.view(dot)
        b.connect(loop, "index", to: times, "a")
        b.connect(times, "result", to: x, "x")
        let pan = b.attach(PatchKind.pan, to: dot, at: .zero)
        let runtime = Runtime(document: b.document)
        runtime.tick(dt: frame)
        runtime.tick(dt: frame)
        // The second copy sits at x 100.
        runtime.send(.touchDown(Point2(x: 130, y: 30)))
        runtime.tick(dt: frame)
        move(runtime, [0: (Point2(x: 130, y: 30), Point2(x: 130, y: 90))])
        let panning = runtime.outputValues(PortRef(node: pan, port: "panning")).map(\.boolValue)
        #expect(panning == [false, true, false])
        #expect(runtime.outputValues(PortRef(node: pan, port: "translation"))[1].pointValue == Point2(x: 0, y: 50))
    }

    @Test func aTouchThePlayerLosesEndsWhatItWasDoingAndIsNoTap() {
        let (runtime, nodes) = card([patch(PatchKind.interaction), patch(PatchKind.pan), patch(PatchKind.tap)])
        runtime.send(.touchBegan(id: 7, Point2(x: 100, y: 350)))
        runtime.tick(dt: frame)
        move(runtime, [7: (Point2(x: 100, y: 350), Point2(x: 160, y: 350))])
        #expect(out(runtime, nodes[1], "panning").boolValue)
        runtime.send(.touchCancelled(id: 7))
        runtime.tick(dt: frame)
        #expect(!out(runtime, nodes[0], "down").boolValue)
        #expect(!out(runtime, nodes[0], "tap").pulseValue)
        #expect(!out(runtime, nodes[1], "panning").boolValue)
        #expect(out(runtime, nodes[1], "ended").pulseValue)
        runtime.advance(seconds: 0.1)
        #expect(!runtime.needsAnotherFrame)
    }

    // MARK: Found in review

    @Test func twoInteractionsOnOneViewEachCountTheirOwnTaps() {
        let (runtime, nodes) = card([patch(PatchKind.interaction), patch(PatchKind.interaction)])
        tap(runtime, 100, 350)
        for node in nodes {
            #expect(out(runtime, node, "tap").pulseValue)
            #expect(!out(runtime, node, "doubleTap").pulseValue)
        }
        tap(runtime, 100, 350)
        for node in nodes { #expect(out(runtime, node, "doubleTap").pulseValue) }
        // A third tap starts over, and one long after is a single again.
        tap(runtime, 100, 350)
        for node in nodes { #expect(!out(runtime, node, "doubleTap").pulseValue) }
        runtime.advance(seconds: 1)
        tap(runtime, 100, 350)
        for node in nodes { #expect(!out(runtime, node, "doubleTap").pulseValue) }
    }

    @Test func aGestureGoesOnWithItsPatchWhenTheDocumentIsEditedUnderTheFinger() {
        let pan = PatchNode(kind: PatchKind.pan, position: .zero, layerID: Self.cardLayer.id)
        let press = PatchNode(kind: PatchKind.interaction, position: .zero, layerID: Self.cardLayer.id)
        var document = Document(screen: Layer(name: "Screen", kind: .screen, children: [Self.cardLayer]), graph: Graph(nodes: [press, pan]))
        let runtime = Runtime(document: document)
        runtime.tick(dt: frame)
        runtime.send(.touchDown(Point2(x: 100, y: 350)))
        runtime.tick(dt: frame)
        move(runtime, [0: (Point2(x: 100, y: 350), Point2(x: 160, y: 350))])
        #expect(out(runtime, pan.id, "panning").boolValue)

        // Patches arrive ahead of them in the order, one of them on the same view.
        let swipe = PatchNode(kind: PatchKind.swipe, position: .zero, layerID: Self.cardLayer.id)
        document.graph.nodes.insert(contentsOf: [PatchNode(kind: "not", position: .zero), swipe], at: 0)
        runtime.update(document: document)
        move(runtime, [0: (Point2(x: 160, y: 350), Point2(x: 200, y: 350))])
        #expect(out(runtime, pan.id, "panning").boolValue)
        #expect(out(runtime, pan.id, "translation").pointValue == Point2(x: 90, y: 0))
        #expect(out(runtime, press.id, "down").boolValue)
        #expect(out(runtime, press.id, "drag").pointValue == Point2(x: 100, y: 0))

        // The Pan itself is deleted under the finger: nothing else takes its gesture.
        document.graph.nodes.removeAll { $0.id == pan.id }
        let rotation = PatchNode(kind: PatchKind.rotation, position: .zero, layerID: Self.cardLayer.id)
        document.graph.nodes.append(rotation)
        runtime.update(document: document)
        move(runtime, [0: (Point2(x: 200, y: 350), Point2(x: 240, y: 350))])
        #expect(!out(runtime, rotation.id, "rotating").boolValue)
        #expect(out(runtime, press.id, "down").boolValue)
        runtime.send(.touchUp(Point2(x: 240, y: 350)))
        runtime.advance(seconds: 0.2)
        #expect(!out(runtime, press.id, "down").boolValue)
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func aViewThatOnlyListensForAGestureDoesNotKeepATapFromWhatIsAroundOrBehindIt() {
        // A picture with a Pinch inside a card with an Interaction, and a button behind
        // a second picture.
        let picture = Layer(name: "Picture", kind: .view, properties: [
            .position: .point(Point2(x: 20, y: 20)), .size: .size(Size2(width: 120, height: 120)),
        ])
        var card = Self.cardLayer
        card.children = [picture]
        let button = Layer(name: "Button", kind: .view, properties: [
            .position: .point(Point2(x: 45, y: 600)), .size: .size(Size2(width: 200, height: 80)),
        ])
        let cover = Layer(name: "Cover", kind: .view, properties: [
            .position: .point(Point2(x: 45, y: 600)), .size: .size(Size2(width: 200, height: 80)),
        ])
        let dismiss = PatchNode(kind: PatchKind.interaction, position: .zero, layerID: card.id)
        let zoom = PatchNode(kind: PatchKind.pinch, position: .zero, layerID: picture.id)
        let press = PatchNode(kind: PatchKind.interaction, position: .zero, layerID: button.id)
        let turn = PatchNode(kind: PatchKind.rotation, position: .zero, layerID: cover.id)
        let runtime = Runtime(document: Document(
            screen: Layer(name: "Screen", kind: .screen, children: [card, button, cover]),
            graph: Graph(nodes: [dismiss, zoom, press, turn])
        ))
        runtime.tick(dt: frame)
        tap(runtime, 100, 360)
        #expect(out(runtime, dismiss.id, "tap").pulseValue)
        tap(runtime, 100, 640)
        #expect(out(runtime, press.id, "tap").pulseValue)
        // And the picture still pinches.
        runtime.send(.touchBegan(id: 0, Point2(x: 80, y: 380)))
        runtime.send(.touchBegan(id: 1, Point2(x: 170, y: 380)))
        runtime.tick(dt: frame)
        move(runtime, [0: (Point2(x: 80, y: 380), Point2(x: 70, y: 380)), 1: (Point2(x: 170, y: 380), Point2(x: 180, y: 380))])
        #expect(out(runtime, zoom.id, "pinching").boolValue)
    }

    @Test func whereAFingerLiftsIsTheLastPlaceItsGestureWent() {
        let (runtime, nodes) = card([patch(PatchKind.pan), patch(PatchKind.interaction)])
        runtime.send(.touchDown(Point2(x: 100, y: 350)))
        runtime.tick(dt: frame)
        move(runtime, [0: (Point2(x: 100, y: 350), Point2(x: 150, y: 350))])
        // No move to where it lifts: the lift itself says where.
        runtime.send(.touchUp(Point2(x: 190, y: 380)))
        runtime.tick(dt: frame)
        #expect(out(runtime, nodes[0], "translation").pointValue == Point2(x: 80, y: 30))
        #expect(out(runtime, nodes[1], "drag").pointValue == Point2(x: 90, y: 30))
    }

    @Test func aFingerThatLandsAgainWithoutLiftingMovesFocusByWhereItLandedLast() {
        let name = Layer(name: "Name", kind: .textField, properties: [.position: .point(Point2(x: 20, y: 100))])
        let input = PatchNode(kind: "textInput", position: .zero, layerID: name.id)
        let runtime = Runtime(document: Document(screen: Layer(name: "Screen", kind: .screen, children: [name]), graph: Graph(nodes: [input])))
        runtime.tick(dt: frame)
        // A lost lift: down on the field, then down again far from it, and up there.
        runtime.send(.touchDown(Point2(x: 40, y: 110)))
        runtime.tick(dt: frame)
        runtime.send(.touchDown(Point2(x: 300, y: 700)))
        runtime.tick(dt: frame)
        runtime.send(.touchUp(Point2(x: 40, y: 110)))
        runtime.tick(dt: frame)
        #expect(!out(runtime, input.id, "editing").boolValue)
        // And an ordinary tap on the field still gives it focus.
        tap(runtime, 40, 110)
        #expect(out(runtime, input.id, "editing").boolValue)
    }

    @Test func touchesThatMakeNoSenseAreHarmless() {
        let (runtime, nodes) = card([
            patch(PatchKind.interaction), patch(PatchKind.pan), patch(PatchKind.pinch), patch(PatchKind.rotation),
            patch(PatchKind.tap, ["taps": .number(-1e308), "fingers": .number(.infinity)]),
            patch(PatchKind.longPress, ["duration": .number(-.infinity), "fingers": .number(1e308)]),
            patch(PatchKind.swipe, ["fingers": .number(.nan)]),
        ])
        let wild = [Point2(x: .nan, y: .infinity), Point2(x: -.infinity, y: 1e308), Point2(x: 100, y: 350), Point2(x: 1e308, y: -1e308)]
        for (step, point) in (wild + wild + wild).enumerated() {
            runtime.send(.touchChanged(id: step % 3, point))
            runtime.send(.touchEnded(id: step % 2, point))
            runtime.send(.touchBegan(id: step % 3, point))
            runtime.send(.touchBegan(id: step % 3, wild[(step + 1) % 4]))
            if step % 4 == 3 { runtime.send(.touchCancelled(id: step % 3)) }
            runtime.send(.pinchChanged(scale: .nan, rotation: .infinity))
            runtime.tick(dt: step % 5 == 0 ? 0 : frame)
            for node in nodes {
                for port in ["scale", "rotation", "velocity", "translation", "position", "center", "drag"] {
                    if let value = runtime.outputValue(PortRef(node: node, port: port)) { #expect(value.isFinite) }
                }
            }
        }
        for id in 0..<3 { runtime.send(.touchCancelled(id: id)) }
        runtime.advance(seconds: 1)
        #expect(!runtime.needsAnotherFrame)
    }
}
