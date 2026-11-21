import Foundation
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

/// A batch is built while the model writes it, and is still one undo step and one answer.
@MainActor
@Suite struct AssistantLiveEditTests {
    private func make() -> (DocumentStore, UndoManager, AssistantSession, FakeTransport) {
        let store = DocumentStore()
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        let transport = FakeTransport()
        return (store, undo, AssistantSession(store: store) { transport }, transport)
    }

    /// Plays the model writing an edit_document call, one operation at a time.
    private func write(_ operations: [[String: Any]], id: String, to transport: FakeTransport,
                       each: (Int) -> Void = { _ in }) {
        transport.onMessage?(["type": "tool_start", "name": "edit_document", "useId": id])
        for (index, operation) in operations.enumerated() {
            transport.onMessage?(["type": "tool_item", "name": "edit_document", "useId": id, "item": operation])
            each(index)
        }
    }

    @Test func theCardIsBuiltWhileItIsWrittenAndIsOneUndoStep() async throws {
        let (store, undo, session, transport) = make()
        let empty = store.fullDocument
        await session.send("Make a card that grows when tapped")
        undo.beginUndoGrouping()
        var patches: [Int] = []
        write(AssistantToolboxTests.cardBatch, id: "toolu_1", to: transport) { _ in
            patches.append(store.document.graph.patches.count)
        }
        // The card is there before the call arrives, and the patches arrive one by one.
        #expect(store.document.screen.children.map(\.name) == ["Card"])
        #expect(patches.prefix(5) == [0, 1, 2, 3, 4])

        transport.onMessage?([
            "type": "tool_call", "id": "call-1", "name": "edit_document", "useId": "toolu_1",
            "input": ["operations": AssistantToolboxTests.cardBatch],
        ])
        undo.endUndoGrouping()
        // Nothing is built twice, and the model hears what it would have heard anyway.
        #expect(store.document.screen.children.map(\.name) == ["Card"])
        #expect(store.document.graph.patches.count == 4)
        #expect(store.document.graph.connections.count >= 4)
        let answer = try #require(transport.sent("tool_result").first)
        #expect(answer["isError"] as? Bool == false)
        #expect((answer["text"] as? String)?.contains("\"applied\":9") == true)
        #expect(session.entries.last?.text == "Added 1 view, 4 patches, and 4 cables")

        transport.onMessage?(["type": "done"])
        let changes = try #require(session.entries.last)
        #expect(changes.kind == .changes && changes.changes?.steps == 1)
        undo.undo()
        #expect(store.fullDocument == empty)
    }

    @Test func aCallThatIsNotWhatStreamedIsBuiltFromTheCall() async throws {
        let (store, undo, session, transport) = make()
        await session.send("Make a card")
        undo.beginUndoGrouping()
        write([["op": "add_view", "kind": "view", "name": "Wrong"]], id: "toolu_1", to: transport)
        #expect(store.document.screen.children.map(\.name) == ["Wrong"])
        transport.onMessage?([
            "type": "tool_call", "id": "call-1", "name": "edit_document", "useId": "toolu_1",
            "input": ["operations": [["op": "add_view", "kind": "view", "name": "Right"]]],
        ])
        undo.endUndoGrouping()
        #expect(store.document.screen.children.map(\.name) == ["Right"])
    }

    @Test func operationsTheStreamMissedAreAppliedWhenTheCallArrives() async throws {
        let (store, undo, session, transport) = make()
        await session.send("Make a card")
        undo.beginUndoGrouping()
        write(Array(AssistantToolboxTests.cardBatch.prefix(3)), id: "toolu_1", to: transport)
        transport.onMessage?([
            "type": "tool_call", "id": "call-1", "name": "edit_document", "useId": "toolu_1",
            "input": ["operations": AssistantToolboxTests.cardBatch],
        ])
        undo.endUndoGrouping()
        #expect(store.document.graph.patches.count == 4)
        #expect(session.entries.last?.text == "Added 1 view, 4 patches, and 4 cables")
    }

    @Test func aCallThatNeverArrivesLeavesNothingBehind() async throws {
        let (store, undo, session, transport) = make()
        let empty = store.fullDocument
        await session.send("Make a card")
        undo.beginUndoGrouping()
        write(Array(AssistantToolboxTests.cardBatch.prefix(2)), id: "toolu_1", to: transport)
        transport.onMessage?(["type": "tool_abandoned", "useId": "toolu_1"])
        undo.endUndoGrouping()
        #expect(store.fullDocument == empty)
        transport.onMessage?(["type": "done"])
        #expect(session.entries.last?.kind != .changes)
        #expect(!store.inTransaction)
    }

