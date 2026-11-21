import Foundation
import Testing
import PaperModel
@testable import PaperEngine

@Suite struct ComponentTests {
    typealias Builder = SampleDocuments.Builder

    func all(_ runtime: Runtime, named name: String) -> [ResolvedLayer] {
        var found: [ResolvedLayer] = []
        func walk(_ layer: ResolvedLayer) {
            if layer.name == name { found.append(layer) }
            layer.children.forEach(walk)
        }
        walk(runtime.resolved)
        return found
    }

    func inside(_ runtime: Runtime, _ instance: LayerID, _ name: String) -> ResolvedLayer? {
        var found: ResolvedLayer?
        func walk(_ layer: ResolvedLayer) {
            if layer.name == name, found == nil { found = layer }
            layer.children.forEach(walk)
        }
        runtime.resolved.find(instance).map(walk)
        return found
    }

    func tap(_ runtime: Runtime, _ x: Double, _ y: Double) {
        runtime.send(.touchDown(Point2(x: x, y: y)))
        runtime.tick(dt: 1 / 60)
        runtime.send(.touchUp(Point2(x: x, y: y)))
        runtime.advance(seconds: 1.5)
    }

    func started() -> (Runtime, SampleDocuments.Controls) {
        let example = SampleDocuments.controls()
        let runtime = Runtime(document: example.document)
        runtime.advance(seconds: 0.2)
        return (runtime, example)
    }

    func port(_ example: SampleDocuments.Controls, _ node: String, _ component: String, _ name: String) -> PortRef {
        PortRef(node: example.nodes[node]!, port: ComponentLibrary.iOS(component).output(named: name)!)
    }

    @Test func aComponentPublishesItsInputAndOutputPatches() {
        let toggle = ComponentLibrary.iOS("Toggle")
        #expect(toggle.inputs.map(\.name) == ["On", "Tint", "Dark"])
        #expect(toggle.inputs.map(\.type) == [.bool, .color, .bool])
        #expect(toggle.outputs.map(\.name) == ["On", "Changed"])
        #expect(toggle.outputs.map(\.type) == [.bool, .pulse])
        // Library ids are the same on every launch, so saved documents keep working.
        #expect(ComponentLibrary.iOS("Toggle") == toggle)
        #expect(Set(ComponentLibrary.iOS.map(\.id)).count == ComponentLibrary.iOS.count)
    }

    /// A screen with one library control on it at (20, 100), and the layer that uses it.
    func alone(_ name: String, inputs: [String: Value] = [:]) -> (Runtime, LayerID) {
        let made = placed(name, inputs: inputs)
        return (made.runtime, made.layer)
    }

    /// The same, with a way to read what the control reports.
    /// What covers the screen is put at its corner, on a screen of the size it was drawn for.
    func placed(_ name: String, inputs: [String: Value] = [:]) -> (runtime: Runtime, layer: LayerID, output: (String) -> Value?) {
        let definition = ComponentLibrary.iOS(name)
        let covers = definition.placement == .fill
        var b = SampleDocuments.Builder(screen: Layer(name: "Screen", kind: .screen, properties: covers ? [.size: definition.root.value(.size)] : [:]))
        let placed = b.place(definition, at: covers ? .zero : Point2(x: 20, y: 100), inputs: inputs, patchAt: Point2(x: 0, y: 0))
        let runtime = Runtime(document: b.document)
        runtime.advance(seconds: 0.2)
        return (runtime, placed.layer, { name in
            definition.output(named: name).flatMap { runtime.outputValue(PortRef(node: placed.node!, port: $0)) }
        })
    }

    @Test func aButtonHasFourStyles() {
        func look(_ style: String) -> (fill: ColorValue, title: String) {
            let (runtime, layer) = alone("Button", inputs: ["Style": .text(style)])
            return (inside(runtime, layer, "Background")!.value(.fill).colorValue, inside(runtime, layer, "Label")!.value(.textColor).colorValue.hex)
        }
        #expect(look("Filled").fill.hex == "#007AFF")
        #expect(look("Filled").title == "#FFFFFF")
        #expect(look("Gray").fill.hex == "#E3E3E8")
        #expect(look("Gray").title == "#007AFF")
        #expect(look("Plain").fill.alpha == 0)
        #expect(look("Plain").title == "#007AFF")
        // Tinted is the tint washed out over the surface: light, and still opaque.
        let tinted = look("Tinted").fill
        #expect(tinted.alpha == 1)
        #expect(tinted.blue == 1 && tinted.red > 0.8 && tinted.red < 0.9)
        #expect(look("Tinted").title == "#007AFF")
    }

    @Test func aSliderReportsItsValueInItsRange() {
        let made = placed("Slider", inputs: ["Minimum": .number(10), "Maximum": .number(20), "Value": .number(15)])
        #expect(made.output("Value") == .number(15))
        #expect(abs(inside(made.runtime, made.layer, "Knob")!.position.x - 121.5) < 0.01)
        // Dragged to the right end, it reports the maximum.
        made.runtime.send(.touchDown(Point2(x: 160, y: 114)))
        made.runtime.tick(dt: 1 / 60)
        made.runtime.send(.touchMoved(Point2(x: 400, y: 114)))
        made.runtime.advance(seconds: 0.2)
        made.runtime.send(.touchUp(Point2(x: 400, y: 114)))
        made.runtime.advance(seconds: 0.2)
        #expect(made.output("Value") == .number(20))
    }

