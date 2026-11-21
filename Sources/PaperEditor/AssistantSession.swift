import AppKit
import Foundation
import Observation
import PaperEngine
import PaperModel

/// One conversation with the assistant about one open document. Owns the transcript, runs
/// the tools the assistant asks for on the document, and keeps the line to Claude.
@Observable
public final class AssistantSession {
    public struct Entry: Identifiable, Equatable {
        public enum Kind: Equatable {
            case user
            case assistant
            /// Something the assistant did to the document.
            case action
            case problem
            /// Claude is not signed in on this Mac.
            case signIn
            case notice
            /// What a finished answer changed in the document, with a way to take it back.
            case changes
        }

        public let id = UUID()
        public var kind: Kind
        public var text: String
        /// What the person attached to a message of theirs.
        public var chips: [AssistantReference.Chip] = []
        /// The SF Symbol for an action.
        public var symbol = "wand.and.stars"
        /// What the assistant saw, when the action was a look at the prototype.
        public var picture: Data?
        public var changes: Changes?
        /// Where the time of the answer went, on the answer's last entry.
        public var timing: String?
    }

    /// The edits one answer made, kept so they can be undone together from the chat.
    public struct Changes: Equatable {
        /// How many undo steps the answer made.
        public var steps: Int
        public var before: PaperModel.Document
        public var after: PaperModel.Document
    }

    /// A message waiting for the answer in progress to finish.
    public struct Queued: Identifiable, Equatable {
        public let id = UUID()
        public var text: String
        public var references: [AssistantReference]
        public var chips: [AssistantReference.Chip]
    }

    /// The Claude models on offer. The raw value is the model id sent to Claude; update
    /// this list when a new generation ships.
    public enum Model: String, CaseIterable, Identifiable {
        /// Whatever the signed-in account uses when no model is named.
        case standard = ""
        case fable = "claude-fable-5-2"
        case opus = "claude-opus-5-5"
        case sonnet = "claude-sonnet-5-5"
        case haiku = "claude-haiku-5-5"

        public var id: String { rawValue }
        public var title: String {
            self == .standard ? "Default" : Self.name(of: rawValue)
        }

        /// The short word for a model on the command line: `fable`, `opus`, `sonnet`, `haiku`.
        public init?(named name: String) {
            guard let match = Self.allCases.first(where: { $0 != .standard && $0.rawValue.contains("-\(name.lowercased())-") }) else {
                return nil
            }
            self = match
        }

        /// A model id as people say it: `claude-opus-5-5` is "Opus 5.5".
        public static func name(of id: String) -> String {
            var parts = id.lowercased().split(whereSeparator: { $0 == "-" || $0 == "[" }).map(String.init)
            if parts.first == "claude" { parts.removeFirst() }
            let words = parts.prefix { Int($0) == nil }.map(\.capitalized)
            // Version numbers are short; a long run of digits is a release date.
            let version = parts.dropFirst(words.count).prefix { Int($0) != nil && $0.count <= 2 }
            guard !words.isEmpty else { return id }
            return (words + (version.isEmpty ? [] : [version.joined(separator: ".")])).joined(separator: " ")
        }
    }

