import Foundation
import Observation
import PaperEngine
import PaperModel

public enum CanvasTool: String, CaseIterable, Sendable {
    case select
    case view
    case ellipse
    case text

    var layerKind: LayerKind? {
        switch self {
        case .select: nil
        case .view: .view
        case .ellipse: .ellipse
        case .text: .text
        }
    }
}

/// What the leading sidebar of the document window shows: the outline of views or the
/// assistant's chat, switched like Xcode's navigators.
public enum SidebarMode: Sendable, Hashable {
    case views
    case assistant
}

/// The single owner of an open document. Every edit goes through `apply` (or the
/// interactive variants for drags), which is what makes undo and live preview uniform.
@Observable
public final class DocumentStore {
    /// The store of the document window worked in most recently. Menu commands fall back
    /// to it when the focused window is one that has no document of its own (the Viewer).
    public nonisolated(unsafe) static weak var current: DocumentStore?

    /// The whole document, as saved.
    public private(set) var fullDocument: Document {
        didSet {
            if oldValue.components != fullDocument.components { registryCache = nil }
            onPackageChange?(package)
            scheduleWebAssets()
        }
    }

    /// The components being edited, outermost first. Empty when editing the document itself.
    public private(set) var scopePath: [ComponentID] = [] {
        didSet { syncRuntimeScope() }
    }

    /// The component whose inside is being edited, if any.
    public var scope: ComponentID? { scopePath.last }

    /// What the editor is showing and changing: the document, or the inside of the component
    /// being edited presented as a document of its own (its root layer as the screen, its
    /// patches as the graph). All editing code works on this, so it works inside components.
    public var document: Document {
        scope.flatMap { fullDocument.inside(of: $0) } ?? fullDocument
    }

    public var assets: [String: Data] {
        didSet {
            // Fonts the document carries are set as themselves before anything is laid out.
            FontBook.register(assets: assets)
            onPackageChange?(package)
        }
    }

    /// The fetched fonts and icons each Viewer or Canvas renderer drew in its last render,
    /// which the document keeps though nothing it stores names them (a cable chose them).
    /// Each report replaces that renderer's last, so what is no longer drawn can go.
    @ObservationIgnored var drawnWebAssets: [ObjectIdentifier: Set<String>] = [:]
    /// Every web asset seen in use this session. Only these are ever let go: a file the
    /// document came with that nothing here has asked for yet (one a script picks) stays.
    @ObservationIgnored var usedWebAssets: Set<String> = []
    @ObservationIgnored var webAssetsScheduled = false
    @ObservationIgnored var webAssetObserver: NSObjectProtocol?
    /// Whether this store fetches what its document uses and keeps it. Off for stores that
    /// only make pictures, and in tests.
    @ObservationIgnored public var keepsWebAssets = false {
        didSet { if keepsWebAssets { startKeepingWebAssets() } }
    }

    /// Called with the new contents after every change, for saving.
    @ObservationIgnored public var onPackageChange: (@Sendable (DocumentPackage) -> Void)?
    /// The selected patches. A view is a patch, so this is the one selection there is: the
    /// outline, the canvas and the graph all show it.
    public var selectedNodes: Set<NodeID> = []
    /// The selected views: those whose patch is selected. Setting it selects those views'
    /// patches (and nothing else), and brings a single one into view in the graph.
    public var selectedLayers: Set<LayerID> {
        get {
            guard !selectedNodes.isEmpty else { return [] }
            return Set(document.graph.nodes.lazy
                .filter { $0.kind == PatchKind.view && self.selectedNodes.contains($0.id) }
                .compactMap(\.layerID))
        }
        set {
            guard newValue != selectedLayers else { return }
            let document = self.document
            let views = document.graph.nodes.filter { $0.kind == PatchKind.view && $0.layerID.map(newValue.contains) == true }
            // The graph goes to where these views' patches are, if they are not in sight.
            if !views.isEmpty, !views.allSatisfy({ document.shows($0, in: openContainer) }) {
                open(document.level(showing: Set(views.compactMap(\.layerID))))
            }
            selectedNodes = Set(views.map(\.id))
            if views.count == 1 { revealNode = views[0].id }
        }
    }
    /// The view whose level of the graph is open: the patches of the views directly in it
    /// and the patches kept there, not its own patch. nil is the screen. Stepping into a view
    /// (a double-click on its patch) opens it; new views and patches then go inside it.
    public private(set) var openView: LayerID?

