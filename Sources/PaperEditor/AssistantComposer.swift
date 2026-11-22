import AppKit
import PaperEngine
import PaperModel
import SwiftUI
import UniformTypeIdentifiers

/// Finding a view or patch by typing "@" and part of its name.
enum AssistantMention {
    struct Candidate: Identifiable, Equatable {
        var target: AssistantReference.Target
        var title: String
        /// What kind of thing it is, and for a patch on a view, which view.
        var detail: String
        var symbol: String

        var id: String {
            switch target {
            case let .view(id): "view-\(id)"
            case let .patch(id): "patch-\(id)"
            case .media: "media"
            }
        }
    }

    /// What is being typed after an "@" at the end of the draft; nil when there is none.
    /// The "@" must start a word, so an address like me@example.com is left alone.
    static func query(in draft: String) -> String? {
        guard let match = draft.firstMatch(of: /(?:^|\s)@([^\s@]*)$/) else { return nil }
        return String(match.1)
    }

    /// The draft with the "@…" being typed taken off its end.
    static func removingQuery(from draft: String) -> String {
        guard let at = draft.lastIndex(of: "@") else { return draft }
        return String(draft[..<at])
    }

    /// Views and patches whose name has `query` in it: names that start with it first, then
    /// views before patches, in document order.
    static func candidates(for query: String, in store: DocumentStore, limit: Int = 7) -> [Candidate] {
        let document = store.document
        var all: [Candidate] = document.screen.flattened.filter { $0.id != document.screen.id }.map {
            Candidate(target: .view($0.id), title: $0.name, detail: $0.type.displayName, symbol: $0.type.symbolName)
        }
        all += document.graph.patches.map { node in
            let kind = store.registry.defaultTitle(for: node)
            let view = node.layerID.flatMap { document.layer($0) }?.name
            return Candidate(
                target: .patch(node.id), title: store.title(for: node),
                detail: view.map { "\(kind) on \($0)" } ?? kind,
                symbol: "point.3.connected.trianglepath.dotted"
            )
        }
        let wanted = query.lowercased()
        guard !wanted.isEmpty else { return Array(all.prefix(limit)) }
        let matching = all.filter { $0.title.lowercased().contains(wanted) || $0.detail.lowercased().contains(wanted) }
        let leading = matching.filter { $0.title.lowercased().hasPrefix(wanted) }
        return Array((leading + matching.filter { !leading.contains($0) }).prefix(limit))
    }
}

/// Where a message is written: what it points at as chips, the text, and the controls.
struct AssistantComposer: View {
    @Bindable var session: AssistantSession
    @Binding var draft: String
    var typing: FocusState<Bool>.Binding
    /// True while files are dragged over the panel.
    var isDropTarget: Bool
    /// What choosing a model does; the list of chats starts a new chat for it when this one has begun.
    var changeModel: ((AssistantSession.Model) -> Void)?

    @Environment(\.openSettings) private var openSettings

    /// Opens Settings on the pane that has the keys and the local server.
    private func showAISettings() {
        UserDefaults.standard.set(SettingsPane.ai.rawValue, forKey: "settingsPane")
        openSettings()
    }

    /// The local server's models, followed here so the menu has them as soon as Settings lists them.
    @AppStorage(AssistantSettings.localModelsKey) private var localModels = ""
    @State private var highlighted = 0
    /// The draft for which the person closed the list of suggestions with Escape.
    @State private var dismissedFor: String?

    private var store: DocumentStore { session.store }

    private var mentionQuery: String? {
        dismissedFor == draft ? nil : AssistantMention.query(in: draft)
    }