    @Test func aStepperCountsByItsStepAndStopsAtItsLimits() {
        let made = placed("Stepper", inputs: ["Value": .number(4), "Step": .number(5), "Maximum": .number(12)])
        #expect(made.output("Value") == .number(4))
        tap(made.runtime, 90, 116)
        #expect(made.output("Value") == .number(9))
        tap(made.runtime, 90, 116)
        #expect(made.output("Value") == .number(12))
        for _ in 0..<4 { tap(made.runtime, 40, 116) }
        #expect(made.output("Value") == .number(0))
        #expect(!made.runtime.needsAnotherFrame)
    }

    @Test func aSegmentedControlReportsTheSegmentThatWasTapped() {
        let made = placed("Segmented Control", inputs: ["Selected": .number(1)])
        #expect(made.output("Selected") == .number(1))
        tap(made.runtime, 20 + 250, 116)
        #expect(made.output("Selected") == .number(2))
        // One capsule rests on the chosen segment; the segments themselves stay clear.
        func selection() -> ResolvedLayer { inside(made.runtime, made.layer, "Selection")! }
        let segments = all(made.runtime, named: "Segment")
        #expect(segments.map { $0.value(.fill).colorValue.alpha } == [0, 0, 0])
        func on(_ index: Int) -> Bool {
            abs(selection().position.x - segments[index].position.x) < 0.01 && abs(selection().size.width - segments[index].size.width) < 0.01
        }
        #expect(on(2))
        #expect(all(made.runtime, named: "Label").map { $0.value(.fontWeight) } == [.number(500), .number(500), .number(600)])
        // Back to the first: on its way it stretches over more than one segment.
        made.runtime.send(.touchDown(Point2(x: 60, y: 116)))
        made.runtime.tick(dt: 1 / 60)
        made.runtime.send(.touchUp(Point2(x: 60, y: 116)))
        made.runtime.advance(seconds: 0.1)
        #expect(selection().size.width > segments[0].size.width + 10)
        made.runtime.advance(seconds: 1.5)
        #expect(on(0))
        #expect(!made.runtime.needsAnotherFrame)
    }

    @Test func aMenuButtonOpensAndTakesAChoice() {
        let made = placed("Menu Button", inputs: ["Options": .text("Day, Week, Month, Year")])
        func label() -> String { inside(made.runtime, made.layer, "Label")!.value(.text).textValue }
        #expect(label() == "Day")
        #expect(inside(made.runtime, made.layer, "Menu") == nil)

        tap(made.runtime, 60, 116)
        #expect(made.output("Open") == .bool(true))
        let menu = inside(made.runtime, made.layer, "Menu")!
        #expect(menu.children.count == 4)
        #expect(abs(menu.size.height - (4 * 44 + 12)) < 0.01)
        #expect(menu.opacity == 1)

        // The third choice: the menu starts at y 140, six points of padding, rows of 44.
        tap(made.runtime, 80, 140 + 6 + 44 * 2 + 22)
        #expect(made.output("Selected") == .number(2))
        #expect(label() == "Month")
        #expect(made.output("Open") == .bool(false))
        #expect(inside(made.runtime, made.layer, "Menu") == nil)
        #expect(!made.runtime.needsAnotherFrame)

        // Picking what is already picked closes it too.
        tap(made.runtime, 60, 116)
        tap(made.runtime, 80, 140 + 6 + 44 * 2 + 22)
        #expect(made.output("Open") == .bool(false))
    }

    @Test func aTextFieldReportsWhatIsTypedAndClears() {
        let made = placed("Text Field", inputs: ["Placeholder": .text("Name")])
        #expect(inside(made.runtime, made.layer, "Field")!.value(.placeholder) == .text("Name"))
        #expect(inside(made.runtime, made.layer, "Clear") == nil)
        tap(made.runtime, 100, 122)
        #expect(made.output("Editing") == .bool(true))
        made.runtime.send(.text("Ada"))
        made.runtime.advance(seconds: 0.2)
        #expect(made.output("Text") == .text("Ada"))
        let clear = inside(made.runtime, made.layer, "Clear")!
        // The button that clears it is at the right end while there is something to clear.
        tap(made.runtime, 20 + clear.origin.x + 8, 122)
        #expect(made.output("Text") == .text(""))
        #expect(!made.runtime.needsAnotherFrame)
    }

    @Test func progressPagesAndTheSpinner() {
        let bar = placed("Progress Bar", inputs: ["Value": .number(0.25)])
        #expect(abs(inside(bar.runtime, bar.layer, "Fill")!.size.width - 70) < 0.01)
        let over = placed("Progress Bar", inputs: ["Value": .number(7)])
        #expect(abs(inside(over.runtime, over.layer, "Fill")!.size.width - 280) < 0.01)

        let pages = placed("Page Control", inputs: ["Pages": .number(5), "Selected": .number(3)])
        let dots = all(pages.runtime, named: "Dot").map { $0.value(.fill).colorValue.alpha }
        #expect(dots == [0.25, 0.25, 0.25, 1, 0.25])
        #expect(!pages.runtime.needsAnotherFrame)

        let spinner = placed("Activity Indicator")
        let ticks = all(spinner.runtime, named: "Tick")
        #expect(ticks.map(\.rotation) == [0, 45, 90, 135, 180, 225, 270, 315])
        #expect(Set(ticks.map { ($0.opacity * 100).rounded() }).count == 8)
        let stopped = placed("Activity Indicator", inputs: ["Animating": .bool(false)])
        #expect(all(stopped.runtime, named: "Tick").isEmpty)
        // Turning, it asks for every frame; stopped, for none.
        #expect(spinner.runtime.needsAnotherFrame)
        stopped.runtime.advance(seconds: 0.5)
        #expect(!stopped.runtime.needsAnotherFrame)

        // A switch at the end of a row is the switch's to take: the row is not tapped.
        let row = placed("List Row", inputs: ["Accessory": .text("Switch")])
        let toggle = middle(row.runtime, "Switch")!
        #expect(!pulses(row, "Tap", tapAt: toggle))
        #expect(row.output("On") == .bool(true))
        #expect(pulses(row, "Tap", tapAt: Point2(x: 60, y: toggle.y)))
        #expect(row.output("On") == .bool(true))
    }