    @Test func stoppingMidWayKeepsWhatWasBuiltAsOneStep() async throws {
        let (store, undo, session, transport) = make()
        let empty = store.fullDocument
        await session.send("Make a card")
        undo.beginUndoGrouping()
        write(Array(AssistantToolboxTests.cardBatch.prefix(3)), id: "toolu_1", to: transport)
        session.stop()
        transport.onMessage?(["type": "done"])
        undo.endUndoGrouping()
        #expect(store.document.screen.children.map(\.name) == ["Card"])
        #expect(!store.inTransaction)
        #expect(session.entries.last?.kind == .changes)
        undo.undo()
        #expect(store.fullDocument == empty)
    }

    @Test func liveBuildingCanBeTurnedOff() async throws {
        let (store, undo, session, transport) = make()
        session.buildsLive = false
        await session.send("Make a card")
        undo.beginUndoGrouping()
        write(AssistantToolboxTests.cardBatch, id: "toolu_1", to: transport)
        #expect(store.document.screen.children.isEmpty)
        transport.onMessage?([
            "type": "tool_call", "id": "call-1", "name": "edit_document", "useId": "toolu_1",
            "input": ["operations": AssistantToolboxTests.cardBatch],
        ])
        undo.endUndoGrouping()
        #expect(store.document.screen.children.map(\.name) == ["Card"])
    }

    @Test func anAnswerSaysWhereItsTimeWent() async throws {
        let (_, undo, session, transport) = make()
        var clock: TimeInterval = 100
        session.now = { clock }
        await session.send("Make a card")
        clock += 3   // waiting for the first word
        transport.onMessage?(["type": "thinking"])
        clock += 10
        undo.beginUndoGrouping()
        write(AssistantToolboxTests.cardBatch, id: "toolu_1", to: transport)
        clock += 25
        transport.onMessage?([
            "type": "tool_call", "id": "call-1", "name": "edit_document", "useId": "toolu_1",
            "input": ["operations": AssistantToolboxTests.cardBatch],
        ])
        undo.endUndoGrouping()
        clock += 2
        transport.onMessage?(["type": "text", "delta": "Done."])
        clock += 0.2
        transport.onMessage?(["type": "done"])
        let answer = try #require(session.entries.last)
        #expect(answer.kind == .changes)
        #expect(answer.timing == "Took 40 s · writing changes 25 s · thinking 10 s · waiting for Claude 5 s")
    }

    @Test func durationsReadPlainly() {
        #expect(AssistantTiming.duration(0.4) == "0 s")
        #expect(AssistantTiming.duration(59.6) == "1 min 0 s")
        #expect(AssistantTiming.duration(125) == "2 min 5 s")
        var timing = AssistantTiming()
        #expect(timing.finish(at: 5) == nil)
        // A quick answer says nothing about its time.
        timing.enter(.thinking, at: 0)
        #expect(timing.finish(at: 4) == nil)
    }

    @Test func aRefFromAnEarlierBatchStillNamesWhatItMade() throws {
        let store = DocumentStore()
        let toolbox = AssistantToolbox(store: store)
        _ = toolbox.call("edit_document", input: ["operations": [
            ["op": "add_view", "kind": "stack", "name": "Days", "ref": "days"],
        ]])
        // The QA agent's second batch named the list by the ref its first batch gave it.
        let second = toolbox.call("edit_document", input: ["operations": [
            ["op": "add_view", "kind": "text", "name": "Today", "parent": "days"],
        ]])
        #expect(!second.isError)
        let days = try #require(store.document.screen.children.first { $0.name == "Days" })
        #expect(days.children.map(\.name) == ["Today"])

        // Once what a ref named is gone, the ref names nothing.
        _ = toolbox.call("edit_document", input: ["operations": [["op": "delete_view", "view": "days"]]])
        let third = toolbox.call("edit_document", input: ["operations": [
            ["op": "add_view", "kind": "text", "parent": "days"],
        ]])
        #expect(third.isError)
    }

    @Test func theStatusNamesWhatARefOrIdPointsAt() async throws {
        let (store, undo, session, transport) = make()
        await session.send("Make a card")
        undo.beginUndoGrouping()
        write([
            ["op": "add_view", "kind": "view", "name": "Card", "ref": "c"],
            ["op": "set_properties", "view": "c", "properties": ["fill": "#FF0000"]],
        ], id: "toolu_1", to: transport)
        #expect(session.status == "2 changes planned · Styling “Card”…")
        let card = try #require(store.document.screen.children.first)
        write([["op": "set_properties", "view": AssistantToolbox.short(card.id), "properties": [:]]], id: "toolu_2", to: transport)
        #expect(session.status == "1 change planned · Styling “Card”…")
        undo.endUndoGrouping()
    }
}
