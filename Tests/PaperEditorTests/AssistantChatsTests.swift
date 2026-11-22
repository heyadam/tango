import Foundation
import PaperModel
import Testing
@testable import PaperEditor

@MainActor
@Suite struct AssistantChatsTests {
    /// Chats with a fake line each, in the order they were made.
    private func make() -> (AssistantChats, () -> [FakeTransport]) {
        var made: [FakeTransport] = []
        let chats = AssistantChats(store: DocumentStore()) {
            let transport = FakeTransport()
            made.append(transport)
            return transport
        }
        return (chats, { made })
    }

    @Test func aNewChatKeepsTheOneBeforeItAnswering() async throws {
        let (chats, transports) = make()
        let first = chats.current
        // A chat that has not begun is the new chat already.
        #expect(chats.newChat() === first)
        #expect(chats.chats.count == 1)

        await first.send("Make a card")
        #expect(first.title == "Make a card")
        let second = chats.newChat()
        #expect(second !== first)
        #expect(chats.chats.map(\.id) == [second.id, first.id])
        #expect(chats.current === second)
        // The first goes on answering on its own line, and the second has its own.
        #expect(first.isWorking)
        await second.send("Make a list")
        #expect(transports().count == 2)
        #expect(chats.working == 2)
        transports()[0].onMessage?(["type": "text", "delta": "Done."])
        transports()[0].onMessage?(["type": "done"])
        #expect(first.entries.last?.text == "Done.")
        #expect(!transports()[0].stopped)
        #expect(chats.working == 1)
    }

    @Test func aChatThatFinishesOutOfSightIsMarkedUntilItIsShown() async {
        let (chats, transports) = make()
        let first = chats.current
        await first.send("One")
        let second = chats.newChat()
        transports()[0].onMessage?(["type": "done"])
        #expect(chats.hasUnseenAnswer(first))
        #expect(!chats.hasUnseenAnswer(second))
        chats.select(first.id)
        #expect(!chats.hasUnseenAnswer(first))
        // Seen while shown: stepping away does not mark it again.
        chats.select(second.id)
        #expect(!chats.hasUnseenAnswer(first))
    }

    @Test func deletingAChatStopsItsLineAndShowsANeighbor() async {
        let (chats, transports) = make()
        let first = chats.current
        await first.send("One")
        let second = chats.newChat()
        await second.send("Two")
        chats.delete(second.id)
        #expect(transports()[1].stopped)
        #expect(!transports()[0].stopped)
        #expect(chats.current === first)
        // Deleting the last leaves a fresh chat.
        chats.delete(first.id)
        #expect(chats.chats.count == 1)
        #expect(chats.current.isEmpty)
    }

    @Test func choosingAModelInABegunChatStartsANewOneWithIt() async {
        let (chats, _) = make()
        let first = chats.current
        chats.setModel(.sonnet)
        #expect(chats.chats.count == 1)
        #expect(first.model == .sonnet)
        await first.send("Hi")
        first.effort = .high
        chats.setModel(.haiku)
        #expect(chats.chats.count == 2)
        #expect(first.model == .sonnet)
        #expect(first.entries.count == 1)
        #expect(chats.current.model == .haiku)
        #expect(chats.current.effort == .high)
    }

    @Test func eachChatKeepsItsOwnDraft() async {
        let (chats, _) = make()
        let first = chats.current
        await first.send("Hi")
        first.draft = "half a thought"
        let second = chats.newChat()
        #expect(second.draft.isEmpty)
        chats.step(by: 1)
        #expect(chats.current.draft == "half a thought")
    }

    // MARK: Two chats building at once

    private func makeBuilding() -> (DocumentStore, UndoManager, AssistantChats, () -> [FakeTransport]) {
        let store = DocumentStore()
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        var made: [FakeTransport] = []
        let chats = AssistantChats(store: store) {
            let transport = FakeTransport()
            made.append(transport)
            return transport
        }
        return (store, undo, chats, { made })
    }

    private func start(_ id: String, on transport: FakeTransport) {
        transport.onMessage?(["type": "tool_start", "name": "edit_document", "useId": id])
    }

    private func write(_ operation: [String: Any], _ id: String, on transport: FakeTransport) {
        transport.onMessage?(["type": "tool_item", "name": "edit_document", "useId": id, "item": operation])
    }

    private func arrive(_ operations: [[String: Any]], _ id: String, on transport: FakeTransport) {
        transport.onMessage?([
            "type": "tool_call", "id": "call-\(id)", "name": "edit_document", "useId": id,
            "input": ["operations": operations],
        ])
    }