    /// The container whose level is open: the open view, or the screen.
    public var openContainer: Layer { document.container(openView) }

    /// What the Patch Editor shows: the open level of the graph.
    public var levelGraph: Graph { document.levelGraph(of: openView) }

    /// From the screen down to the open view, for showing where one is.
    public var openPath: [Layer] { document.screen.path(to: openContainer.id) }

    /// Opens a view's level of the graph. Only a view that can hold others has one.
    public func open(_ id: LayerID?) {
        let target = document.container(id).id
        let next: LayerID? = target == document.screen.id ? nil : target
        guard next != openView else { return }
        openView = next
        // What is selected stays selected if it is still in sight.
        let shown = Set(levelGraph.nodes.map(\.id))
        if !selectedNodes.isSubset(of: shown) { selectedNodes.formIntersection(shown) }
        fitRequest += 1
    }

    /// Goes back out to the view the open one is in.
    public func closeView() {
        guard openView != nil else { return }
        open(document.screen.parent(of: openContainer.id)?.id)
    }

    /// Selects a patch wherever it is, opening its level, and scrolls to it.
    public func show(_ id: NodeID) {
        guard let node = document.graph.node(id) else { return }
        if !document.shows(node, in: openContainer) {
            open(node.layerID.map { document.level(showing: [$0]) } ?? node.home)
        }
        selectedNodes = [id]
        revealNode = id
    }

    /// Whether the canvas is shown above the patch graph.
    public var showsCanvas = UserDefaults.standard.bool(forKey: DocumentStore.showsCanvasKey) {
        didSet { UserDefaults.standard.set(showsCanvas, forKey: DocumentStore.showsCanvasKey) }
    }
    public static let showsCanvasKey = "showsCanvas"
    public var tool: CanvasTool = .select
    /// Whether the floating Viewer window is open.
    public var showsViewer = true
    /// Whether the Viewer is being recorded.
    public var isRecording = false
    /// The JavaScript patch whose script is open for editing.
    public var editingScript: NodeID?
    /// The shader view whose code is open under the patch graph.
    public var editingShader: LayerID?
    /// Whether the leading sidebar is open, and whether it shows the views or the assistant.
    public var showsSidebar = true
    public var sidebarMode: SidebarMode = .views
    /// Whether the Inspector, on the trailing edge, is open.
    public var showsInspector = true
    /// What the person has pointed the assistant at for their next message: views, patches,
    /// pictures and videos. The assistant's composer shows them and sends them.
    public var assistantReferences: [AssistantReference] = []
    /// The refs agents gave what they made, kept while the document is open so a later batch
    /// can name what an earlier one made. Ids only; a ref whose thing is gone is ignored.
    @ObservationIgnored public var agentRefs = AgentRefs()
    @ObservationIgnored private var transactionHolds = 0
    @ObservationIgnored private var holdsOwnTransaction = false
    /// Bumped to ask the assistant's composer to take the keyboard.
    public private(set) var assistantFocusRequest = 0
    public func requestAssistantFocus() { assistantFocusRequest += 1 }

    /// Set by the Viewer: plays steps on the prototype for the person to watch.
    @ObservationIgnored var onReplay: (([ViewerSnapshot.Step], LayerID?) -> Void)?

    /// Shows in the Viewer what an agent just did to its own copy of the prototype. Only
    /// when there is something to watch: the Viewer is open, the setting is on, and the
    /// steps touch the prototype (a look alone would only start it over under the person).
    /// `from` is the screen the agent's run started on; nil is the first.
    public func replayInViewer(_ steps: [ViewerSnapshot.Step], from start: LayerID? = nil) {
        let touches = steps.contains { step in
            switch step {
            case .wait, .look: false
            default: true
            }
        }
        guard touches, showsViewer, ViewerView.showsAssistantTouches else { return }
        onReplay?(steps, start)
    }