    /// Taps a point and says whether an output pulsed on the way.
    func pulses(_ made: (runtime: Runtime, layer: LayerID, output: (String) -> Value?), _ output: String, tapAt point: Point2) -> Bool {
        var pulsed = false
        made.runtime.send(.touchDown(point))
        made.runtime.tick(dt: 1 / 60)
        made.runtime.send(.touchUp(point))
        for _ in 0..<6 {
            made.runtime.tick(dt: 1 / 60)
            if made.output(output) == .pulse(true) { pulsed = true }
        }
        made.runtime.advance(seconds: 0.5)
        return pulsed
    }

    @Test func aNavigationBarReportsBackAndItsAction() {
        let plain = placed("Navigation Bar")
        #expect(pulses(plain, "Back", tapAt: Point2(x: 50, y: 122)))
        // With no action named there is nothing at the trailing end to tap.
        #expect(!pulses(plain, "Action", tapAt: Point2(x: 20 + 370, y: 122)))

        let editing = placed("Navigation Bar", inputs: ["Action": .text("Edit"), "Title": .text("Notes")])
        #expect(inside(editing.runtime, editing.layer, "Action Label")!.value(.text) == .text("Edit"))
        #expect(pulses(editing, "Action", tapAt: Point2(x: 20 + 370, y: 122)))
        #expect(!pulses(editing, "Back", tapAt: Point2(x: 20 + 370, y: 122)))
    }

    @Test func aLargeTitleBarShrinksAsTheContentScrolls() {
        func bar(_ offset: Double) -> (height: Double, output: Value?, inline: Double, largeY: Double) {
            let made = placed("Large Title Bar", inputs: ["Scroll Offset": .number(offset), "Title": .text("Inbox")])
            // Where the large title's top is in the bar, and how much room it has to show in.
            let area = inside(made.runtime, made.layer, "Title Area")!
            room = area.size.height
            return (
                inside(made.runtime, made.layer, "Background")!.size.height, made.output("Height"),
                inside(made.runtime, made.layer, "Inline Title")!.opacity,
                area.position.y + inside(made.runtime, made.layer, "Large Title")!.position.y
            )
        }
        var room = 0.0
        #expect(bar(0).height == 96)
        #expect(bar(0).inline == 0)
        #expect(bar(0).largeY == 58)
        #expect(room == 52)
        #expect(bar(-26).height == 70)
        #expect(bar(-26).inline == 0)
        #expect(bar(-26).largeY == 32)
        // Scrolled away, the large title has no room left: it is never seen in the row.
        _ = bar(-300)
        #expect(room == 0)
        // Scrolled past the title, it is an ordinary bar with the title in it.
        #expect(bar(-300).height == 44)
        #expect(bar(-300).output == .number(44))
        #expect(bar(-300).inline == 1)
        // Pulled down past the top (a scroll view's offset is then above zero) it stays as it is.
        #expect(bar(80).height == 96)
    }

    @Test func aTabBarCanFloat() {
        // It floats unless it is told not to.
        #expect(ComponentLibrary.iOS("Tab Bar").inputs.first { $0.name == "Floating" }?.defaultValue == .bool(true))
        let flat = placed("Tab Bar", inputs: ["Floating": .bool(false)])
        let bar = inside(flat.runtime, flat.layer, "Background")!
        #expect(bar.size.width == 402)
        #expect(all(flat.runtime, named: "Tab").map(\.size.width) == [134, 134, 134])
        #expect(all(flat.runtime, named: "Icon").map { $0.value(.fill).colorValue.hex } == ["#007AFF", "#8E8E93", "#8E8E93"])
        #expect(bar.value(.cornerRadius) == .number(0))
        // The bar is glass. Flat against the edge it only softens and tints what is under it.
        #expect(bar.shader?.source == SystemStyle.glassShader)
        #expect(bar.shader?.values["tint"]?.colorValue.hex == "#F9F9F9D9")
        #expect(bar.shader?.values["refraction"] == .number(0))
        #expect(bar.shader?.values["radius"] == .number(0))

        let floating = placed("Tab Bar", inputs: ["Selected": .number(1)])
        let capsule = inside(floating.runtime, floating.layer, "Background")!
        // As the real one measures: as wide as its three tabs of 86 with 8 at each end, 62
        // high, in the middle, with 21 points under it.
        #expect(capsule.size == Size2(width: 274, height: 62))
        #expect(capsule.position == Point2(x: 64, y: 0))
        #expect(floating.runtime.resolved.find(floating.layer)!.size.height == 83)
        #expect(capsule.value(.cornerRadius) == .number(31))
        #expect(capsule.value(.shadowRadius) == .number(18))
        // Floating, its rim bends what is behind it, in the shape of the capsule.
        #expect(capsule.shader?.values["radius"] == .number(31))
        #expect(capsule.shader?.values["refraction"] == .number(SystemStyle.glassRefraction))
        #expect(capsule.shader?.values["tint"]?.colorValue.alpha == SystemStyle.glassTint.light.alpha)
        // The chosen tab is on a pill a little wider than the tab, and the others are the color of text.
        let tabs = all(floating.runtime, named: "Tab")
        let pill = inside(floating.runtime, floating.layer, "Selection")!
        #expect(pill.value(.fill).colorValue.alpha == 1)
        #expect(pill.size == Size2(width: 94, height: 54))
        #expect(pill.position == Point2(x: tabs[1].position.x - 4, y: tabs[1].position.y + 4))
        #expect(!floating.runtime.needsAnotherFrame)
        #expect(all(floating.runtime, named: "Icon").map { $0.value(.fill).colorValue.hex } == ["#000000", "#007AFF", "#000000"])
        #expect(all(floating.runtime, named: "Tab").map(\.size.width) == [86, 86, 86])
        tap(floating.runtime, 20 + 64 + 8 + 43, 130)
        #expect(floating.output("Selected") == .number(0))
        // Five tabs make a wider capsule, still in the middle.
        let five = placed("Tab Bar", inputs: ["Titles": .text("A, B, C, D, E"), "Symbols": .text("star, star, star, star, star")])
        #expect(inside(five.runtime, five.layer, "Background")!.size.width == 5 * 86 + 16 || inside(five.runtime, five.layer, "Background")!.size.width == 446)
    }

