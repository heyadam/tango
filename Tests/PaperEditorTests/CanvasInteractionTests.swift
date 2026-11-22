import AppKit
import Foundation
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

/// The Canvas as a person uses it: presses, drags and keys sent to a real `CanvasView` in
/// a window that is never shown, and the document read back.
@MainActor
@Suite struct CanvasInteractionTests {
    @MainActor final class Bench {
        let store: DocumentStore
        let canvas: CanvasView
        let window: NSWindow
        var time: TimeInterval = 100

        let undo = UndoManager()

        /// One thing a person does, as one undo step.
        func step(_ body: () -> Void) {
            undo.beginUndoGrouping()
            body()
            undo.endUndoGrouping()
        }

        /// With `undoes`, every edit must be made inside `step`.
        init(_ document: Document, undoes: Bool = false) {
            store = DocumentStore(package: DocumentPackage(document: document))
            undo.groupsByEvent = false
            if undoes { store.undoManager = undo }
            canvas = CanvasView(store: store)
            window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
            canvas.frame = CGRect(x: 0, y: 0, width: 1200, height: 700)
            window.contentView = canvas
            canvas.layoutSubtreeIfNeeded()
            sync()
        }

        /// What SwiftUI does after every change.
        func sync() {
            canvas.update(document: store.document, selection: store.selectedLayers, selectedNodes: store.selectedNodes, tool: store.tool)
        }

        func event(_ type: NSEvent.EventType, at point: CGPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            time += 0.05
            return NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: flags, timestamp: time, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
            )!
        }

        /// A board point, as the window has it.
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { canvas.windowPoint(forBoard: CGPoint(x: x, y: y)) }

        func press(_ point: CGPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
            canvas.mouseDown(with: event(.leftMouseDown, at: point, clicks: clicks, flags: flags))
            sync()
        }

