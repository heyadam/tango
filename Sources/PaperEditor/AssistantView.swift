import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The chat with the assistant, shown in the trailing column in place of the Inspector.
struct AssistantView: View {
    @Bindable var session: AssistantSession
    @State private var draft = ""
    @State private var isDropTarget = false
    @State private var pasteMonitor: Any?
    @FocusState private var typing: Bool

    private static let starters = [
        "A card that expands when tapped",
        "A settings screen with toggles",
        "A bottom sheet I can drag",
    ]

    var body: some View {
        VStack(spacing: 0) {
            if session.entries.isEmpty {
                ContentUnavailableView {
                    Label("Assistant", systemImage: "sparkles")
                } description: {
                    Text("Describe what you want built. Point at views and patches with @, or drop in a picture or video to work from.")
                } actions: {
                    VStack(spacing: AssistantStyle.lineSpacing) {
                        ForEach(Self.starters, id: \.self) { starter in
                            Button(starter) { Task { await session.send(starter) } }
                                .buttonStyle(AssistantBoxButtonStyle())
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                transcript
            }

            VStack(alignment: .leading, spacing: AssistantStyle.lineSpacing) {
                ForEach(session.queued) { message in
                    QueuedRow(message: message, session: session)
                }
                AssistantComposer(session: session, draft: $draft, typing: $typing, isDropTarget: isDropTarget)
            }
            .padding(.horizontal, AssistantStyle.margin)
            .padding(.bottom, AssistantStyle.margin)
            .padding(.top, AssistantStyle.lineSpacing)
            .animation(.snappy(duration: 0.2), value: session.queued.map(\.id))
        }
        .foregroundStyle(AssistantStyle.text)
        .dropDestination(for: URL.self) { urls, _ in
            Task { await session.attach(urls) }
            return true
        } isTargeted: { isDropTarget = $0 }
        .onAppear {
            typing = true
            watchForPastedPictures()
        }
        .onDisappear {
            if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
            pasteMonitor = nil
        }
        .onChange(of: session.store.assistantFocusRequest) { typing = true }
    }

    private var transcript: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AssistantStyle.blockSpacing) {
                ForEach(AssistantBlock.blocks(of: session.entries)) { block in
                    switch block {
                    case let .entry(entry):
                        AssistantEntryRow(entry: entry, session: session)
                        if let timing = entry.timing {
                            Text(timing)
                                .font(AssistantStyle.small)
                                .foregroundStyle(AssistantStyle.dim)
                                .help("Where the time of this answer went")
                        }
                    case let .steps(_, entries): AssistantSteps(entries: entries)
                    }
                }
                if session.isWorking {
                    HStack(spacing: AssistantStyle.iconGap) {
                        ProgressView().controlSize(.small).frame(width: AssistantStyle.iconColumn)
                        Text(session.status.isEmpty ? "Working…" : session.status)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(AssistantStyle.small)
                    .foregroundStyle(AssistantStyle.dim)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AssistantStyle.margin)
            .padding(.vertical, AssistantStyle.lineSpacing)
        }
        .defaultScrollAnchor(.bottom)
    }

    /// Command-V with a picture on the clipboard attaches it; a text field would ignore it.
    private func watchForPastedPictures() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard typing, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v"
            else { return event }
            let pasteboard = NSPasteboard.general
            let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
                .filter(AssistantMediaLoader.canLoad)
            if !files.isEmpty {
                Task { await session.attach(files) }
                return nil
            }
            if pasteboard.string(forType: .string) == nil, let image = NSImage(pasteboard: pasteboard) {
                session.attach(image)
                return nil
            }
            return event
        }
    }
}

/// The transcript in the pieces it is drawn as: what the assistant did, one thing after
/// another, is one list.
enum AssistantBlock: Identifiable, Equatable {
    case entry(AssistantSession.Entry)
    case steps(UUID, [AssistantSession.Entry])

    var id: UUID {
        switch self {
        case let .entry(entry): entry.id
        case let .steps(id, _): id
        }
    }

    static func blocks(of entries: [AssistantSession.Entry]) -> [AssistantBlock] {
        var blocks: [AssistantBlock] = []
        for entry in entries {
            guard entry.kind == .action || entry.kind == .problem else {
                blocks.append(.entry(entry))
                continue
            }
            if case let .steps(id, steps) = blocks.last {
                blocks[blocks.count - 1] = .steps(id, steps + [entry])
            } else {
                blocks.append(.steps(entry.id, [entry]))
            }
        }
        return blocks
    }
}

