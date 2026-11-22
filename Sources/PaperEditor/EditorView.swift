import PaperEngine
import PaperModel
import SwiftUI

/// The app's scenes. The app target is only an `@main` wrapper around this.
public struct EditorScene: Scene {
    public init() {
        // Only the app listens for agents; papertool and tests never get here.
        AgentService.shared.startIfEnabled()
        DeviceLink.shared.startIfEnabled()
    }

    public var body: some Scene {
        DocumentGroup(newDocument: { PaperDocument(package: DocumentPackage(document: .blank())) }) { file in
            EditorView(store: file.document.store, fileURL: file.fileURL)
        }
        .defaultSize(width: 1440, height: 900)
        .commands { EditorCommands() }

        // Presented at launch in place of the Open panel a document app would show.
        Window("Welcome to Tango", id: WelcomeView.windowID) {
            WelcomeView()
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .containerBackground(.thickMaterial, for: .window)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.presented)
        .defaultPosition(.center)
        .keyboardShortcut("1", modifiers: [.command, .shift])

        Window("Example Gallery", id: GalleryView.windowID) {
            GalleryView()
        }
        .defaultSize(width: 980, height: 760)

        Window("Extensions", id: ExtensionManagerView.windowID) {
            ExtensionManagerView()
        }
        .defaultSize(width: 900, height: 640)

        Settings {
            AgentSettingsView(service: AgentService.shared)
        }
    }
}

/// The document window, assembled from standard containers: a sidebar with the outline of
/// views or the assistant, the patch graph in the middle, and the system inspector on the
/// trailing edge.
/// The graph is the main workspace: every view is a patch in it. The canvas is an optional
/// pane above it. Tools live in the window toolbar. Only the surfaces themselves (patch
/// graph, canvas, viewer) are custom-drawn.
public struct EditorView: View {
    @Bindable var store: DocumentStore
    @Environment(\.undoManager) private var undoManager
    @Environment(\.appearsActive) private var appearsActive
    @State private var assistant: AssistantChats
    private let fileURL: URL?
    /// What is installed on this Mac; a change there changes what this document's patches do.
    private let extensions: ExtensionStore
    @State private var extensionReview: ExtensionReview?
    @State private var dismissedOffers: Set<ExtensionStore.Offer> = []

    /// What an outside agent sees this document called.
    private var documentName: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    /// `assistant` is given by `papertool`, to show conversations it has prepared.
    public init(
        store: DocumentStore, fileURL: URL? = nil, assistant: AssistantChats? = nil, extensions: ExtensionStore = .shared
    ) {
        self.store = store
        self.fileURL = fileURL
        self.extensions = extensions
        // Opus while the assistant is being tested; `.standard` leaves the choice to the account.
        _assistant = State(initialValue: assistant ?? AssistantChats(store: store, model: AssistantSettings.model()))
    }

