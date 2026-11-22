import AppKit
import Foundation
import Testing
import PaperEngine
import PaperModel
import PaperRender
@testable import PaperEditor

/// Ways the iOS shelf could go wrong in a person's hands or an agent's, each written down
/// as a test: odd inputs and sizes, the editor's own commands on what the shelf puts in a
/// document, and the names agents find ports by.
///
/// `TANGO_LIBRARY_QA_FULL=1 swift test --filter LibraryQATests` runs every odd input
/// of every component, which takes a minute; without it, one in eight.
@MainActor
@Suite struct LibraryQATests {
    func makeStore() -> (DocumentStore, UndoManager) {
        let store = DocumentStore()
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        return (store, undo)
    }

    func step(_ undo: UndoManager, _ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    func finite(_ layer: ResolvedLayer) -> Bool {
        let numbers = [layer.position.x, layer.position.y, layer.size.width, layer.size.height, layer.opacity, layer.scale, layer.rotation]
        return numbers.allSatisfy(\.isFinite) && layer.children.allSatisfy(finite)
    }

    /// Values a person or an agent might give an input of each type, sensible or not.
    func odd(_ port: ComponentPort) -> [Value] {
        switch port.type {
        case .text:
            return port.options.isEmpty
                ? [.text(""), .text(" , ,, "), .text(String(repeating: "Supercalifragilistic ", count: 12)), .text((0..<40).map { "Item \($0)" }.joined(separator: ", "))]
                : port.options.map(Value.text) + [.text("Nothing Like It")]
        case .number: return [.number(-1e9), .number(-1), .number(0), .number(0.5), .number(7.5), .number(1e9)]
        case .bool: return [.bool(true), .bool(false)]
        case .color: return [.color(ColorValue(white: 0, alpha: 0)), .color(ColorValue(hex: "#FF00FF")!)]
        default: return []
        }
    }

    @Test func everyComponentTakesOddInputsAndSizesAndStillComesToRest() {
        var state: UInt64 = 0x9E3779B97F4A7C15
        func chance() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 33) / Double(1 << 31)
        }
        for definition in ComponentLibrary.iOS {
            let natural = definition.root.value(.size).sizeValue
            var cases: [(inputs: [String: Value], size: Size2)] = [([:], Size2(width: 1, height: 1)), ([:], Size2(width: 37, height: 9)), ([:], Size2(width: 900, height: 700))]
            for port in definition.inputs where port.type != .pulse {
                for value in odd(port) { cases.append(([port.name: value], natural)) }
            }
            // Everything odd at once, too.
            cases.append((Dictionary(uniqueKeysWithValues: definition.inputs.compactMap { port in odd(port).last.map { (port.name, $0) } }), natural))
            // Every case takes a minute in all: one in eight by default, and the last,
            // which is everything odd at once.
            let every = ProcessInfo.processInfo.environment["TANGO_LIBRARY_QA_FULL"] == nil ? 8 : 1
            for (index, (inputs, size)) in cases.enumerated() where index % every == 0 || index == cases.count - 1 {
                // Nothing a person can type into an input should make the prototype crawl.
                let began = CFAbsoluteTimeGetCurrent()
                defer {
                    let took = CFAbsoluteTimeGetCurrent() - began
                    #expect(took < 5, "\(definition.name) \(inputs.keys.sorted()): \(Int(took)) seconds to play a few seconds")
                }
                var b = SampleDocuments.Builder(screen: Layer(name: "Screen", kind: .screen, properties: [.size: .size(Size2(width: 402, height: 874))]))
                let placed = b.place(definition, at: Point2(x: 10, y: 60), inputs: inputs, properties: [.size: .size(size)])
                let runtime = Runtime(document: b.document)
                runtime.advance(seconds: 0.5)
                // A finger wanders over it: taps and drags, wherever they land.
                for _ in 0..<6 {
                    let from = Point2(x: 10 + chance() * min(size.width, 380), y: 60 + chance() * min(size.height, 780))
                    let to = Point2(x: from.x + (chance() - 0.5) * 240, y: from.y + (chance() - 0.5) * 240)
                    runtime.send(.touchDown(from))
                    runtime.tick(dt: 1 / 60)
                    if chance() > 0.5 {
                        for part in 1...4 {
                            runtime.send(.touchMoved(Point2(x: from.x + (to.x - from.x) * Double(part) / 4, y: from.y + (to.y - from.y) * Double(part) / 4)))
                            runtime.tick(dt: 1 / 60)
                        }
                        runtime.send(.touchUp(to))
                    } else {
                        runtime.send(.touchUp(from))
                    }
                    runtime.advance(seconds: 0.2)
                }
                runtime.send(.text("typed"))
                // Up to four seconds to come to rest; one that does has nothing left to run.
                runtime.settle(within: 4)
                let label = "\(definition.name) \(inputs.keys.sorted()) \(Int(size.width))×\(Int(size.height))"
                #expect(finite(runtime.resolved), "\(label): a frame is not a number")
                if definition.name != "Activity Indicator" {
                    #expect(!runtime.needsAnotherFrame, "\(label): never comes to rest")
                }
                _ = placed
            }
        }
    }

    @Test func everyComponentIsDrawnInBothAppearancesAtAnySize() {
        for definition in ComponentLibrary.iOS {
            for (dark, size) in [(false, Size2(width: 1, height: 1)), (true, Size2(width: 700, height: 500))] {
                var b = SampleDocuments.Builder(screen: Layer(name: "Screen", kind: .screen, properties: [.size: .size(Size2(width: 402, height: 874))]))
                _ = b.place(definition, at: Point2(x: 0, y: 0), inputs: ["Dark": .bool(dark)], properties: [.size: .size(size)])
                let picture = ViewerSnapshot.bitmaps(of: b.document, steps: [.wait(0.6), .look]).first
                #expect(picture?.pixelsWide == 402, "\(definition.name)")
            }
        }
    }

    // MARK: The editor's commands

    @Test func whatTheShelfPutsInSurvivesSavingAndReading() throws {
        let (store, undo) = makeStore()
        for definition in ComponentLibrary.iOS { step(undo) { store.insertComponent(definition) } }
        for template in ComponentLibrary.templates { step(undo) { store.insertTemplate(template) } }
        let saved = try store.fullDocument.encoded()
        let read = try Document.decode(from: saved)
        #expect(read == store.fullDocument)
        // Reading it settles nothing further: what was written is what a store keeps.
        let again = DocumentStore(package: DocumentPackage(document: read))
        #expect(again.fullDocument == read)
        #expect(try again.fullDocument.encoded() == saved)
        // And it plays: every frame a number, the spinner the only thing that moves.
        let runtime = Runtime(document: read, registry: again.runtimeRegistry)
        runtime.advance(seconds: 2)
        #expect(finite(runtime.resolved))

        // Every insert was one step; undoing them all leaves an empty document.
        while undo.canUndo { undo.undo() }
        #expect(store.document.screen.children.isEmpty)
        #expect(store.fullDocument.components.isEmpty)
        #expect(store.document.graph.nodes.count == 1)
        while undo.canRedo { undo.redo() }
        #expect(store.fullDocument == read)
    }

    @Test func aSecondCopyOfATemplateDoesNotLandOnTheFirst() throws {
        for template in ComponentLibrary.templates {
            let (store, undo) = makeStore()
            var ids: [LayerID] = []
            for _ in 0..<3 { step(undo) { if let id = store.insertTemplate(template) { ids.append(id) } } }
            #expect(ids.count == 3)
            let patches = ids.compactMap { store.viewNode(for: $0)?.position }
            #expect(Set(patches.map { "\($0.x),\($0.y)" }).count == 3, "\(template.name): the patches of two copies are on top of each other")
            #expect(Set(ids.compactMap { store.document.layer($0)?.name }).count == 3)
        }
    }

    @Test func aTemplateIsCopiedPastedGroupedAndDeletedLikeAnyViews() throws {
        let (store, undo) = makeStore()
        let template = try #require(ComponentLibrary.template("Sheet"))
        var made: LayerID?
        step(undo) { made = store.insertTemplate(template) }
        let id = try #require(made)
        let before = store.fullDocument

        // A duplicate keeps every port the original publishes, pointing into itself.
        store.selectedLayers = [id]
        step(undo) { store.duplicateSelectedLayers() }
        let copy = try #require(store.document.screen.children.last)
        #expect(copy.id != id)
        let original = Set(store.document.layer(id)!.flattened.map(\.id))
        let published = try #require(store.viewNode(for: copy.id)?.published)
        #expect(published.map(\.name) == store.viewNode(for: id)?.published?.map(\.name))
        for port in published {
            let inner = try #require(store.fullDocument.graph.node(port.inner.node))
            let home = inner.layerID ?? inner.home
            #expect(home.map { !original.contains($0) } == true, "\(port.name) of the copy points into the original")
        }
        let runtime = Runtime(document: store.fullDocument, registry: store.runtimeRegistry)
        runtime.advance(seconds: 2)
        #expect(!runtime.needsAnotherFrame)
        undo.undo()
        #expect(store.fullDocument == before)

        // Deleted, nothing of it is left: no view, no patch, no cable.
        store.selectedLayers = [id]
        step(undo) { store.deleteSelectedLayers() }
        #expect(store.document.screen.children.isEmpty)
        #expect(store.fullDocument.graph.nodes.count == 1)
        #expect(store.fullDocument.graph.connections.isEmpty)
        undo.undo()
        #expect(store.fullDocument == before)
    }

    @Test func theShelfGoesOntoTheScreenThatIsSelected() throws {
        let (store, undo) = makeStore()
        var second: LayerID?
        step(undo) { store.addScreen() }
        step(undo) { second = store.addScreen() }
        let screen = try #require(second)
        store.selectedLayers = [screen]
        var bar: LayerID?, sheet: LayerID?, row: LayerID?
        step(undo) { bar = store.insertComponent(ComponentLibrary.iOS("Navigation Bar")) }
        store.selectedLayers = [screen]
        step(undo) { sheet = store.insertTemplate(ComponentLibrary.template("Sheet")!) }
        store.selectedLayers = [screen]
        step(undo) { row = store.insertComponent(ComponentLibrary.iOS("List Row")) }
        for id in [bar, sheet, row] {
            #expect(store.document.screen.parent(of: try #require(id))?.id == screen)
        }
        let board = store.document.screen.value(.size).sizeValue
        #expect(store.document.layer(bar!)?.value(.size).sizeValue.width == board.width)
        #expect(store.document.layer(sheet!)?.value(.size) == .size(board))
    }

    // MARK: Agents find ports by name

    func edit(_ store: DocumentStore, _ operations: [[String: Any]]) -> [String] {
        let result = AssistantToolbox(store: store).call("edit_document", input: ["operations": operations])
        let answer = (try? JSONSerialization.jsonObject(with: Data(result.text.utf8))) as? [String: Any] ?? [:]
        return (answer["errors"] as? [Any])?.map { "\($0)" } ?? []
    }

    /// A component's port may share a name with one of a view's own inputs (a Status Bar
    /// has Time, as a video does). Named on an instance, it is the component's that is meant.
    @Test func aComponentsPortWinsOverAViewsOwnInputOfTheSameName() throws {
        let own = Set(ViewInput.all.map { $0.name.lowercased() })
        for definition in ComponentLibrary.iOS {
            for port in definition.inputs where own.contains(port.name.lowercased()) && port.type == .text {
                let store = DocumentStore()
                #expect(edit(store, [
                    ["op": "insert_component", "component": definition.name, "ref": "it"],
                    ["op": "add_patch", "kind": "value", "type": "text", "ref": "words", "inputs": ["value": "From a cable"]],
                    ["op": "connect", "from": "words", "output": "value", "to": "it", "input": port.name],
                ]) == [], "\(definition.name).\(port.name)")
                let instance = try #require(store.document.screen.children.first)
                let node = try #require(store.viewNode(for: instance.id))
                let cable = try #require(store.document.graph.connections.first { $0.to.node == node.id })
                #expect(cable.to.port == port.id, "\(definition.name): \"\(port.name)\" was taken for the view's own input")
            }
        }
    }

    @Test func anAgentInsertsEveryComponentAndTemplateAndSetsEveryInputByName() throws {
        for definition in ComponentLibrary.iOS {
            let store = DocumentStore()
            var inputs: [String: Any] = [:]
            for port in definition.inputs {
                switch port.type {
                case .text: inputs[port.name] = port.options.last ?? "Words"
                case .number: inputs[port.name] = 1
                case .bool: inputs[port.name] = true
                case .color: inputs[port.name] = "#112233"
                default: break
                }
            }
            #expect(edit(store, [["op": "insert_component", "component": definition.name, "inputs": inputs]]) == [], "\(definition.name)")
            let stored = try #require(store.document.screen.children.first?.component?.inputs)
            #expect(stored.count == inputs.count, "\(definition.name)")
        }
        for template in ComponentLibrary.templates {
            let store = DocumentStore()
            var inputs: [String: Any] = [:]
            for port in template.publishedInputs {
                switch port.type {
                case .text: inputs[port.name] = "Words"
                case .number: inputs[port.name] = 300
                case .bool: inputs[port.name] = true
                case .color: inputs[port.name] = "#11223380"
                default: break
                }
            }
            var operations: [[String: Any]] = [["op": "insert_template", "template": template.name, "ref": "it"]]
            if !inputs.isEmpty { operations.append(["op": "set_inputs", "patch": "it", "inputs": inputs]) }
            if let content = template.contentName {
                operations.append(["op": "add_view", "kind": "text", "name": "Mine", "parent": content == template.name ? "it" : content, "properties": ["text": "Hello"]])
            }
            #expect(edit(store, operations) == [], "\(template.name)")
            let root = try #require(store.document.screen.children.first)
            #expect(root.flattened.contains { $0.name == "Mine" }, "\(template.name)")
        }
    }
}