    /// Bumped a few times a second while the prototype runs, so views showing live values refresh.
    public private(set) var liveTick = 0
    /// Bumped to ask the Viewer to start the prototype over.
    public private(set) var restartToken = 0
    /// Bumped to ask the Patch Editor to open the Patch Library.
    public private(set) var libraryRequest = 0
    /// Bumped to ask the Patch Editor to fit the whole graph in view.
    public private(set) var fitRequest = 0
    /// Set to ask the Patch Editor to scroll a patch into view.
    public var revealNode: NodeID?
    /// The Inspector property a dragged cable is hovering over.
    public var cableDropProperty: ViewInput?

    @ObservationIgnored private var baseRegistry: PatchRegistry
    @ObservationIgnored private var registryCache: PatchRegistry?
    /// Counts changes of the patch definitions themselves, as when an extension is
    /// installed or switched off, so what shows them is drawn again.
    public private(set) var registryRevision = 0
    /// Tells the Viewer that the definitions changed.
    @ObservationIgnored var onRegistryChange: (() -> Void)?
    /// The patch definitions, plus the ports of this document's components.
    public var registry: PatchRegistry {
        _ = registryRevision
        if let registryCache { return registryCache }
        let built = baseRegistry.with(components: fullDocument.components)
        registryCache = built
        return built
    }

    @ObservationIgnored public var undoManager: UndoManager?
    /// The running prototype, owned by the Viewer.
    @ObservationIgnored public weak var runtime: Runtime? {
        didSet { syncRuntimeScope() }
    }
    @ObservationIgnored private var frameObservers: [ObjectIdentifier: () -> Void] = [:]
    @ObservationIgnored private var framesSinceLiveTick = 0
    @ObservationIgnored private var interactiveBase: Document?
    @ObservationIgnored private var transactionBase: Document?
    @ObservationIgnored private var pendingEnd: Task<Void, Never>?
    @ObservationIgnored private var splitsNextUndo = false
    @ObservationIgnored var propertyDropTargets: [ViewInput: () -> CGRect?] = [:]

    public init(package: DocumentPackage = DocumentPackage(), registry: PatchRegistry = .standard) {
        var document = package.document
        document.normalize(measure: registry.with(components: document.components).height)
        registry.settlePublished(in: &document)
        self.fullDocument = document
        self.assets = package.assets
        self.baseRegistry = registry
        self.copies = package.extensions
        FontBook.register(assets: package.assets)
        remember(registry.extensions)
    }

    /// The best copy known of each extension, by id: the one the document came with, or
    /// the installed one, which takes its place. Kept when an extension is removed from
    /// this Mac, so a document that uses it goes on carrying it.
    @ObservationIgnored private var copies: [String: [String: Data]]

    private func remember(_ set: ExtensionSet) {
        for member in set.members where member.isAvailable {
            let id = member.package.id
            // A document made with a newer version than is installed here goes on
            // carrying that one, so saving it on this Mac does not take it back a version.
            if let files = copies[id], let carried = try? PaperExtension(files: files), carried.id == id,
               carried.version > member.package.version { continue }
            copies[id] = member.package.files
        }
        copiesRevision += 1
    }

    /// The document as it is saved, with a copy of each extension it uses.
    public var package: DocumentPackage {
        let used = usedExtensionIDs
        return DocumentPackage(document: fullDocument, assets: assets, extensions: copies.filter { used.contains($0.key) })
    }

    /// The ids of the extensions the document uses. Worked out again only when the
    /// document changed, since the window asks every time it is drawn.
    public var usedExtensionIDs: Set<String> {
        if let known = usedCache, known.document == fullDocument { return known.ids }
        let ids = fullDocument.usedExtensionIDs
        usedCache = (fullDocument, ids)
        return ids
    }
    @ObservationIgnored private var usedCache: (document: Document, ids: Set<String>)?

    /// The copies this document carries of the extensions it uses, to tell the registry
    /// what the patches of one that is not installed look like, and to offer it.
    public var carriedExtensions: [PaperExtension] {
        let used = usedExtensionIDs
        if let known = carriedCache, known.used == used, known.revision == copiesRevision { return known.value }
        let value = used.sorted().compactMap { id -> PaperExtension? in
            guard let files = copies[id], let package = try? PaperExtension(files: files), package.id == id else { return nil }
            return package
        }
        carriedCache = (used, copiesRevision, value)
        return value
    }
    @ObservationIgnored private var carriedCache: (used: Set<String>, revision: Int, value: [PaperExtension])?
    @ObservationIgnored private var copiesRevision = 0