    @Test func aToolbarSaysWhichButtonWasTapped() {
        let made = placed("Toolbar", inputs: ["Symbols": .text("plus, heart, trash, folder")])
        #expect(all(made.runtime, named: "Item").count == 4)
        #expect(made.output("Tapped") == .number(-1))
        // The third of four across 402 points.
        #expect(pulses(made, "Tap", tapAt: Point2(x: 20 + 250, y: 125)))
        #expect(made.output("Tapped") == .number(2))
        // The same one again is still a tap.
        #expect(pulses(made, "Tap", tapAt: Point2(x: 20 + 250, y: 125)))
    }

    @Test func theStatusBarAndTheHomeIndicatorFollowDark() {
        let status = placed("Status Bar", inputs: ["Time": .text("12:00"), "Dark": .bool(true)])
        #expect(inside(status.runtime, status.layer, "Time")!.value(.text) == .text("12:00"))
        #expect(inside(status.runtime, status.layer, "Time")!.value(.textColor).colorValue.hex == "#FFFFFF")
        #expect(inside(status.runtime, status.layer, "Battery")!.value(.fill).colorValue.hex == "#FFFFFF")
        let home = placed("Home Indicator")
        let line = inside(home.runtime, home.layer, "Bar")!
        #expect(line.value(.fill).colorValue.hex == "#000000")
        #expect(abs(line.position.x - (402 - 144) / 2) < 0.01)
        #expect(abs(line.position.y - (34 - 8 - 5)) < 0.01)
    }

    @Test func aListRowShowsOnlyWhatItIsGiven() {
        let plain = placed("List Row")
        #expect(inside(plain.runtime, plain.layer, "Symbol") == nil)
        #expect(inside(plain.runtime, plain.layer, "Subtitle") == nil)
        #expect(inside(plain.runtime, plain.layer, "Chevron") != nil)
        #expect(inside(plain.runtime, plain.layer, "Switch") == nil)
        #expect(inside(plain.runtime, plain.layer, "Separator") == nil)
        #expect(pulses(plain, "Tap", tapAt: Point2(x: 100, y: 122)))
        let hidden = placed("List Row", inputs: ["Shows Chevron": .bool(false)])
        #expect(inside(hidden.runtime, hidden.layer, "Chevron") == nil)

        let full = placed("List Row", inputs: [
            "Title": .text("Wi-Fi"), "Subtitle": .text("Home"), "Symbol": .text("wifi"), "Accessory": .text("Checkmark"), "Separator": .bool(true),
        ])
        let tile = inside(full.runtime, full.layer, "Symbol")!
        #expect(tile.position.x == SystemStyle.tileInset)
        #expect(inside(full.runtime, full.layer, "Tile")!.size == Size2(width: 28, height: 28))
        #expect(inside(full.runtime, full.layer, "Glyph")!.value(.symbol) == .text("wifi"))
        #expect(inside(full.runtime, full.layer, "Subtitle")!.value(.text) == .text("Home"))
        // The title starts after the tile, and the subtitle is under it.
        let texts = inside(full.runtime, full.layer, "Texts")!
        #expect(texts.position.x == SystemStyle.tileTextInset)
        #expect(texts.children.map(\.name) == ["Title", "Subtitle"])
        #expect(inside(full.runtime, full.layer, "Chevron") == nil)
        #expect(inside(full.runtime, full.layer, "Checkmark") != nil)
        let line = inside(full.runtime, full.layer, "Separator")!
        // The line runs from where the text starts to the row's inset from the far edge.
        #expect(line.position == Point2(x: SystemStyle.tileTextInset, y: 51))
        #expect(line.size == Size2(width: 370 - SystemStyle.tileTextInset - SystemStyle.rowInset, height: 1))
        let bare = placed("List Row", inputs: ["Separator": .bool(true)])
        #expect(inside(bare.runtime, bare.layer, "Separator")!.position.x == SystemStyle.rowInset)
        #expect(inside(bare.runtime, bare.layer, "Texts")!.position.x == SystemStyle.rowInset)
        #expect(bare.runtime.resolved.find(bare.layer)!.size == Size2(width: 370, height: 52))
    }