        func drag(to point: CGPoint, steps: Int = 6, from: CGPoint, flags: NSEvent.ModifierFlags = []) {
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let here = CGPoint(x: from.x + (point.x - from.x) * t, y: from.y + (point.y - from.y) * t)
                canvas.mouseDragged(with: event(.leftMouseDragged, at: here, flags: flags))
                sync()
            }
        }

        func release(_ point: CGPoint) {
            canvas.mouseUp(with: event(.leftMouseUp, at: point))
            sync()
        }

        func click(_ point: CGPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
            for count in 1...clicks {
                press(point, clicks: count, flags: flags)
                release(point)
            }
        }

        func key(_ code: UInt16, _ characters: String = "", flags: NSEvent.ModifierFlags = []) {
            time += 0.05
            canvas.keyDown(with: NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: time, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            )!)
            sync()
        }
    }

    static func view(_ name: String, _ x: Double, _ y: Double, _ width: Double = 100, _ height: Double = 60, children: [Layer] = []) -> Layer {
        Layer(name: name, kind: .view, properties: [
            .position: .point(Point2(x: x, y: y)), .size: .size(Size2(width: width, height: height)), .fill: .color(Layer.viewFill),
        ], children: children)
    }

    static func root(_ children: [Layer]) -> Document {
        Document(screen: Layer(name: "Screen", kind: .screen, properties: [.size: .size(Size2(width: 400, height: 800))], children: children))
    }

    /// Two screens, 400 wide: the second starts at 400 + the gap on the board.
    static func twoScreens() -> (Document, a: Layer, b: Layer, button: Layer) {
        let button = view("Button", 100, 100)
        var a = Layer.newPage(name: "A")
        a.children = [button]
        let b = Layer.newPage(name: "B")
        return (root([a, b]), a, b, button)
    }

    func position(_ bench: Bench, _ id: LayerID) -> Point2 { bench.store.document.layer(id)!.value(.position).pointValue }

    // MARK: Selecting and moving

    @Test func aClickSelectsAndADragMovesByWhatThePointerMoved() {
        let card = Self.view("Card", 40, 300)
        let bench = Bench(Self.root([card]))
        bench.press(bench.at(60, 320))
        #expect(bench.store.selectedLayers == [card.id])
        // Command keeps it from lining up with anything.
        bench.drag(to: bench.at(160, 370), from: bench.at(60, 320), flags: .command)
        bench.release(bench.at(160, 370))
        #expect(position(bench, card.id) == Point2(x: 140, y: 350))
        bench.click(bench.at(380, 780))
        #expect(bench.store.selectedLayers.isEmpty)
    }

    @Test func aDraggedViewLinesUpWithItsNeighbor() {
        let still = Self.view("Still", 200, 100)
        let moved = Self.view("Moved", 40, 400)
        let bench = Bench(Self.root([still, moved]))
        bench.press(bench.at(50, 410))
        // Three points short of the other's left edge: it is taken there.
        bench.drag(to: bench.at(207, 510), from: bench.at(50, 410))
        bench.release(bench.at(207, 510))
        #expect(position(bench, moved.id).x == 200)
    }

    @Test func aViewOnTheSecondScreenIsMovedInThatScreensCoordinates() {
        var (document, _, b, _) = Self.twoScreens()
        let badge = Self.view("Badge", 20, 30)
        document.screen.update(b.id) { $0.children = [badge] }
        let bench = Bench(document)
        let left = 400 + Board.gap
        bench.press(bench.at(left + 40, 50))
        #expect(bench.store.selectedLayers == [badge.id])
        bench.drag(to: bench.at(left + 90, 150), from: bench.at(left + 40, 50), flags: .command)
        bench.release(bench.at(left + 90, 150))
        #expect(position(bench, badge.id) == Point2(x: 70, y: 130))
    }

    @Test func aViewLetGoOverAnotherScreenMovesToIt() {
        let (document, a, b, button) = Self.twoScreens()
        let bench = Bench(document)
        let left = 400 + Board.gap
        bench.press(bench.at(110, 110))
        bench.drag(to: bench.at(left + 210, 310), from: bench.at(110, 110), flags: .command)
        bench.release(bench.at(left + 210, 310))
        #expect(bench.store.document.layer(a.id)?.children.isEmpty == true)
        #expect(bench.store.document.layer(b.id)?.children.map(\.id) == [button.id])
        #expect(position(bench, button.id) == Point2(x: 200, y: 300))
    }

    @Test func aScreenIsNotDraggedOutOfPlaceAndItsTitleReordersIt() {
        let (document, a, b, _) = Self.twoScreens()
        let bench = Bench(document)
        // Empty room on a screen: a click selects the screen, a drag there moves nothing.
        bench.click(bench.at(300, 600))
        #expect(bench.store.selectedLayers == [a.id])
        bench.press(bench.at(300, 600))
        bench.drag(to: bench.at(350, 700), from: bench.at(300, 600))
        bench.release(bench.at(350, 700))
        #expect(bench.store.document.layer(a.id)?.properties[.position] == nil)
        // Its title, a little above it, dragged past the other.
        let title = CGPoint(x: bench.at(20, 0).x, y: bench.at(20, 0).y + 12)
        bench.press(title)
        #expect(bench.store.selectedLayers == [a.id])
        let far = CGPoint(x: bench.at(400 + Board.gap + 200, 0).x, y: title.y)
        bench.drag(to: far, from: title)
        bench.release(far)
        #expect(bench.store.screens.map(\.id) == [b.id, a.id])
    }

    @Test func aDragIsOneUndoStepEvenAcrossScreens() {
        let (document, _, _, _) = Self.twoScreens()
        let bench = Bench(document, undoes: true)
        let before = bench.store.document
        let left = 400 + Board.gap
        bench.step {
            bench.press(bench.at(110, 110))
            bench.drag(to: bench.at(left + 210, 310), from: bench.at(110, 110), flags: .command)
            bench.release(bench.at(left + 210, 310))
        }
        #expect(bench.store.document != before)
        bench.undo.undo()
        #expect(bench.store.document == before)
        #expect(!bench.undo.canUndo)
    }

    @Test func anEmptyContainerCanBeSteppedIntoAndDrawnIn() {
        var stack = Layer.new(.stack, name: "List")
        stack.set(.position, .point(Point2(x: 50, y: 100)))
        stack.set(.size, .size(Size2(width: 200, height: 400)))
        let bench = Bench(Self.root([stack]))
        bench.click(bench.at(100, 200), clicks: 2)
        #expect(bench.store.openView == stack.id)
        bench.store.tool = .view
        bench.sync()
        bench.press(bench.at(80, 150))
        bench.drag(to: bench.at(160, 200), from: bench.at(80, 150))
        bench.release(bench.at(160, 200))
        #expect(bench.store.document.layer(stack.id)?.children.count == 1)
    }

    // MARK: Levels

    @Test func aClickReachesTheOpenLevelAndADoubleClickStepsIn() {
        let label = Self.view("Label", 10, 10, 40, 20)
        let card = Self.view("Card", 50, 200, 200, 120, children: [label])
        let bench = Bench(Self.root([card]))
        bench.click(bench.at(70, 215))
        #expect(bench.store.selectedLayers == [card.id])
        bench.click(bench.at(70, 215), clicks: 2)
        #expect(bench.store.openView == card.id)
        bench.click(bench.at(70, 215))
        #expect(bench.store.selectedLayers == [label.id])
        // Escape: out of the selection, then out of the view.
        bench.key(53)
        #expect(bench.store.selectedLayers.isEmpty && bench.store.openView == card.id)
        bench.key(53)
        #expect(bench.store.openView == nil)
        // Command reaches the deepest from anywhere.
        bench.click(bench.at(70, 215), flags: .command)
        #expect(bench.store.selectedLayers == [label.id])
    }

    @Test func onAScreenAClickReachesWhatIsDirectlyOnIt() {
        let (document, _, _, button) = Self.twoScreens()
        let bench = Bench(document)
        bench.click(bench.at(110, 110))
        #expect(bench.store.selectedLayers == [button.id])
    }

    @Test func aMarqueeSelectsWhatItTouchesInTheLevel() {
        let one = Self.view("One", 20, 100)
        let two = Self.view("Two", 20, 200)
        let three = Self.view("Three", 20, 600)
        let bench = Bench(Self.root([one, two, three]))
        bench.press(bench.at(300, 80))
        bench.drag(to: bench.at(60, 230), from: bench.at(300, 80))
        bench.release(bench.at(60, 230))
        #expect(bench.store.selectedLayers == [one.id, two.id])
    }

    // MARK: Stacks

    @Test func aStackChildIsReorderedAndNeverGivenAPosition() {
        let rows = (0..<3).map { Self.view("Row \($0)", 0, 0, 200, 60) }
        var stack = Layer.new(.stack, name: "List")
        stack.set(.position, .point(Point2(x: 50, y: 100)))
        stack.set(.size, .size(Size2(width: 200, height: 400)))
        stack.children = rows
        let bench = Bench(Self.root([stack]))
        bench.click(bench.at(60, 110), clicks: 2)
        #expect(bench.store.openView == stack.id)
        // The first row, dragged down past the middle of the third.
        bench.press(bench.at(100, 120))
        #expect(bench.store.selectedLayers == [rows[0].id])
        bench.drag(to: bench.at(100, 262), from: bench.at(100, 120))
        bench.release(bench.at(100, 262))
        let after = bench.store.document.layer(stack.id)!.children
        #expect(after.map(\.name) == ["Row 1", "Row 2", "Row 0"])
        #expect(after.allSatisfy { $0.value(.position).pointValue == .zero })
        // Arrow keys leave it where the stack puts it.
        bench.key(124)
        #expect(bench.store.document.layer(rows[0].id)?.value(.position).pointValue == .zero)
    }

    @Test func aSmallRowDraggedOverALargeOneChangesPlacesOnce() {
        var stack = Layer.new(.stack, name: "List")
        stack.set(.position, .point(Point2(x: 50, y: 100)))
        stack.set(.size, .size(Size2(width: 200, height: 400)))
        stack.children = [Self.view("Small", 0, 0, 200, 40), Self.view("Large", 0, 0, 200, 160)]
        let bench = Bench(Self.root([stack]))
        bench.click(bench.at(60, 110), clicks: 2)
        bench.press(bench.at(100, 120))
        var orders: [[String]] = []
        var last = bench.at(100, 120)
        // Slowly down through the large row, noting the order at every step.
        for y in stride(from: 125.0, through: 290.0, by: 5.0) {
            bench.drag(to: bench.at(100, y), steps: 1, from: last)
            last = bench.at(100, y)
            let order = bench.store.document.layer(stack.id)!.children.map(\.name)
            if orders.last != order { orders.append(order) }
        }
        bench.release(last)
        #expect(orders == [["Small", "Large"], ["Large", "Small"]])
    }

    // MARK: Resizing and drawing

    @Test func aHandleResizesFromItsCorner() {
        let card = Self.view("Card", 100, 100, 100, 60)
        let bench = Bench(Self.root([card]))
        bench.click(bench.at(150, 130))
        bench.press(bench.at(200, 160))
        bench.drag(to: bench.at(240, 200), from: bench.at(200, 160))
        bench.release(bench.at(240, 200))
        let layer = bench.store.document.layer(card.id)!
        #expect(layer.value(.size).sizeValue == Size2(width: 140, height: 100))
        #expect(layer.value(.position).pointValue == Point2(x: 100, y: 100))
    }

    @Test func aNewViewGoesIntoTheOpenViewWhereItWasDrawn() {
        let child = Self.view("Child", 0, 0, 10, 10)
        let card = Self.view("Card", 50, 200, 300, 300, children: [child])
        let bench = Bench(Self.root([card]))
        bench.click(bench.at(200, 400), clicks: 2)
        #expect(bench.store.openView == card.id)
        bench.store.tool = .view
        bench.sync()
        bench.press(bench.at(100, 260))
        bench.drag(to: bench.at(180, 320), from: bench.at(100, 260))
        bench.release(bench.at(180, 320))
        let made = bench.store.document.layer(card.id)!.children.last!
        #expect(made.id != child.id)
        #expect(made.value(.position).pointValue == Point2(x: 50, y: 60))
        #expect(made.value(.size).sizeValue == Size2(width: 80, height: 60))
        #expect(bench.store.tool == .select)
    }

    @Test func aNewViewOnTheSecondScreenGoesIntoThatScreen() {
        let (document, _, b, _) = Self.twoScreens()
        let bench = Bench(document)
        let left = 400 + Board.gap
        bench.store.tool = .ellipse
        bench.sync()
        bench.press(bench.at(left + 30, 40))
        bench.drag(to: bench.at(left + 90, 100), from: bench.at(left + 30, 40))
        bench.release(bench.at(left + 90, 100))
        let made = bench.store.document.layer(b.id)!.children
        #expect(made.count == 1 && made[0].kind == .ellipse)
        #expect(made[0].value(.position).pointValue == Point2(x: 30, y: 40))
    }

    // MARK: Text

    @Test func aDoubleClickOnATextRetypesItInPlace() {
        let label = Layer(name: "Label", kind: .text, properties: [
            .position: .point(Point2(x: 40, y: 100)), .size: .size(Size2(width: 200, height: 30)), .text: .text("Hello"),
        ])
        let bench = Bench(Self.root([label]))
        bench.click(bench.at(60, 110), clicks: 2)
        let field = bench.canvas.textField
        #expect(field?.stringValue == "Hello")
        field?.stringValue = "Goodbye"
        bench.canvas.endTextEditing(commit: true)
        bench.sync()
        #expect(bench.store.document.layer(label.id)?.value(.text) == .text("Goodbye"))
        #expect(bench.canvas.textField == nil)
        // Cancelled, nothing changes.
        bench.click(bench.at(60, 110), clicks: 2)
        bench.canvas.textField?.stringValue = "Never"
        bench.canvas.endTextEditing(commit: false)
        #expect(bench.store.document.layer(label.id)?.value(.text) == .text("Goodbye"))
    }

    // MARK: Flows

    @Test func theHandleOfASelectedViewDrawsAFlow() throws {
        let (document, _, b, button) = Self.twoScreens()
        let bench = Bench(document)
        bench.click(bench.at(110, 110))
        let handle = try #require(bench.canvas.flowHandleWindowPoint)
        bench.press(handle)
        let left = 400 + Board.gap
        bench.drag(to: bench.at(left + 100, 300), from: handle)
        #expect(bench.canvas.flowBeingDrawn?.from == button.id)

        // Over the other screen it offers every style; over its own, the way back; over
        // empty room, a new screen.
        let there = bench.canvas.flowChoices(from: button.id, at: CGPoint(x: left + 100, y: 300))
        #expect(there.map(\.title) == ["Push", "Modal", "Fade", "Instant", "Morph"])
        #expect(bench.canvas.flowChoices(from: button.id, at: CGPoint(x: 300, y: 600)).map(\.title) == ["Go Back"])
        let nowhere = bench.canvas.flowChoices(from: button.id, at: CGPoint(x: left + 100, y: 2000))
        #expect(nowhere.first?.title == "Push to a New Screen")

        there[1].run()
        bench.sync()
        let flow = try #require(bench.store.flows.first)
        #expect(flow.source == button.id && flow.target == b.id && flow.style == .modal)

        nowhere[0].run()
        bench.sync()
        #expect(bench.store.screens.count == 3)
        #expect(bench.store.flows.contains { $0.target == bench.store.screens[2].id })
    }

    @Test func anArrowIsSelectedAsItsPatchAndDeletedWithIt() throws {
        let (document, _, b, button) = Self.twoScreens()
        let bench = Bench(document)
        let flow = try #require(bench.store.addFlow(from: button.id, to: b.id))
        bench.store.selectedNodes = []
        bench.sync()
        // Halfway between the button's right edge and the second screen.
        bench.click(bench.at((200 + 400 + Board.gap) / 2, 130))
        #expect(bench.store.selectedNodes == [flow])
        bench.key(51)
        #expect(bench.store.flows.isEmpty)
        #expect(bench.store.document.layer(button.id) != nil)
    }

    @Test func inADocumentWithoutScreensTheFirstFlowMakesThem() throws {
        let card = Self.view("Card", 40, 300)
        let bench = Bench(Self.root([card]))
        bench.click(bench.at(60, 320))
        #expect(bench.canvas.flowHandleWindowPoint != nil)
        // On its own (only) screen there is nothing to go back to.
        #expect(bench.canvas.flowChoices(from: card.id, at: CGPoint(x: 200, y: 600)).isEmpty)
        let choices = bench.canvas.flowChoices(from: card.id, at: CGPoint(x: 900, y: 300))
        try #require(!choices.isEmpty)
        choices[0].run()
        bench.sync()
        #expect(bench.store.screens.count == 2)
        #expect(bench.store.screen(holding: card.id)?.id == bench.store.screens[0].id)
        #expect(bench.store.flows.first?.target == bench.store.screens[1].id)
    }

    @Test func theAddScreenButtonAddsOne() {
        let bench = Bench(Self.root([Self.view("Card", 40, 300)]))
        // To the right of the last frame, halfway down.
        let right = bench.at(400, 400)
        bench.click(CGPoint(x: right.x + 60, y: right.y))
        #expect(bench.store.screens.count == 2)
    }

    // MARK: Polish

    @Test func thePointerIsToldWhatAPressWouldTakeHoldOf() throws {
        let (document, _, b, button) = Self.twoScreens()
        let bench = Bench(document)
        #expect(bench.canvas.spot(atWindow: bench.at(110, 110)) == .view(button.id, frame: 0))
        #expect(bench.canvas.spot(atWindow: bench.at(300, 600)) == .room(frame: 0))
        #expect(bench.canvas.spot(atWindow: bench.at(450, 300)) == .outside)
        let title = CGPoint(x: bench.at(20, 0).x, y: bench.at(20, 0).y + 12)
        #expect(bench.canvas.spot(atWindow: title) == .title(0))
        // The slot after the last screen adds one.
        let slot = CGPoint(x: bench.at(2 * 400 + Board.gap, 400).x + 50, y: bench.at(0, 400).y)
        #expect(bench.canvas.spot(atWindow: slot) == .addScreen)

        // Selected, the view has handles and a flow handle; each has its own cursor.
        bench.click(bench.at(110, 110))
        #expect(bench.canvas.spot(atWindow: bench.at(200, 160)) == .resize(.bottomRight, button.id))
        let handle = try #require(bench.canvas.flowHandleWindowPoint)
        #expect(bench.canvas.spot(atWindow: handle) == .flowHandle(button.id))
        #expect(bench.canvas.cursor(for: .flowHandle(button.id)) == NSCursor.pointingHand)
        #expect(bench.canvas.cursor(for: .title(0)) == NSCursor.pointingHand)
        #expect(bench.canvas.cursor(for: .room(frame: 0)) == NSCursor.arrow)
        #expect(bench.canvas.cursor(for: .resize(.bottomRight, button.id)) != NSCursor.arrow)
        // With a drawing tool, a crosshair over the screens.
        bench.store.tool = .view
        bench.sync()
        #expect(bench.canvas.cursor(for: .room(frame: 0)) == NSCursor.crosshair)
        bench.store.tool = .select
        bench.sync()

        // An arrow is picked by its label as well as its line.
        let flow = try #require(bench.store.addFlow(from: button.id, to: b.id))
        bench.store.selectedNodes = []
        bench.sync()
        // In the middle of the room between the screens, seven points off the line:
        // outside the line's own reach, inside the label on it.
        let gap = 400 + Board.gap / 2
        let label = CGPoint(x: bench.at(gap, 130).x, y: bench.at(gap, 130).y + 7)
        #expect(bench.canvas.spot(atWindow: label) == .arrow(flow))
    }

    func titles(_ menu: NSMenu?) -> [String] { (menu?.items ?? []).map { $0.isSeparatorItem ? "-" : $0.title } }

    func choose(_ title: String, in menu: NSMenu?, bench: Bench) {
        guard let item = menu?.items.first(where: { $0.title == title }) else {
            Issue.record("no item called \(title)")
            return
        }
        _ = item.target?.perform(item.action, with: item)
        bench.sync()
    }

    @Test func aRightClickOffersWhatFitsWhatIsUnderIt() throws {
        let (document, a, b, button) = Self.twoScreens()
        let bench = Bench(document)
        // On a view: where a tap leads, its order, and the usual.
        let onView = bench.canvas.menu(for: bench.event(.rightMouseDown, at: bench.at(110, 110)))
        #expect(bench.store.selectedLayers == [button.id])
        #expect(titles(onView) == ["Step Into Button", "On Tap, Go To", "Move To", "-", "Bring Forward", "Send Backward", "-", "Duplicate", "Delete"])
        let leads = try #require(onView?.items.first { $0.title == "On Tap, Go To" }?.submenu)
        #expect(titles(leads) == ["B", "-", "Back"])
        choose("B", in: leads, bench: bench)
        let flow = try #require(bench.store.flows.first)
        #expect(flow.source == button.id && flow.target == b.id)

        // On the arrow: its style, checked, and a way to delete it.
        bench.store.selectedNodes = []
        bench.sync()
        let onArrow = bench.canvas.menu(for: bench.event(.rightMouseDown, at: bench.at((200 + 400 + Board.gap) / 2, 130)))
        #expect(titles(onArrow) == ["Push", "Modal", "Fade", "Instant", "Morph", "-", "Delete Flow"])
        #expect(onArrow?.items.first { $0.state == .on }?.title == "Push")
        choose("Fade", in: onArrow, bench: bench)
        #expect(bench.store.flows.first?.style == .fade)
        choose("Delete Flow", in: onArrow, bench: bench)
        #expect(bench.store.flows.isEmpty)

        // On a screen: the second can be made the first.
        let left = 400 + Board.gap
        let onScreen = bench.canvas.menu(for: bench.event(.rightMouseDown, at: bench.at(left + 200, 600)))
        #expect(titles(onScreen) == ["Preview from Here", "-", "Rename", "Make First Screen", "Duplicate", "-", "Add Screen", "Delete Screen"])
        choose("Make First Screen", in: onScreen, bench: bench)
        #expect(bench.store.screens.map(\.id) == [b.id, a.id])
        // Off the screens: a new one.
        #expect(titles(bench.canvas.menu(for: bench.event(.rightMouseDown, at: bench.at(450, 300)))) == ["Add Screen"])
    }

    @Test func aDoubleClickOnATitleRenamesTheScreen() {
        let (document, a, _, _) = Self.twoScreens()
        let bench = Bench(document)
        let title = CGPoint(x: bench.at(20, 0).x, y: bench.at(20, 0).y + 12)
        bench.click(title, clicks: 2)
        #expect(bench.canvas.editedName == a.id)
        #expect(bench.canvas.textField?.stringValue == "A")
        bench.canvas.textField?.stringValue = "  Home "
        bench.canvas.endTextEditing(commit: true)
        bench.sync()
        #expect(bench.store.document.layer(a.id)?.name == "Home")
        // An empty name is not a name.
        bench.click(title, clicks: 2)
        bench.canvas.textField?.stringValue = "  "
        bench.canvas.endTextEditing(commit: true)
        #expect(bench.store.document.layer(a.id)?.name == "Home")
        #expect(bench.canvas.editedName == nil)
    }

    @Test func theSpaceBarPansAndCommandKeysZoom() {
        let (document, _, _, button) = Self.twoScreens()
        let bench = Bench(document)
        let before = bench.canvas.viewport
        // With the space bar held a drag moves the board and touches nothing on it.
        bench.key(49, " ")
        let from = bench.at(110, 110)
        bench.press(from)
        bench.drag(to: CGPoint(x: from.x + 80, y: from.y - 40), from: from)
        bench.release(CGPoint(x: from.x + 80, y: from.y - 40))
        bench.canvas.keyUp(with: NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: [], timestamp: 500, windowNumber: bench.window.windowNumber,
            context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49
        )!)
        #expect(abs(bench.canvas.viewport.offset.x - (before.offset.x + 80)) < 0.01)
        #expect(abs(bench.canvas.viewport.offset.y - (before.offset.y + 40)) < 0.01)
        #expect(bench.store.selectedLayers.isEmpty)
        #expect(position(bench, button.id) == Point2(x: 100, y: 100))

        bench.key(18, "1", flags: .command)
        #expect(bench.canvas.viewport.zoom == 1)
        bench.key(24, "=", flags: .command)
        #expect(bench.canvas.viewport.zoom == 1.25)
        bench.key(29, "0", flags: .command)
        #expect(bench.canvas.viewport.zoom == before.zoom)
        #expect(bench.canvas.viewport.offset == before.offset)
    }

    // MARK: Whole pixels

    @Test func theBoardStaysOnWholePixelsHoweverItIsMoved() {
        let (document, _, _, _) = Self.twoScreens()
        let bench = Bench(document)
        func onPixels(_ value: CGFloat) -> Bool { abs(value * 2 - (value * 2).rounded()) < 0.0001 }
        #expect(onPixels(bench.canvas.viewport.offset.x) && onPixels(bench.canvas.viewport.offset.y))
        // Panned by a part of a point, and zoomed to an awkward scale.
        bench.key(49, " ")
        let from = bench.at(110, 110)
        bench.press(from)
        bench.drag(to: CGPoint(x: from.x + 33.3, y: from.y - 12.7), from: from)
        bench.release(CGPoint(x: from.x + 33.3, y: from.y - 12.7))
        #expect(onPixels(bench.canvas.viewport.offset.x) && onPixels(bench.canvas.viewport.offset.y))
        bench.key(24, "=", flags: .command)
        #expect(onPixels(bench.canvas.viewport.offset.x) && onPixels(bench.canvas.viewport.offset.y))
    }

    @Test func aLabelIsAsWideAsItsTextAndSitsOnWholePixels() {
        let short = CanvasPill(), long = CanvasPill()
        short.set("Push", scale: 2, text: .white, fill: .black, border: nil)
        long.set("1024 × 768", scale: 2, text: .white, fill: .black, border: nil)
        short.center(at: CGPoint(x: 100.3, y: 50.7), scale: 2)
        long.center(at: CGPoint(x: 100.3, y: 50.7), scale: 2)
        #expect(long.frame.width > short.frame.width)
        for pill in [short, long] {
            #expect(pill.frame.height == CanvasPill.height)
            #expect(pill.frame.width.truncatingRemainder(dividingBy: 2) == 0)
            #expect((pill.frame.minX * 2).rounded() == pill.frame.minX * 2)
            #expect((pill.frame.minY * 2).rounded() == pill.frame.minY * 2)
            // Its middle is within half a pixel of where it was asked to be.
            #expect(abs(pill.frame.midX - 100.3) <= 0.25 && abs(pill.frame.midY - 50.7) <= 0.25)
        }
    }

    @Test func aSideIsTakenHoldOfAnywhereAlongItAndTheFlowPointSitsOnTheEdge() throws {
        let card = Self.view("Card", 100, 100, 200, 120)
        let bench = Bench(Self.root([card]))
        bench.click(bench.at(150, 130))
        // A third of the way along the top, and the bottom: no mark is drawn there, the side is.
        #expect(bench.canvas.spot(atWindow: bench.at(160, 100)) == .resize(.top, card.id))
        #expect(bench.canvas.spot(atWindow: bench.at(250, 220)) == .resize(.bottom, card.id))
        #expect(bench.canvas.spot(atWindow: bench.at(100, 190)) == .resize(.left, card.id))
        // The middle of the right side is where flows start; the rest of it resizes.
        let node = try #require(bench.canvas.flowHandleWindowPoint)
        #expect(abs(node.x - bench.at(300, 160).x) <= 0.5 && abs(node.y - bench.at(300, 160).y) <= 0.5)
        #expect(bench.canvas.spot(atWindow: node) == .flowHandle(card.id))
        #expect(bench.canvas.spot(atWindow: bench.at(300, 125)) == .resize(.right, card.id))
        // Dragging the bottom side changes the height alone.
        bench.press(bench.at(250, 220))
        bench.drag(to: bench.at(260, 260), from: bench.at(250, 220))
        bench.release(bench.at(260, 260))
        #expect(bench.store.document.layer(card.id)?.value(.size).sizeValue == Size2(width: 200, height: 160))
    }

    @Test func theScreenTheViewerShowsIsMarkedAndFollowsIt() throws {
        let (document, a, b, button) = Self.twoScreens()
        let bench = Bench(document)
        _ = try #require(bench.store.addFlow(from: button.id, to: b.id))
        // A Viewer of its own, as the app has: it is the store's runtime.
        let viewer = ViewerView(store: bench.store)
        viewer.advance(by: 1.0 / 60)
        #expect(bench.store.viewerScreen == a.id)
        viewer.runtime.send(.touchBegan(id: 0, Point2(x: 110, y: 110)))
        viewer.advance(by: 1.0 / 60)
        viewer.runtime.send(.touchEnded(id: 0, Point2(x: 110, y: 110)))
        for _ in 0..<120 { viewer.advance(by: 1.0 / 60) }
        #expect(bench.store.viewerScreen == b.id)
        bench.canvas.update(document: bench.store.document, selection: [], tool: .select, viewerScreen: bench.store.viewerScreen)
        #expect(bench.canvas.viewerScreen == b.id)
        let title = CGPoint(x: bench.at(400 + Board.gap + 20, 0).x, y: bench.at(0, 0).y + 12)
        #expect(bench.canvas.help(for: bench.canvas.spot(atWindow: title))?.contains("The Viewer is showing it") == true)
    }

    @Test func aWayBackIsDrawnToWhereItLeads() throws {
        // Three screens: A pushes B, A opens C with a sheet; B and C each have a Back.
        let (document, a, b, button) = Self.twoScreens()
        let bench = Bench(document)
        bench.store.addScreen(name: "C")
        let c = bench.store.screens[2].id
        let back = Self.view("Back", 10, 60, 80, 40), close = Self.view("Close", 10, 60, 80, 40)
        bench.store.apply("Setup") { document in
            document.screen.update(b.id) { $0.children = [back] }
            document.screen.update(c) { $0.children = [close] }
        }
        let open = Self.view("Open", 100, 300)
        bench.store.apply("Setup") { $0.screen.update(a.id) { $0.children.append(open) } }
        _ = try #require(bench.store.addFlow(from: button.id, to: b.id))
        _ = try #require(bench.store.addFlow(from: open.id, to: c, style: .modal))
        let toA = try #require(bench.store.addFlow(from: back.id, to: nil))
        let fromC = try #require(bench.store.addFlow(from: close.id, to: nil))
        bench.sync()
        let titles = bench.canvas.arrowTitles
        // Beside the screen it came from: a dashed arrow there, saying Back.
        #expect(titles.contains { $0.flow == toA && $0.title == "Back" && $0.dashed })
        // Two screens away: a short mark that names where it goes.
        #expect(titles.contains { $0.flow == fromC && $0.title == "Back to A" && $0.dashed })
        // Forward arrows say their style and are not dashed.
        #expect(titles.contains { $0.title == "Push" && !$0.dashed })
        #expect(titles.contains { $0.title == "Modal" && !$0.dashed })
        // The way back is picked by its arrow, between the screens.
        let gap = 400 + Board.gap / 2
        bench.click(bench.at(gap, 80))
        #expect(bench.store.selectedNodes == [toA])
    }
}
