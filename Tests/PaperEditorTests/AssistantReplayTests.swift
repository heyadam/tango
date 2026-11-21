import AppKit
import Foundation
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

/// The Viewer showing what the assistant does when it tries the prototype.
@MainActor
@Suite struct AssistantReplayTests {
    private let frame = ViewerSnapshot.frameLength

    private func cardStore() -> DocumentStore {
        DocumentStore(package: DocumentPackage(document: SampleDocuments.card().document))
    }

    private func viewer(_ store: DocumentStore) -> ViewerView {
        let screen = store.document.screen.value(.size).sizeValue
        let view = ViewerView(store: store, sendsRequests: false)
        view.fillsWindow = true
        view.frame = NSRect(x: 0, y: 0, width: screen.width, height: screen.height)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func events(_ beats: [ViewerSnapshot.Beat]) -> [InputEvent] {
        beats.flatMap { beat -> [InputEvent] in
            if case let .frame(frame) = beat { return frame.events }
            return []
        }
    }

    private func cardHeight(_ view: ViewerView) -> Double {
        view.runtime.resolved.children.first { $0.name == "Card" }?.size.height ?? 0
    }

    private func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    private func frames(_ beats: [ViewerSnapshot.Beat]) -> [ViewerSnapshot.Frame] {
        beats.compactMap { beat -> ViewerSnapshot.Frame? in
            if case let .frame(frame) = beat { return frame }
            return nil
        }
    }

    /// What the prototype is sent in each sixtieth of a second of its own time.
    private func timeline(_ beats: [ViewerSnapshot.Beat]) -> [[InputEvent]] {
        frames(beats).flatMap { frame -> [[InputEvent]] in
            frame.ticks == 0 ? [] : [frame.events] + Array(repeating: [], count: frame.ticks - 1)
        }
    }

    @Test func pacingNeverMovesThePrototypesOwnTime() {
        let scripts: [[ViewerSnapshot.Step]] = [
            [.tap(Point2(x: 100, y: 200)), .tap(Point2(x: 150, y: 200)), .look],
            [.tap(Point2(x: 100, y: 200)), .wait(0.5), .tap(Point2(x: 300, y: 600)), .wait(7), .look],
            [.drag(from: Point2(x: 10, y: 10), to: Point2(x: 10, y: 70), seconds: 0.1), .look,
             .pinch(at: Point2(x: 100, y: 100), scale: 2, rotation: 90, seconds: 0.1),
             .hover(Point2(x: 5, y: 5)), .tap(Point2(x: 9, y: 9)), .type("hey"), .submit, .deleteBackward, .look],
            [.down(Point2(x: 1, y: 1)), .wait(0.6), .move(to: Point2(x: 90, y: 1), seconds: 0.2), .up(), .look],
            [.wait(40), .tap(Point2(x: 1, y: 1)), .look],
            // Two fingers, each its own: down one after the other, moved, lifted in turn.
            [.down(Point2(x: 100, y: 100)), .down(Point2(x: 200, y: 100), finger: 2), .look,
             .move(to: Point2(x: 260, y: 140), seconds: 0.2, finger: 2), .move(to: Point2(x: 80, y: 90), seconds: 0.1),
             .up(finger: 2), .wait(0.3), .up(), .look],
            [.pinch(at: Point2(x: 195, y: 400), scale: 1.5, rotation: 30, seconds: 0.3, pan: Point2(x: 40, y: -20)), .look],
        ]
        for steps in scripts {
            let exact = ViewerSnapshot.beats(for: steps), paced = ViewerSnapshot.beats(for: steps, paced: true)
            // The same things, at the same moments of the prototype's time.
            #expect(timeline(exact) == timeline(paced))
            #expect(frames(exact).allSatisfy { $0.ticks == 1 })
            // A frame in which the prototype stands still sends it nothing.
            #expect(frames(paced).allSatisfy { $0.ticks > 0 || $0.events.isEmpty })
        }
    }

    @Test func aLongWaitIsHurriedThroughNotCutShort() {
        let paced = frames(ViewerSnapshot.beats(for: [.tap(.zero), .wait(20), .look], paced: true))
        // Twenty seconds of the prototype's time, shown in about two.
        #expect(paced.map(\.ticks).reduce(0, +) >= 20 * 60)
        #expect(Double(paced.count) * frame < 3.5)
        // A short one is shown as it is.
        let short = frames(ViewerSnapshot.beats(for: [.wait(1)], paced: true))
        #expect(short.filter { $0.ticks == 1 }.count == 60 && !short.contains { $0.ticks > 1 })
    }

    @Test func theFingerTravelsDuringAWaitRatherThanHoldingThePrototypeUp() {
        let far = Point2(x: 300, y: 600)
        let paced = frames(ViewerSnapshot.beats(for: [.tap(.zero), .wait(1), .tap(far), .look], paced: true))
        let second = paced.firstIndex { $0.events.contains(.touchDown(far)) }!
        // The frames before the second touch are the wait's own, with the finger on its way.
        let before = paced[(second - 18)..<second]
        #expect(before.allSatisfy { $0.ticks == 1 && $0.resting != nil })
        #expect(before.last?.resting == far)
        // Only the very first touch, with nothing before it, makes the prototype wait.
        #expect(paced[..<second].filter { $0.ticks == 0 }.count <= 8)
    }

    @Test func fingersAreWhereTheStepsPutThem() throws {
        let point = Point2(x: 100, y: 200)
        let paced = frames(ViewerSnapshot.beats(for: [.tap(point), .look], paced: true))
        // It arrives without touching, touches, and lifts.
        #expect(paced.first?.resting == point && paced.first?.fingers.isEmpty == true)
        let down = try #require(paced.firstIndex { $0.events == [.touchDown(point)] })
        #expect(paced[down].fingers == [point])
        let up = try #require(paced.firstIndex { $0.events == [.touchUp(point)] })
        #expect(up == down + 1 && paced[up].fingers.isEmpty)

        // Straight from one touch to the next, the prototype stands still while it travels.
        let two = frames(ViewerSnapshot.beats(for: [.tap(Point2(x: 0, y: 0)), .tap(Point2(x: 100, y: 0))], paced: true))
        #expect(two.contains { $0.ticks == 0 && ($0.resting?.x ?? 0) > 10 && ($0.resting?.x ?? 0) < 90 })

        let pinch = ViewerSnapshot.pinchFingers(at: Point2(x: 100, y: 100), scale: 2, rotation: 90)
        #expect(abs(pinch[0].x - 100) < 0.001 && abs(pinch[1].y - pinch[0].y) > 150)
    }

    @Test func aReplayNeverSendsAnAIRequest() throws {
        let button = Layer(name: "Button", kind: .view, properties: [
            .position: .point(Point2(x: 0, y: 0)), .size: .size(Size2(width: 300, height: 300)),
        ])
        var screen = Layer(name: "Screen", kind: .screen)
        screen.children = [button]
        let touch = PatchNode(kind: PatchKind.interaction, layerID: button.id)
        let ai = PatchNode(kind: "aiText", inputs: ["prompt": .text("Hi")])
        var graph = Graph(nodes: [touch, ai])
        graph.connect(from: PortRef(node: touch.id, port: "tap"), to: PortRef(node: ai.id, port: "send"))
        let store = DocumentStore(package: DocumentPackage(document: PaperModel.Document(screen: screen, graph: graph)))
        let view = ViewerView(store: store, sendsRequests: true)
        view.fillsWindow = true
        view.frame = NSRect(x: 0, y: 0, width: 402, height: 874)
        view.replay([.tap(Point2(x: 100, y: 100)), .wait(0.5)])
        var frames = 0
        while view.isReplaying, frames < 600 {
            view.advance(by: frame)
            frames += 1
        }
        view.advance(by: frame)
        #expect(view.runtime.outputValue(PortRef(node: ai.id, port: "error")) == .text(ViewerView.notSentDuringReplay))
        #expect(view.runtime.outputValue(PortRef(node: ai.id, port: "loading")) == .bool(false))
    }

    @Test func aReplayedTapOpensTheCardAndShowsTheFinger() throws {
        let store = cardStore()
        let view = viewer(store)
        let closed = cardHeight(view)
        let card = try #require(view.runtime.resolved.children.first { $0.name == "Card" })
        let middle = Point2(x: card.position.x + card.size.width / 2, y: card.position.y + card.size.height / 2)
        #expect(!view.isReplaying && !view.showsAgentBadge)

        view.replay([.tap(middle), .wait(1), .look])
        #expect(view.isReplaying)
        var sawFinger = false
        var frames = 0
        while view.isReplaying, frames < 600 {
            view.advance(by: frame)
            frames += 1
            if let finger = view.agentFingerPositions.first {
                sawFinger = true
                #expect(view.showsAgentBadge)
                // View coordinates have y going up; the screen fills this view.
                #expect(abs(finger.x - middle.x) < 0.5 && abs(finger.y - (view.bounds.height - middle.y)) < 0.5)
            }
        }
        #expect(sawFinger && frames > 60)
        #expect(cardHeight(view) > closed + 100)
        // Once it is over nothing of the assistant's is left on screen.
        for _ in 0..<30 { view.advance(by: frame) }
        #expect(view.agentFingerPositions.isEmpty && !view.showsAgentBadge)
    }

    @Test func aReplayPlaysAtTheSameSpeedOnAFasterDisplay() {
        let steps: [ViewerSnapshot.Step] = [.tap(Point2(x: 10, y: 10)), .wait(0.5)]
        func seconds(dt: Double) -> Double {
            let view = viewer(DocumentStore())
            view.replay(steps)
            var time = 0.0
            while view.isReplaying, time < 30 {
                view.advance(by: dt)
                time += dt
            }
            return time
        }
        #expect(abs(seconds(dt: 1.0 / 60) - seconds(dt: 1.0 / 120)) < 0.1)
    }

    @Test func theToolsHandTheirStepsToTheViewer() throws {
        let store = cardStore()
        var replayed: [[ViewerSnapshot.Step]] = []
        store.onReplay = { steps, _ in replayed.append(steps) }
        let toolbox = AssistantToolbox(store: store)

        // A look alone would only start the prototype over under the person.
        _ = toolbox.call("view_prototype", input: [:])
        #expect(replayed.isEmpty)

        _ = toolbox.call("view_prototype", input: ["tap": ["x": 200, "y": 400], "seconds": 1])
        #expect(replayed == [[.tap(Point2(x: 200, y: 400)), .wait(1), .look]])

        let result = toolbox.call("interact_prototype", input: ["steps": [
            ["do": "drag", "from": ["x": 10, "y": 10], "to": ["x": 10, "y": 90]], ["do": "look"],
        ]])
        #expect(!result.isError && result.images.count == 1)
        #expect(replayed.last == [.drag(from: Point2(x: 10, y: 10), to: Point2(x: 10, y: 90), seconds: 0.3), .look])

        // Steps that are refused are not shown.
        _ = toolbox.call("interact_prototype", input: ["steps": [["do": "fly"]]])
        #expect(replayed.count == 2)

        // Nor is anything while the Viewer is closed.
        store.showsViewer = false
        _ = toolbox.call("view_prototype", input: ["tap": ["x": 1, "y": 1]])
        #expect(replayed.count == 2)
    }

    @Test func theLiveViewerPlaysWhatTheToolsDid() {
        let store = cardStore()
        let view = viewer(store)
        _ = AssistantToolbox(store: store).call("view_prototype", input: ["tap": ["x": 200, "y": 400]])
        #expect(view.isReplaying)
    }

    @Test func thePersonTouchingThePrototypeEndsTheReplay() {
        let store = cardStore()
        let view = viewer(store)
        view.replay([.down(Point2(x: 200, y: 400)), .wait(2)])
        view.replay([.tap(Point2(x: 5, y: 5))])
        for _ in 0..<40 { view.advance(by: frame) }
        #expect(view.isReplaying && !view.agentFingerPositions.isEmpty)

        view.mouseDown(with: event(.leftMouseDown, 20, 20))
        #expect(!view.isReplaying && view.agentFingerPositions.isEmpty && !view.showsAgentBadge)
        // The waiting replay is gone too, and the assistant's finger was lifted for it.
        view.mouseUp(with: event(.leftMouseUp, 20, 20))
        for _ in 0..<30 { view.advance(by: frame) }
        #expect(!view.isReplaying)
    }

    @Test func aReplayAskedForDuringAnotherWaitsAndOnlyTheNewestIsKept() {
        let view = viewer(DocumentStore())
        view.replay([.tap(Point2(x: 10, y: 10))])
        view.replay([.tap(Point2(x: 20, y: 20))])
        view.replay([.tap(Point2(x: 300, y: 30))])
        var xs: Set<Int> = []
        var frames = 0
        while view.isReplaying, frames < 600 {
            view.advance(by: frame)
            frames += 1
            if let finger = view.agentFingerPositions.first { xs.insert(Int(finger.x.rounded())) }
        }
        #expect(xs == [10, 300])
    }

    // MARK: QA

    private func play(_ view: ViewerView, limit: Int = 60 * 120) -> Int {
        var frames = 0
        while view.isReplaying, frames < limit {
            view.advance(by: frame)
            frames += 1
        }
        return frames
    }

    /// A screen with a button at 100...300 both ways that counts its taps and knows when a
    /// finger or a pointer is on it, and a text field under it.
    private func playground() -> DocumentStore {
        let store = DocumentStore()
        let result = AssistantToolbox(store: store).call("edit_document", input: ["operations": [
            ["op": "add_view", "kind": "view", "name": "Button", "ref": "button", "properties": [
                "x": 100, "y": 100, "width": 200, "height": 200,
            ]],
            ["op": "add_view", "kind": "textField", "name": "Field", "properties": [
                "x": 100, "y": 400, "width": 200, "height": 44,
            ]],
            ["op": "add_patch", "kind": "interaction", "view": "button", "ref": "touch"],
            ["op": "add_patch", "kind": "hover", "view": "button"],
            ["op": "add_patch", "kind": "counter", "ref": "count"],
            ["op": "connect", "from": "touch", "output": "tap", "to": "count", "input": "increase"],
        ]])
        #expect(!result.isError, "\(result.text)")
        return store
    }

    private func output(_ kind: String, _ port: String, in view: ViewerView, _ store: DocumentStore) -> Value {
        let node = store.document.graph.patches.first { $0.kind == kind }
        return node.flatMap { view.runtime.outputValue(PortRef(node: $0.id, port: port)) } ?? .number(-1)
    }

    /// A mouse event at a point of the screen, for a Viewer the screen fills.
    private func mouse(_ type: NSEvent.EventType, at point: Point2, in view: ViewerView) -> NSEvent {
        event(type, point.x, view.bounds.height - point.y)
    }

    @Test func aFingerLeftDownByTheStepsIsLiftedWhenTheReplayEnds() {
        let store = playground()
        let view = viewer(store)
        view.replay([.down(Point2(x: 200, y: 200)), .look])
        _ = play(view)
        for _ in 0..<40 { view.advance(by: frame) }
        #expect(!output("interaction", "down", in: view, store).boolValue)
        #expect(view.agentFingerPositions.isEmpty && !view.showsAgentBadge)
    }

    @Test func twoFingersAreTwoTouchesAndBothAreShown() throws {
        let steps: [ViewerSnapshot.Step] = [
            .pinch(at: Point2(x: 195, y: 400), scale: 2, rotation: 0, seconds: 0.2, pan: Point2(x: 0, y: 60)), .look,
        ]
        let all = frames(ViewerSnapshot.beats(for: steps))
        // They land 88 points apart, either side of the middle, each with a number.
        let down = try #require(all.first { !$0.events.isEmpty })
        #expect(down.events == [.touchBegan(id: 0, Point2(x: 151, y: 400)), .touchBegan(id: 1, Point2(x: 239, y: 400))])
        #expect(down.fingers.count == 2)
        // And lift twice as far apart, 60 points further down.
        let up = try #require(all.last { !$0.events.isEmpty })
        #expect(up.events == [.touchEnded(id: 0, Point2(x: 107, y: 460)), .touchEnded(id: 1, Point2(x: 283, y: 460))])
        #expect(all.allSatisfy { $0.fingers.count == 2 || $0.fingers.isEmpty })

        // A second finger beside the first stays where it is while the first moves.
        let held = frames(ViewerSnapshot.beats(for: [
            .down(Point2(x: 10, y: 10)), .down(Point2(x: 90, y: 10), finger: 2), .move(to: Point2(x: 10, y: 80), seconds: 0.1),
        ]))
        #expect(held.last?.fingers == [Point2(x: 10, y: 80), Point2(x: 90, y: 10)])
        #expect(held.contains { $0.events == [.touchBegan(id: 1, Point2(x: 90, y: 10))] })
    }

    @Test func aReplayedPinchMovesThePictureAndLeavesNoFingerOnIt() {
        let example = SampleDocuments.pinchZoom()
        let store = DocumentStore(package: DocumentPackage(document: example.document))
        let view = viewer(store)
        func on(_ node: NodeID, _ port: String) -> Bool {
            view.runtime.outputValue(PortRef(node: node, port: port))?.boolValue ?? false
        }
        // Stopped short of the lift: two fingers are down when the steps run out.
        view.replay([.down(Point2(x: 150, y: 400)), .down(Point2(x: 250, y: 400), finger: 2),
                     .move(to: Point2(x: 330, y: 400), seconds: 0.3, finger: 2), .look])
        var pinched = false, most = 0
        while view.isReplaying {
            view.advance(by: frame)
            pinched = pinched || on(example.pinch, "pinching")
            most = max(most, view.agentFingerPositions.count)
        }
        #expect(pinched && most == 2)
        // The replay lifts both itself, and the picture springs back.
        for _ in 0..<120 { view.advance(by: frame) }
        #expect(!on(example.pinch, "pinching") && !on(example.pan, "panning"))
        #expect(abs((view.runtime.resolved.find(example.photo)?.scale ?? 0) - 1) < 0.01)
        #expect(view.agentFingerPositions.isEmpty)
    }

    @Test func aHoverLeftByTheStepsEndsWithTheReplay() {
        let store = playground()
        let view = viewer(store)
        view.replay([.hover(Point2(x: 200, y: 200)), .wait(0.2)])
        for _ in 0..<8 { view.advance(by: frame) }
        #expect(output("hover", "hovering", in: view, store).boolValue)
        _ = play(view)
        for _ in 0..<10 { view.advance(by: frame) }
        #expect(!output("hover", "hovering", in: view, store).boolValue)
    }

    @Test func aReplayDoesNotStartUnderThePersonsFinger() {
        let store = playground()
        let view = viewer(store)
        view.mouseDown(with: mouse(.leftMouseDown, at: Point2(x: 200, y: 200), in: view))
        view.advance(by: frame)
        view.advance(by: frame)
        #expect(output("interaction", "down", in: view, store).boolValue)
        view.replay([.tap(Point2(x: 5, y: 5))])
        #expect(!view.isReplaying)
        view.advance(by: frame)
        #expect(output("interaction", "down", in: view, store).boolValue)
    }

    @Test func thePersonsTapAfterCancellingAReplayStillCounts() {
        let store = playground()
        let view = viewer(store)
        view.replay([.down(Point2(x: 200, y: 250)), .wait(2)])
        for _ in 0..<40 { view.advance(by: frame) }
        #expect(output("interaction", "down", in: view, store).boolValue)
        let point = Point2(x: 150, y: 150)
        view.mouseDown(with: mouse(.leftMouseDown, at: point, in: view))
        view.advance(by: frame)
        view.advance(by: frame)
        view.mouseUp(with: mouse(.leftMouseUp, at: point, in: view))
        for _ in 0..<5 { view.advance(by: frame) }
        #expect(output("counter", "value", in: view, store).numberValue == 1)
        #expect(!output("interaction", "down", in: view, store).boolValue)
    }

    @Test func aReplayedTapCountsOnceAndTwoCountTwice() {
        let store = playground()
        let view = viewer(store)
        // Steps that stop before the lift: the replay lifts the finger itself when it ends.
        view.replay([.tap(Point2(x: 200, y: 200))])
        _ = play(view)
        view.advance(by: frame)
        #expect(output("counter", "value", in: view, store).numberValue == 1)
        #expect(!output("interaction", "down", in: view, store).boolValue)
        // Each replay starts the prototype over, like the run it shows.
        view.replay([.tap(Point2(x: 200, y: 200)), .tap(Point2(x: 200, y: 200)), .wait(0.2)])
        _ = play(view)
        #expect(output("counter", "value", in: view, store).numberValue == 2)
    }

    @Test func theReplayEndsWhereTheHiddenRunDid() {
        // What the person is left looking at is what the assistant's last picture showed.
        let store = cardStore()
        let view = viewer(store)
        let steps: [ViewerSnapshot.Step] = [.tap(Point2(x: 200, y: 400)), .wait(1.5), .look]
        view.replay(steps)
        _ = play(view)
        for _ in 0..<60 { view.advance(by: frame) }
        let hidden = ViewerSnapshot.bitmaps(of: store.runtimeDocument, steps: steps).first
        let shown = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        view.layer?.render(in: NSGraphicsContext(bitmapImageRep: shown)!.cgContext)
        #expect(hidden?.representation(using: .png, properties: [:]) == shown.representation(using: .png, properties: [:]))
    }

    @Test func theReplayIsInStepWithTheHiddenRunEvenMidAnimation() throws {
        // Stopped a fifth of a second into the card's spring, after a delay longer than is
        // shown: every value must be the one the assistant's picture was drawn from.
        let steps: [ViewerSnapshot.Step] = [
            .wait(4), .tap(Point2(x: 200, y: 400)), .wait(0.2), .look,
        ]
        let hidden = viewer(cardStore())
        hidden.advance(by: frame)
        for beat in ViewerSnapshot.beats(for: steps) {
            guard case let .frame(step) = beat else { continue }
            for event in step.events { hidden.runtime.send(event) }
            hidden.advance(by: frame)
        }
        let shown = viewer(cardStore())
        shown.replay(steps)
        // An uneven display: the prototype's own time must not care.
        var odd = false
        while shown.isReplaying {
            shown.advance(by: odd ? 1.0 / 50 : 1.0 / 144)
            odd.toggle()
        }
        func card(_ view: ViewerView) -> ResolvedLayer? { view.runtime.resolved.children.first { $0.name == "Card" } }
        let height = try #require(card(shown)?.size.height)
        #expect(height > 201 && height < 559)
        #expect(height == card(hidden)?.size.height)
        #expect(card(shown)?.position == card(hidden)?.position)
    }

    @Test func aDoubleTapIsADoubleTapInTheReplayToo() {
        let store = playground()
        _ = AssistantToolbox(store: store).call("edit_document", input: ["operations": [
            ["op": "add_patch", "kind": "counter", "ref": "doubles", "name": "Doubles"],
            ["op": "connect", "from": "Interaction", "output": "doubleTap", "to": "doubles", "input": "increase"],
        ]])
        let view = viewer(store)
        // Two taps a finger's travel apart: the travel must not come between them.
        view.replay([.tap(Point2(x: 120, y: 120)), .tap(Point2(x: 280, y: 280)), .wait(0.2), .look])
        _ = play(view)
        let doubles = store.document.graph.patches.first { $0.name == "Doubles" }!
        #expect(view.runtime.outputValue(PortRef(node: doubles.id, port: "value"))?.numberValue == 1)
    }

    @Test func aVeryLongRunIsNotReplayedForMinutes() {
        let view = viewer(DocumentStore())
        view.replay(Array(repeating: ViewerSnapshot.Step.tap(Point2(x: 10, y: 10)), count: 1500))
        #expect(Double(play(view)) * frame <= 61)
        // Nor is a list of a great many steps laid out whole.
        let many = Array(repeating: ViewerSnapshot.Step.tap(Point2(x: 10, y: 10)), count: 300_000)
        #expect(ViewerSnapshot.beats(for: many, paced: true).count <= ViewerSnapshot.longestPacedRun + 1)
        for _ in 0..<40 { view.advance(by: frame) }
        #expect(view.agentFingerPositions.isEmpty && !view.showsAgentBadge)
    }

    @Test func aReplayRunsTheDocumentAsItIsNow() throws {
        let store = playground()
        let view = viewer(store)
        // An edit the Viewer has not been handed yet, as when one tool call follows another at once.
        _ = AssistantToolbox(store: store).call("edit_document", input: ["operations": [
            ["op": "set_properties", "view": "Button", "properties": ["y": 600]],
        ]])
        view.replay([.wait(0.1)])
        _ = play(view)
        #expect(view.runtime.resolved.children.first { $0.name == "Button" }?.position.y == 600)
    }

    @Test func typingIsReplayedIntoTheField() {
        let store = playground()
        let view = viewer(store)
        view.replay([.tap(Point2(x: 150, y: 420)), .type("ada"), .deleteBackward, .wait(0.2), .look])
        _ = play(view)
        #expect(view.runtime.resolved.children.first { $0.name == "Field" }?.value(.text).textValue == "ad")
    }

    @Test func aSmallerViewerPutsTheFingerWhereTheScreenPointIs() {
        let store = playground()
        let screen = store.document.screen.value(.size).sizeValue
        let view = ViewerView(store: store, sendsRequests: false)
        view.fillsWindow = true
        view.frame = NSRect(x: 0, y: 0, width: screen.width / 2, height: screen.height / 2)
        view.layoutSubtreeIfNeeded()
        view.replay([.down(Point2(x: 200, y: 200)), .wait(0.5)])
        for _ in 0..<30 { view.advance(by: frame) }
        #expect(view.agentFingerPositions == [CGPoint(x: 100, y: screen.height / 2 - 100)])
        #expect(output("interaction", "down", in: view, store).boolValue)
    }

    @Test func restartingEndsTheReplay() {
        let store = playground()
        let view = viewer(store)
        view.replay([.down(Point2(x: 200, y: 200)), .wait(2)])
        for _ in 0..<40 { view.advance(by: frame) }
        store.restartPrototype()
        view.update(document: store.runtimeDocument, restartToken: store.restartToken)
        view.advance(by: frame)
        #expect(!view.isReplaying && view.agentFingerPositions.isEmpty && !view.showsAgentBadge)
        #expect(!output("interaction", "down", in: view, store).boolValue)
    }

    @Test func turningTheSettingOffShowsNothing() {
        let store = cardStore()
        var replayed = 0
        store.onReplay = { _, _ in replayed += 1 }
        UserDefaults.standard.set(false, forKey: ViewerView.showsAssistantTouchesKey)
        defer { UserDefaults.standard.removeObject(forKey: ViewerView.showsAssistantTouchesKey) }
        store.replayInViewer([.tap(.zero)])
        #expect(replayed == 0)
        UserDefaults.standard.removeObject(forKey: ViewerView.showsAssistantTouchesKey)
        store.replayInViewer([.tap(.zero)])
        #expect(replayed == 1)
    }
}