    @Test func aListRowCanEndInASwitch() {
        let made = placed("List Row", inputs: ["Accessory": .text("Switch"), "On": .bool(true)])
        let toggle = inside(made.runtime, made.layer, "Switch")!
        #expect(made.output("On") == .bool(true))
        #expect(abs(inside(made.runtime, made.layer, "Knob")!.position.x - 24) < 0.01)
        // The switch is 63 by 28 and stands fourteen points from the row's edge, as in SwiftUI's List.
        #expect(toggle.size == Size2(width: 63, height: 28))
        #expect(toggle.position.x == 370 - SystemStyle.switchTrailing - 63)
        tap(made.runtime, 20 + toggle.position.x + 25, 126)
        #expect(made.output("On") == .bool(false))
        #expect(abs(inside(made.runtime, made.layer, "Knob")!.position.x - 2) < 0.01)
        #expect(inside(made.runtime, made.layer, "Track")!.value(.fill).colorValue.hex == "#D0D0D1")
        #expect(!made.runtime.needsAnotherFrame)
    }

    @Test func aSwipeActionsRowOpensWhenDraggedFarEnough() {
        func drag(_ made: (runtime: Runtime, layer: LayerID, output: (String) -> Value?), from start: Double = 300, by distance: Double) {
            made.runtime.send(.touchDown(Point2(x: start, y: 122)))
            made.runtime.tick(dt: 1 / 60)
            for step in 1...10 {
                made.runtime.send(.touchMoved(Point2(x: start + distance * Double(step) / 10, y: 122)))
                made.runtime.tick(dt: 1 / 60)
            }
            made.runtime.send(.touchUp(Point2(x: start + distance, y: 122)))
            made.runtime.advance(seconds: 1.5)
        }
        let made = placed("Swipe Actions Row")
        func x() -> Double { inside(made.runtime, made.layer, "Content")!.position.x }
        #expect(x() == 0)
        // A short drag springs back.
        drag(made, by: -30)
        #expect(abs(x()) < 0.5)
        #expect(made.output("Open") == .bool(false))
        // A long one stays open by the width of the action.
        drag(made, by: -90)
        #expect(abs(x() + 88) < 0.5)
        #expect(made.output("Open") == .bool(true))
        #expect(!made.runtime.needsAnotherFrame)
        #expect(pulses(made, "Action", tapAt: Point2(x: 20 + 358 - 40, y: 122)))
        // Dragged back by what is still showing of the row, it closes.
        drag(made, from: 120, by: 90)
        #expect(abs(x()) < 0.5)
    }

    /// The middle of the `index`th view called `name`, on the screen.
    func middle(_ runtime: Runtime, _ name: String, _ index: Int = 0) -> Point2? {
        var found: [Point2] = []
        func walk(_ layer: ResolvedLayer, _ offset: Point2) {
            let origin = Point2(x: offset.x + layer.origin.x, y: offset.y + layer.origin.y)
            if layer.name == name { found.append(Point2(x: origin.x + layer.size.width / 2, y: origin.y + layer.size.height / 2)) }
            layer.children.forEach { walk($0, origin) }
        }
        walk(runtime.resolved, .zero)
        return found.indices.contains(index) ? found[index] : nil
    }

    @Test func anAlertIsDismissedByAButtonAndSaysWhich() {
        let made = placed("Alert", inputs: ["Buttons": .text("Cancel, Delete"), "Title": .text("Delete Photo?")])
        made.runtime.advance(seconds: 1)
        #expect(made.output("Showing") == .bool(true))
        #expect(all(made.runtime, named: "Button").count == 2)
        #expect(inside(made.runtime, made.layer, "Title")!.value(.text) == .text("Delete Photo?"))
        // Both are gray capsules, as on iOS 26: neither is tinted.
        let gray = SystemStyle.alertButton.light.hex
        #expect(all(made.runtime, named: "Button").map { $0.value(.fill).colorValue.hex } == [gray, gray])
        #expect(inside(made.runtime, made.layer, "Card")!.size.width == 320)
        #expect(all(made.runtime, named: "Button").map(\.size) == [Size2(width: 141, height: 48), Size2(width: 141, height: 48)])
        #expect(inside(made.runtime, made.layer, "Card")!.scale == 1)
        #expect(!made.runtime.needsAnotherFrame)

        tap(made.runtime, middle(made.runtime, "Button", 1)!.x, middle(made.runtime, "Button", 1)!.y)
        #expect(made.output("Chosen") == .number(1))
        #expect(made.output("Showing") == .bool(false))
        #expect(made.runtime.resolved.find(made.layer) == nil)
        #expect(!made.runtime.needsAnotherFrame)

        let hidden = placed("Alert", inputs: ["Presented": .bool(false)])
        #expect(hidden.runtime.resolved.find(hidden.layer) == nil)
    }

    @Test func aButtonBringsUpAnAlert() {
        var b = SampleDocuments.Builder(screen: Layer(name: "Screen", kind: .screen))
        let button = b.place(ComponentLibrary.iOS("Button"), at: Point2(x: 100, y: 700), patchAt: Point2(x: 0, y: 0))
        let alert = b.place(ComponentLibrary.iOS("Alert"), inputs: ["Presented": .bool(false)], patchAt: Point2(x: 400, y: 0))
        b.wire(button.node!, "Tap", to: alert.node!, "Present")
        let runtime = Runtime(document: b.document)
        runtime.advance(seconds: 0.3)
        #expect(runtime.resolved.find(alert.layer) == nil)
        tap(runtime, 200, 725)
        #expect(runtime.resolved.find(alert.layer) != nil)
        // The alert is over the button now, and takes the touch.
        tap(runtime, 200, 725)
        #expect(runtime.resolved.find(alert.layer) != nil)
        let ok = middle(runtime, "Button", 1)!
        tap(runtime, ok.x, ok.y)
        #expect(runtime.resolved.find(alert.layer) == nil)
        tap(runtime, 200, 725)
        #expect(runtime.resolved.find(alert.layer) != nil)
    }