    private func names(_ store: DocumentStore) -> Set<String> {
        Set(store.document.screen.children.map(\.name))
    }

    @Test func batchesThatOverlapAreOneUndoStepWhicheverFinishesFirst() async {
        let (store, undo, chats, transports) = makeBuilding()
        let empty = store.fullDocument
        await chats.current.send("A card")
        await chats.newChat().send("A list")
        let (a, b) = (transports()[0], transports()[1])
        undo.beginUndoGrouping()
        let card: [String: Any] = ["op": "add_view", "kind": "view", "name": "Card"]
        let list: [String: Any] = ["op": "add_view", "kind": "view", "name": "List"]
        let more: [String: Any] = ["op": "add_view", "kind": "text", "name": "Title"]
        start("a", on: a); write(card, "a", on: a)
        start("b", on: b); write(list, "b", on: b)
        // The first chat finishes while the second is still writing.
        arrive([card], "a", on: a)
        a.onMessage?(["type": "done"])
        write(more, "b", on: b)
        arrive([list, more], "b", on: b)
        b.onMessage?(["type": "done"])
        undo.endUndoGrouping()
        #expect(names(store) == ["Card", "List", "Title"])
        #expect(store.transactionHolders == 0)
        #expect(!store.inTransaction)
        undo.undo()
        #expect(store.fullDocument == empty)
    }

    @Test func aChatTakingBackItsCallLeavesWhatAnotherBuilt() async {
        let (store, undo, chats, transports) = makeBuilding()
        await chats.current.send("A card")
        await chats.newChat().send("A list")
        let (a, b) = (transports()[0], transports()[1])
        undo.beginUndoGrouping()
        start("a", on: a); write(["op": "add_view", "kind": "view", "name": "Card"], "a", on: a)
        start("b", on: b); write(["op": "add_view", "kind": "view", "name": "List"], "b", on: b)
        // The first call never arrives, and the second differs from what streamed.
        a.onMessage?(["type": "tool_abandoned", "useId": "a"])
        arrive([["op": "add_view", "kind": "view", "name": "Other"]], "b", on: b)
        undo.endUndoGrouping()
        // Each kept what was built rather than go back over the other's work.
        #expect(names(store) == ["Card", "List"])
        #expect(!store.inTransaction)
    }

    @Test func aChatThatFinishedMeanwhileIsNotTakenBack() async {
        let (store, undo, chats, transports) = makeBuilding()
        await chats.current.send("A list")
        await chats.newChat().send("A card")
        let (a, b) = (transports()[0], transports()[1])
        undo.beginUndoGrouping()
        start("a", on: a); write(["op": "add_view", "kind": "view", "name": "Wrong"], "a", on: a)
        // The second chat builds and finishes while the first is writing.
        arrive([["op": "add_view", "kind": "view", "name": "Card"]], "b", on: b)
        b.onMessage?(["type": "done"])
        arrive([["op": "add_view", "kind": "view", "name": "Right"]], "a", on: a)
        undo.endUndoGrouping()
        #expect(names(store).contains("Card"))
    }

    @Test func aChatAloneStillBuildsADifferingCallAgain() async {
        let (store, undo, chats, transports) = makeBuilding()
        await chats.current.send("A card")
        let a = transports()[0]
        undo.beginUndoGrouping()
        start("a", on: a); write(["op": "add_view", "kind": "view", "name": "Wrong"], "a", on: a)
        arrive([["op": "add_view", "kind": "view", "name": "Right"]], "a", on: a)
        undo.endUndoGrouping()
        #expect(names(store) == ["Right"])
    }

    @Test func eachChatHasItsOwnRefs() async {
        let (store, undo, chats, transports) = makeBuilding()
        await chats.current.send("A card")
        await chats.newChat().send("A list")
        let (a, b) = (transports()[0], transports()[1])
        undo.beginUndoGrouping()
        arrive([["op": "add_view", "kind": "view", "name": "Card", "ref": "box"]], "a", on: a)
        arrive([["op": "add_view", "kind": "view", "name": "List", "ref": "box"]], "b", on: b)
        // "box" is the card to the first chat and the list to the second.
        arrive([["op": "set_properties", "view": "box", "properties": ["opacity": 0.5]]], "a2", on: a)
        undo.endUndoGrouping()
        let card = store.document.screen.children.first { $0.name == "Card" }
        let list = store.document.screen.children.first { $0.name == "List" }
        #expect(card?.value(.opacity) == .number(0.5))
        #expect(list?.value(.opacity) != .number(0.5))
        // Outside agents keep refs of their own.
        #expect(store.agentRefs.layers.isEmpty)
    }
}