    /// The definitions a prototype of this document runs with: the built-in patches and
    /// those of the extensions. The ports of components are not among them; a running
    /// prototype has its components expanded.
    public var runtimeRegistry: PatchRegistry { baseRegistry }

    /// Replaces the patch definitions. The document is left as it is: a patch whose
    /// extension has gone keeps its place, its values and its cables.
    public func setRegistry(_ registry: PatchRegistry) {
        guard registry.extensions != baseRegistry.extensions else { return }
        remember(registry.extensions)
        baseRegistry = registry
        registryCache = nil
        registryRevision += 1
        onRegistryChange?()
    }

    // MARK: Editing inside a component

    /// The id of the stand-in instance that runs in the Viewer while a component is edited.
    private func previewInstance(of component: ComponentID) -> LayerID { component }

    /// What the Viewer runs: the document, or while a component is being edited, that
    /// component on its own in the middle of an empty screen.
    public var runtimeDocument: Document {
        guard let scope, let definition = fullDocument.component(scope) else { return fullDocument }
        let screen = DeviceTemplate.iPhone18Pro.size
        let size = definition.root.value(.size).sizeValue
        var instance = definition.instance(at: Point2(
            x: ((screen.width - size.width) / 2).rounded(), y: ((screen.height - size.height) / 2).rounded()
        ))
        instance.id = previewInstance(of: scope)
        var preview = Document(screen: Layer(
            id: ComponentExpansion.derive(scope, scope), name: "Preview", kind: .screen,
            properties: [.fill: .color(ColorValue(hex: "#F2F2F7")!)], children: [instance]
        ))
        preview.components = fullDocument.components
        return preview
    }

    private func syncRuntimeScope() {
        guard let runtime else { return }
        guard let scope, let definition = fullDocument.component(scope) else {
            runtime.inspectionMap = nil
            return
        }
        let instance = previewInstance(of: scope)
        let root = definition.root.id
        runtime.inspectionMap = { $0 == root ? instance : ComponentExpansion.derive(instance, $0) }
    }

    /// Starts editing the inside of a component.
    public func enterComponent(_ id: ComponentID) {
        guard fullDocument.component(id) != nil, !scopePath.contains(id) else { return }
        selectedLayers = []
        selectedNodes = []
        openView = nil
        scopePath.append(id)
        fitRequest += 1
    }

    /// Goes back out one level.
    public func exitComponent() {
        guard !scopePath.isEmpty else { return }
        selectedLayers = []
        selectedNodes = []
        openView = nil
        scopePath.removeLast()
        fitRequest += 1
    }

    /// Runs `change` on what is being edited and returns the whole document that results.
    ///
    /// Every edit ends by making the graph agree with the layers again (one view patch per
    /// layer), so a new layer gets its patch, and a deleted one loses it, in the same undo step.
    private func changing(_ full: Document, _ change: (inout Document) -> Void) -> Document {
        var result: Document
        if let scope, var view = full.inside(of: scope) {
            change(&view)
            result = full.merging(inside: view, of: scope)
        } else {
            result = full
            change(&result)
        }
        if result != full {
            result.forgetUncabledShaderCode()
            result.normalize(measure: baseRegistry.with(components: result.components).height)
            baseRegistry.settlePublished(in: &result)
        }
        return result
    }

    // MARK: Editing

    /// Makes one undoable change.
    public func apply(_ actionName: String, _ change: (inout Document) -> Void) {
        let before = fullDocument
        let after = changing(before, change)
        guard after != before else { return }
        fullDocument = after
        pruneSelection()
        if transactionBase == nil { registerUndo(restoring: before, actionName: actionName) }
    }

    /// Makes the document as it is now the starting point of a sketch: what `SketchChanges`
    /// later compares against. It is about the whole document, also while a component is open.
    public func markBaseline(source: String? = nil) {
        finishInteractive()
        let before = fullDocument
        var after = before
        after.sketch = Sketch(source: source ?? before.sketch?.source, baseline: Sketch.Baseline(before))
        guard after != before else { return }
        fullDocument = after
        if transactionBase == nil { registerUndo(restoring: before, actionName: "Mark Starting Point") }
    }