    private func useInstalledExtensions() {
        store.setRegistry(extensions.registry(carrying: store.carriedExtensions))
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { store.showsSidebar ? .all : .detailOnly },
            set: { store.showsSidebar = $0 != .detailOnly }
        )) {
            // The views or the assistant, switched from the sidebar's part of the toolbar as
            // Xcode switches its navigators.
            Group {
                switch store.sidebarMode {
                case .views: LayerSidebar(store: store)
                case .assistant: AssistantView(chats: assistant)
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 520)
            .toolbar {
                ToolbarItem {
                    Picker("Sidebar", selection: $store.sidebarMode) {
                        Label("Views", systemImage: "list.bullet").tag(SidebarMode.views)
                        Label("Assistant", systemImage: "sparkles").tag(SidebarMode.assistant)
                    }
                    .pickerStyle(.segmented)
                    .labelStyle(.iconOnly)
                    .help("Show the views or the assistant (Option-Command-A)")
                }
                // In the place the outline's Group button has, so the switch does not move.
                if store.sidebarMode == .assistant {
                    ToolbarItem {
                        // One button, as the outline has, so the switch does not move; the chats
                        // themselves are listed above the transcript.
                        Button("New Chat", systemImage: "square.and.pencil") { assistant.newChat() }
                            .disabled(assistant.current.isEmpty)
                            .help("Start another chat (Option-Command-N). The others keep going, and the document keeps every change.")
                    }
                }
            }
        } detail: {
            VStack(spacing: 0) {
            // What the document needs that this Mac lacks, said once above the graph.
            let offers = extensions.offers(used: store.usedExtensionIDs, carried: store.carriedExtensions)
                .filter { !dismissedOffers.contains($0) }
            if !offers.isEmpty {
                ExtensionOfferBar(offers: offers, extensions: extensions) { extensionReview = $0 } dismiss: {
                    dismissedOffers.insert($0)
                }
            }
            // The patch graph, with the canvas above it when it is shown.
            VSplitView {
                if store.showsCanvas {
                    CanvasRepresentable(
                        store: store, document: store.document, selection: store.selectedLayers,
                        selectedNodes: store.selectedNodes, tool: store.tool, openView: store.openView,
                        viewerScreen: store.showsViewer ? store.viewerScreen : nil, startScreen: store.previewScreen,
                        registryRevision: store.registryRevision, fitRequest: store.canvasFitRequest
                    )
                    .surfaceLabel("Canvas")
                    .frame(minWidth: 320, maxWidth: .infinity, minHeight: 160, idealHeight: 380, maxHeight: .infinity)
                }

                PatchEditorRepresentable(
                    store: store,
                    graph: store.levelGraph,
                    selection: store.selectedNodes,
                    reveal: store.revealNode,
                    layers: store.document.screen,
                    libraryRequest: store.libraryRequest,
                    fitRequest: store.fitRequest,
                    registryRevision: store.registryRevision
                )
                .surfaceLabel(store.showsCanvas ? "Patches" : "")
                .frame(minWidth: 320, maxWidth: .infinity, minHeight: 160, idealHeight: 420, maxHeight: .infinity)

                // A shader's code stays open here while the Viewer runs it.
                if let id = store.editingShader, store.document.layer(id)?.shader != nil {
                    ShaderEditorPane(store: store, layerID: id)
                        .frame(minWidth: 320, maxWidth: .infinity, minHeight: 160, idealHeight: 320, maxHeight: .infinity)
                }
            }
            // The Viewer is a window of its own, floating over this one.
            .background(ViewerWindowBridge(
                store: store, document: store.runtimeDocument,
                restartToken: store.restartToken,
                // The Viewer floats above everything, so it steps aside for the script editor.
                shown: store.showsViewer && store.editingScript == nil,
                keys: extensions.keys
            ))
            // A paired iPhone gets what the Viewer gets.
            .background(DeviceLinkBridge(
                store: store, name: documentName, fileURL: fileURL, link: .shared
            ))
            }
        }
        .inspector(isPresented: $store.showsInspector) {
            InspectorView(store: store)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 440)
        }
        .sheet(item: $extensionReview) { review in
            ExtensionReviewSheet(review: review, extensions: extensions)
        }
        // Installing, updating or switching off an extension reaches every open document.
        .onAppear { useInstalledExtensions() }
        .onChange(of: extensions.revision) { useInstalledExtensions() }
        // Where one is: the component being edited, then the views stepped into.
        .navigationSubtitle((
            (store.scope.flatMap { store.fullDocument.component($0) }.map { ["Editing \($0.name)"] } ?? [])
                + (store.openView != nil ? [store.openPath.map(\.name).joined(separator: " › ")] : [])
        ).joined(separator: ": "))
        // Laid out as Origami lays out its toolbar: what to insert on the left beside the title,
        // how the window is arranged and what plays in the middle, the Inspector on the right.
        // The assistant's switch stays in the sidebar's part of the toolbar.
        .toolbar {
            // Going back out of a view is in the sidebar, above the outline.
            if store.scope != nil, store.openView == nil {
                ToolbarItem(placement: .navigation) {
                    Button("Done", systemImage: "chevron.backward") { store.exitComponent() }
                        .help("Finish editing this component")
                }
            }
            ToolbarItem(placement: .navigation) {
                InsertMenu(store: store)
            }
            ToolbarItemGroup(placement: .principal) {
                if store.showsCanvas {
                    Picker("Tool", selection: $store.tool) {
                        Label("Select", systemImage: "cursorarrow").tag(CanvasTool.select)
                        Label("View", systemImage: "rectangle").tag(CanvasTool.view)
                        Label("Ellipse", systemImage: "circle").tag(CanvasTool.ellipse)
                        Label("Text", systemImage: "textformat").tag(CanvasTool.text)
                    }
                    .pickerStyle(.segmented)
                    .labelStyle(.iconOnly)
                    .help("Canvas tool: Select (V), View (R), Ellipse (O), Text (T)")
                }
                Toggle("Canvas", systemImage: "rectangle.dashed", isOn: $store.showsCanvas)
                    .help("Show or hide the canvas: every screen side by side, to arrange views and draw flows between screens (Option-Command-C)")
                Button("Fit", systemImage: "arrow.up.left.and.arrow.down.right") {
                    store.requestFitPatches()
                    store.requestFitCanvas()
                }
                .help("Fit the whole graph, and every screen on the canvas, in view")
            }
            ToolbarItemGroup(placement: .principal) {
                // The screen is sized for a device; a component's root is not a screen.
                if store.scope == nil {
                    DevicePicker(store: store)
                }
                Toggle("Viewer", systemImage: "iphone", isOn: $store.showsViewer)
                    .help("Show or hide the Viewer window")
                Button("Restart", systemImage: "arrow.counterclockwise") {
                    store.restartPrototype()
                }
                .help("Restart the prototype in the Viewer")
                DeviceLinkButton(link: .shared)
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle("Inspector", systemImage: "sidebar.trailing", isOn: $store.showsInspector)
                    .help("Show or hide the Inspector")
            }
        }
        .sheet(isPresented: Binding(
            get: { store.editingScript != nil },
            set: { if !$0 { store.editingScript = nil } }
        )) {
            if let id = store.editingScript, let node = store.document.graph.node(id) {
                ScriptEditor(store: store, node: node)
            }
        }
        .onAppear {
            store.undoManager = undoManager
            OpenDocuments.shared.open(store, name: documentName)
            if appearsActive { OpenDocuments.shared.bringToFront(store) }
            // A prototype of several screens is opened where they can be seen side by side.
            if !store.screens.isEmpty { store.showsCanvas = true }
        }
        .onDisappear { OpenDocuments.shared.close(store) }
        .onChange(of: documentName) { _, name in OpenDocuments.shared.open(store, name: name) }
        .onChange(of: appearsActive) { _, active in
            if active { OpenDocuments.shared.bringToFront(store) }
        }
        .onChange(of: undoManager) { _, manager in store.undoManager = manager }
        .focusedSceneValue(\.documentStore, store)
        .focusedSceneValue(\.assistantChats, assistant)
    }
}