    @Test func anActionSheetIsACardOfChoicesInTheMiddle() {
        let made = placed("Action Sheet", inputs: ["Actions": .text("Share, Duplicate, Delete"), "Destructive": .number(2)])
        made.runtime.advance(seconds: 1)
        // As the real one measures: 240 wide, the title 23 from the top, capsules of 48
        // eight apart, sixteen from the sides and the bottom.
        let card = inside(made.runtime, made.layer, "Card")!
        #expect(card.size.width == 240)
        #expect(abs(card.size.height - (23 + 21 + 9 + 8 + 3 * 48 + 2 * 8 + 16)) < 1.5)
        #expect(abs(card.position.x - 81) < 0.01)
        #expect(all(made.runtime, named: "Action").map(\.size) == Array(repeating: Size2(width: 208, height: 48), count: 3))
        let inks = all(made.runtime, named: "Action Label").map { $0.value(.textColor).colorValue.hex }
        #expect(inks == ["#000000", "#000000", "#FF3B30"])
        #expect(!made.runtime.needsAnotherFrame)

        let second = middle(made.runtime, "Action", 1)!
        #expect(pulses(made, "Picked", tapAt: second))
        #expect(made.output("Chosen") == .number(1))
        made.runtime.advance(seconds: 1)
        #expect(made.runtime.resolved.find(made.layer) == nil)

        // There is no Cancel: a tap outside the card is the way out, and chooses nothing.
        let other = placed("Action Sheet")
        other.runtime.advance(seconds: 1)
        #expect(pulses(other, "Cancelled", tapAt: Point2(x: 200, y: 150)))
        #expect(other.output("Chosen") == .number(-1))
        other.runtime.advance(seconds: 1)
        #expect(other.output("Showing") == .bool(false))
        let outside = placed("Action Sheet")
        outside.runtime.advance(seconds: 1)
        #expect(pulses(outside, "Dismissed", tapAt: Point2(x: 200, y: 800)))
    }

    @Test func aContextMenuAndTheKeyboard() {
        let menu = placed("Context Menu")
        menu.runtime.advance(seconds: 1)
        #expect(all(menu.runtime, named: "Item").count == 3)
        #expect(all(menu.runtime, named: "Item Label").map { $0.value(.textColor).colorValue.hex } == ["#000000", "#000000", "#FF3B30"])
        #expect(pulses(menu, "Picked", tapAt: middle(menu.runtime, "Item", 1)!))
        #expect(menu.output("Chosen") == .number(1))
        menu.runtime.advance(seconds: 1)
        #expect(menu.runtime.resolved.find(menu.layer) == nil)

        let keys = placed("Keyboard")
        keys.runtime.advance(seconds: 1)
        #expect(all(keys.runtime, named: "Top Key").count == 10)
        #expect(all(keys.runtime, named: "Middle Key").count == 9)
        #expect(all(keys.runtime, named: "Bottom Key").count == 7)
        #expect(all(keys.runtime, named: "Top Letter").map { $0.value(.text).textValue }.joined() == "QWERTYUIOP")
        #expect(inside(keys.runtime, keys.layer, "Board")!.position.y == 0)
        #expect(!keys.runtime.needsAnotherFrame)
        let away = placed("Keyboard", inputs: ["Presented": .bool(false)])
        #expect(away.runtime.resolved.find(away.layer) == nil)
    }

    @Test func aScreenFromTheShelfAloneWorksTogether() {
        let kit = SampleDocuments.systemKit()
        let runtime = Runtime(document: kit.document)
        runtime.advance(seconds: 0.5)
        #expect(!runtime.needsAnotherFrame)
        func barHeight() -> Double { inside(runtime, kit.bar, "Background")!.size.height }
        #expect(barHeight() == 96)
        #expect(runtime.resolved.find(kit.alert) == nil)
        #expect(all(runtime, named: "Separator").count == 8)

        // The switch in the Airplane Mode row turns on.
        let toggle = middle(runtime, "Switch")!
        tap(runtime, toggle.x, toggle.y)
        #expect(abs(inside(runtime, kit.airplane, "Knob")!.position.x - 24) < 0.01)

        // Scrolling the form shrinks the title into the bar.
        runtime.send(.touchDown(Point2(x: 200, y: 600)))
        runtime.tick(dt: 1 / 60)
        for step in 1...12 {
            runtime.send(.touchMoved(Point2(x: 200, y: 600 - Double(step) * 12)))
            runtime.tick(dt: 1 / 60)
        }
        #expect(barHeight() < 60)
        #expect(inside(runtime, kit.bar, "Inline Title")!.opacity == 1)
        runtime.send(.touchUp(Point2(x: 200, y: 456)))
        runtime.advance(seconds: 3)
        #expect(!runtime.needsAnotherFrame)

        // Scrolled to the end, Sign Out is above the tab bar. A tap on it brings the alert
        // over everything; Cancel sends it away.
        for _ in 0..<3 {
            runtime.send(.touchDown(Point2(x: 200, y: 600)))
            runtime.tick(dt: 1 / 60)
            for step in 1...12 {
                runtime.send(.touchMoved(Point2(x: 200, y: 600 - Double(step) * 30)))
                runtime.tick(dt: 1 / 60)
            }
            runtime.send(.touchUp(Point2(x: 200, y: 240)))
            runtime.advance(seconds: 3)
        }
        let row = middle(runtime, "Sign Out Row")!
        #expect(row.y < 874 - 34 - 62)
        tap(runtime, row.x, row.y)
        #expect(runtime.resolved.find(kit.alert) != nil)
        #expect(runtime.resolved.children.last?.id == kit.alert)
        let cancel = middle(runtime, "Button", 0)!
        tap(runtime, cancel.x, cancel.y)
        #expect(runtime.resolved.find(kit.alert) == nil)
        #expect(!runtime.needsAnotherFrame)
    }