    private var candidates: [AssistantMention.Candidate] {
        mentionQuery.map { AssistantMention.candidates(for: $0, in: store) } ?? []
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let candidates = self.candidates
        VStack(alignment: .leading, spacing: AssistantStyle.lineSpacing) {
            if mentionQuery != nil {
                suggestions(candidates)
            }
            if let notice = session.composerNotice {
                AssistantRow(symbol: "exclamationmark.triangle", color: .orange) { Text(notice) }
            }
            VStack(alignment: .leading, spacing: AssistantStyle.inset) {
                chips
                TextField(session.isWorking ? "Add a follow-up…" : "Ask for a change…", text: $draft, axis: .vertical)
                    .lineLimit(1...8)
                    .textFieldStyle(.plain)
                    .font(AssistantStyle.body)
                    .focused(typing)
                    .onSubmit(send)
                    .onKeyPress(.downArrow) { move(1, among: candidates) }
                    .onKeyPress(.upArrow) { move(-1, among: candidates) }
                    .onKeyPress(.tab) { pickHighlighted(candidates) }
                    .onKeyPress(.return) { pickHighlighted(candidates) }
                    .onKeyPress(.escape) {
                        guard mentionQuery != nil else { return .ignored }
                        dismissedFor = draft
                        return .handled
                    }
                controls
            }
            .assistantBox(outlined: true, highlighted: isDropTarget)
        }
        .onChange(of: draft) { highlighted = 0 }
        .animation(.snappy(duration: 0.2), value: store.assistantReferences.map(\.id))
    }

    // MARK: Chips

    private var selectionTitle: String? {
        let selected = store.selectedNodes
        guard !selected.isEmpty else { return nil }
        if selected.count == 1, let node = store.document.graph.node(selected.first!) { return store.title(for: node) }
        return "\(selected.count) selected"
    }