    /// Runs several edits as one undo step. Used when one request makes many changes,
    /// such as a batch from the assistant.
    public func transaction(_ actionName: String, _ body: () -> Void) {
        guard beginTransaction() else {
            body()
            return
        }
        body()
        endTransaction(actionName)
    }

    /// Opens a transaction that stays open across turns of the event loop, for edits that
    /// arrive over time but are one step to the person (an assistant's batch applied as the
    /// model writes it). False when one is already open, which then takes these edits too.
    @discardableResult
    public func beginTransaction() -> Bool {
        guard transactionBase == nil else { return false }
        transactionBase = fullDocument
        return true
    }

    /// A transaction several holders share, such as chats building the document at once:
    /// the first hold opens it (unless one is open already, which then takes these edits)
    /// and the last release closes it, so overlapping batches are one undo step and none
    /// is left applying its edits a step at a time when another finishes first.
    public func holdTransaction() {
        if transactionHolds == 0 { holdsOwnTransaction = beginTransaction() }
        transactionHolds += 1
        holdsBegun += 1
    }

    /// How many holds have begun, ever: a holder that sees it move knows another began after it.
    public private(set) var holdsBegun = 0

    public func releaseTransaction(_ actionName: String) {
        guard transactionHolds > 0 else { return }
        transactionHolds -= 1
        guard transactionHolds == 0, holdsOwnTransaction else { return }
        holdsOwnTransaction = false
        endTransaction(actionName)
    }

    /// How many hold the shared transaction: more than one means another is building too.
    public var transactionHolders: Int { transactionHolds }

    public func endTransaction(_ actionName: String) {
        guard let before = transactionBase else { return }
        transactionBase = nil
        guard before != fullDocument else { return }
        registerUndo(restoring: before, actionName: actionName)
    }

    /// Whether a transaction is open.
    public var inTransaction: Bool { transactionBase != nil }

    /// Starts a continuous change such as a drag. Changes made with `interactive` until
    /// `endInteractive` collapse into one undo step.
    public func beginInteractive() {
        if interactiveBase == nil { interactiveBase = fullDocument }
    }

    public func interactive(_ change: (inout Document) -> Void) {
        beginInteractive()
        let after = changing(fullDocument, change)
        if after != fullDocument { fullDocument = after }
    }

    public func endInteractive(_ actionName: String) {
        guard let before = interactiveBase else { return }
        interactiveBase = nil
        guard before != fullDocument else { return }
        pruneSelection()
        registerUndo(restoring: before, actionName: actionName)
    }

    /// Closes any change still in progress as its own undo step, now. For something that
    /// arrives from outside (an agent's edit) in the middle of the person's.
    public func finishInteractive(_ actionName: String = "Change") {
        pendingEnd?.cancel()
        pendingEnd = nil
        guard let before = interactiveBase, before != fullDocument else {
            interactiveBase = nil
            return
        }
        endInteractive(actionName)
        // Undo steps registered in one pass of the event loop are one step. Whatever is
        // registered next in this pass starts a group of its own, so it is undone separately
        // from the change just closed. Nothing is opened until then: an empty group would
        // be an undo that does nothing.
        splitsNextUndo = true
        DispatchQueue.main.async { [weak self] in self?.splitsNextUndo = false }
    }