/// A message waiting for the answer in progress: a message's box, one line, stepped back.
private struct QueuedRow: View {
    let message: AssistantSession.Queued
    let session: AssistantSession

    var body: some View {
        HStack(spacing: AssistantStyle.iconGap) {
            AssistantRow(symbol: "clock") {
                Text(message.text).lineLimit(1)
                if !message.chips.isEmpty {
                    Text("+ \(message.chips.count) attached").font(AssistantStyle.tiny).lineLimit(1).layoutPriority(1)
                }
            }
            Spacer(minLength: 0)
            if !session.isWorking, session.queued.first?.id == message.id {
                Button("Send Now", systemImage: "arrow.up") { Task { await session.sendNext() } }
                    .buttonStyle(AssistantIconButtonStyle(size: 16, iconSize: 9))
                    .help("Send this message now")
            }
            Button("Remove", systemImage: "xmark") { session.unqueue(message.id) }
                .buttonStyle(AssistantIconButtonStyle(size: 16, iconSize: 8))
                .help("Do not send this message")
        }
        .padding(.vertical, -2)
        .assistantBox()
        .help("Waiting for the answer in progress: \(message.text)")
    }
}

/// What the assistant did, as a quiet list: an icon column, then one line each.
private struct AssistantSteps: View {
    let entries: [AssistantSession.Entry]

    var body: some View {
        VStack(alignment: .leading, spacing: AssistantStyle.lineSpacing) {
            ForEach(entries) { entry in
                let failed = entry.kind == .problem
                AssistantRow(symbol: failed ? "exclamationmark.triangle" : entry.symbol, color: failed ? .orange : AssistantStyle.dim) {
                    VStack(alignment: .leading, spacing: AssistantStyle.lineSpacing) {
                        Text(entry.text).textSelection(.enabled)
                        if let data = entry.picture, let image = NSImage(data: data) {
                            AssistantLook(image: image)
                        }
                    }
                }
            }
        }
    }
}

private struct AssistantEntryRow: View {
    let entry: AssistantSession.Entry
    let session: AssistantSession

    var body: some View {
        switch entry.kind {
        case .user:
            VStack(alignment: .leading, spacing: AssistantStyle.iconGap) {
                if !entry.chips.isEmpty {
                    FlowLayout(spacing: 5) {
                        ForEach(entry.chips) { chip in
                            AssistantChip(chip: chip, store: session.store)
                        }
                    }
                }
                Text(entry.text).font(AssistantStyle.body).textSelection(.enabled)
            }
            .assistantBox()
        case .assistant:
            AssistantMarkdown(text: entry.text)
        case .action, .problem:
            AssistantSteps(entries: [entry])
        case .notice:
            AssistantRow(symbol: "info.circle") { Text(entry.text) }
        case .changes:
            let undone = session.canRedo(entry)
            AssistantRow(symbol: undone ? "arrow.uturn.backward" : "checkmark") {
                Text(undone ? "Changes undone" : entry.text)
                Spacer(minLength: 4)
                if undone {
                    Button("Redo") { session.redoChanges(entry) }
                        .help("Put back what this answer changed")
                } else if session.canUndo(entry) {
                    Button("Undo") { session.undoChanges(entry) }
                        .help("Take back everything this answer changed")
                }
            }
            .buttonStyle(.link)
        case .signIn:
            AssistantRow(symbol: "person.crop.circle.badge.exclamationmark") {
                VStack(alignment: .leading, spacing: AssistantStyle.iconGap) {
                    Text(entry.text)
                    Button("Sign In to Claude…") { session.signIn() }
                        .controlSize(.small)
                }
            }
        }
    }
}

/// What the assistant saw when it looked at the prototype: small in the chat, larger on a click.
private struct AssistantLook: View {
    let image: NSImage
    @State private var isEnlarged = false

    var body: some View {
        Button { isEnlarged = true } label: {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 84)
                .clipShape(.rect(cornerRadius: AssistantStyle.smallRadius))
                .overlay { RoundedRectangle(cornerRadius: AssistantStyle.smallRadius).strokeBorder(AssistantStyle.line) }
        }
        .buttonStyle(.plain)
        .help("What the assistant saw. Click to enlarge.")
        .popover(isPresented: $isEnlarged, arrowEdge: .leading) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 520)
                .padding(AssistantStyle.inset)
        }
    }
}
