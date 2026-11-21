import AppKit
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

@MainActor
@Suite struct TwoFingerTests {
    @Test func theSecondFingerIsTheMirrorImageOfTheFirst() {
        #expect(TwoFingerGesture.mirror(of: CGPoint(x: 30, y: 80), through: CGPoint(x: 100, y: 100)) == CGPoint(x: 170, y: 120))
    }

    private func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: NSPoint(x: x, y: y), modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    /// The pinch example at actual size: view points are screen points, y flipped.
    private func viewer() -> (ViewerView, SampleDocuments.PinchZoom) {
        let example = SampleDocuments.pinchZoom()
        let view = ViewerView(store: DocumentStore(package: DocumentPackage(document: example.document)))
        view.fillsWindow = true
        view.frame = NSRect(x: 0, y: 0, width: 390, height: 844)
        view.layoutSubtreeIfNeeded()
        view.advance(by: 1.0 / 60.0)
        return (view, example)
    }

    private func run(_ view: ViewerView, _ seconds: Double) {
        for _ in 0..<Int(seconds * 60) { view.advance(by: 1.0 / 60.0) }
    }

    @Test func optionAddsAMirroredFingerAndDraggingPinches() {
        let (view, example) = viewer()
        func out(_ port: String) -> Value { view.runtime.outputValue(PortRef(node: example.pinch, port: port))! }

        // No Option: one finger, no twin.
        view.mouseMoved(with: event(.mouseMoved, 245, 422))
        #expect(view.secondFingerPosition == nil)

        // The twin is the pointer mirrored through the middle of the screen (195, 422).
        view.mouseMoved(with: event(.mouseMoved, 245, 422, .option))
        #expect(view.secondFingerPosition == CGPoint(x: 145, y: 422))

        view.mouseDown(with: event(.leftMouseDown, 245, 422, .option))
        view.mouseDragged(with: event(.leftMouseDragged, 295, 422, .option))
        run(view, 0.1)
        // Two real fingers, 100 points apart, now 200: the pinch counts from where it
        // began, eight points of spread on.
        #expect(out("pinching").boolValue)
        #expect(abs(out("scale").numberValue - 200.0 / 108) < 0.001)
        #expect(view.secondFingerPosition == CGPoint(x: 95, y: 422))
        // They spread around the middle, so nothing was dragged along.
        #expect(!view.runtime.bool(example.pan, "panning"))

        // Up the screen in the view is up on the screen: a quarter turn counter-clockwise.
        view.mouseDragged(with: event(.leftMouseDragged, 195, 472, .option))
        run(view, 0.1)
        #expect(abs(view.runtime.number(example.rotation, "rotation") + 85) < 0.001)
        #expect(view.runtime.bool(example.rotation, "rotating"))

        // Letting go of Option mid-pinch does not drop the fingers; the mouse button does.
        view.mouseDragged(with: event(.leftMouseDragged, 195, 522))
        run(view, 0.1)
        #expect(out("pinching").boolValue)
        view.mouseUp(with: event(.leftMouseUp, 195, 522))
        run(view, 0.1)
        #expect(!out("pinching").boolValue)
        #expect(view.secondFingerPosition == nil)
    }

    @Test func shiftMovesBothFingersTogether() {
        let (view, example) = viewer()
        view.mouseMoved(with: event(.mouseMoved, 245, 422, .option))
        // 100 points down the view: the pivot and the twin come along.
        view.mouseMoved(with: event(.mouseMoved, 245, 322, [.option, .shift]))
        #expect(view.secondFingerPosition == CGPoint(x: 145, y: 322))

        // The fingers now meet below the picture (screen y 522 is inside it; 722 is not).
        view.mouseMoved(with: event(.mouseMoved, 245, 122, [.option, .shift]))
        view.mouseDown(with: event(.leftMouseDown, 245, 122, .option))
        view.mouseDragged(with: event(.leftMouseDragged, 345, 122, .option))
        run(view, 0.1)
        #expect(view.runtime.outputValue(PortRef(node: example.pinch, port: "pinching"))?.boolValue == false)
        view.mouseUp(with: event(.leftMouseUp, 345, 122, .option))
    }

    /// Shift while the fingers are down carries the pivot along: two fingers side by side.
    @Test func shiftWhileDraggingPansWithBothFingers() {
        let (view, example) = viewer()
        view.mouseMoved(with: event(.mouseMoved, 245, 422, .option))
        view.mouseDown(with: event(.leftMouseDown, 245, 422, .option))
        view.advance(by: 1.0 / 60.0)
        view.mouseDragged(with: event(.leftMouseDragged, 285, 392, [.option, .shift]))
        run(view, 0.1)
        // The twin went the same way, so they are as far apart as they were.
        #expect(view.secondFingerPosition == CGPoint(x: 185, y: 392))
        #expect(view.runtime.bool(example.pan, "panning"))
        #expect(!view.runtime.bool(example.pinch, "pinching"))
        // 40 right and 30 down the screen, less the ten points it took to begin.
        let travel = view.runtime.outputValue(PortRef(node: example.pan, port: "translation"))!.pointValue
        #expect(abs(travel.x - 32) < 0.001 && abs(travel.y - 24) < 0.001)
        // Without Shift the pointer spreads them again, around where the pivot now is.
        view.mouseDragged(with: event(.leftMouseDragged, 335, 392, .option))
        run(view, 0.1)
        #expect(view.secondFingerPosition == CGPoint(x: 135, y: 392))
        #expect(view.runtime.bool(example.pinch, "pinching"))
        view.mouseUp(with: event(.leftMouseUp, 335, 392, .option))
        run(view, 0.1)
        #expect(!view.runtime.bool(example.pan, "panning"))
    }

    @Test func aPlainClickIsStillOneFinger() {
        let example = SampleDocuments.card()
        let view = ViewerView(store: DocumentStore(package: DocumentPackage(document: example.document)))
        view.fillsWindow = true
        view.frame = NSRect(x: 0, y: 0, width: 390, height: 844)
        view.layoutSubtreeIfNeeded()
        view.advance(by: 1.0 / 60.0)
        view.mouseDown(with: event(.leftMouseDown, 195, 444))
        view.advance(by: 1.0 / 60.0)
        view.mouseUp(with: event(.leftMouseUp, 195, 444))
        run(view, 0.2)
        #expect(view.runtime.outputValue(PortRef(node: example.expanded, port: "on"))?.boolValue == true)
    }
}

private extension Runtime {
    func bool(_ node: NodeID, _ port: String) -> Bool { outputValue(PortRef(node: node, port: port))?.boolValue ?? false }
    func number(_ node: NodeID, _ port: String) -> Double { outputValue(PortRef(node: node, port: port))?.numberValue ?? 0 }
}