    /// Every control but the spinner stands still when nothing touches it.
    @Test func everyControlComesToRest() {
        for component in ComponentLibrary.iOS where component.name != "Activity Indicator" {
            let (runtime, _) = alone(component.name)
            runtime.advance(seconds: 1)
            #expect(!runtime.needsAnotherFrame, "\(component.name)")
        }
    }

    @Test func aControlIsLightUntilItsDarkInputIsOn() {
        let (light, lightRow) = alone("List Row")
        #expect(inside(light, lightRow, "Title")!.value(.textColor).colorValue.hex == "#000000")
        #expect(light.resolved.find(lightRow)!.value(.fill).colorValue.hex == "#FFFFFF")

        let (dark, darkRow) = alone("List Row", inputs: ["Dark": .bool(true)])
        #expect(inside(dark, darkRow, "Title")!.value(.textColor).colorValue.hex == "#FFFFFF")
        #expect(dark.resolved.find(darkRow)!.value(.fill).colorValue.hex == "#1C1C1E")
        #expect(!dark.needsAnotherFrame)

        let (stepper, layer) = alone("Stepper", inputs: ["Dark": .bool(true)])
        #expect(stepper.resolved.find(layer)!.value(.fill).colorValue.hex == SystemStyle.stepperFill.dark.hex)
        #expect(inside(stepper, layer, "Glyph")!.value(.fill).colorValue.hex == "#FFFFFF")

        // Every control that has colors of its own has the input, under the same name.
        for component in ComponentLibrary.iOS {
            #expect(component.inputs.contains { $0.name == "Dark" && $0.type == .bool }, "\(component.name)")
        }
    }

    @Test func aToggleFlipsWhenTappedAndTellsTheGraphAround() {
        let (runtime, example) = started()
        let on = port(example, "toggle", "Toggle", "On")
        func detail() -> String { inside(runtime, example.wifiRow, "Detail")!.value(.text).textValue }
        func knob() -> Double { inside(runtime, example.toggle, "Knob")!.position.x }
        #expect(runtime.outputValue(on) == .bool(true))
        #expect(detail() == "Home Wi-Fi")
        #expect(abs(knob() - 24) < 0.01)

        tap(runtime, 332, 136)
        #expect(runtime.outputValue(on) == .bool(false))
        #expect(detail() == "Off")
        #expect(abs(knob() - 2) < 0.01)
        #expect(inside(runtime, example.toggle, "Track")!.value(.fill).colorValue.hex == "#D0D0D1")

        tap(runtime, 332, 136)
        #expect(runtime.outputValue(on) == .bool(true))
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func aSliderFollowsADragAndStaysWhereItIsReleased() {
        let (runtime, example) = started()
        func knob() -> Double { inside(runtime, example.slider, "Knob")!.position.x }
        func label() -> String { runtime.resolved.find(example.brightness)!.value(.text).textValue }
        // It stretched to the instance's width: travel is 358 less the knob's 37.
        #expect(abs(knob() - 160.5) < 0.01)
        #expect(inside(runtime, example.slider, "Track")!.size.width == 358)
        #expect(label() == "50%")

        runtime.send(.touchDown(Point2(x: 195, y: 400)))
        runtime.tick(dt: 1 / 60)
        // A fifth of the way the knob can travel.
        runtime.send(.touchMoved(Point2(x: 259.2, y: 404)))
        runtime.advance(seconds: 0.1)
        #expect(abs(knob() - 224.7) < 0.75)
        #expect(label() == "70%")
        runtime.send(.touchUp(Point2(x: 259.2, y: 404)))
        runtime.advance(seconds: 1)
        #expect(abs(knob() - 224.7) < 0.75)

        // Dragging far past the end stops at the end.
        runtime.send(.touchDown(Point2(x: 261, y: 400)))
        runtime.tick(dt: 1 / 60)
        runtime.send(.touchMoved(Point2(x: 900, y: 400)))
        runtime.advance(seconds: 0.1)
        runtime.send(.touchUp(Point2(x: 900, y: 400)))
        runtime.advance(seconds: 0.5)
        #expect(label() == "100%")
        #expect(abs(knob() - 321) < 0.01)
    }

    @Test func buttonStepperAndTabBarReportToTheGraph() {
        let (runtime, example) = started()
        func buttonTitle() -> String { inside(runtime, example.button, "Label")!.value(.text).textValue }
        #expect(buttonTitle() == "Continue")
        tap(runtime, 195, 555)
        #expect(buttonTitle() == "Done")

        tap(runtime, 351, 462)
        tap(runtime, 351, 462)
        tap(runtime, 303, 462)
        #expect(runtime.resolved.find(example.count)!.value(.text).textValue == "1")

        #expect(all(runtime, named: "Tab").count == 3)
        #expect(all(runtime, named: "Label").filter { $0.kind == .text }.map { $0.value(.text).textValue }
            .contains("Profile"))
        tap(runtime, 325, 816)
        #expect(all(runtime, named: "Title").first!.value(.text).textValue == "Profile")
        let icons = all(runtime, named: "Icon").map { $0.value(.fill).colorValue.hex }
        #expect(icons == ["#000000", "#000000", "#007AFF"])
    }

