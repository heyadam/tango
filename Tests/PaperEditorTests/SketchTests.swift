import AppKit
import Foundation
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

/// The scratch pad for code: a sketch remembers where it started and where each view came
/// from, and says what changed since in terms an agent can write into code.
@MainActor
@Suite struct SketchTests {
    @discardableResult
    private func edit(_ store: DocumentStore, _ operations: [[String: Any]]) -> [String] {
        let result = AssistantToolbox(store: store).call("edit_document", input: ["operations": operations])
        let answer = (try? JSONSerialization.jsonObject(with: Data(result.text.utf8))) as? [String: Any] ?? [:]
        return (answer["errors"] as? [[String: Any]] ?? []).compactMap { $0["error"] as? String }
    }

    private func object(_ text: String) throws -> [String: Any] {
        let json = text.components(separatedBy: "\n\nImage 1").first ?? text
        return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func changes(_ store: DocumentStore) throws -> [String: Any] {
        try object(AssistantToolbox(store: store).call("get_changes", input: [:]).text)
    }

    /// The card that grows on a tap, as the reference builds it, with sources noted.
    private func sketch() throws -> DocumentStore {
        let store = DocumentStore()
        let operations = try #require(try JSONSerialization.jsonObject(with: Data(AssistantPrompt.tapExample.utf8)) as? [[String: Any]])
        #expect(edit(store, operations) == [])
        #expect(edit(store, [
            ["op": "set_source", "view": "Card", "source": "Card.swift:12 CardView"],
            ["op": "rename_patch", "patch": "Spring Animation", "name": "Open Spring"],
            ["op": "set_source", "patch": "Open Spring", "source": "Card.swift:30 withAnimation"],
            ["op": "add_view", "kind": "text", "name": "Title", "parent": "Card", "source": "Card.swift:14 Text", "properties": ["text": "Hello"]],
        ]) == [])
        _ = AssistantToolbox(store: store).call("mark_baseline", input: ["source": "Card.swift"])
        return store
    }

    // MARK: The model

    @Test func sourcesAndTheStartingPointAreSavedAndOlderFilesStillOpen() throws {
        let store = try sketch()
        let document = store.fullDocument
        #expect(document.sketch?.source == "Card.swift")
        #expect(document.sketch?.baseline.screen == document.screen)
        let again = try PaperModel.Document.decode(from: try document.encoded())
        #expect(again == document)
        #expect(again.screen.children.first?.source == "Card.swift:12 CardView")

        // A file from before any of this has neither, and reads as it always did.
        let plain = try PaperModel.Document.decode(from: try PaperModel.Document.blank().encoded())
        #expect(plain.sketch == nil && plain.screen.source == nil)
        #expect(!String(decoding: try plain.encoded(), as: UTF8.self).contains("sketch"))
    }

    @Test func aSourceIsReadBackAndStaysOnACopy() throws {
        let store = try sketch()
        let described = AssistantToolbox(store: store).describe()
        #expect(described["sketch_of"] as? String == "Card.swift")
        let card = try #require((described["views"] as? [String: Any])?["children"] as? [[String: Any]]).first
        #expect(card?["source"] as? String == "Card.swift:12 CardView")
        let patches = try #require(described["patches"] as? [[String: Any]])
        #expect(patches.first { $0["title"] as? String == "Open Spring" }?["source"] as? String == "Card.swift:30 withAnimation")

        #expect(edit(store, [["op": "set_source", "view": "Title", "source": ""]]) == [])
        #expect(store.document.screen.flattened.first { $0.name == "Title" }?.source == nil)

        store.selectedLayers = [try #require(store.document.screen.children.first?.id)]
        store.duplicateSelectedLayers()
        #expect(store.document.screen.children.count == 2)
        #expect(store.document.screen.children.allSatisfy { $0.source == "Card.swift:12 CardView" })

    }

    // MARK: What changed

    @Test func nothingIsReportedUntilSomethingChanges() throws {
        let store = try sketch()
        let report = try changes(store)
        #expect(report["sketch_of"] as? String == "Card.swift")
        #expect((report["changes"] as? String)?.contains("Nothing") == true)
        #expect(report["views"] == nil && report["patches"] == nil && report["motion"] == nil)

        let none = AssistantToolbox(store: DocumentStore()).call("get_changes", input: [:])
        #expect(none.isError && none.text.contains("mark_baseline"))
    }

    @Test func everyKindOfChangeIsReportedWithWhereItCameFrom() throws {
        let store = try sketch()
        #expect(edit(store, [
            ["op": "set_properties", "view": "Card", "properties": ["cornerRadius": 40, "x": 20, "fill": "#FF0000"]],
            ["op": "rename_view", "view": "Title", "name": "Headline"],
            ["op": "add_view", "kind": "symbol", "name": "Badge", "parent": "Card", "properties": ["symbol": "star.fill"]],
            ["op": "add_view", "kind": "view", "name": "Footer"],
            ["op": "add_patch", "kind": "easing", "ref": "fade", "name": "Fade"],
            ["op": "connect", "from": "Open", "output": "on", "to": "fade", "input": "target"],
            ["op": "connect", "from": "fade", "output": "value", "to": "Headline", "input": "opacity"],
        ]) == [])

        let report = try changes(store)
        let views = try #require(report["views"] as? [String: Any])
        let changed = try #require(views["changed"] as? [[String: Any]])
        let card = try #require(changed.first { $0["view"] as? String == "Card" })
        #expect(card["source"] as? String == "Card.swift:12 CardView")
        let properties = try #require(card["properties"] as? [String: [String: Any]])
        #expect(properties["cornerRadius"]?["from"] as? Double == 28 && properties["cornerRadius"]?["to"] as? Double == 40)
        #expect(properties["x"]?["from"] as? Double == 40 && properties["x"]?["to"] as? Double == 20)
        #expect(properties["y"] == nil && properties["width"] == nil)
        #expect(properties["fill"]?["to"] as? String == "#FF0000")
        let title = try #require(changed.first { $0["view"] as? String == "Headline" })
        #expect((title["renamed"] as? [String: String])?["from"] == "Title")
        #expect(title["source"] as? String == "Card.swift:14 Text")

        let added = try #require(views["added"] as? [[String: Any]])
        #expect(Set(added.compactMap { $0["name"] as? String }) == ["Badge", "Footer"])
        let badge = try #require(added.first { $0["name"] as? String == "Badge" })
        #expect(badge["parent"] as? String == "Card" && badge["after"] as? String == "Headline")

        let patches = try #require(report["patches"] as? [String: Any])
        #expect((patches["added"] as? [[String: Any]])?.map { $0["patch"] as? String } == ["Fade"])
        let cables = try #require((report["cables"] as? [String: Any])?["added"] as? [String])
        #expect(cables.contains("Open.on -> Fade.target") && cables.contains("Fade.value -> Headline.opacity"))
        #expect(SketchChanges.count(in: report) == 7)

        // Taking it all back leaves nothing to report.
        #expect(edit(store, [
            ["op": "set_properties", "view": "Card", "properties": ["cornerRadius": 28, "x": 40, "fill": "#3D7BF7"]],
            ["op": "rename_view", "view": "Headline", "name": "Title"],
            ["op": "delete_view", "view": "Badge"], ["op": "delete_view", "view": "Footer"],
            ["op": "delete_patch", "patch": "Fade"],
        ]) == [])
        #expect((try changes(store)["changes"] as? String)?.contains("Nothing") == true)
    }

    @Test func removedMovedAndReorderedViewsAreToldApart() throws {
        let store = DocumentStore()
        #expect(edit(store, [
            ["op": "add_view", "kind": "stack", "name": "List", "ref": "list"],
            ["op": "add_view", "kind": "view", "name": "One", "parent": "list"],
            ["op": "add_view", "kind": "view", "name": "Two", "parent": "list"],
            ["op": "add_view", "kind": "view", "name": "Three", "parent": "list", "source": "Rows.swift:9"],
            ["op": "add_view", "kind": "view", "name": "Tray"],
        ]) == [])
        store.markBaseline()
        #expect(edit(store, [
            ["op": "move_view", "view": "Two", "parent": "List", "index": 0],
            ["op": "move_view", "view": "One", "parent": "Tray"],
            ["op": "delete_view", "view": "Three"],
        ]) == [])
        let views = try #require(try changes(store)["views"] as? [String: Any])
        let removed = try #require(views["removed"] as? [[String: Any]])
        #expect(removed.count == 1 && removed[0]["view"] as? String == "Three" && removed[0]["source"] as? String == "Rows.swift:9")
        #expect(views["added"] == nil)
        let changed = try #require(views["changed"] as? [[String: Any]])
        let one = try #require(changed.first { $0["view"] as? String == "One" })
        #expect((one["moved"] as? [String: String]) == ["from": "List", "to": "Tray"])

        // Order alone is reported on the container, by name.
        store.markBaseline()
        #expect(edit(store, [
            ["op": "add_view", "kind": "view", "name": "Four", "parent": "List"],
            ["op": "move_view", "view": "Four", "parent": "List", "index": 0],
        ]) == [])
        store.markBaseline()
        #expect(edit(store, [["op": "move_view", "view": "Two", "parent": "List", "index": 0]]) == [])
        let reordered = try #require((try changes(store)["views"] as? [String: Any])?["changed"] as? [[String: Any]])
        #expect(reordered.first { $0["view"] as? String == "List" }?["children_now_in_order"] as? [String] == ["Two", "Four"])
    }

    // MARK: Motion

    @Test func aChangedSpringComesWithWhatItDrivesAndItsNumbersInCode() throws {
        let store = try sketch()
        #expect(edit(store, [["op": "set_inputs", "patch": "Open Spring", "inputs": ["response": 0.6, "damping": 0.5]]]) == [])
        let motion = try #require(try changes(store)["motion"] as? [[String: Any]])
        #expect(motion.count == 1)
        let spring = motion[0]
        #expect(spring["animation"] as? String == "Open Spring" && spring["status"] as? String == "changed")
        #expect(spring["source"] as? String == "Card.swift:30 withAnimation")
        #expect(spring["drives"] as? [String] == ["Card.height 180 → 520"], "\(spring)")
        #expect((spring["started_by"] as? String)?.hasPrefix("Open.on") == true)
        #expect((spring["started_by"] as? String)?.contains("tap on Card") == true)
        let code = try #require(spring["code"] as? [String: String])
        #expect(code["swiftui"] == ".spring(response: 0.6, dampingFraction: 0.5)")
        #expect(code["reanimated"] == "withSpring(value, { mass: 1, stiffness: 109.7, damping: 10.5 })")
        #expect((spring["code_before"] as? [String: String])?["swiftui"] == ".spring(response: 0.4, dampingFraction: 0.8)")

        // The distance it travels is part of how it feels, so that counts too.
        store.markBaseline()
        #expect(edit(store, [["op": "set_inputs", "patch": "Transition", "inputs": ["end": 400]]]) == [])
        let again = try #require(try changes(store)["motion"] as? [[String: Any]])
        #expect(again.first?["drives"] as? [String] == ["Card.height 180 → 400"])
        #expect(again.first?["drove_before"] as? [String] == ["Card.height 180 → 520"])
        #expect(again.first?["code_before"] == nil)
    }

    /// The stiffness and damping handed to Reanimated describe the spring the patch runs.
    @Test func theReanimatedNumbersAreTheSameSpring() {
        for (response, ratio) in [(0.45, 0.7), (0.3, 1.0), (0.8, 0.35)] {
            let stiffness = pow(2 * Double.pi / response, 2)
            let damping = 4 * Double.pi * ratio / response
            // A mass of 1 on that spring, stepped finely, against the patch's own arithmetic.
            var (x, v) = (0.0, 0.0)
            var (position, velocity) = (0.0, 0.0)
            let dt = 1.0 / 6000
            var worst = 0.0
            for step in 1...6000 {
                v += (stiffness * (1 - x) - damping * v) * dt
                x += v * dt
                if step % 100 == 0 {
                    (position, velocity) = Spring.step(
                        position: position, velocity: velocity, target: 1, response: response, dampingRatio: ratio, dt: 1.0 / 60
                    )
                    worst = max(worst, abs(position - x))
                }
            }
            #expect(worst < 0.01, "response \(response), ratio \(ratio)")
        }
        #expect(SketchChanges.easingCode(duration: 0.25, curve: .easeOut)["reanimated"] == "withTiming(value, { duration: 250, easing: Easing.out(Easing.cubic) })")
        #expect(SketchChanges.easingCode(duration: 0.25, curve: .linear)["swiftui"] == ".linear(duration: 0.25)")
    }

    // MARK: Pictures

    @Test func changesComeWithBeforeAndAfterPicturesWhenAsked() throws {
        let store = try sketch()
        #expect(edit(store, [["op": "set_properties", "view": "Card", "properties": ["fill": "#FF0000"]]]) == [])
        let result = AssistantToolbox(store: store).call("get_changes", input: ["pictures": true])
        #expect(result.images.count == 2 && result.images[0] != result.images[1])
        #expect(result.text.contains("Image 1 is the starting point"))
        #expect(try object(result.text)["views"] != nil)
        #expect(result.summary == "Read 1 change since the starting point")
        #expect(SketchChanges.text(for: store)?.contains("\"fill\"") == true)
    }

    @Test func thePrototypeIsShownBesideAPictureOfTheRealThing() throws {
        let store = try sketch()
        let toolbox = AssistantToolbox(store: store)
        let png = try #require(toolbox.call("view_prototype", input: [:]).image)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sketch-\(UUID().uuidString).png")
        try png.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let same = toolbox.call("compare_prototype", input: ["path": file.path])
        #expect(!same.isError && same.text.contains(" 0% of the pixels differ"))
        let picture = try #require(same.image)
        let both = try #require(NSBitmapImageRep(data: picture))
        #expect(both.pixelsWide == 390 * 2 + 16 && both.pixelsHigh == 844)

        #expect(edit(store, [["op": "set_properties", "view": "Card", "properties": ["fill": "#FF0000", "height": 400]]]) == [])
        let different = toolbox.call("compare_prototype", input: ["path": file.path])
        #expect(!different.text.contains(" 0% of the pixels differ"))

        #expect(toolbox.call("compare_prototype", input: ["path": "/nowhere/at-all.png"]).isError)
        #expect(toolbox.call("compare_prototype", input: [:]).isError)
    }

    // MARK: What code needs that views lacked

    @Test func aSideOfAStackCanHaveItsOwnPadding() throws {
        var stack = Layer.new(.stack, name: "Stack")
        stack.set(.size, .size(Size2(width: 200, height: 400)))
        stack.set(.paddingVertical, .number(10))
        stack.set(.paddingHorizontal, .number(20))
        var child = Layer(name: "Child", kind: .view, properties: [.size: .size(Size2(width: 50, height: 50))])
        child.set(.widthMode, .text("Grow"))
        child.set(.heightMode, .text("Grow"))
        stack.children = [child]

        func frame(_ stack: Layer) throws -> CGRect {
            let placed = ResolvedLayer(stack).laidOut().find(child.id)
            return try #require(placed).frame
        }
        #expect(try frame(stack) == CGRect(x: 20, y: 10, width: 160, height: 380))
        // Until a side is set it follows the pair; once set it is its own.
        #expect(stack.value(.paddingTop).numberValue == 10 && stack.value(.paddingLeft).numberValue == 20)
        stack.set(.paddingTop, .number(72))
        stack.set(.paddingRight, .number(0))
        #expect(try frame(stack) == CGRect(x: 20, y: 72, width: 180, height: 318))
        #expect(stack.value(.paddingBottom).numberValue == 10)

        let store = DocumentStore()
        #expect(edit(store, [["op": "add_view", "kind": "stack", "name": "Root", "properties": ["paddingTop": 72, "paddingBottom": 40, "paddingHorizontal": 20]]]) == [])
        #expect(store.document.screen.children.first?.value(.paddingTop).numberValue == 72)
        #expect(edit(store, [["op": "add_view", "kind": "text", "properties": ["paddingTop": 4]]]).count == 1)
    }

    @Test func aViewThatIsNotVisibleIsNotThere() throws {
        let store = DocumentStore()
        #expect(edit(store, [
            ["op": "add_view", "kind": "stack", "name": "Column", "ref": "column", "properties": ["x": 0, "y": 0, "width": 200, "height": 300, "spacing": 10]],
            ["op": "add_view", "kind": "view", "name": "Detail", "parent": "column", "ref": "detail", "properties": ["height": 60, "visible": false]],
            ["op": "add_view", "kind": "view", "name": "Row", "parent": "column", "ref": "row", "properties": ["height": 40]],
            ["op": "add_patch", "kind": "interaction", "view": "row", "ref": "touch"],
            ["op": "add_patch", "kind": "switch", "ref": "expanded", "name": "expanded"],
            ["op": "connect", "from": "touch", "output": "tap", "to": "expanded", "input": "flip"],
            ["op": "connect", "from": "expanded", "output": "on", "to": "detail", "input": "visible"],
        ]) == [])
        let runtime = Runtime(document: store.runtimeDocument)
        runtime.tick(dt: 1.0 / 60)
        func find(_ name: String) -> ResolvedLayer? { runtime.resolved.children.first?.children.first { $0.name == name } }
        // Hidden: no room is kept for it, so the row is at the top.
        #expect(find("Detail") == nil)
        #expect(find("Row")?.frame.minY == 0)

        runtime.send(.touchDown(Point2(x: 20, y: 20)))
        runtime.tick(dt: 1.0 / 60)
        runtime.send(.touchUp(Point2(x: 20, y: 20)))
        for _ in 0..<3 { runtime.tick(dt: 1.0 / 60) }
        #expect(find("Detail")?.frame.height == 60)
        #expect(find("Row")?.frame.minY == 70)
    }

    @Test func theButtonTakesACornerRadiusAndAWeightAndKeepsItsOldInputs() throws {
        let button = try #require(ComponentLibrary.iOS.first { $0.name == "Button" })
        #expect(button.inputs.map(\.name) == ["Title", "Tint", "Corner Radius", "Weight", "Style", "Dark"])

        let store = DocumentStore()
        #expect(edit(store, [[
            "op": "insert_component", "component": "Button", "name": "Edit", "source": "Profile.swift:20 Button",
            "inputs": ["Title": "Edit Profile", "Corner Radius": 14, "Weight": 700],
        ]]) == [])
        #expect(store.document.screen.children.first?.source == "Profile.swift:20 Button")
        let runtime = Runtime(document: store.runtimeDocument)
        runtime.tick(dt: 1.0 / 60)
        let background = try #require(runtime.resolved.children.first?.children.first)
        #expect(background.value(.cornerRadius).numberValue == 14)
        #expect(background.children.first?.value(.fontWeight).numberValue == 700)
        #expect(background.children.first?.value(.text).textValue == "Edit Profile")
    }

    // MARK: For outside agents

    @Test func outsideAgentsAreTaughtBothVerbsAndTheAssistantIsNot() throws {
        let documents = OpenDocuments()
        let store = try sketch()
        documents.open(store, name: "Card")
        let server = AgentServer(documents: documents)
        func call(_ name: String, _ arguments: [String: Any] = [:]) throws -> String {
            let message: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
            let answer = try #require(server.handle(try JSONSerialization.data(withJSONObject: message)))
            let result = try #require((try JSONSerialization.jsonObject(with: answer) as? [String: Any])?["result"] as? [String: Any])
            return (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        }
        let reference = try call("get_reference")
        for word in ["# Sketching from code", "mark_baseline", "get_changes", "compare_prototype", "`source`", "paddingTop", "`visible`", "set_source"] {
            #expect(reference.contains(word), "\(word)")
        }
        #expect(AgentServer.instructions.contains("get_changes"))
        #expect(!AssistantPrompt.system(registry: .standard, components: []).contains("Sketching from code"))

        #expect(try call("edit_document", ["operations": [["op": "set_properties", "view": "Card", "properties": ["cornerRadius": 12]]]]).contains("\"applied\":1"))
        #expect(try call("get_changes").contains("cornerRadius"))
        #expect(try call("mark_baseline").contains("starting point"))
        #expect(try call("get_changes").contains("Nothing has changed"))
    }
}
