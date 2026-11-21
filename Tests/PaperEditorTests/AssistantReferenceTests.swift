import AppKit
import Foundation
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

/// Pointing the assistant at views, patches, pictures and videos, and the chat around it.
@MainActor
@Suite struct AssistantReferenceTests {
    private func cardStore() -> DocumentStore {
        DocumentStore(package: DocumentPackage(document: SampleDocuments.card().document))
    }

    private func make(_ store: DocumentStore) -> (AssistantSession, FakeTransport) {
        let transport = FakeTransport()
        return (AssistantSession(store: store) { transport }, transport)
    }

    private func picture(width: Int = 40, height: Int = 20) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        return image
    }

    @Test func addingTheSelectionHoldsItAndOpensTheAssistant() throws {
        let store = cardStore()
        let card = try #require(store.document.screen.flattened.first { $0.name == "Card" })
        let patch = try #require(store.document.graph.patches.first)
        store.sidebarMode = .views
        store.selectedNodes = [patch.id]
        store.selectedLayers = [card.id]
        store.addToAssistant()
        store.addToAssistant([patch.id])
        // Twice is still once.
        store.addToAssistant([patch.id])
        #expect(store.assistantReferences.map(\.target) == [.view(card.id), .patch(patch.id)])
        #expect(store.sidebarMode == .assistant && store.showsSidebar)
        let chips = store.assistantReferences.compactMap { $0.chip(in: store) }
        #expect(chips.map(\.title) == ["Card", store.title(for: patch)])
    }

    @Test func referencesTravelWithTheMessageAndShowInTheTranscript() async throws {
        let store = cardStore()
        let card = try #require(store.document.screen.flattened.first { $0.name == "Card" })
        let patch = try #require(store.document.graph.patches.first { $0.kind == "spring" })
        store.addToAssistant([patch.id])
        store.assistantReferences.append(AssistantReference(.view(card.id)))
        let (session, transport) = make(store)
        await session.send("Make this slower")

        let text = try #require(transport.sent("user").first?["text"] as? String)
        #expect(text.contains("Patch \"\(store.title(for: patch))\" (\(AssistantToolbox.short(patch.id))), kind `spring`"))
        #expect(text.contains("cables in: "))
        #expect(text.contains("View \"Card\" (\(AssistantToolbox.short(card.id)))"))
        #expect(text.hasSuffix("\n\nMake this slower"))
        #expect(transport.sent("user").first?["images"] == nil)
        // The transcript keeps what was typed and what was attached; the composer is empty again.
        #expect(session.entries[0].text == "Make this slower")
        #expect(session.entries[0].chips.map(\.title) == [store.title(for: patch), "Card"])
        #expect(store.assistantReferences.isEmpty)
    }

    @Test func aReferenceToSomethingDeletedIsLeftOut() async throws {
        let store = cardStore()
        let reference = AssistantReference(.view(LayerID()))
        #expect(reference.chip(in: store) == nil)
        let message = AssistantMessage.make("Hi", references: [reference], store: store)
        #expect(message.text == "Hi")
    }

    @Test func aPictureIsSentAsAnImageWithALabel() async throws {
        let store = DocumentStore()
        let (session, transport) = make(store)
        session.attach(picture(), name: "mock.png")
        #expect(store.assistantReferences.count == 1)
        await session.send("Build this")
        let sent = try #require(transport.sent("user").first)
        let images = try #require(sent["images"] as? [[String: String]])
        #expect(images.count == 1)
        #expect(images[0]["label"] == "Image 1: \"mock.png\"")
        #expect(images[0]["mediaType"] == "image/jpeg")
        let data = try #require(Data(base64Encoded: images[0]["data"] ?? ""))
        #expect(data.starts(with: [0xFF, 0xD8]))
        #expect((sent["text"] as? String)?.contains("Picture \"mock.png\": image 1.") == true)
        #expect(session.entries[0].chips.first?.symbol == "photo")
    }

    @Test func aLargePictureIsMadeSmaller() throws {
        let media = try #require(AssistantMediaLoader.picture(picture(width: 4000, height: 1000), name: "wide"))
        let image = try #require(NSBitmapImageRep(data: media.frames[0].data))
        #expect(max(image.pixelsWide, image.pixelsHigh) <= Int(AssistantMediaLoader.imageSide))
        #expect(media.thumbnail != nil && !media.isVideo)
    }

    @Test func aVideoBecomesStillsSpreadOverItsLength() {
        #expect(AssistantMediaLoader.frameTimes(duration: 0) == [0])
        #expect(AssistantMediaLoader.frameTimes(duration: .nan) == [0])
        let short = AssistantMediaLoader.frameTimes(duration: 0.5)
        #expect(short.count == 4 && short.first == 0)
        let long = AssistantMediaLoader.frameTimes(duration: 60)
        #expect(long.count == 12)
        #expect(long == long.sorted() && (long.last ?? 0) < 60 && (long.last ?? 0) > 59)
    }

    @Test func aRecordedMovieIsReadAndSentAsLabelledStills() async throws {
        // Record a second of a layer changing color, as the Viewer's recorder would.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reference-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let layer = CALayer()
        layer.frame = CGRect(x: 0, y: 0, width: 120, height: 200)
        let recorder = try PrototypeRecorder(size: layer.bounds.size, url: url)
        for frame in 0...30 {
            layer.backgroundColor = CGColor(red: Double(frame) / 30, green: 0.2, blue: 0.4, alpha: 1)
            recorder.append(layer, at: Double(frame) / 30)
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await recorder.finish())

        let store = DocumentStore()
        let (session, transport) = make(store)
        await session.attach([url, URL(fileURLWithPath: "/tmp/notes.txt")])
        #expect(session.composerNotice == "notes.txt is not a picture or a video.")
        let media = try #require(store.assistantReferences.compactMap { reference -> AssistantMedia? in
            if case let .media(media) = reference.target { return media }
            return nil
        }.first)
        #expect(media.isVideo && media.frames.count >= 2)
        #expect(media.frames.map(\.time) == media.frames.map(\.time).sorted())

        await session.send("Match this motion")
        let sent = try #require(transport.sent("user").first)
        let images = try #require(sent["images"] as? [[String: String]])
        #expect(images.count == media.frames.count)
        #expect(images[0]["label"]?.hasPrefix("Image 1: \"\(url.lastPathComponent)\" at 0.0 s of ") == true)
        #expect((sent["text"] as? String)?.contains("images 1 to \(images.count) are stills in order") == true)
        #expect(session.composerNotice == nil)
    }

    @Test func aMessageSentWhileWorkingWaitsItsTurn() async throws {
        let store = DocumentStore()
        let (session, transport) = make(store)
        await session.send("First")
        await session.send("Second")
        await session.send("Third")
        #expect(session.entries.map(\.text) == ["First"])
        #expect(session.queued.map(\.text) == ["Second", "Third"])
        session.unqueue(session.queued[1].id)

        transport.onMessage?(["type": "done"])
        // The next one goes out by itself.
        for _ in 0..<50 where transport.sent("user").count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(transport.sent("user").map { $0["text"] as? String } == ["First", "Second"])
        #expect(session.queued.isEmpty && session.isWorking)
    }

    @Test func stoppingHoldsTheQueueUntilThePersonSendsIt() async throws {
        let (session, transport) = make(DocumentStore())
        await session.send("First")
        await session.send("Second")
        session.stop()
        transport.onMessage?(["type": "done"])
        try await Task.sleep(for: .milliseconds(50))
        #expect(!session.isWorking && session.queued.map(\.text) == ["Second"])
        await session.sendNext()
        #expect(session.isWorking && session.queued.isEmpty)
        #expect(transport.sent("user").count == 2)
    }

    @Test func anAnswersChangesCanBeUndoneAndRedoneFromTheChat() async throws {
        let store = DocumentStore()
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        let (session, transport) = make(store)
        let empty = store.fullDocument
        await session.send("Make a card, then make it green")
        for (call, operations) in [
            ("call-1", AssistantToolboxTests.cardBatch),
            ("call-2", [["op": "set_properties", "view": "Card", "properties": ["fill": "#00FF00"]]]),
        ] {
            undo.beginUndoGrouping()
            transport.onMessage?(["type": "tool_call", "id": call, "name": "edit_document", "input": ["operations": operations]])
            undo.endUndoGrouping()
        }
        // Looking changes nothing and is not a step.
        transport.onMessage?(["type": "tool_call", "id": "call-3", "name": "view_prototype", "input": [:]])
        #expect(session.entries.last?.picture != nil && session.entries.last?.symbol == "eye")
        transport.onMessage?(["type": "done"])

        let entry = try #require(session.entries.last)
        #expect(entry.kind == .changes && entry.changes?.steps == 2)
        #expect(entry.text == "Changed the prototype in 2 steps")
        let built = store.fullDocument
        #expect(session.canUndo(entry) && !session.canRedo(entry))

        session.undoChanges(entry)
        #expect(store.fullDocument == empty)
        #expect(session.canRedo(entry) && !session.canUndo(entry))
        session.redoChanges(entry)
        #expect(store.fullDocument == built)

        // Once the person has changed something since, the button is gone.
        undo.beginUndoGrouping()
        store.addLayer(.view, frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        undo.endUndoGrouping()
        #expect(!session.canUndo(entry))
    }

    @Test func anAnswerThatChangesNothingLeavesNoChangesRow() async {
        let (session, transport) = make(DocumentStore())
        await session.send("What is here?")
        transport.onMessage?(["type": "tool_call", "id": "call-1", "name": "get_document", "input": [:]])
        transport.onMessage?(["type": "text", "delta": "Nothing yet."])
        transport.onMessage?(["type": "done"])
        #expect(session.entries.map(\.kind) == [.user, .action, .assistant])
    }

    @Test func thinkingEffortIsSentAtTheStartAndCanChangeMidChat() async throws {
        #expect(AssistantSession.Effort.allCases.map(\.title) == ["Default", "Low", "Medium", "High", "Extra High", "Max"])
        let (session, transport) = make(DocumentStore())
        // Chosen before the chat begins: nothing to tell yet.
        session.effort = .high
        #expect(transport.sent.isEmpty)
        await session.send("Hi")
        #expect(transport.sent("start").first?["effort"] as? String == "high")

        transport.onMessage?(["type": "done"])
        session.effort = .low
        session.effort = .standard
        #expect(transport.sent("effort").map { $0["effort"] as? String } == ["low", nil])
        #expect(transport.sent("effort").last?["effort"] is NSNull)
        // The conversation goes on; only a new model starts a new one.
        #expect(session.entries.count == 1 && !transport.stopped)

        let (plain, other) = make(DocumentStore())
        await plain.send("Hi")
        #expect(other.sent("start").first?["effort"] == nil)
    }

    @Test func typingAtFindsViewsAndPatchesByName() throws {
        #expect(AssistantMention.query(in: "Make @Ca") == "Ca")
        #expect(AssistantMention.query(in: "@") == "")
        #expect(AssistantMention.query(in: "Make @Card bigger") == nil)
        #expect(AssistantMention.query(in: "mail me@example") == nil)
        #expect(AssistantMention.removingQuery(from: "Make @Ca") == "Make ")

        let store = cardStore()
        let card = try #require(store.document.screen.flattened.first { $0.name == "Card" })
        let found = AssistantMention.candidates(for: "car", in: store)
        #expect(found.first?.target == .view(card.id))
        #expect(AssistantMention.candidates(for: "spring", in: store).contains { $0.symbol.hasPrefix("point.3") })
        #expect(AssistantMention.candidates(for: "zzzz", in: store).isEmpty)
        #expect(AssistantMention.candidates(for: "", in: store, limit: 3).count == 3)
    }

    @Test func markdownIsSplitIntoBlocks() {
        let text = "# Done\nI made a **card**.\n\n- One\n  - Nested\n2. Two\n\n```swift\nlet x = 1\n\nlet y = 2\n```\nAfter"
        #expect(AssistantMarkdown.blocks(of: text) == [
            .heading("Done"),
            .paragraph("I made a **card**."),
            .item(marker: "•", indent: 0, text: "One"),
            .item(marker: "•", indent: 1, text: "Nested"),
            .item(marker: "2.", indent: 0, text: "Two"),
            .code("let x = 1\n\nlet y = 2"),
            .paragraph("After"),
        ])
        // An answer still arriving may stop inside a fence.
        #expect(AssistantMarkdown.blocks(of: "Here:\n```\nfloat x;") == [.paragraph("Here:"), .code("float x;")])
    }

    @Test func thePromptExplainsWhatComesWithAMessage() {
        let store = DocumentStore()
        let prompt = AssistantPrompt.system(registry: store.registry, components: [])
        #expect(prompt.contains("# What comes with a message"))
        #expect(prompt.contains("stills in order"))
    }
}