    @Test func aButtonDimsWhilePressed() {
        let (runtime, example) = started()
        runtime.send(.touchDown(Point2(x: 195, y: 555)))
        runtime.advance(seconds: 0.5)
        #expect(abs(inside(runtime, example.button, "Background")!.opacity - 0.55) < 0.01)
        runtime.send(.touchUp(Point2(x: 195, y: 555)))
        runtime.advance(seconds: 0.5)
        #expect(abs(inside(runtime, example.button, "Background")!.opacity - 1) < 0.01)
    }

    @Test func editingADefinitionChangesEveryUse() {
        var b = Builder(screen: Layer(kind: .screen))
        let first = b.place(ComponentLibrary.iOS("Button"), at: Point2(x: 10, y: 10))
        let second = b.place(ComponentLibrary.iOS("Button"), at: Point2(x: 10, y: 100), inputs: ["Title": .text("Second")])
        let runtime = Runtime(document: b.document)
        runtime.tick(dt: 1 / 60)
        #expect(inside(runtime, first.layer, "Label")!.value(.text).textValue == "Button")
        #expect(inside(runtime, second.layer, "Label")!.value(.text).textValue == "Second")

        // Enter the component, change the label's size, come back out.
        var document = b.document
        let id = ComponentLibrary.iOS("Button").id
        var view = document.inside(of: id)!
        let label = view.screen.flattened.first { $0.name == "Label" }!.id
        view.screen.update(label) { $0.set(.fontSize, .number(24)) }
        document = document.merging(inside: view, of: id)
        runtime.update(document: document)
        runtime.tick(dt: 1 / 60)
        #expect(inside(runtime, first.layer, "Label")!.value(.fontSize).numberValue == 24)
        #expect(inside(runtime, second.layer, "Label")!.value(.fontSize).numberValue == 24)
        #expect(inside(runtime, second.layer, "Label")!.value(.text).textValue == "Second")
    }

    @Test func aLoopIntoAnInputRepeatsTheComponent() {
        var b = Builder(screen: Layer(kind: .screen, properties: [.layout: .text("Stack"), .spacing: .number(10)]))
        let button = b.place(ComponentLibrary.iOS("Button"), patchAt: .zero)
        let titles = b.document.graph.add(PatchNode(
            kind: "loopBuilder", inputs: ["value0": .text("One"), "value1": .text("Two"), "value2": .text("Three")],
            valueType: .text
        ))
        b.wire(titles, "loop", to: button.node!, "Title")
        let runtime = Runtime(document: b.document)
        runtime.advance(seconds: 0.1)

        let buttons = all(runtime, named: "Button")
        #expect(buttons.count == 3)
        #expect(buttons.map(\.frame.minY) == [0, 60, 120])
        #expect(all(runtime, named: "Label").map { $0.value(.text).textValue } == ["One", "Two", "Three"])

        // Tapping the second one: the Tap output is a loop that says which.
        tap(runtime, 100, 85)
        let taps = PortRef(node: button.node!, port: ComponentLibrary.iOS("Button").output(named: "Tap")!)
        #expect(runtime.outputValues(taps).count == 3)
    }

    @Test func variablesCascadeIntoComponentsAndCanBeOverridden() {
        // A component whose label shows the variable "Accent Name".
        let label = Layer(name: "Label", kind: .text)
        var inner = Builder(screen: Layer(name: "Tag", kind: .view, children: [label]))
        let receive = inner.add("receive", at: .zero, type: .text, inputs: ["name": .text("Accent Name")])
        inner.connect(receive, "value", to: inner.property(.text, of: label.id, at: .zero), "value")
        let tag = ComponentDefinition(name: "Tag", root: inner.document.screen, graph: inner.document.graph)

        // The same, but it sets the variable itself.
        var overriding = tag
        overriding.id = ComponentID()
        overriding.name = "Own Tag"
        overriding.graph.add(PatchNode(kind: "broadcast", inputs: ["name": .text("Accent Name"), "value": .text("Mine")], valueType: .text))

        var b = Builder(screen: Layer(kind: .screen))
        b.add("broadcast", at: .zero, type: .text, inputs: ["name": .text("Accent Name"), "value": .text("Document")])
        let plain = b.place(tag)
        let own = b.place(overriding)
        let runtime = Runtime(document: b.document)
        runtime.advance(seconds: 0.1)
        #expect(inside(runtime, plain.layer, "Label")!.value(.text).textValue == "Document")
        #expect(inside(runtime, own.layer, "Label")!.value(.text).textValue == "Mine")
    }

    @Test func documentsWithComponentsRoundTripAndOlderDocumentsStillOpen() throws {
        let document = SampleDocuments.controls().document
        #expect(try Document.decode(from: document.encoded()) == document)

        let card = SampleDocuments.card().document
        var legacy = try #require(JSONSerialization.jsonObject(with: card.encoded()) as? [String: Any])
        legacy["components"] = nil
        legacy["version"] = 1
        let opened = try Document.decode(from: JSONSerialization.data(withJSONObject: legacy))
        #expect(opened.components.isEmpty)
        #expect(opened.screen == card.screen)
    }

    @Test func aComponentInsideItselfDoesNotRunForever() {
        var definition = ComponentDefinition(name: "Loop", root: Layer(name: "Loop", kind: .view))
        definition.root.children = [definition.instance()]
        var document = Document()
        document.components = [definition]
        document.screen.children = [definition.instance()]
        let runtime = Runtime(document: document)
        runtime.tick(dt: 1 / 60)
        #expect(runtime.resolved.instanceCounts().values.reduce(0, +) < 40)
    }
}
