import PaperModel
import SwiftUI

extension ViewType {
    var symbolName: String {
        switch self {
        case .screen: "iphone"
        case .view: "rectangle"
        case .stack: "rectangle.split.3x1"
        case .grid: "square.grid.2x2"
        case .scrollView: "scroll"
        case .ellipse: "circle"
        case .text: "textformat"
        case .image: "photo"
        case .symbol: "star"
        case .camera: "camera"
        case .video: "play.rectangle"
        case .textField: "character.cursor.ibeam"
        case .component: "puzzlepiece.extension"
        case .shader: "sparkles.rectangle.stack"
        case .custom: "paintbrush.pointed"
        }
    }
}

/// The outline of views: a standard sidebar list with disclosure groups. It is where views
/// are nested and ordered; each row's Touch menu adds an interaction for that view.
struct LayerSidebar: View {
    @Bindable var store: DocumentStore
    @State private var renaming: LayerID?
    @State private var rebuilds = 0

    var body: some View {
        List(selection: $store.selectedLayers) {
            if let scope = store.scope, let component = store.fullDocument.component(scope) {
                Section("Editing Component") {
                    Button {
                        store.exitComponent()
                    } label: {
                        Label("Done Editing \(component.name)", systemImage: "chevron.backward")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .selectionDisabled()
                    .help("Go back to where this component is used")
                }
            }
            // The outline follows the graph, one level at a time: the views directly in the
            // open view. What is nested in one of them is seen by stepping into it; the
            // header above goes back out.
            Section(store.openView == nil ? "Views" : "") {
                let open = store.openContainer
                if store.openView == nil {
                    LayerRow(store: store, layer: open, renaming: $renaming).tag(open.id)
                }
                // With screens, what is beside them in the device floats over all of them.
                let floating = open.children.filter { !$0.isPage }
                ForEach(floating.reversed()) { child in
                    LayerRow(store: store, layer: child, renaming: $renaming).tag(child.id)
                }
                // Dragging a row reorders it among its siblings. The list shows the top
                // view first, so list positions run opposite to the stacking order.
                .onMove { source, destination in
                    guard let from = source.first else { return }
                    let count = floating.count
                    let moved = floating[count - 1 - from].id
                    // Before the view that ends up above it, or on top of everything.
                    let above = count - destination < count ? floating[count - destination].id : nil
                    let index = above.flatMap { id in open.children.firstIndex { $0.id == id } } ?? open.children.count
                    store.moveLayer(moved, in: open.id, to: index)
                }
            }
            // The screens, in the order they have on the Canvas: the first is where the
            // prototype starts. Dragging one changes that order.
            if store.openView == nil, store.scope == nil, !store.screens.isEmpty {
                let screens = store.screens
                Section("Screens") {
                    ForEach(screens) { screen in
                        LayerRow(store: store, layer: screen, renaming: $renaming).tag(screen.id)
                    }
                    .onMove { source, destination in
                        guard let from = source.first else { return }
                        store.moveScreen(screens[from].id, to: destination > from ? destination - 1 : destination)
                    }
                }
            }
            if !store.fullDocument.components.isEmpty {
                Section("Components") {
                    ForEach(store.fullDocument.components) { component in
                        ComponentRow(store: store, component: component)
                            .selectionDisabled()
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // Several layers arriving at once at different depths (an agent's batch, a paste,
        // an undo) leaves the outline drawn wrong: rows on top of each other and out of
        // order. A fresh list is right, and what is open or selected is kept outside it.
        .id("\(rebuilds) \(store.openView?.uuidString ?? "")")
        .safeAreaInset(edge: .top, spacing: 0) {
            if store.openView != nil {
                let open = store.openContainer
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Button("Back", systemImage: "chevron.backward") { store.closeView() }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Go back out to \(store.openPath.dropLast().last?.name ?? "the screen") (Command-Up Arrow)")
                        Label(open.name, systemImage: LayerRow.symbol(for: open))
                            .font(.headline)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    Divider()
                }
            }
        }
        .onChange(of: store.document.screen.flattened.map(\.id)) { old, new in
            if Set(old).symmetricDifference(new).count > 1 { rebuilds += 1 }
        }
        .onDeleteCommand { store.deleteSelectedLayers() }
        .toolbar {
            ToolbarItem {
                Button("Group", systemImage: "folder.badge.plus") {
                    store.groupSelectedLayers()
                }
                .disabled(store.selectedLayers.subtracting([store.document.screen.id]).isEmpty)
                .help("Put the selected views in a new view")
            }
        }
    }
}

/// A component the document has. The buttons place another use of it or open it for editing.
struct ComponentRow: View {
    let store: DocumentStore
    let component: ComponentDefinition
    @State private var renaming = false
    @State private var draftName = ""

    var body: some View {
        let uses = store.useCount(of: component.id)
        HStack {
            Label(component.name, systemImage: "puzzlepiece.extension")
                .foregroundStyle(store.scope == component.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            Spacer()
            Button("Add", systemImage: "plus") { store.insertComponent(component) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(!store.canInsert(component))
                .help("Add \(component.name) to the screen")
            Button("Edit", systemImage: "square.and.pencil") { store.enterComponent(component.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(store.scopePath.contains(component.id))
                .help("Edit the inside of \(component.name)")
        }
        .contextMenu {
            Button("Add to Screen") { store.insertComponent(component) }.disabled(!store.canInsert(component))
            Button("Edit Component") { store.enterComponent(component.id) }
            Button("Rename…") {
                draftName = component.name
                renaming = true
            }
            Divider()
            Button("Delete", role: .destructive) { store.deleteComponent(component.id) }
                .disabled(uses > 0 || store.scopePath.contains(component.id))
        }
        .alert("Rename Component", isPresented: $renaming) {
            TextField("Name", text: $draftName)
            Button("Rename") { store.renameComponent(component.id, to: draftName) }
            Button("Cancel", role: .cancel) {}
        }
        .help(component.summary ?? (uses == 1 ? "Used once" : "Used \(uses) times"))
    }
}

struct LayerRow: View {
    let store: DocumentStore
    let layer: Layer
    @Binding var renaming: LayerID?
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    /// Whether this row is a view with views in it, which one steps into to see.
    private var holdsViews: Bool { !layer.children.isEmpty && layer.id != store.openContainer.id }

    /// A view with views in it is shown as a folder, whatever kind of container it is.
    private var symbolName: String { LayerRow.symbol(for: layer, holdsViews: holdsViews) }

    /// A screen is a page; the device that holds screens a phone; a view with views in it a
    /// folder, whatever kind of container it is.
    static func symbol(for layer: Layer, holdsViews: Bool = false) -> String {
        if layer.isPage { return screenSymbol }
        if layer.kind == .screen { return "iphone" }
        return holdsViews ? "folder" : layer.type.symbolName
    }

    private var hasInteraction: Bool {
        store.document.graph.nodes.contains { DocumentStore.touchPatchKinds.contains($0.kind) && $0.layerID == layer.id }
    }

    var body: some View {
        HStack {
            if renaming == layer.id {
                Label {
                    TextField("Name", text: $draftName)
                        .focused($nameFocused)
                        .onSubmit(commitRename)
                        .onExitCommand { renaming = nil }
                        .onAppear {
                            draftName = layer.name
                            nameFocused = true
                        }
                        .onChange(of: nameFocused) { _, focused in
                            if !focused { commitRename() }
                        }
                } icon: {
                    Image(systemName: symbolName)
                }
            } else {
                // The screen the Viewer starts on says so after its name, in the row's own
                // line, so the controls at the end of every row stay in one column.
                let starts = layer.isPage && layer.id == store.startScreen
                Label {
                    Text("\(layer.name)\(Text(starts ? "  Start" : "").font(.caption).foregroundColor(.secondary))")
                } icon: {
                    Image(systemName: symbolName)
                }
                    .help(starts ? "Screen: the Viewer starts here" : layer.isPage ? "Screen: fills the device" : holdsViews ? "\(layer.type.displayName) with \(layer.children.count == 1 ? "1 view" : "\(layer.children.count) views") in it" : layer.type.displayName)
            }
            Spacer()
            if holdsViews, layer.component == nil {
                Button("Step Into \(layer.name)", systemImage: "chevron.forward") { store.open(layer.id) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Show the views in \(layer.name)")
            }
            if layer.kind != .screen {
                Menu {
                    if layer.kind == .textField {
                        Button("Text Input", systemImage: "character.cursor.ibeam") { store.addTouchPatch("textInput", for: layer.id) }
                        Divider()
                    }
                    if layer.kind == .video {
                        Button("Video Time", systemImage: "play.rectangle") { store.addTouchPatch(PatchKind.videoTime, for: layer.id) }
                        Divider()
                    }
                    Button("Interaction", systemImage: "hand.tap") { store.addInteraction(for: layer.id) }
                    Divider()
                    Button("Tap", systemImage: "hand.point.up.left") { store.addTouchPatch(PatchKind.tap, for: layer.id) }
                    Button("Long Press", systemImage: "hand.raised") { store.addTouchPatch(PatchKind.longPress, for: layer.id) }
                    Button("Pan", systemImage: "arrow.up.and.down.and.arrow.left.and.right") { store.addTouchPatch(PatchKind.pan, for: layer.id) }
                    Button("Swipe", systemImage: "hand.draw") { store.addTouchPatch(PatchKind.swipe, for: layer.id) }
                    Button("Pinch", systemImage: "arrow.up.left.and.arrow.down.right") { store.addTouchPatch(PatchKind.pinch, for: layer.id) }
                    Button("Rotation", systemImage: "rotate.right") { store.addTouchPatch(PatchKind.rotation, for: layer.id) }
                    Divider()
                    Button("Hover", systemImage: "cursorarrow.rays") { store.addTouchPatch("hover", for: layer.id) }
                } label: {
                    Image(systemName: hasInteraction ? "hand.tap.fill" : "hand.tap")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(hasInteraction ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .help("Touch: add an interaction for this view")
            }
        }
        .contextMenu {
            if layer.kind != .screen {
                Button("Rename") { renaming = layer.id }
                if let use = layer.component {
                    Button("Edit Component") { store.enterComponent(use.id) }
                    Button("Show Component Patch") { store.revealComponentPatch(for: layer.id) }
                }
                Button("Add to Assistant") {
                    if !store.selectedLayers.contains(layer.id) { store.selectedLayers = [layer.id] }
                    store.addToAssistant()
                }
                Button("Duplicate") {
                    if !store.selectedLayers.contains(layer.id) { store.selectedLayers = [layer.id] }
                    store.duplicateSelectedLayers()
                }
                Button("Create Component") {
                    if !store.selectedLayers.contains(layer.id) { store.selectedLayers = [layer.id] }
                    store.createComponentFromSelection()
                }
                if layer.isPage {
                    if store.previewScreen == layer.id {
                        Button("Preview from the Start") { store.preview(from: nil) }
                    } else {
                        Button("Preview from Here") { store.preview(from: layer.id) }
                    }
                }
                let moves = store.screenMoves(for: layer.id)
                if !moves.screens.isEmpty || moves.everyScreen {
                    Menu("Move To") {
                        if moves.everyScreen { Button("Every Screen") { store.move(layer.id, toScreen: nil) } }
                        if moves.everyScreen, !moves.screens.isEmpty { Divider() }
                        ForEach(moves.screens) { screen in
                            Button(screen.name) { store.move(layer.id, toScreen: screen.id) }
                        }
                    }
                }
                // A plain view directly in the root can be one of the prototype's screens.
                if store.scope == nil, layer.kind == .view, store.document.screen.children.contains(where: { $0.id == layer.id }) {
                    Button(layer.isPage ? "Make Plain View" : "Make Screen") { store.setScreen(layer.id, !layer.isPage) }
                }
                Menu("Touch") {
                    if layer.kind == .textField {
                        Button("Text Input") { store.addTouchPatch("textInput", for: layer.id) }
                        Divider()
                    }
                    if layer.kind == .video {
                        Button("Video Time") { store.addTouchPatch(PatchKind.videoTime, for: layer.id) }
                        Divider()
                    }
                    Button("Interaction") { store.addInteraction(for: layer.id) }
                    Divider()
                    Button("Tap") { store.addTouchPatch(PatchKind.tap, for: layer.id) }
                    Button("Long Press") { store.addTouchPatch(PatchKind.longPress, for: layer.id) }
                    Button("Pan") { store.addTouchPatch(PatchKind.pan, for: layer.id) }
                    Button("Swipe") { store.addTouchPatch(PatchKind.swipe, for: layer.id) }
                    Button("Pinch") { store.addTouchPatch(PatchKind.pinch, for: layer.id) }
                    Button("Rotation") { store.addTouchPatch(PatchKind.rotation, for: layer.id) }
                    Divider()
                    Button("Hover") { store.addTouchPatch("hover", for: layer.id) }
                }
                Divider()
                Button("Bring Forward") { store.reorderLayer(layer.id, by: 1) }
                Button("Send Backward") { store.reorderLayer(layer.id, by: -1) }
                Divider()
                Button("Group Selection") {
                    if !store.selectedLayers.contains(layer.id) { store.selectedLayers = [layer.id] }
                    store.groupSelectedLayers()
                }
                if layer.kind.canHaveChildren, layer.component == nil {
                    Button("Step Into in Graph") { store.open(layer.id) }
                        .disabled(store.openContainer.id == layer.id)
                }
                if layer.kind == .view {
                    Menu("Change To") {
                        ForEach(DocumentStore.convertibleTypes, id: \.self) { type in
                            Button(type.displayName) { store.convert(layer.id, to: type) }
                                .disabled(layer.type == type)
                        }
                    }
                    if !layer.children.isEmpty {
                        Button("Ungroup") { store.ungroup(layer.id) }
                    }
                }
                Divider()
                Button("Delete", role: .destructive) {
                    if !store.selectedLayers.contains(layer.id) { store.selectedLayers = [layer.id] }
                    store.deleteSelectedLayers()
                }
            }
        }
    }

    private func commitRename() {
        guard renaming == layer.id else { return }
        store.renameLayer(layer.id, to: draftName)
        renaming = nil
    }
}