    @ViewBuilder private var chips: some View {
        let held = store.assistantReferences.compactMap { $0.chip(in: store) }
        if !held.isEmpty || selectionTitle != nil || session.attaching > 0 {
            FlowLayout(spacing: 5) {
                if let title = selectionTitle {
                    Button { store.addToAssistant() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "scope").font(AssistantStyle.rowIcon)
                            Text(title).lineLimit(1).truncationMode(.middle)
                        }
                        .font(AssistantStyle.small)
                        .foregroundStyle(AssistantStyle.dim)
                        .padding(.horizontal, 7)
                        .frame(height: AssistantStyle.chipHeight)
                        .overlay { RoundedRectangle(cornerRadius: AssistantStyle.smallRadius).strokeBorder(AssistantStyle.line) }
                        .frame(maxWidth: 170)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("What is selected goes with your message. Click to keep it attached while you select something else (Command-L).")
                }
                ForEach(held) { chip in
                    AssistantChip(chip: chip, store: store) {
                        store.assistantReferences.removeAll { $0.id == chip.id }
                    }
                }
                if session.attaching > 0 {
                    ProgressView().controlSize(.small).frame(height: AssistantStyle.chipHeight)
                }
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 2) {
            Button("Attach Picture or Video", systemImage: "paperclip", action: chooseFiles)
                .buttonStyle(AssistantIconButtonStyle())
                .help("Attach a picture or a video of what you want. You can also drop or paste one.")
            Button("Point at a View or Patch", systemImage: "at") {
                if !draft.isEmpty, draft.last?.isWhitespace == false { draft += " " }
                draft += "@"
                dismissedFor = nil
                typing.wrappedValue = true
            }
            .buttonStyle(AssistantIconButtonStyle())
            .help("Point at a view or a patch by name")

            Spacer(minLength: 4)

            Menu {
                ForEach(AssistantProvider.allCases) { provider in
                    Section(provider.name) { models(of: provider) }
                }
            } label: {
                menuLabel(modelTitle)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Who answers. Changing the model starts a new chat.")

            if session.model.provider != .local {
                Menu {
                    Picker("Thinking", selection: $session.effort) {
                        ForEach(AssistantSession.Effort.allCases) { effort in
                            Text(effort.title).tag(effort)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    menuLabel(session.effort.title)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("How hard it thinks before answering: \(session.effort.title). Applies from your next message.")
            }

            if session.isWorking, !canSend {
                roundButton("Stop", symbol: "stop.fill", iconSize: 9, isOn: true, color: AnyShapeStyle(AssistantStyle.text), icon: Color(nsColor: .windowBackgroundColor)) { session.stop() }
                    .help("Stop the answer in progress")
            } else {
                roundButton(session.isWorking ? "Queue" : "Send", symbol: "arrow.up", iconSize: 12, isOn: canSend, color: AnyShapeStyle(.tint), action: send)
                    .disabled(!canSend)
                    .help(session.isWorking ? "Send when the answer in progress is finished (Return)" : "Send (Return)")
            }
        }
        // The buttons' own margins: their icons line up with the text above.
        .padding(.leading, -5)
        .padding(.bottom, -3)
    }

    /// The round button that sends or stops: filled when it can be pressed.
    private func roundButton(
        _ title: String, symbol: String, iconSize: CGFloat, isOn: Bool, color: AnyShapeStyle, icon: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .bold))
                .foregroundStyle(isOn ? icon : AssistantStyle.faint)
                .frame(width: AssistantStyle.control, height: AssistantStyle.control)
                .background(isOn ? color : AnyShapeStyle(AssistantStyle.raised), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    /// What the menu offers of one provider: its models, or the way to set it up.
    @ViewBuilder private func models(of provider: AssistantProvider) -> some View {
        let models = provider == .local
            ? AssistantSession.Model.models(listed: AssistantSettings.models(in: localModels))
            : AssistantSession.Model.models(for: provider)
        if provider == .local, models.isEmpty {
            Button("Set Up a Local Server…", action: showAISettings)
        } else if [.openAI, .gemini].contains(provider), !AIKeys.shared.hasKey(account: provider.keyAccount) {
            Button("Add a Key in Settings…", action: showAISettings)
        } else {
            ForEach(models) { model in
                Toggle(model.title, isOn: Binding(
                    get: { session.model == model },
                    set: { chosen in
                        guard chosen, session.model != model else { return }
                        AssistantSettings.remember(model)
                        if let changeModel { changeModel(model) } else { session.model = model }
                    }
                ))
            }
        }
    }

    /// The model that answers, by name once Claude has said which one Default is.
    private var modelTitle: String {
        session.model == .standard ? (session.answeringModel ?? "Default") : session.model.title
    }

    /// A menu's label in the composer: dim words and a chevron.
    private func menuLabel(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
        }
        .font(AssistantStyle.small)
        .foregroundStyle(AssistantStyle.dim)
        .padding(.horizontal, 6)
        .frame(height: AssistantStyle.control)
        .contentShape(.rect)
    }

    // MARK: Suggestions

    private func suggestions(_ candidates: [AssistantMention.Candidate]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if candidates.isEmpty {
                Text("No view or patch by that name")
                    .foregroundStyle(AssistantStyle.dim)
                    .padding(.horizontal, 6)
                    .frame(height: AssistantStyle.control)
            }
            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                let isOn = index == highlighted
                Button { pick(candidate) } label: {
                    HStack(spacing: AssistantStyle.iconGap) {
                        Image(systemName: candidate.symbol)
                            .font(AssistantStyle.rowIcon)
                            .frame(width: AssistantStyle.iconColumn)
                            .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(AssistantStyle.dim))
                        Text(candidate.title).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(candidate.detail)
                            .font(AssistantStyle.tiny)
                            .lineLimit(1)
                            .foregroundStyle(isOn ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(AssistantStyle.dim))
                    }
                    .padding(.horizontal, 6)
                    .frame(height: AssistantStyle.control)
                    .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(AssistantStyle.text))
                    .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: .rect(cornerRadius: AssistantStyle.smallRadius))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { if $0 { highlighted = index } }
            }
        }
        .font(AssistantStyle.small)
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AssistantStyle.fill, in: .rect(cornerRadius: AssistantStyle.radius))
        .overlay { RoundedRectangle(cornerRadius: AssistantStyle.radius).strokeBorder(AssistantStyle.line) }
    }

    private func move(_ step: Int, among candidates: [AssistantMention.Candidate]) -> KeyPress.Result {
        guard !candidates.isEmpty else { return .ignored }
        highlighted = (highlighted + step + candidates.count) % candidates.count
        return .handled
    }

    private func pickHighlighted(_ candidates: [AssistantMention.Candidate]) -> KeyPress.Result {
        guard candidates.indices.contains(highlighted) else { return .ignored }
        pick(candidates[highlighted])
        return .handled
    }

    private func pick(_ candidate: AssistantMention.Candidate) {
        draft = AssistantMention.removingQuery(from: draft)
        if !store.assistantReferences.contains(where: { $0.target == candidate.target }) {
            store.assistantReferences.append(AssistantReference(candidate.target))
        }
        typing.wrappedValue = true
    }

    // MARK: Sending

    private func send() {
        guard canSend else { return }
        let text = draft
        draft = ""
        Task { await session.send(text) }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AssistantMediaLoader.fileTypes
        panel.allowsMultipleSelection = true
        panel.message = "Choose pictures or videos of what you want built"
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await session.attach(urls) }
    }
}