/// Edits the script of a JavaScript patch. Problems show as you type; Save applies it.
struct ScriptEditor: View {
    let store: DocumentStore
    let node: PatchNode
    @State private var source = ""

    var body: some View {
        let interface = Script.interface(of: source)
        VStack(alignment: .leading, spacing: 12) {
            Text(store.title(for: node)).font(.headline)
            TextEditor(text: $source)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .frame(minWidth: 560, minHeight: 340)
                .border(.separator)
            if let error = interface.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else {
                let inputs = interface.ports.inputs.map(\.name).joined(separator: ", ")
                let outputs = interface.ports.outputs.map(\.name).joined(separator: ", ")
                Label("In: \(inputs.isEmpty ? "none" : inputs)   Out: \(outputs.isEmpty ? "none" : outputs)", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { store.editingScript = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    store.setScript(source, node: node.id)
                    store.editingScript = nil
                }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .onAppear { source = node.script ?? Script.template }
    }
}

/// The toolbar's Insert button: a click opens the Patch Library, its arrow lists views,
/// components and a comment.
struct InsertMenu: View {
    let store: DocumentStore

    var body: some View {
        Menu {
            AddViewMenu(store: store)
            ComponentMenu(store: store)
            Button("Screen", systemImage: screenSymbol) {
                store.addScreen()
                store.requestFitCanvas()
            }
            .disabled(store.scope != nil)
            Divider()
            Button("Patch Library…", systemImage: "plus.square.on.square") { store.requestPatchLibrary() }
            Button("Comment", systemImage: "text.bubble") { store.addComment(at: store.freePatchPosition()) }
        } label: {
            Label("Insert", systemImage: "plus")
        } primaryAction: {
            store.requestPatchLibrary()
        }
        .help("Find and add a view or a patch (Option-Space); the arrow lists views, components and a comment")
    }
}

/// Adds a view inside the selected container: the same list the Patch Library starts with.
struct AddViewMenu: View {
    let store: DocumentStore

    var body: some View {
        Menu("Add View", systemImage: "plus.rectangle.on.rectangle") {
            ForEach(LibraryItem.views) { item in
                if case let .view(type) = item {
                    Button(type.displayName, systemImage: type.symbolName) { store.addView(type) }
                }
            }
            // The views extensions add, under the name of each.
            ForEach(store.registry.extensions.available) { package in
                let views = store.registry.viewLibrary.filter { $0.origin.id == package.id }
                if !views.isEmpty {
                    Section(package.name) {
                        ForEach(views) { view in
                            Button(view.name, systemImage: view.symbolName) { store.addExtensionView(view) }
                        }
                    }
                }
            }
        }
        .help("Add a view inside \(store.containerForNewViews.name)")
    }
}

/// The toolbar's component picker: the prebuilt iOS controls, the document's own
/// components, and making a new one from the selection.
struct ComponentMenu: View {
    let store: DocumentStore

    var body: some View {
        Menu("Components", systemImage: "puzzlepiece.extension") {
            // The iOS controls, then what each extension ships.
            // The iOS shelf in its groups, each with the templates that belong to it.
            Section("iOS") {
                ForEach(ComponentLibrary.groups) { group in
                    Menu(group.name) {
                        ForEach(group.components) { component in
                            Button(component.name) { store.insertComponent(component) }
                                .disabled(!store.canInsert(component))
                        }
                        if !group.templates.isEmpty {
                            Divider()
                            ForEach(group.templates) { template in
                                Button(template.name) { store.insertTemplate(template) }
                            }
                        }
                    }
                }
            }
            // What each extension ships.
            ForEach(store.registry.shelves) { shelf in
                Section(shelf.name) {
                    ForEach(shelf.components) { component in
                        Button(component.name) { store.insertComponent(component) }
                            .disabled(!store.canInsert(component))
                    }
                }
            }
            let own = store.fullDocument.components.filter { $0.library == nil }
            if !own.isEmpty {
                Section("This Document") {
                    ForEach(own) { component in
                        Button(component.name) { store.insertComponent(component) }
                            .disabled(!store.canInsert(component))
                    }
                }
            }
            Divider()
            Button("Create Component from Selection") { store.createComponentFromSelection() }
                .disabled(store.selectedLayers.subtracting([store.document.screen.id]).isEmpty)
        }
        .help("Add a component: iOS controls, those of extensions, or your own")
    }
}

private struct SurfaceLabel: ViewModifier {
    let title: String

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if !title.isEmpty {
                Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassEffect()
                .padding(10)
                .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    /// A small Liquid Glass caption naming a working surface.
    func surfaceLabel(_ title: String) -> some View {
        modifier(SurfaceLabel(title: title))
    }
}

// MARK: - Menu commands

struct DocumentStoreKey: FocusedValueKey {
    typealias Value = DocumentStore
}

extension FocusedValues {
    var documentStore: DocumentStore? {
        get { self[DocumentStoreKey.self] }
        set { self[DocumentStoreKey.self] = newValue }
    }
}

struct AssistantChatsKey: FocusedValueKey {
    typealias Value = AssistantChats
}

extension FocusedValues {
    var assistantChats: AssistantChats? {
        get { self[AssistantChatsKey.self] }
        set { self[AssistantChatsKey.self] = newValue }
    }
}

struct EditorCommands: Commands {
    @FocusedValue(\.documentStore) private var focusedStore
    @FocusedValue(\.assistantChats) private var chats
    @Environment(\.openWindow) private var openWindow
    @AppStorage(ViewerView.recordsTouchesKey) private var recordsTouches = true
    @AppStorage(ViewerView.showsAssistantTouchesKey) private var showsAssistantTouches = true

    /// The document the commands act on: the focused one, or while the Viewer has focus,
    /// the one it belongs to.
    private var store: DocumentStore? { focusedStore ?? DocumentStore.current }

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Extensions…") { openWindow(id: ExtensionManagerView.windowID) }
                .keyboardShortcut("e", modifiers: [.command, .option])
        }
        CommandGroup(after: .newItem) {
            Button("New from Gallery…") { openWindow(id: GalleryView.windowID) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .saveItem) {
            Divider()
            Button("Mark as Starting Point") { store?.markBaseline() }
                .disabled(store == nil)
                .help("Remember the document as it is now, to see later what changed")
            Button("Copy Changes for an Agent") { store.map(SketchChanges.copy) }
                .disabled(store?.fullDocument.sketch == nil)
                .help("Copy what changed since the starting point, to paste into a coding agent")
        }
        CommandGroup(after: .sidebar) {
            Button(store?.showsCanvas == true ? "Hide Canvas" : "Show Canvas") { store?.showsCanvas.toggle() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(store == nil)
            Button(store?.showsSidebar == true && store?.sidebarMode == .assistant ? "Show Views" : "Show Assistant") {
                store?.toggleAssistant()
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
            .disabled(store == nil)
            Button("Add Selection to Assistant") { store?.addToAssistant() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(store?.selectedNodes.isEmpty != false)
            Divider()
            Button("New Chat") {
                chats?.newChat()
                store?.sidebarMode = .assistant
                store?.showsSidebar = true
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(chats == nil)
            // The list of chats is in the sidebar's menu: the menu bar is not drawn again
            // when chats come and go, so it has only what needs no list.
            Button("Show Next Chat") { chats?.step(by: 1) }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .disabled(chats == nil)
            Button("Show Previous Chat") { chats?.step(by: -1) }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .disabled(chats == nil)
            Button("Delete Chat") { chats.map { $0.delete($0.currentID) } }
                .disabled(chats == nil)
        }
        CommandMenu("Insert") {
            ForEach(LibraryItem.views) { item in
                if case let .view(type) = item {
                    Button("Add \(type.displayName)") { store?.addView(type) }
                }
            }
            .disabled(store == nil)
            if let store, !store.registry.viewLibrary.isEmpty {
                Menu("Add from an Extension") {
                    ForEach(store.registry.viewLibrary) { view in
                        Button(view.name) { store.addExtensionView(view) }
                    }
                }
            }
            Divider()
            Menu("Change To") {
                ForEach(DocumentStore.convertibleTypes, id: \.self) { type in
                    Button(type.displayName) {
                        if let store, let layer = store.selectedLayer { store.convert(layer.id, to: type) }
                    }
                }
            }
            .disabled(store?.selectedLayer?.kind != .view || store?.selectedLayer?.id == store?.document.screen.id)
            Button("Group Selection") { store?.groupSelectedLayers() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(store == nil)
            Divider()
            Button("Step Into View") {
                if let store, let layer = store.selectedLayer { store.open(layer.id) }
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(store?.selectedLayer.map { $0.kind.canHaveChildren && $0.component == nil && $0.id != store?.openContainer.id } != true)
            Button("Step Out") { store?.closeView() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(store?.openView == nil)
        }
        CommandMenu("Component") {
            ForEach(ComponentLibrary.groups) { group in
                Menu("Add iOS \(group.name)") {
                    ForEach(group.components) { component in
                        Button(component.name) { store?.insertComponent(component) }
                    }
                    if !group.templates.isEmpty {
                        Divider()
                        ForEach(group.templates) { template in
                            Button(template.name) { store?.insertTemplate(template) }
                        }
                    }
                }
                .disabled(store == nil)
            }
            if let store {
                ForEach(store.registry.shelves) { shelf in
                    Menu("Add \(shelf.name) Component") {
                        ForEach(shelf.components) { component in
                            Button(component.name) { store.insertComponent(component) }
                        }
                    }
                }
            }
            Button("Create Component from Selection") { store?.createComponentFromSelection() }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .disabled(store == nil)
            Divider()
            Button("Edit Selected Component") {
                if let use = store?.selectedLayer?.component { store?.enterComponent(use.id) }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(store?.selectedLayer?.component == nil)
            Button("Done Editing Component") { store?.exitComponent() }
                .keyboardShortcut(.escape, modifiers: .command)
                .disabled(store?.scope == nil)
        }
        CommandMenu("Patch") {
            Button("Library…") { store?.requestPatchLibrary() }
                .keyboardShortcut(.space, modifiers: .option)
                .disabled(store == nil)
            Button("Add Comment") {
                if let store { store.addComment(at: store.freePatchPosition()) }
            }
            .disabled(store == nil)
            Button("Edit Script…") { store?.editingScript = selectedScript }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(selectedScript == nil)
            Button("Edit Shader…") { store?.editingShader = selectedShader }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(selectedShader == nil)
            Divider()
            Button("Show All Patches") { store?.requestFitPatches() }
                .disabled(store == nil)
        }
        CommandMenu("Prototype") {
            Button("Restart") { store?.restartPrototype() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store == nil)
            Button(store?.showsViewer == false ? "Show Viewer" : "Hide Viewer") { store?.showsViewer.toggle() }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(store == nil)
            Divider()
            Toggle("Show Touches in Recordings", isOn: $recordsTouches)
            Toggle("Show Assistant Using the Prototype", isOn: $showsAssistantTouches)
        }
    }

    /// The selected view, when it is a single shader view.
    private var selectedShader: LayerID? {
        guard let store, let layer = store.selectedLayer, layer.shader != nil else { return nil }
        return layer.id
    }

    /// The selected patch, when it is a single JavaScript patch.
    private var selectedScript: NodeID? {
        guard let store, store.selectedNodes.count == 1, let id = store.selectedNodes.first,
              store.document.graph.node(id)?.kind == PatchKind.javascript
        else { return nil }
        return id
    }

}

/// Sizes the screen for a device. A size that matches no template shows as Custom.
struct DevicePicker: View {
    let store: DocumentStore

    var body: some View {
        let size = store.document.screen.value(.size).sizeValue
        let current = DeviceTemplate.matching(size)
        Picker("Device", selection: Binding(
            get: { current },
            set: { if let template = $0 { store.setDevice(template) } }
        )) {
            ForEach(DeviceTemplate.all) { template in
                Text(template.name).tag(Optional(template))
            }
            if current == nil {
                Divider()
                Text("Custom \(size.width.whole) × \(size.height.whole)").tag(DeviceTemplate?.none)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("The device the screen is sized for")
    }
}
