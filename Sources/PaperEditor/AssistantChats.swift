import Foundation
import Observation

/// Every chat with the assistant about one open document, as Cursor or Claude Code keep
/// them: one is shown, the others go on answering in the background, each with its own
/// line to its model. They all work on the same document through the same store.
@Observable
public final class AssistantChats {
    /// Newest first, as they are listed.
    public private(set) var chats: [AssistantSession]
    public private(set) var currentID: AssistantSession.ID
    /// How many answers of each chat the person has seen finish, so a chat that finished
    /// while another was shown can say so.
    private var seenAnswers: [AssistantSession.ID: Int] = [:]

    @ObservationIgnored private let make: (AssistantSession.Model, AssistantSession.Effort) -> AssistantSession

    /// `make` builds a chat with a model and a thinking level; tests give it a fake transport.
    public init(
        store: DocumentStore, model: AssistantSession.Model = .standard,
        makeTransport: (() -> AssistantTransport)? = nil
    ) {
        let make: (AssistantSession.Model, AssistantSession.Effort) -> AssistantSession = { model, effort in
            let session = AssistantSession(store: store, model: model, makeTransport: makeTransport)
            session.effort = effort
            return session
        }
        let first = make(model, .standard)
        self.make = make
        chats = [first]
        currentID = first.id
    }

    public var current: AssistantSession {
        chats.first { $0.id == currentID } ?? chats[0]
    }

    /// How many chats are answering right now.
    public var working: Int { chats.count { $0.isWorking } }

    /// Starts a chat, unless the one shown has not begun: then that one is the new chat.
    /// It answers with the model and thinking of the one shown.
    @discardableResult
    public func newChat() -> AssistantSession {
        let shown = current
        if shown.isEmpty { return shown }
        let made = make(shown.model, shown.effort)
        chats.insert(made, at: 0)
        select(made.id)
        return made
    }

    public func select(_ id: AssistantSession.ID) {
        guard chats.contains(where: { $0.id == id }) else { return }
        // What was shown was seen up to now.
        seenAnswers[currentID] = current.finishedAnswers
        currentID = id
        seenAnswers[id] = current.finishedAnswers
    }

    /// Whether a chat finished an answer since the person last looked at it.
    public func hasUnseenAnswer(_ session: AssistantSession) -> Bool {
        session.id != currentID && session.finishedAnswers > (seenAnswers[session.id] ?? 0)
    }

    /// Whether Delete Chat does anything: not for the one fresh chat there is.
    public var canDeleteCurrent: Bool { chats.count > 1 || !current.isEmpty }

    /// Stops a chat and forgets it. The document keeps what it changed. Deleting the last one
    /// leaves a fresh one.
    public func delete(_ id: AssistantSession.ID) {
        guard let index = chats.firstIndex(where: { $0.id == id }) else { return }
        let closing = chats[index]
        closing.newChat()
        chats.remove(at: index)
        seenAnswers[id] = nil
        if chats.isEmpty {
            let made = make(closing.model, closing.effort)
            chats = [made]
            currentID = made.id
        } else if currentID == id {
            select(chats[min(index, chats.count - 1)].id)
        }
    }

    /// Changes the model of the chat shown. A model cannot change in the middle of a
    /// conversation, so a chat that has begun keeps its own and the new model answers in a
    /// new chat beside it, rather than wiping it.
    public func setModel(_ model: AssistantSession.Model) {
        let shown = current
        guard model != shown.model else { return }
        if shown.isEmpty {
            shown.model = model
        } else {
            let made = make(model, shown.effort)
            chats.insert(made, at: 0)
            select(made.id)
        }
    }

    /// Steps to the chat before or after the one shown, in the order they are listed.
    public func step(by offset: Int) {
        guard let index = chats.firstIndex(where: { $0.id == currentID }), chats.count > 1 else { return }
        select(chats[(index + offset + chats.count) % chats.count].id)
    }
}