/// A reference as a small labelled capsule. A view or patch chip shows it in the graph when
/// clicked; a picture or video chip shows what will be sent.
struct AssistantChip: View {
    let chip: AssistantReference.Chip
    let store: DocumentStore
    /// Given in the composer, where a chip can be taken off again.
    var remove: (() -> Void)?

    @State private var showsPreview = false

    var body: some View {
        HStack(spacing: 2) {
            Button(action: open) {
                HStack(spacing: 5) {
                    if let data = chip.thumbnail, let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 14, height: 14)
                            .clipShape(.rect(cornerRadius: 3))
                    } else {
                        Image(systemName: chip.symbol).font(AssistantStyle.rowIcon).foregroundStyle(.tint)
                    }
                    Text(chip.title).lineLimit(1).truncationMode(.middle)
                    if case let .media(media) = chip.target, media.isVideo {
                        Text("\(media.frames.count) stills").font(AssistantStyle.tiny).foregroundStyle(AssistantStyle.dim)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if let remove {
                Button("Remove", systemImage: "xmark", action: remove)
                    .buttonStyle(AssistantIconButtonStyle(size: 16, iconSize: 8))
                    .padding(.trailing, -4)
            }
        }
        .font(AssistantStyle.small)
        .foregroundStyle(AssistantStyle.text)
        .padding(.horizontal, 7)
        .frame(height: AssistantStyle.chipHeight)
        .background(AssistantStyle.raised, in: .rect(cornerRadius: AssistantStyle.smallRadius))
        .frame(maxWidth: 190)
        .help(help)
        .popover(isPresented: $showsPreview, arrowEdge: .leading) {
            if case let .media(media) = chip.target { AssistantMediaPreview(media: media) }
        }
    }

    private var help: String {
        switch chip.target {
        case .view, .patch: "Show \(chip.title) in the patch graph"
        case let .media(media):
            media.duration.map { String(format: "%@: %.1f seconds, sent as %d stills", media.name, $0, media.frames.count) } ?? media.name
        }
    }

    private func open() {
        switch chip.target {
        case let .view(id):
            if store.document.layer(id) != nil { store.selectedLayers = [id] }
        case let .patch(id):
            store.show(id)
        case .media:
            showsPreview = true
        }
    }
}

/// What a picture or video chip stands for: the picture, or the stills taken from the video.
struct AssistantMediaPreview: View {
    let media: AssistantMedia

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if media.isVideo {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 6) {
                        ForEach(Array(media.frames.enumerated()), id: \.offset) { _, frame in
                            VStack(spacing: 3) {
                                picture(frame.data).frame(height: 220)
                                Text(String(format: "%.1f s", frame.time))
                                    .font(AssistantStyle.tiny.monospacedDigit())
                                    .foregroundStyle(AssistantStyle.dim)
                            }
                        }
                    }
                }
                .frame(maxWidth: 520)
                Text("The assistant sees these \(media.frames.count) stills, in order, with their times.")
                    .font(.caption)
                    .foregroundStyle(AssistantStyle.dim)
            } else if let frame = media.frames.first {
                picture(frame.data).frame(maxWidth: 420, maxHeight: 420)
            }
        }
        .padding(10)
    }

    @ViewBuilder private func picture(_ data: Data) -> some View {
        if let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(.rect(cornerRadius: AssistantStyle.smallRadius))
        }
    }
}

/// Lays views out left to right, starting a new row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = arrange(subviews, width: bounds.width)
        for (subview, frame) in zip(subviews, placed.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), frames)
    }
}