    /// Ends an interactive change shortly after the last update. For controls that report a
    /// stream of values with no "finished" event, such as the color picker.
    public func endInteractiveSoon(_ actionName: String) {
        pendingEnd?.cancel()
        pendingEnd = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.endInteractive(actionName)
        }
    }

    private func registerUndo(restoring previous: Document, actionName: String) {
        guard let undoManager else { return }
        if splitsNextUndo {
            splitsNextUndo = false
            if undoManager.groupingLevel == 1 {
                undoManager.endUndoGrouping()
                undoManager.beginUndoGrouping()
            }
        }
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                let current = store.fullDocument
                store.fullDocument = previous
                store.pruneSelection()
                store.registerUndo(restoring: current, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
    }

    private func pruneSelection() {
        // Undo can remove the component being edited.
        while let last = scopePath.last, fullDocument.component(last) == nil { scopePath.removeLast() }
        // The open view can be deleted, or stop being something that holds views.
        if let openView, document.container(openView).id != openView { self.openView = nil }
        let nodeIDs = Set(document.graph.nodes.map(\.id))
        if !selectedNodes.isSubset(of: nodeIDs) { selectedNodes.formIntersection(nodeIDs) }
    }

    // MARK: Live preview plumbing

    public func restartPrototype() { restartToken += 1 }

    /// The screen the Viewer is showing, when the prototype has screens.
    public private(set) var viewerScreen: LayerID?

    /// The screen the Viewer starts on, when the person asked to preview from one
    /// (`preview(from:)`); nil is the first screen. For this window only.
    public var previewScreen: LayerID?
    public func requestPatchLibrary() { libraryRequest += 1 }
    public func requestFitPatches() { fitRequest += 1 }

    /// Bumped to make the Canvas show every screen again.
    public private(set) var canvasFitRequest = 0
    public func requestFitCanvas() { canvasFitRequest += 1 }

    func addFrameObserver(_ owner: AnyObject, _ callback: @escaping () -> Void) {
        frameObservers[ObjectIdentifier(owner)] = callback
    }

    func removeFrameObserver(_ owner: AnyObject) {
        frameObservers[ObjectIdentifier(owner)] = nil
    }

    /// Code that a cable brings to a shader view's Code input is known only while the
    /// prototype runs. When code arrives that is not the view's own, it is remembered on
    /// the view, so its inputs become ports of the patch. This is the document catching up
    /// with what is running, not an edit: it is not an undo step.
    func noteArrivingShaderCode() {
        guard let runtime else { return }
        noteArrivingShaderCode(from: runtime)
    }

    /// The same without a Viewer: runs the prototype for a moment by itself to see what
    /// code its cables bring. For an agent, whose next step may cable to an input that
    /// only the arriving code declares.
    public func settleArrivingShaderCode() {
        guard document.graph.connections.contains(where: { $0.to.port == ShaderUse.codePort }) else { return }
        let trial = Runtime(document: runtimeDocument, registry: runtimeRegistry)
        for _ in 0..<3 { trial.tick(dt: 1.0 / 60) }
        noteArrivingShaderCode(from: trial)
    }

    private func noteArrivingShaderCode(from runtime: Runtime) {
        guard scope == nil, interactiveBase == nil else { return }
        var found: [LayerID: String] = [:]
        for connection in document.graph.connections where connection.to.port == ShaderUse.codePort {
            guard let layer = document.graph.node(connection.to.node)?.layerID, let stored = document.layer(layer)?.shader,
                  let running = runtime.resolved.find(layer)?.shader?.source,
                  running != stored.source, running != stored.arriving,
                  ShaderSource.interface(of: running).error == nil else { continue }
            found[layer] = running
        }
        guard !found.isEmpty else { return }
        let after = changing(fullDocument) { document in
            for (layer, code) in found { document.screen.update(layer) { $0.shader?.arriving = code } }
        }
        if after != fullDocument { fullDocument = after }
    }

    /// Called by the Viewer after each frame of the running prototype.
    func frameDidTick() {
        noteArrivingShaderCode()
        // The Canvas marks the screen the Viewer is on; it changes only when a screen does.
        let showing = runtime.flatMap { $0.navigation.hasPages ? $0.navigation.current : nil }
        if showing != viewerScreen { viewerScreen = showing }
        for observer in frameObservers.values { observer() }
        framesSinceLiveTick += 1
        if framesSinceLiveTick >= 4 {
            framesSinceLiveTick = 0
            liveTick &+= 1
        }
    }

    /// The live value of a layer property in the running prototype.
    public func liveValue(_ property: LayerProperty, of layer: LayerID) -> Value? {
        runtime?.resolvedLayer(layer)?.value(property)
    }
}


/// What `AssistantToolbox` batches named with `ref`, by kind of thing.
public struct AgentRefs: Equatable {
    public var layers: [String: LayerID] = [:]
    public var nodes: [String: NodeID] = [:]
    public init() {}
}