    /// How hard the model thinks before it answers. The raw value is what the Agent SDK
    /// calls the level.
    public enum Effort: String, CaseIterable, Identifiable {
        /// The model's own default.
        case standard = ""
        case low, medium, high, xhigh, max

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .standard: "Default"
            case .xhigh: "Extra High"
            default: rawValue.capitalized
            }
        }
    }

    public private(set) var entries: [Entry] = []
    /// True from sending a message until the assistant has finished answering it.
    public private(set) var isWorking = false
    /// What the assistant is busy with, shown while it works.
    public private(set) var status = ""
    /// The model that is actually answering, once Claude has said so. This is how the
    /// Default choice gets a name.
    public private(set) var answeringModel: String?
    /// Messages sent while an answer was in progress, in the order they go out.
    public private(set) var queued: [Queued] = []
    /// How many pictures and videos are still being read.
    public private(set) var attaching = 0
    /// Something the composer should say, such as a file that could not be read.
    public var composerNotice: String?
    /// The model the next conversation uses. Changing it starts a new conversation.
    public var model: Model = .standard {
        didSet { if model != oldValue { newChat() } }
    }

    /// How hard the model thinks. Unlike the model, it can change in the middle of a
    /// conversation: it applies from the next message.
    public var effort: Effort = .standard {
        didSet {
            // Before the conversation has started, `start` carries it instead.
            guard effort != oldValue, transport != nil, starting == nil else { return }
            transport?.send(["type": "effort", "effort": effort == .standard ? NSNull() : effort.rawValue])
        }
    }

    @ObservationIgnored let store: DocumentStore
    @ObservationIgnored private let makeTransport: () -> AssistantTransport
    @ObservationIgnored private var transport: AssistantTransport?
    @ObservationIgnored private var starting: Task<Bool, Never>?
    /// Counts conversations, so work begun for an earlier one can tell it is stale.
    @ObservationIgnored private var chat = 0
    /// The document before the first edit of the answer in progress, and its undo steps.
    @ObservationIgnored private var turnBefore: PaperModel.Document?
    @ObservationIgnored private var turnSteps = 0
    /// How many operations or steps of the call being written have arrived so far.
    @ObservationIgnored private var itemsWritten = 0
    /// Batches being built as the model writes them, by the call's id. They share one
    /// store transaction, so all that is built from them is one undo step.
    @ObservationIgnored private var liveEdits: [String: AssistantToolbox.LiveEdit] = [:]
    @ObservationIgnored private var liveStart: PaperModel.Document?
    @ObservationIgnored private var ownsLiveTransaction = false
    /// Whether changes are applied while the model writes them, or only once the call arrives.
    @ObservationIgnored public var buildsLive = true
    @ObservationIgnored private var timing = AssistantTiming()
    /// The clock timings are read from; tests set their own.
    @ObservationIgnored var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Set by Stop: the queue then waits for the person instead of going out by itself.
    @ObservationIgnored private var holdsQueue = false

    public init(
        store: DocumentStore, model: Model = .standard,
        makeTransport: @escaping () -> AssistantTransport = { ProcessTransport() }
    ) {
        self.model = model
        self.store = store
        self.makeTransport = makeTransport
    }

    // MARK: Talking

    /// Sends what the person typed, with what they pointed at (by default everything held in
    /// `store.assistantReferences`, which is then emptied). While an answer is in progress
    /// the message waits its turn. Returns once it is on its way; the answer arrives later.
    public func send(_ text: String, references: [AssistantReference]? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attached = references ?? store.assistantReferences
        guard !trimmed.isEmpty else { return }
        if references == nil { store.assistantReferences = [] }
        composerNotice = nil
        queued.append(Queued(text: trimmed, references: attached, chips: attached.compactMap { $0.chip(in: store) }))
        holdsQueue = false
        await sendNext()
    }

    /// Sends the first waiting message, if nothing is being answered.
    public func sendNext() async {
        guard !isWorking, !queued.isEmpty else { return }
        let next = queued.removeFirst()
        holdsQueue = false
        // Written now, so it names what is selected as the message goes out.
        let message = AssistantMessage.make(next.text, references: next.references, store: store)
        entries.append(Entry(kind: .user, text: next.text, chips: next.chips))
        isWorking = true
        status = "Thinking…"
        timing = AssistantTiming()
        timing.enter(.waiting, at: now())
        turnBefore = nil
        turnSteps = 0
        let chat = self.chat
        guard await connect() else {
            // A new chat may have begun, and be working, while this one was still starting.
            if chat == self.chat {
                isWorking = false
                status = ""
            }
            return
        }
        guard chat == self.chat else { return }
        var sent: [String: Any] = ["type": "user", "text": message.text]
        if !message.pictures.isEmpty {
            sent["images"] = message.pictures.map {
                ["label": $0.label, "data": $0.data.base64EncodedString(), "mediaType": "image/jpeg"]
            }
        }
        transport?.send(sent)
    }

    /// Takes a waiting message back out of the queue.
    public func unqueue(_ id: Queued.ID) {
        queued.removeAll { $0.id == id }
    }

    /// Reads pictures and videos and holds them for the next message.
    public func attach(_ urls: [URL]) async {
        for url in urls {
            guard AssistantMediaLoader.canLoad(url) else {
                composerNotice = "\(url.lastPathComponent) is not a picture or a video."
                continue
            }
            attaching += 1
            defer { attaching -= 1 }
            do {
                let media = try await AssistantMediaLoader.load(url)
                store.assistantReferences.append(AssistantReference(.media(media)))
            } catch {
                composerNotice = error.localizedDescription
            }
        }
    }

    /// Holds a picture, such as one pasted or dropped, for the next message.
    public func attach(_ image: NSImage, name: String = "Pasted picture") {
        guard let media = AssistantMediaLoader.picture(image, name: name) else {
            composerNotice = "That picture could not be read."
            return
        }
        store.assistantReferences.append(AssistantReference(.media(media)))
    }

    /// Stops the answer in progress.
    public func stop() {
        guard isWorking else { return }
        transport?.send(["type": "interrupt"])
        status = "Stopping…"
        holdsQueue = true
    }

    /// Forgets the conversation. The document keeps every change made so far.
    public func newChat() {
        chat += 1
        starting?.cancel()
        starting = nil
        settleLive()
        transport?.onMessage = nil
        transport?.onClose = nil
        transport?.stop()
        transport = nil
        entries = []
        queued = []
        isWorking = false
        status = ""
        answeringModel = nil
        turnBefore = nil
        turnSteps = 0
    }

    // MARK: Taking an answer back

    /// Whether an answer's changes can be undone from the chat: only while the document is
    /// still exactly as that answer left it.
    public func canUndo(_ entry: Entry) -> Bool {
        guard let changes = entry.changes, !isWorking, store.undoManager?.canUndo == true else { return false }
        return store.fullDocument == changes.after
    }

    public func canRedo(_ entry: Entry) -> Bool {
        guard let changes = entry.changes, !isWorking, store.undoManager?.canRedo == true else { return false }
        return store.fullDocument == changes.before
    }

    /// Undoes everything one answer changed, a step at a time until the document is as it was.
    public func undoChanges(_ entry: Entry) {
        guard canUndo(entry), let changes = entry.changes, let manager = store.undoManager else { return }
        var steps = 0
        while store.fullDocument != changes.before, steps < changes.steps, manager.canUndo {
            manager.undo()
            steps += 1
        }
    }

    public func redoChanges(_ entry: Entry) {
        guard canRedo(entry), let changes = entry.changes, let manager = store.undoManager else { return }
        var steps = 0
        while store.fullDocument != changes.after, steps < changes.steps, manager.canRedo {
            manager.redo()
            steps += 1
        }
    }

    // MARK: The line to Claude

    private func connect() async -> Bool {
        if transport != nil, starting == nil { return true }
        if let starting { return await starting.value }
        let transport = makeTransport()
        self.transport = transport
        transport.onMessage = { [weak self] message in self?.receive(message) }
        transport.onClose = { [weak self, weak transport] problem in
            guard let self, self.transport === transport else { return }
            self.transport = nil
            self.settleLive()
            if let problem { self.report(problem) }
            if self.isWorking, problem == nil { self.report("The assistant stopped before it finished.") }
            self.isWorking = false
            self.status = ""
        }
        let prompt = AssistantPrompt.system(registry: store.registry, components: store.fullDocument.components)
        let model = self.model.rawValue
        let task = Task { [weak self] in
            do {
                try await transport.start { message in
                    self?.status = message
                }
                guard !Task.isCancelled, let self, self.transport === transport else { return false }
                var start: [String: Any] = ["type": "start", "systemPrompt": prompt]
                if !model.isEmpty { start["model"] = model }
                // Read now, not when connecting began: it may have been changed meanwhile.
                if self.effort != .standard { start["effort"] = self.effort.rawValue }
                transport.send(start)
                self.status = "Thinking…"
                return true
            } catch {
                guard let self, self.transport === transport else { return false }
                self.transport = nil
                self.report(error.localizedDescription)
                return false
            }
        }
        starting = task
        let connected = await task.value
        if starting == task { starting = nil }
        return connected
    }

    private func receive(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "text":
            guard let delta = message["delta"] as? String else { return }
            timing.enter(.answering, at: now())
            if let last = entries.indices.last, entries[last].kind == .assistant {
                entries[last].text += delta
            } else if !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entries.append(Entry(kind: .assistant, text: delta))
            }
            status = ""
        case "thinking":
            timing.enter(.thinking, at: now())
            status = "Thinking…"
        case "tool_start":
            // The call is being written: say so now rather than when it is finished.
            let name = message["name"] as? String ?? ""
            timing.enter(name == "edit_document" ? .writingChanges : .planning, at: now())
            itemsWritten = 0
            status = AssistantProgress.starting(name)
            if name == "edit_document", buildsLive, let useId = message["useId"] as? String { beginLive(useId) }
        case "tool_item":
            guard let item = message["item"] as? [String: Any] else { return }
            itemsWritten += 1
            let toolbox = AssistantToolbox(store: store)
            let live = (message["useId"] as? String).flatMap { liveEdits[$0] }
            // Built as it is written, so the person watches the prototype take shape.
            if let live { toolbox.apply(item, to: live) }
            status = AssistantProgress.line(
                tool: message["name"] as? String ?? "", item: item, count: itemsWritten,
                resolve: { toolbox.name(for: $0, in: live) }
            )
        case "tool_abandoned":
            // A call the model wrote that never arrived: what was built from it goes.
            guard let useId = message["useId"] as? String, let live = liveEdits.removeValue(forKey: useId) else { return }
            if liveEdits.isEmpty, store.document != live.startingPoint {
                store.apply("Revert") { $0 = live.startingPoint }
            }
            closeLiveTransaction()
        case "tool_call":
            guard let id = message["id"] as? String, let name = message["name"] as? String else { return }
            let input = message["input"] as? [String: Any] ?? [:]
            timing.enter(["view_prototype", "interact_prototype"].contains(name) ? .looking : .applying, at: now())
            let result: AssistantToolResult
            if name == "edit_document", let useId = message["useId"] as? String,
               let live = liveEdits.removeValue(forKey: useId) {
                result = finishLive(live, operations: input["operations"] as? [[String: Any]] ?? [])
            } else {
                let before = store.fullDocument
                result = AssistantToolbox(store: store).call(name, input: input)
                if store.fullDocument != before {
                    if turnBefore == nil { turnBefore = before }
                    turnSteps += 1
                }
            }
            // Reading is not worth a line of its own every time; changes are.
            if name != "get_document" || entries.last?.text != result.summary {
                entries.append(Entry(
                    kind: result.isError ? .problem : .action, text: result.summary,
                    symbol: Self.symbol(of: name), picture: result.images.last
                ))
            }
            var answer: [String: Any] = ["type": "tool_result", "id": id, "text": result.text, "isError": result.isError]
            if !result.images.isEmpty { answer["images"] = result.images.map { $0.base64EncodedString() } }
            transport?.send(answer)
            timing.enter(.waiting, at: now())
            status = "Working…"
        case "model":
            answeringModel = (message["model"] as? String).map(Model.name(of:))
        case "error":
            report(message["message"] as? String ?? "Something went wrong.")
        case "done":
            settleLive()
            isWorking = false
            status = ""
            if let before = turnBefore, before != store.fullDocument {
                entries.append(Entry(
                    kind: .changes, text: turnSteps == 1 ? "Changed the prototype" : "Changed the prototype in \(turnSteps) steps",
                    changes: Changes(steps: turnSteps, before: before, after: store.fullDocument)
                ))
            }
            if let took = timing.finish(at: now()), let last = entries.indices.last,
               [.changes, .assistant].contains(entries[last].kind) {
                entries[last].timing = took
            }
            timing = AssistantTiming()
            turnBefore = nil
            turnSteps = 0
            if !holdsQueue, !queued.isEmpty { Task { await sendNext() } }
        default:
            break
        }
    }

    // MARK: Building as the model writes

    private func beginLive(_ useId: String) {
        let toolbox = AssistantToolbox(store: store)
        let live = toolbox.beginEdit()
        if liveStart == nil {
            if turnBefore == nil { turnBefore = store.fullDocument }
            liveStart = store.fullDocument
            ownsLiveTransaction = store.beginTransaction()
        }
        liveEdits[useId] = live
    }

    /// The call arrived whole. What streamed was built already; anything the stream missed
    /// is applied now. If the call is not what streamed, the batch is built again from it.
    private func finishLive(_ live: AssistantToolbox.LiveEdit, operations: [[String: Any]]) -> AssistantToolResult {
        let toolbox = AssistantToolbox(store: store)
        let built = live.operations
        let matches = operations.count >= built.count
            && zip(built, operations).allSatisfy { NSDictionary(dictionary: $0).isEqual(to: $1) }
        let result: AssistantToolResult
        if matches {
            for operation in operations.dropFirst(built.count) { toolbox.apply(operation, to: live) }
            result = toolbox.finishEdit(live)
        } else {
            if store.document != live.startingPoint { store.apply("Revert") { $0 = live.startingPoint } }
            let fresh = toolbox.beginEdit()
            for operation in operations { toolbox.apply(operation, to: fresh) }
            result = toolbox.finishEdit(fresh)
        }
        closeLiveTransaction()
        return result
    }

    /// Ends the answer's live building: what was built stays (Stop keeps it), laid out, as
    /// one undo step.
    private func settleLive() {
        let toolbox = AssistantToolbox(store: store)
        for live in liveEdits.values where !live.operations.isEmpty { _ = toolbox.finishEdit(live) }
        liveEdits = [:]
        closeLiveTransaction()
    }

    private func closeLiveTransaction() {
        guard liveEdits.isEmpty, let start = liveStart else { return }
        liveStart = nil
        if ownsLiveTransaction {
            ownsLiveTransaction = false
            store.endTransaction(AssistantToolbox(store: store).editName)
        }
        if store.fullDocument != start { turnSteps += 1 }
    }

    static func symbol(of tool: String) -> String {
        switch tool {
        case "get_document": "doc.text.magnifyingglass"
        case "view_prototype": "eye"
        case "interact_prototype": "hand.tap"
        default: "wand.and.stars"
        }
    }

    private func report(_ problem: String) {
        let lowered = problem.lowercased()
        let signedOut = ["auth login", "/login", "authenticate", "invalid api key", "not logged in"].contains { lowered.contains($0) }
        if signedOut {
            entries.append(Entry(kind: .signIn, text: "Claude is not signed in on this Mac. Sign in with your Claude account, then send your message again."))
        } else {
            entries.append(Entry(kind: .problem, text: problem))
        }
    }

    // MARK: Signing in

    /// Opens Terminal on Claude's sign-in, which finishes in the browser.
    public func signIn() {
        guard let claude = ProcessTransport.claudeExecutable else {
            entries.append(Entry(kind: .problem, text: "Run `claude auth login` in Terminal to sign in."))
            return
        }
        let script = ProcessTransport.directory.appendingPathComponent("Sign In to Claude.command")
        let text = "#!/bin/zsh\nclear\n\"\(claude.path)\" auth login\necho\necho \"You can close this window and go back to tango.\"\n"
        do {
            try text.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
            // The next message starts fresh, so it picks up the new login.
            let kept = entries, waiting = queued
            newChat()
            queued = waiting
            entries = kept + [Entry(kind: .notice, text: "Finish signing in in Terminal and your browser, then send your message again.")]
        } catch {
            entries.append(Entry(kind: .problem, text: "Run `claude auth login` in Terminal to sign in."))
        }
    }
}
