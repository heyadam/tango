import Foundation
import PaperModel

/// Something a person did, in screen coordinates.
public enum InputEvent: Sendable, Equatable {
    /// A finger came down. `id` tells fingers apart for as long as they are down; a
    /// player passes on the touches its screen reports.
    case touchBegan(id: Int, Point2)
    /// It moved. (Named apart from the one-finger `touchMoved` below.)
    case touchChanged(id: Int, Point2)
    case touchEnded(id: Int, Point2)
    /// A finger was taken away without lifting: the player lost the screen.
    case touchCancelled(id: Int)
    /// One finger, for a host that only has one: the same as the events above with id 0.
    case touchDown(Point2)
    case touchMoved(Point2)
    case touchUp(Point2)
    case keyDown(String)
    case keyUp(String)
    /// Characters typed into the text field that has focus.
    case text(String)
    case deleteBackward
    /// Return in a text field.
    case submit
    /// A pinch the host has already recognized, as a trackpad's, began over a point. It
    /// drives the Pinch and Rotation patches of the view there without any fingers.
    case pinchBegan(Point2)
    /// How far it has spread (1 = as it started) and turned, in degrees.
    case pinchChanged(scale: Double, rotation: Double)
    case pinchEnded
    /// Where a pointer is without touching, or nil once it has left.
    case hover(Point2?)
}

/// A request a Network Request patch wants made. The runtime does no networking itself:
/// its host performs the request and reports back with `Runtime.complete`.
public struct NetworkRequest: Sendable, Hashable {
    public let id: UUID
    public let url: String
    public let method: String
    public let body: String
    /// Headers a script asked for. The Network Request patch sends none of its own.
    public var headers: [String: String] = [:]
    /// The id of the extension whose script asked, or nil for the Network Request patch.
    /// The host decides by it what the request may reach and carry.
    public var origin: String?
    /// Seconds to wait for an answer; 0 leaves it to the host.
    public var timeout: Double = 0

    public init(
        id: UUID = UUID(), url: String, method: String = "GET", body: String = "",
        headers: [String: String] = [:], origin: String? = nil, timeout: Double = 0
    ) {
        self.id = id
        self.url = url
        self.method = method
        self.body = body
        self.headers = headers
        self.origin = origin
        self.timeout = timeout
    }
}

extension NetworkRequest {
    /// The methods the Network Request patch offers.
    public static let patchMethods = ["GET", "POST", "PUT", "PATCH", "DELETE"]

    /// The name under which the host keeps a picture that came back for request `id`:
    /// what the patch's Image output gives, for an Image view to show.
    public static func pictureName(for id: UUID) -> String { "fetched:" + id.uuidString }

    /// What a Network Request patch's inputs ask for. `headers` and `query` are either a JSON
    /// object or one field per line (`Name: value`, `name=value`; a query may also be joined
    /// with `&`). Query fields are added to the address, encoded.
    public static func forPatch(
        url: String, method: String, body: String, headers: String, query: String
    ) -> NetworkRequest {
        let verb = method.trimmingCharacters(in: .whitespaces).uppercased()
        let chosen = patchMethods.contains(verb) ? verb : "GET"
        var address = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let parameters = fields(query, separator: "=", splitsOnAmpersand: true)
        if !parameters.isEmpty, var parts = URLComponents(string: address) {
            // Appended as text, so what the address already had is sent exactly as written,
            // and encoded strictly, so a `+` or `&` in a value stays one.
            let added = parameters.map { encode($0.name) + "=" + encode($0.value) }.joined(separator: "&")
            let existing = parts.percentEncodedQuery ?? ""
            parts.percentEncodedQuery = existing.isEmpty ? added : existing + "&" + added
            address = parts.string ?? address
        }
        var named: [String: String] = [:]
        for field in fields(headers, separator: ":", splitsOnAmpersand: false) { named[field.name] = field.value }
        return NetworkRequest(url: address, method: chosen, body: chosen == "GET" ? "" : body, headers: named)
    }

    static func encode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    static func fields(_ text: String, separator: Character, splitsOnAmpersand: Bool) -> [(name: String, value: String)] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        if trimmed.hasPrefix("{"), case let .object(entries)? = Value.parseJSON(Data(trimmed.utf8)) {
            return entries.keys.sorted().map { key in
                let value = entries[key]!
                if case let .text(text) = value { return (key, text) }
                return (key, value.coerced(to: .text)?.textValue ?? value.summary)
            }
        }
        var pieces = trimmed.split(whereSeparator: \.isNewline).map(String.init)
        if splitsOnAmpersand { pieces = pieces.flatMap { $0.split(separator: "&").map(String.init) } }
        return pieces.compactMap { piece in
            guard let cut = piece.firstIndex(of: separator) else {
                let name = piece.trimmingCharacters(in: .whitespaces)
                return name.isEmpty || separator == ":" ? nil : (name, "")
            }
            let name = piece[..<cut].trimmingCharacters(in: .whitespaces)
            let value = piece[piece.index(after: cut)...].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : (name, value)
        }
    }
}

public struct NetworkResponse: Sendable, Hashable {
    public var status: Int
    public var body: Data
    /// Set when the request did not get an answer at all.
    public var error: String?
    /// The answer's headers, by lowercased name. Only scripts read them.
    public var headers: [String: String]

    public init(status: Int = 200, body: Data = Data(), error: String? = nil, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.error = error
        self.headers = headers
    }
}

/// Runs a document: evaluates its graph frame by frame and resolves layer properties.
///
/// The runtime has no clock of its own. The host calls `tick(dt:)` once per frame, which
/// makes behavior reproducible in tests. It is not thread safe; use it from one isolation.
public final class Runtime {
    public private(set) var document: Document
    public private(set) var registry: PatchRegistry

    /// The layer tree with all graph-driven values applied, as of the last tick.
    public private(set) var resolved: ResolvedLayer
    /// The document with its component instances expanded: what actually runs.
    private var expanded: ExpandedDocument
    /// Translates the ids the editor asks about into the ids that are running. Set while
    /// the editor shows the inside of a component, which runs as one instance of it.
    public var inspectionMap: ((UUID) -> UUID)?
    // MARK: Device

    /// The services this prototype needs from its player, as of the last compile.
    public private(set) var capabilities: Set<DeviceCapability> = []
    private var device: [String: Value] = [:]
    private var pendingDeviceEvents: Set<String> = []
    private var deviceEvents: Set<String> = []
    private var effects: [DeviceEffect] = []

    /// Supplies a value from the player's hardware, such as "microphone.level".
    public func setDevice(_ key: String, _ value: Value) {
        guard device[key] != value else { return }
        device[key] = value
        needsFrame = true
    }

    /// Reports something that happened on the hardware, such as "camera.captured".
    public func deviceEvent(_ key: String) {
        pendingDeviceEvents.insert(key)
        needsFrame = true
    }

    /// What patches asked the player to do since the last call. The player performs them.
    public func takeEffects() -> [DeviceEffect] {
        defer { effects = [] }
        return effects
    }

    /// Performs network requests for the prototype. Without one, requests fail.
    public var requestHandler: ((NetworkRequest) -> Void)?
    private var responses: [UUID: NetworkResponse] = [:]
    /// Requests still waited for. An answer to any other request is ignored.
    private var openRequests: Set<UUID> = []
    /// Requests made by extension scripts and still waited for: whose they are.
    private var scriptRequests: [UUID: (node: NodeID, row: Int, token: Int)] = [:]
    /// Answers that arrived for them, by patch, handed over at the patch's next turn.
    private var scriptReplies: [NodeID: [(row: Int, reply: ScriptReply)]] = [:]

    /// Makes the calls AI patches ask for. Without one, they fail.
    public var aiHandler: ((AIRequest) -> Void)?
    /// What the host reported, by request, handed to the patch at its next turn.
    var aiUpdates: [UUID: [AIUpdate]] = [:]
    /// AI requests a patch still waits on. Reports about any other are ignored.
    var openAIRequests: Set<UUID> = []

    /// Reports progress or the outcome of a request passed to `aiHandler`. The host
    /// should then tick the runtime again.
    public func update(ai id: UUID, _ update: AIUpdate) {
        guard openAIRequests.contains(id) else { return }
        // Each partial holds the whole answer so far: only the newest is worth keeping.
        if case .partial = update, case .partial? = aiUpdates[id]?.last {
            aiUpdates[id]![aiUpdates[id]!.count - 1] = update
        } else {
            aiUpdates[id, default: []].append(update)
        }
        switch update {
        case .failed: openAIRequests.remove(id)
        case .finished: break
        case .playing(false): openAIRequests.remove(id)
        default: break
        }
        needsFrame = true
    }

    /// Reports the outcome of a request passed to `requestHandler`. The host should then
    /// tick the runtime again.
    public func complete(_ id: UUID, with response: NetworkResponse) {
        guard openRequests.contains(id) else { return }
        responses[id] = response
        needsFrame = true
    }
    // MARK: Video

    /// Where each video is. The runtime keeps the playhead, so a video is in the same place
    /// at the same moment of the prototype's time however it is drawn.
    private struct VideoState {
        var time: Double
        /// The `time` input as last seen: a change to it is a jump.
        var asked: Double
        var wasPlaying = false
        /// Held at an end it reached while not looping.
        var stopped = false
        /// The frame in which it last reached an end.
        var endedFrame = -1
    }

    /// Leaves every screen where it is stored, all of them there at once: for the Canvas,
    /// which lays them out side by side.
    public var showsEveryScreen = false
    /// The screen a fresh start (`restart()`, a new runtime) shows: the first when nil.
    /// The host's to set, as the Viewer's "Preview from Here" does; not saved.
    public var startPage: LayerID? {
        didSet { if oldValue != startPage { needsFrame = true } }
    }
    /// A finger that came down at the left edge of a pushed screen, dragging it back.
    private var edgeSwipe: (id: Int, startX: Double, lastX: Double, lastTime: Double, velocity: Double)?
    /// Which screen is showing, when the document has screens.
    public private(set) var navigation = Navigation()

    private var videos: [ResolvedLayer.Hit: VideoState] = [:]
    /// How long each video is, by its `video` value, as its player found out.
    private var videoDurations: [String: Double] = [:]
    /// Whether any view is a video.
    private var hasVideos = false

    /// Tells the runtime how long the video a `video` value names is, once its player has
    /// loaded it. Until then a video plays on with no end.
    public func setVideoDuration(_ seconds: Double, for source: String) {
        guard seconds.isFinite, seconds > 0 else { return }
        // The player and the file can disagree by a frame; a prototype that scales a time
        // by the length would jump at each switch between them.
        if let known = videoDurations[source], abs(known - seconds) < 0.05 { return }
        videoDurations[source] = seconds
        unplayableVideos.remove(source)
        needsFrame = true
    }

    /// How long a video is, if its player has said.
    public func videoDuration(of source: String) -> Double? { videoDurations[source] }

    /// Videos the host could not load (a missing asset, an address that is not a video).
    /// They stand still, so a typo does not keep the prototype asking for frames. Restart
    /// tries them again.
    private var unplayableVideos: Set<String> = []

    /// Says that the video `source` names cannot be played.
    public func setVideoUnplayable(_ source: String) {
        guard videoDurations[source] == nil, unplayableVideos.insert(source).inserted else { return }
        needsFrame = true
    }

    /// Seconds of prototype time elapsed.
    public private(set) var time: Double = 0
    public private(set) var frameCount = 0

    // MARK: Compiled graph

    /// Whether any view is drawn through a shader.
    private var hasShaders = false
    /// Whether any view is drawn by an extension.
    private var hasCustomViews = false
    /// Runs the scripts of views that extensions draw.
    private let painter: ViewPainter

    private enum Role {
        case patch(PatchDefinition)
        /// A view's patch: each cabled input drives that property of the layer. `instance`
        /// marks the patch of a component instance, which wins over the patch the
        /// component's own root has inside when both drive the same input.
        /// `scrolls` marks a scroll view, whose patch also runs the scrolling.
        case view(LayerID, instance: Bool, scrolls: Bool)
        case interaction(LayerID)
        case scroll(LayerID)
        case textInput(LayerID)
        case swipe(LayerID)
        case pinch(LayerID)
        case tap(LayerID)
        case longPress(LayerID)
        case pan(LayerID)
        case rotation(LayerID)
        case hover(LayerID)
        /// Reads the laid-out size of a layer from the previous frame, as view patches read
        /// their frame outputs (`laidOut`).
        case layerSize(LayerID)
        /// Reads where a video's playhead was at the end of the previous frame.
        case videoTime(LayerID)
        /// Shows a screen (`navigation`); nil when what it is attached to is not one.
        case navigate(LayerID?)
        case navigateBack
        /// Outputs come from the player's hardware; the definition may also ask for effects.
        case device(PatchDefinition, keys: [String])
        case network
        /// An AI patch: the host makes the call (`aiHandler`) and reports back.
        case ai(AIRequest.Task)
        /// Reads the input of the Broadcast patch with the same name (nil when there is none).
        case receive(broadcaster: Int?)
        case keyboard
        case unknown
    }

    private enum Source {
        case literal(Value)
        case cable(node: Int, output: Int)
    }

    private struct CompiledNode {
        let id: NodeID
        let kind: String
        let valueType: PortType
        let role: Role
        let ports: NodePorts
        let sources: [Source]
        let pulseOutputs: [Int]
        let script: String?
        /// Set on a component's published input fed by a cable: a loop arriving there
        /// repeats this instance layer.
        let repeatsLayer: LayerID?
        /// On a view's patch whose frame outputs are cabled or shown: the index of the
        /// first of them (x, y, width, height follow in order). nil leaves them alone, so
        /// a view nobody reads costs nothing.
        let frameSlot: Int?
    }

    /// Where layout put a view: its position in its parent and its size.
    private struct LaidOutFrame: Equatable {
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
    }

    /// The layers whose frame is read by a View Size patch or a view's frame outputs.
    private var framedLayers: Set<LayerID> = []
    /// Their frames in the last layout, one per repetition. Patches read them on the next
    /// frame, since layout runs after every patch: a view's outputs can feed its own inputs
    /// without a cycle inside one frame.
    private var laidOut: [LayerID: [LaidOutFrame]] = [:]

    /// Nodes in evaluation order.
    private var nodes: [CompiledNode] = []
    /// The layers that run, by id, for the stored half of a position or size driven in part.
    private var layersByID: [LayerID: Layer] = [:]
    private var indexByID: [NodeID: Int] = [:]

    // Per-node storage, parallel to `nodes`. A patch fed by a loop runs once per loop index,
    // so outputs and state are kept as one row per index (`outputs[node][row][port]`). Most
    // patches have exactly one row.
    private var outputs: [[[Value]]] = []
    private var states: [[(any Sendable)?]] = []
    /// What arrived on each input last tick: `lastInputs[node][port]` is that port's whole loop.
    private var lastInputs: [[[Value]]?] = []
    private var wantsFrame: [Bool] = []
    /// How many times each layer appeared in the last resolved tree. An Interaction on a
    /// repeated layer outputs a loop with one value per repetition.
    private var instanceCounts: [LayerID: Int] = [:]

    // MARK: Input state

    private struct ScrollState {
        var offset = 0.0
        /// Where the finger has pulled the content, before rubber-banding.
        var raw = 0.0
        var velocity = 0.0
        var grab: Double?
        /// Where paging decided the content should come to rest.
        var pageTarget: Double?
        /// The range the offset rests in, as of the last frame.
        var low = 0.0, high = 0.0
    }

    private var pendingEvents: [InputEvent] = []
    /// Tells gestures apart from the touches the host sends (`Gestures.swift`). Each patch
    /// that listens for one is a recognizer there, named by its place in `nodes`.
    private var arena = GestureArena()
    /// The patch that stands for each scroll view in the arena: the first that scrolls it.
    private var scrollOwners: [LayerID: Int] = [:]

    /// Two taps on a layer within this many seconds are a double tap.
    public static let doubleTapInterval = GestureMetrics.doubleTapInterval
    /// Holding still this long is a long press.
    public static let longPressDelay = GestureMetrics.longPressDelay
    private var keysDown: Set<String> = []
    private var keysPressed: Set<String> = []
    private var needsFrame = true

    // Text fields. A field keeps what was typed in it until the prototype restarts.
    private var focus: ResolvedLayer.Hit?
    private var fieldText: [ResolvedLayer.Hit: String] = [:]
    private var fieldChanged: Set<ResolvedLayer.Hit> = []
    private var fieldSubmitted: Set<ResolvedLayer.Hit> = []
    /// The text field (or nothing) under the finger that just came down. A tap there moves focus.
    private var focusCandidate: (id: Int, hit: ResolvedLayer.Hit?, start: Point2)?

    /// Whether any patch listens for a pointer that is not touching.
    public var usesHover: Bool { !hoverLayers.isEmpty }

    /// Whether a text field has focus, so typing belongs to it.
    public var isEditingText: Bool { focus != nil }

    private var hoverPoint: Point2?
    private var hovered: ResolvedLayer.Hit?
    /// The layers with a Hover patch, as of the last compile.
    private var hoverLayers: Set<LayerID> = []

    /// A swipe is a touch that moved at least this far and was still moving this fast when lifted.
    public static let swipeDistance = GestureMetrics.swipeDistance
    public static let swipeSpeed = GestureMetrics.swipeSpeed

    /// How far a touch may move and still count as a tap.
    public static let tapSlop = GestureMetrics.tapSlop
    /// Points a second a scroll view must still be moving for a finger to catch it rather
    /// than tap what is in it.
    static let caughtScrollSpeed: Double = 30

    /// `painter` draws the views of extensions; one that outlives the runtime keeps their
    /// scripts loaded, as the Canvas does while it is redrawn again and again.
    public init(document: Document, registry: PatchRegistry = .standard, painter: ViewPainter = ViewPainter()) {
        self.document = document
        self.registry = registry
        self.painter = painter
        expanded = ComponentExpansion.expand(document)
        resolved = ResolvedLayer(expanded.screen)
        instanceCounts = resolved.instanceCounts()
        compile(keepingState: false)
    }

    // MARK: Editing while running

    /// Replaces the document. Patches that still exist keep their state and outputs, so a
    /// Switch stays on and a spring keeps moving while the graph is rewired.
    public func update(document: Document) {
        guard document != self.document else { return }
        self.document = document
        expanded = ComponentExpansion.expand(document)
        compile(keepingState: true)
        needsFrame = true
    }

    /// Replaces the patch definitions, as when an extension is installed, updated or
    /// switched off. A patch keeps its state unless its own script changed.
    public func update(registry: PatchRegistry) {
        self.registry = registry
        compile(keepingState: true)
        needsFrame = true
    }

    /// Starts the prototype over: clears all state and time.
    public func restart() {
        time = 0
        frameCount = 0
        arena.reset()
        keysDown = []
        keysPressed = []
        focus = nil
        fieldText = [:]
        fieldChanged = []
        fieldSubmitted = []
        focusCandidate = nil
        hovered = nil
        pendingEvents = []
        openRequests = []
        responses = [:]
        scriptRequests = [:]
        scriptReplies = [:]
        for id in openAIRequests { aiHandler?(AIRequest(id: id, task: .text, phase: .cancel, model: "")) }
        openAIRequests = []
        aiUpdates = [:]
        effects = []
        pendingDeviceEvents = []
        videos = [:]
        unplayableVideos = []
        edgeSwipe = nil
        painter.reset()
        compile(keepingState: false)
        needsFrame = true
    }

    private func compile(keepingState: Bool) {
        let graph = expanded.graph
        let previousIndex = indexByID
        let previousNodes = nodes
        let previousOutputs = outputs
        let previousStates = states
        let previousWants = wantsFrame

        // Evaluation order: every patch after the patches it reads from. A cable that closes
        // a cycle is left as a back edge, which reads the previous frame's value.
        let byID = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var incoming: [NodeID: [Connection]] = [:]
        // The views whose frame outputs a cable reads.
        var framesRead: Set<NodeID> = []
        for connection in graph.connections {
            incoming[connection.to.node, default: []].append(connection)
            if ViewOutput.ids.contains(connection.from.port) { framesRead.insert(connection.from.node) }
        }
        var order: [NodeID] = []
        var visited: Set<NodeID> = []
        var visiting: Set<NodeID> = []
        func visit(_ id: NodeID) {
            guard byID[id] != nil, !visited.contains(id), !visiting.contains(id) else { return }
            visiting.insert(id)
            for connection in incoming[id] ?? [] {
                visit(connection.from.node)
            }
            // A Receive depends on the Broadcast it listens to.
            if let node = byID[id], node.kind == "receive", let source = broadcaster(for: node, in: graph) {
                visit(source)
            }
            visiting.remove(id)
            visited.insert(id)
            order.append(id)
        }
        for node in graph.nodes { visit(node.id) }

        layersByID = Dictionary(expanded.screen.flattened.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let shaders = layersByID.values.compactMap(\.shader)
        hasShaders = !shaders.isEmpty
        hasCustomViews = layersByID.values.contains { $0.custom != nil }
        hasVideos = layersByID.values.contains { $0.kind == .video }
        if !keepingState { navigation = Navigation() }
        navigation.settle(pages: expanded.screen.pages.map(\.id))
        if !keepingState, let startPage { navigation.start(at: startPage) }
        indexByID = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let portsByID = Dictionary(uniqueKeysWithValues: order.map { ($0, registry.ports(for: byID[$0]!)) })

        nodes = order.map { id in
            let node = byID[id]!
            var ports = portsByID[id]!
            let role: Role
            if node.kind == PatchKind.view, let layer = node.layerID {
                role = .view(
                    layer, instance: node.componentID != nil,
                    scrolls: node.componentID == nil && layersByID[layer]?.arrangement == .scrollView
                )
            } else if node.kind == PatchKind.interaction, let layer = node.layerID {
                role = .interaction(layer)
            } else if node.kind == "scroll", let layer = node.layerID {
                role = .scroll(layer)
            } else if node.kind == "layerSize", let layer = node.layerID {
                role = .layerSize(layer)
            } else if node.kind == PatchKind.videoTime, let layer = node.layerID {
                role = .videoTime(layer)
            } else if node.kind == PatchKind.navigate {
                role = .navigate(node.layerID)
            } else if node.kind == PatchKind.navigateBack {
                role = .navigateBack
            } else if node.kind == "textInput", let layer = node.layerID {
                role = .textInput(layer)
            } else if node.kind == "swipe", let layer = node.layerID {
                role = .swipe(layer)
            } else if node.kind == "pinch", let layer = node.layerID {
                role = .pinch(layer)
            } else if node.kind == PatchKind.tap, let layer = node.layerID {
                role = .tap(layer)
            } else if node.kind == PatchKind.longPress, let layer = node.layerID {
                role = .longPress(layer)
            } else if node.kind == PatchKind.pan, let layer = node.layerID {
                role = .pan(layer)
            } else if node.kind == PatchKind.rotation, let layer = node.layerID {
                role = .rotation(layer)
            } else if node.kind == "hover", let layer = node.layerID {
                role = .hover(layer)
            } else if node.kind == "networkRequest" {
                role = .network
            } else if let task = StandardPatches.aiTasks[node.kind] {
                role = .ai(task)
            } else if let definition = registry.definition(node.kind), let keys = definition.deviceOutputs {
                role = .device(definition, keys: keys)
            } else if node.kind == "receive" {
                role = .receive(broadcaster: broadcaster(for: node, in: graph).flatMap { indexByID[$0] })
            } else if node.kind == "keyboard" {
                role = .keyboard
            } else if let definition = registry.definition(node.kind),
                      !["interaction", "scroll", "layerSize", PatchKind.videoTime, "networkRequest", "textInput", "swipe", "pinch", "hover",
                        PatchKind.navigate, PatchKind.navigateBack, PatchKind.tap, PatchKind.longPress, PatchKind.pan, PatchKind.rotation].contains(node.kind),
                      StandardPatches.aiTasks[node.kind] == nil {
                role = .patch(definition)
            } else {
                role = .unknown
            }

            // The cables into this patch, in the graph's order (the first into a port wins, as
            // `graph.connection(into:)` has it): a view has an input for every property, and
            // searching every cable of the graph for each was most of compiling.
            let cablesIn = incoming[id] ?? []
            var sources: [Source] = ports.inputs.map { port in
                if let connection = cablesIn.first(where: { $0.to.port == port.id }),
                   let sourceIndex = indexByID[connection.from.node],
                   let sourcePorts = portsByID[connection.from.node],
                   let outputIndex = sourcePorts.outputs.firstIndex(where: { $0.id == connection.from.port }),
                   Value.canConnect(from: sourcePorts.outputs[outputIndex].type, to: port.type) {
                    return .cable(node: sourceIndex, output: outputIndex)
                }
                return .literal(registry.literal(for: port, of: node))
            }

            // A view has an input for every property, and nearly all of them have no cable.
            // Only the cabled ones are kept, so a frame costs nothing for the rest.
            if case .view = role {
                let cabled = sources.indices.filter { if case .cable = sources[$0] { true } else { false } }
                ports.inputs = cabled.map { ports.inputs[$0] }
                sources = cabled.map { sources[$0] }
            }

            // Frame outputs are filled only when something reads them: a cable, or the
            // person asked to see them on the patch.
            var frameSlot: Int?
            if case .view = role, let first = ports.outputs.firstIndex(where: { $0.id == ViewOutput.x.id }),
               framesRead.contains(id)
                || (node.shownPorts ?? []).contains(where: ViewOutput.ids.contains) {
                frameSlot = first
            }

            var repeatsLayer: LayerID?
            if node.kind == PatchKind.componentInput, case .cable = sources.first,
               node.inputs["loops"]?.textValue != PatchKind.passLoopInside {
                repeatsLayer = node.layerID
            }

            return CompiledNode(
                id: id,
                kind: node.kind,
                valueType: registry.valueType(for: node),
                role: role,
                ports: ports,
                sources: sources,
                pulseOutputs: ports.outputs.indices.filter { ports.outputs[$0].type == .pulse },
                // A patch from an extension runs the script its definition has.
                script: node.script ?? registry.definition(node.kind)?.script,
                repeatsLayer: repeatsLayer,
                frameSlot: frameSlot
            )
        }
        framedLayers = Set(nodes.compactMap { node -> LayerID? in
            switch node.role {
            case let .layerSize(layer): layer
            case let .view(layer, _, _) where node.frameSlot != nil: layer
            default: nil
            }
        })
        laidOut = frames(in: resolved)
        scrollOwners = [:]
        for (index, node) in nodes.enumerated() {
            switch node.role {
            case let .view(layer, _, true), let .scroll(layer):
                if scrollOwners[layer] == nil { scrollOwners[layer] = index }
            default: break
            }
        }

        capabilities = Set(nodes.compactMap { registry.definition($0.kind)?.capability })
        if expanded.screen.flattened.contains(where: { $0.kind == .camera }) { capabilities.insert(.camera) }

        outputs = nodes.map { [$0.ports.outputs.map(\.defaultValue)] }
        states = nodes.map { _ in [nil] }
        lastInputs = nodes.map { _ in nil }
        wantsFrame = nodes.map { _ in false }

        // Gestures under way go on with their patches, which may have new places in the
        // order; one whose patch is gone or is no longer the same kind ends there.
        if keepingState {
            arena.renumberOwners { old in
                guard previousNodes.indices.contains(old), let new = indexByID[previousNodes[old].id],
                      nodes[new].kind == previousNodes[old].kind else { return nil }
                return new
            }
        }
        hoverLayers = Set(nodes.compactMap { if case let .hover(layer) = $0.role { layer } else { nil } })

        var kept: Set<NodeID> = []
        if keepingState {
            for (index, node) in nodes.enumerated() {
                guard let old = previousIndex[node.id] else { continue }
                let before = previousNodes[old]
                guard before.kind == node.kind, before.valueType == node.valueType, before.script == node.script,
                      before.ports.outputs == node.ports.outputs
                else { continue }
                outputs[index] = previousOutputs[old]
                states[index] = previousStates[old]
                wantsFrame[index] = previousWants[old]
                kept.insert(node.id)
                // Last inputs are deliberately not carried over: every patch evaluates once
                // after an edit, so changed literals and cables take effect.
            }
        }
        // A script that starts over is not waiting for what its old self asked.
        forgetScriptRequests { !kept.contains($0.node) }
        // Nor is an AI patch that was deleted or replaced: what it asked for is stopped
        // (a voice speaking, a microphone recording, a stream still coming).
        for (old, node) in previousNodes.enumerated() where !kept.contains(node.id) {
            for state in previousStates[old] {
                guard let ai = state as? AIState else { continue }
                for id in ai.waitingOn where openAIRequests.contains(id) {
                    openAIRequests.remove(id)
                    aiUpdates[id] = nil
                    aiHandler?(AIRequest(id: id, task: .text, phase: .cancel, model: ""))
                }
            }
        }
    }

    /// Stops waiting for the scripts' requests that `gone` picks out; a late answer to one
    /// is then ignored.
    private func forgetScriptRequests(where gone: ((node: NodeID, row: Int, token: Int)) -> Bool) {
        for (id, owner) in scriptRequests where gone(owner) {
            scriptRequests[id] = nil
            openRequests.remove(id)
            responses[id] = nil
        }
        for (node, replies) in scriptReplies {
            let left = replies.filter { !gone((node, $0.row, $0.reply.token)) }
            scriptReplies[node] = left.isEmpty ? nil : left
        }
    }

    private func variableName(_ node: PatchNode) -> String {
        node.inputs["name"]?.textValue ?? "Variable"
    }

    /// The Broadcast patch a Receive listens to: same name and same type.
    private func broadcaster(for receiver: PatchNode, in graph: Graph) -> NodeID? {
        let name = variableName(receiver)
        let type = registry.valueType(for: receiver)
        return graph.nodes.first {
            $0.kind == "broadcast" && variableName($0) == name && registry.valueType(for: $0) == type
        }?.id
    }

    // MARK: Input

    public func send(_ event: InputEvent) {
        pendingEvents.append(event)
        needsFrame = true
    }

    /// Whether another tick would change anything. When false the host can pause its frame clock.
    public var needsAnotherFrame: Bool { needsFrame }

    private struct TouchTargets {
        /// The patches that listen for touches on each layer, in the order they run, as
        /// the arena's recognizers.
        var gestures: [LayerID: [(owner: Int, kind: GestureArena.Kind)]] = [:]
        /// Scroll views: the patch that stands for each, and whether it scrolls sideways.
        var scrolls: [LayerID: (owner: Int, horizontal: Bool)] = [:]
    }

    /// What an input of a patch holds now: its stored value, or what its cable last brought.
    private func setting(_ index: Int, _ slot: Int) -> Value? {
        guard slot < nodes[index].sources.count else { return nil }
        switch nodes[index].sources[slot] {
        case let .literal(value): return value
        case let .cable(from, output):
            guard let row = outputs[from].first, output < row.count else { return nil }
            return row[output]
        }
    }

    private func touchTargets() -> TouchTargets {
        var targets = TouchTargets()
        func count(_ index: Int, _ slot: Int, _ fallback: Int) -> Int {
            min(max(setting(index, slot)?.numberValue.whole ?? fallback, 0), 10)
        }
        for (index, node) in nodes.enumerated() {
            func listen(_ layer: LayerID, _ kind: GestureArena.Kind) {
                targets.gestures[layer, default: []].append((index, kind))
            }
            switch node.role {
            case let .interaction(layer): listen(layer, .touch)
            case let .swipe(layer): listen(layer, .swipe(fingers: max(count(index, 0, 1), 1)))
            case let .tap(layer):
                listen(layer, .tap(taps: max(count(index, 0, 1), 1), fingers: max(count(index, 1, 1), 1)))
            case let .longPress(layer):
                let duration = setting(index, 0)?.numberValue ?? GestureMetrics.longPressDelay
                listen(layer, .longPress(duration: min(max(duration.clampedFinite, 0), 60), fingers: max(count(index, 1, 1), 1)))
            case let .pan(layer):
                let direction: GestureArena.PanDirection = switch setting(index, 0)?.textValue {
                case "Horizontal": .horizontal
                case "Vertical": .vertical
                default: .any
                }
                listen(layer, .pan(direction: direction, minFingers: max(count(index, 1, 1), 1), maxFingers: count(index, 2, 0)))
            case let .pinch(layer): listen(layer, .pinch)
            case let .rotation(layer): listen(layer, .rotation)
            case let .view(layer, _, true):
                guard scrollOwners[layer] == index else { break }
                targets.scrolls[layer] = (index, resolved.find(layer)?.value(.axis).textValue == "Horizontal")
            case let .scroll(layer):
                guard scrollOwners[layer] == index else { break }
                targets.scrolls[layer] = (index, setting(index, 0)?.textValue == "Horizontal")
            default: break
            }
        }
        return targets
    }

    /// Whether a scroll view is coasting, bouncing or settling on a page.
    private func isScrolling(_ layer: LayerID) -> Bool {
        nodes.indices.contains { index in
            switch nodes[index].role {
            case .view(layer, _, true), .scroll(layer):
                // A finger at rest on it leaves no speed; a flick, a bounce or a page settling does.
                abs((states[index].first as? ScrollState)?.velocity ?? 0) > Runtime.caughtScrollSpeed
            default: false
            }
        }
    }

    /// Whether a finger moving `along` (points, positive toward a higher offset) could still
    /// move the content of the scroll view a patch runs before it reaches an end.
    private func canScroll(_ owner: Int, _ along: Double) -> Bool {
        guard states.indices.contains(owner), let state = states[owner].first as? ScrollState else { return true }
        return along > 0 ? state.offset < state.high - 0.5 : state.offset > state.low + 0.5
    }

    /// A finger comes down: the arena is told which recognizers it could mean.
    ///
    /// The touch belongs to the topmost view under it that listens for touches; views that
    /// do not listen do not block it. It is offered to that view's gesture patches, to those
    /// of the views that view is in, and to the scroll views it is in: a button on a bar
    /// over a list neither scrolls the list nor is caught by it. Deeper views come first.
    ///
    /// The raw touch is separate, as a view's own touches are from its recognizers in
    /// UIKit: it goes to the Interactions of the topmost view under the finger that has an
    /// Interaction or a Swipe, whatever gesture patches lie over it. So a picture that only
    /// listens for a pinch does not keep a tap from the button behind it or the view it is in.
    private func touchBegan(_ id: Int, at point: Point2) {
        let targets = touchTargets()
        var hits = resolved.hits(at: point, options: .touch)
        // A screen is opaque to touches: what is behind it (another screen, or a tab bar
        // under a sheet) does not hear a finger on it, though the screen listens for nothing.
        if let page = hits.firstIndex(where: { layersByID[$0.layer]?.isPage == true }) {
            hits = Array(hits[...page])
        }
        // The first finger down, or the same finger come down again without lifting.
        if arena.fingersDown.allSatisfy({ $0.id == id }) {
            focusCandidate = (id, hits.first.flatMap { isTextField($0) ? $0 : nil }, point)
        }
        let target = hits.first { targets.gestures[$0.layer] != nil }
        let touched = hits.first { hit in
            targets.gestures[hit.layer]?.contains { gesture in
                if case .swipe = gesture.kind { true } else { gesture.kind == .touch }
            } == true
        }
        var candidates: [GestureArena.Candidate] = []
        var seen: Set<LayerID> = []
        var caught = false
        for hit in hits {
            let holdsTarget = target.map { hit == $0 || (hit.layer != $0.layer && expanded.screen.find(hit.layer)?.contains($0.layer) == true) }
            for gesture in targets.gestures[hit.layer] ?? [] {
                guard gesture.kind == .touch ? hit == touched : holdsTarget == true else { continue }
                candidates.append(GestureArena.Candidate(owner: gesture.owner, hit: hit, kind: gesture.kind))
            }
            if let scroll = targets.scrolls[hit.layer], holdsTarget != false, seen.insert(hit.layer).inserted {
                // One still moving is caught by the finger at once.
                let moving = isScrolling(hit.layer)
                caught = caught || moving
                candidates.append(GestureArena.Candidate(
                    owner: scroll.owner, hit: ResolvedLayer.Hit(layer: hit.layer, instance: 0),
                    kind: .scroll(horizontal: scroll.horizontal, moving: moving)
                ))
            }
        }
        // A finger that catches moving content stops it, and does not reach what was
        // passing under it.
        if caught { candidates.removeAll { if case .scroll = $0.kind { false } else { true } } }
        arena.begin(id: id, at: point, time: time, candidates: candidates)
    }

    /// A finger lifts. A tap on a text field gives it focus; a tap anywhere else takes it away.
    private func touchEnded(_ id: Int, at point: Point2) {
        let ended = arena.end(id: id, at: point, time: time)
        guard let candidate = focusCandidate, candidate.id == id else { return }
        if (point - candidate.start).length <= Runtime.tapSlop, ended?.heldLong != true, ended?.wasTaken != true {
            focus = candidate.hit
        }
        focusCandidate = nil
    }

    private func finite(_ point: Point2) -> Point2 {
        Point2(x: point.x.clampedFinite, y: point.y.clampedFinite)
    }

    private func isTextField(_ hit: ResolvedLayer.Hit) -> Bool {
        expanded.screen.find(hit.layer)?.kind == .textField
    }

    /// What a text field holds: what was typed, or the text it starts with.
    private func text(of hit: ResolvedLayer.Hit) -> String {
        fieldText[hit] ?? expanded.screen.find(hit.layer)?.value(.text).textValue ?? ""
    }

    /// Hands an event to the swipe back from the edge, if it is that swipe's. Returns
    /// whether it took it.
    private func edgeSwipeTakes(_ event: InputEvent, begunThisTick: inout Set<Int>) -> Bool {
        let width = max(resolved.size.width, 1)
        switch event {
        case let .touchBegan(id, point):
            guard edgeSwipe == nil, !showsEveryScreen, navigation.canSwipeBack, point.x.isFinite,
                  point.x <= Navigation.edgeWidth, arena.fingersDown.isEmpty else { return false }
            edgeSwipe = (id, point.x, point.x, time, 0)
            begunThisTick.insert(id)
            return true
        case let .touchChanged(id, point):
            guard var swipe = edgeSwipe, swipe.id == id, point.x.isFinite else { return false }
            if time > swipe.lastTime { swipe.velocity = (point.x - swipe.lastX) / (time - swipe.lastTime) }
            swipe.lastX = point.x
            swipe.lastTime = time
            edgeSwipe = swipe
            navigation.dragBack((point.x - swipe.startX) / width)
            return true
        case let .touchEnded(id, _), let .touchCancelled(id):
            guard let swipe = edgeSwipe, swipe.id == id else { return false }
            edgeSwipe = nil
            if case .touchCancelled = event {
                navigation.endDragBack(velocity: -1)
            } else {
                navigation.endDragBack(velocity: swipe.velocity / width)
            }
            needsFrame = true
            return true
        default:
            return false
        }
    }

    private func processEvents(dt: Double) {
        arena.beginFrame()
        keysPressed = []
        fieldChanged = []
        fieldSubmitted = []
        var begunThisTick: Set<Int> = []
        var index = 0

        events: while index < pendingEvents.count {
            var event = pendingEvents[index]
            // One finger without a name is finger 0.
            switch event {
            case let .touchDown(point): event = .touchBegan(id: 0, point)
            case let .touchMoved(point): event = .touchChanged(id: 0, point)
            case let .touchUp(point): event = .touchEnded(id: 0, point)
            default: break
            }
            // A finger at the left edge of a pushed screen drags it back, as on iPhone. The
            // edge is the system's there: nothing under the finger hears it.
            if edgeSwipeTakes(event, begunThisTick: &begunThisTick) {
                index += 1
                continue
            }
            switch event {
            case let .touchBegan(id, point):
                arena.settle(canScroll: canScroll)
                touchBegan(id, at: finite(point))
                begunThisTick.insert(id)
            case let .touchChanged(id, point):
                // Fingers that move in one frame are looked at together (`settle`).
                arena.move(id: id, to: finite(point))
            case let .touchEnded(id, point):
                // Keep a down and its up in separate frames so Down is visible for a frame.
                if begunThisTick.contains(id) { break events }
                arena.settle(canScroll: canScroll)
                touchEnded(id, at: finite(point))
            case let .touchCancelled(id):
                if begunThisTick.contains(id) { break events }
                arena.settle(canScroll: canScroll)
                arena.cancel(id: id)
                if focusCandidate?.id == id { focusCandidate = nil }
            case .touchDown, .touchMoved, .touchUp:
                break
            case let .keyDown(key):
                let name = key.lowercased()
                if !keysDown.contains(name) { keysPressed.insert(name) }
                keysDown.insert(name)
            case let .keyUp(key):
                keysDown.remove(key.lowercased())
            case let .text(typed):
                if let focus, !typed.isEmpty {
                    fieldText[focus] = text(of: focus) + typed
                    fieldChanged.insert(focus)
                }
            case .deleteBackward:
                if let focus, !text(of: focus).isEmpty {
                    fieldText[focus] = String(text(of: focus).dropLast())
                    fieldChanged.insert(focus)
                }
            case .submit:
                if let focus {
                    fieldSubmitted.insert(focus)
                    self.focus = nil
                }
            case let .pinchBegan(point):
                // The topmost view under it that listens for a pinch or a turn.
                let targets = touchTargets()
                func twoFingered(_ kind: GestureArena.Kind) -> Bool { kind == .pinch || kind == .rotation }
                let hit = resolved.hits(at: finite(point), options: .touch).first { hit in
                    targets.gestures[hit.layer]?.contains { twoFingered($0.kind) } == true
                }
                let candidates = hit.map { hit in
                    (targets.gestures[hit.layer] ?? []).filter { twoFingered($0.kind) }
                        .map { GestureArena.Candidate(owner: $0.owner, hit: hit, kind: $0.kind) }
                } ?? []
                arena.indirectBegan(at: finite(point), candidates: candidates)
            case let .pinchChanged(scale, rotation):
                arena.indirectChanged(scale: scale, rotation: rotation)
            case .pinchEnded:
                arena.indirectEnded()
            case let .hover(point):
                hoverPoint = point.map(finite)
            }
            index += 1
        }
        pendingEvents.removeFirst(index)

        // What is under a still pointer can change as layers move, so this is asked every frame.
        if let hoverPoint {
            hovered = hoverLayers.isEmpty ? nil
                : resolved.hits(at: hoverPoint, options: .touch).first { hoverLayers.contains($0.layer) }
        } else {
            hovered = nil
        }

        arena.settle(canScroll: canScroll)
        arena.advance(time: time, dt: dt)
    }

    // MARK: Frame

    /// Advances the prototype by `dt` seconds. Returns whether another frame is needed.
    @discardableResult
    public func tick(dt: Double) -> Bool {
        time += dt
        frameCount += 1
        processEvents(dt: dt)
        deviceEvents = pendingDeviceEvents
        pendingDeviceEvents = []
        // Answers to scripts' requests go to their patches, which run this frame for them.
        if !scriptRequests.isEmpty {
            for (id, response) in responses {
                guard let owner = scriptRequests.removeValue(forKey: id) else { continue }
                responses[id] = nil
                openRequests.remove(id)
                scriptReplies[owner.node, default: []].append((owner.row, ScriptReply(token: owner.token, response: response)))
            }
        }

        var overrides: [LayerID: [LayerProperty: [Value]]] = [:]
        // What cables bring to view patches this frame, by layer and port id.
        var driven: [LayerID: [String: [Value]]] = [:]
        var drivenByInstance: [LayerID: [String: [Value]]] = [:]
        var repeats: [LayerID: Int] = [:]
        var stillActive = !pendingEvents.isEmpty

        for index in nodes.indices {
            let node = nodes[index]

            // Gathered before this patch's pulses are cleared, so a patch cabled to itself
            // (a field's Submitted into its own Clear) reads its pulse from the last frame,
            // as any back edge does. Cleared after, it never saw it.
            let inputs = gatherInputs(for: node)

            // A pulse lasts one frame: it is cleared here, at the emitting patch's own turn,
            // so patches later in the order saw it this frame and back-edge readers see it
            // exactly once on the next.
            for row in outputs[index].indices {
                for output in node.pulseOutputs {
                    outputs[index][row][output] = .pulse(false)
                }
            }

            switch node.role {
            case let .view(layer, instance, scrolls):
                for (slot, port) in node.ports.inputs.enumerated() {
                    if instance {
                        drivenByInstance[layer, default: [:]][port.id] = inputs[slot]
                    } else {
                        driven[layer, default: [:]][port.id] = inputs[slot]
                    }
                }
                if scrolls {
                    // How far it can move comes from the last layout: content longer than
                    // the view scrolls by the difference.
                    let shown = resolved.find(layer)
                    let axis = shown?.value(.axis) ?? .text("Vertical")
                    let size = shown?.size ?? .zero
                    let room = (axis.textValue == "Horizontal" ? size.width : size.height) - (shown?.contentLength ?? 0)
                    evaluateScroll(at: index, layer: layer, inputs: [
                        axis, .number(min(room, 0)), .number(0), shown?.value(.pageSize) ?? .number(0),
                    ], dt: dt)
                    overrides[layer, default: [:]][.contentOffset] = [outputs[index][0][0]]
                }
                if let slot = node.frameSlot { outputs[index] = frameRows(at: index, slot: slot, of: layer) }
            case let .interaction(layer):
                evaluateInteraction(at: index, layer: layer)
            case let .scroll(layer):
                let single = zip(inputs, node.ports.inputs).map { $0.first ?? $1.defaultValue }
                evaluateScroll(at: index, layer: layer, inputs: single, dt: dt)
            case let .layerSize(layer):
                outputs[index] = sizeRows(of: layer)
            case let .videoTime(layer):
                outputs[index] = videoRows(of: layer, asking: frameCount)
            case let .navigate(layer):
                // Inputs: go, style, response. Outputs: progress, arrived, showing.
                if let layer, inputs[0].contains(where: \.pulseValue) {
                    let style = Navigation.Style.named(inputs[1].first?.textValue ?? "") ?? .push
                    navigation.go(to: layer, style: style, response: inputs[2].first?.numberValue ?? Navigation.defaultResponse)
                    stillActive = true
                }
                outputs[index] = [[
                    .number(layer.map(navigation.presence) ?? 0),
                    .pulse(layer != nil && navigation.event == layer.map(Navigation.Event.arrived)),
                    .bool(layer != nil && navigation.current == layer && navigation.move == nil),
                ]]
            case .navigateBack:
                // Inputs: go, response. Outputs: can go back, arrived.
                if inputs[0].contains(where: \.pulseValue) {
                    navigation.back(response: inputs[1].first?.numberValue ?? Navigation.defaultResponse)
                    stillActive = true
                }
                var wentBack = false
                if case .wentBack = navigation.event { wentBack = true }
                outputs[index] = [[.bool(navigation.canGoBack), .pulse(wentBack)]]
            case let .textInput(layer):
                evaluateTextInput(at: index, layer: layer, inputs: inputs)
            case let .swipe(layer):
                // Outputs: left, right, up, down.
                outputs[index] = rows(at: index, for: layer).enumerated().map { row, _ in
                    let swipe = arena.reading(owner: index, hit: ResolvedLayer.Hit(layer: layer, instance: row))?.swipe
                    return (0..<4).map { .pulse(swipe?.rawValue == $0) }
                }
            case let .pinch(layer):
                // Outputs: scale, rotation, pinching, velocity, center, began, ended. What
                // it measured stays after the fingers lift, and until another pinch begins.
                var rows = rows(at: index, for: layer)
                for row in rows.indices {
                    let reading = arena.reading(owner: index, hit: ResolvedLayer.Hit(layer: layer, instance: row))
                    if let reading, reading.isActive || reading.ended {
                        rows[row][0] = .number(reading.scale)
                        rows[row][1] = .number(reading.rotation)
                        rows[row][3] = .number(reading.scaleVelocity)
                        rows[row][4] = .point(reading.position)
                    }
                    rows[row][2] = .bool(reading?.isActive == true)
                    rows[row][5] = .pulse(reading?.began == true)
                    rows[row][6] = .pulse(reading?.ended == true)
                }
                outputs[index] = rows
            case let .rotation(layer):
                // Outputs: rotation, velocity, rotating, center, began, ended.
                var rows = rows(at: index, for: layer)
                for row in rows.indices {
                    let reading = arena.reading(owner: index, hit: ResolvedLayer.Hit(layer: layer, instance: row))
                    if let reading, reading.isActive || reading.ended {
                        rows[row][0] = .number(reading.rotation)
                        rows[row][1] = .number(reading.rotationVelocity)
                        rows[row][3] = .point(reading.position)
                    }
                    rows[row][2] = .bool(reading?.isActive == true)
                    rows[row][4] = .pulse(reading?.began == true)
                    rows[row][5] = .pulse(reading?.ended == true)
                }
                outputs[index] = rows
            case let .pan(layer):
                // Outputs: translation, velocity, position, panning, began, ended.
                var rows = rows(at: index, for: layer)
                for row in rows.indices {
                    let reading = arena.reading(owner: index, hit: ResolvedLayer.Hit(layer: layer, instance: row))
                    if let reading, reading.isActive || reading.ended {
                        rows[row][0] = .point(reading.translation)
                        rows[row][1] = .point(reading.velocity)
                        rows[row][2] = .point(reading.position)
                    }
                    rows[row][3] = .bool(reading?.isActive == true)
                    rows[row][4] = .pulse(reading?.began == true)
                    rows[row][5] = .pulse(reading?.ended == true)
                }
                outputs[index] = rows
            case let .tap(layer):
                // Outputs: tapped, position.
                var rows = rows(at: index, for: layer)
                for row in rows.indices {
                    let reading = arena.reading(owner: index, hit: ResolvedLayer.Hit(layer: layer, instance: row))
                    rows[row][0] = .pulse(reading?.recognized == true)
                    if let reading, reading.recognized { rows[row][1] = .point(reading.position) }
                }
                outputs[index] = rows
            case let .longPress(layer):
                // Outputs: pressing, began, ended, position.
                var rows = rows(at: index, for: layer)
                for row in rows.indices {
                    let reading = arena.reading(owner: index, hit: ResolvedLayer.Hit(layer: layer, instance: row))
                    rows[row][0] = .bool(reading?.isActive == true)
                    rows[row][1] = .pulse(reading?.began == true)
                    rows[row][2] = .pulse(reading?.ended == true)
                    if let reading, reading.isActive || reading.ended { rows[row][3] = .point(reading.position) }
                }
                outputs[index] = rows
            case let .hover(layer):
                // Outputs: hovering, position.
                var rows = rows(at: index, for: layer)
                for row in rows.indices {
                    let mine = hovered == ResolvedLayer.Hit(layer: layer, instance: row)
                    rows[row][0] = .bool(mine)
                    if mine, let hoverPoint { rows[row][1] = .point(hoverPoint) }
                }
                outputs[index] = rows
            case let .device(definition, keys):
                // Requests for effects run like any patch: when an input changes.
                if lastInputs[index] != inputs {
                    evaluate(definition, at: index, inputs: inputs, dt: dt)
                }
                var row = outputs[index].first ?? node.ports.outputs.map(\.defaultValue)
                for (slot, key) in keys.enumerated() where slot < row.count {
                    let port = node.ports.outputs[slot]
                    if port.type == .pulse {
                        row[slot] = .pulse(deviceEvents.contains(key))
                    } else {
                        row[slot] = device[key]?.coerced(to: port.type) ?? port.defaultValue
                    }
                }
                outputs[index] = [row]
            case .network:
                let single = zip(inputs, node.ports.inputs).map { $0.first ?? $1.defaultValue }
                if evaluateNetwork(at: index, inputs: single) { stillActive = true }
            case let .ai(task):
                let single = zip(inputs, node.ports.inputs).map { $0.first ?? $1.defaultValue }
                var state = states[index].first as? AIState ?? AIState()
                var row = outputs[index].first ?? node.ports.outputs.map(\.defaultValue)
                let before = row
                let waitedOn = state.waitingOn
                evaluateAI(task, state: &state, inputs: single, row: &row, updates: { id in
                    self.aiUpdates.removeValue(forKey: id) ?? []
                }, send: { request in
                    if request.phase == .cancel {
                        self.openAIRequests.remove(request.id)
                        self.aiUpdates[request.id] = nil
                    } else {
                        self.openAIRequests.insert(request.id)
                    }
                    if let handler = self.aiHandler {
                        handler(request)
                    } else if request.phase == .send || request.phase == .startRecording {
                        self.aiUpdates[request.id, default: []].append(.failed("This player cannot use AI."))
                    }
                })
                // A request the patch no longer waits on is forgotten: what comes for it is ignored.
                for id in waitedOn.subtracting(state.waitingOn) {
                    openAIRequests.remove(id)
                    aiUpdates[id] = nil
                }
                outputs[index] = [row]
                states[index] = [state]
                // An answer queued for this patch, or one that changed what it shows, is
                // seen on the next frame.
                if row != before || state.waitingOn.contains(where: { aiUpdates[$0] != nil }) { stillActive = true }
            case let .receive(broadcaster):
                // Port order of Broadcast is name, value. A broadcast loop arrives as a loop.
                if let broadcaster, let sent = lastInputs[broadcaster], sent.count > 1 {
                    outputs[index] = sent[1].map { [$0] }
                }
            case .keyboard:
                let key = (inputs.first?.first?.textValue ?? "").lowercased()
                outputs[index][0][0] = .bool(keysDown.contains(key))
                outputs[index][0][1] = .pulse(keysPressed.contains(key))
            case let .patch(definition):
                // A pulse that arrives two frames running is two pulses, though the inputs
                // look the same as last frame: two taps a frame apart count twice.
                let pulsed = inputs.contains { $0.contains(where: \.pulseValue) }
                if wantsFrame[index] || pulsed || lastInputs[index] != inputs || scriptReplies[node.id] != nil {
                    evaluate(definition, at: index, inputs: inputs, dt: dt)
                }
                if let layer = node.repeatsLayer {
                    let count = outputs[index].count
                    let known = repeats[layer]
                    repeats[layer] = (known == 0 || count == 0) ? 0 : max(known ?? 1, count)
                }
            case .unknown:
                break
            }

            lastInputs[index] = inputs
            if wantsFrame[index] { stillActive = true }
            if outputs[index].contains(where: { row in node.pulseOutputs.contains { row[$0].pulseValue } }) {
                stillActive = true
            }
        }

        if arena.needsFrames { stillActive = true }
        if !keysPressed.isEmpty { stillActive = true }
        if !deviceEvents.isEmpty { stillActive = true }

        // A text field shows what was typed in it, unless a cable drives its text. This is
        // put on the resolved tree, not fed in as a loop, so it never decides how many
        // times a repeated field appears.
        for (layer, ports) in drivenByInstance { driven[layer, default: [:]].merge(ports) { _, outer in outer } }
        // Only the screen that is showing is there, and one giving way to another is moved.
        // This goes in before what cables bring, so a cable on a screen still wins.
        if navigation.hasPages, !showsEveryScreen {
            if navigation.step(dt: dt) { stillActive = true }
            let device = resolved.size
            for page in navigation.pages {
                let placement = navigation.placement(of: page, in: device)
                if !placement.visible {
                    overrides[page, default: [:]][.visible] = [.bool(false)]
                    continue
                }
                if placement.offset != .zero { overrides[page, default: [:]][.position] = [.point(placement.offset)] }
                if placement.opacity != 1 { overrides[page, default: [:]][.opacity] = [.number(placement.opacity)] }
            }
        }
        for (layer, ports) in driven { apply(ports, to: layer, in: &overrides) }
        var tree = ResolvedLayer(expanded.screen, loops: overrides, repeats: repeats)
        if let front = navigation.front { tree.bringPageToFront(front) }
        // A screen presented as a sheet covers the tab bar too, and takes its touches.
        if navigation.hasPages, !showsEveryScreen {
            let covering = navigation.pages.filter(navigation.coversEverything)
            if !covering.isEmpty { tree.liftToTop(covering) }
        }
        if !fieldText.isEmpty { tree.setTyped(fieldText) }
        if hasShaders {
            var inputs: [LayerID: [String: [Value]]] = [:]
            var code: [LayerID: [Value]] = [:]
            for (layer, ports) in driven {
                for (id, loop) in ports {
                    if let name = ShaderUse.inputName(port: id) { inputs[layer, default: [:]][name] = loop }
                    if id == ShaderUse.codePort { code[layer] = loop }
                }
            }
            // A shader that reads the time is drawn every frame.
            if tree.setShaderInputs(inputs, code: code, time: time) { stillActive = true }
        }
        if hasCustomViews {
            var inputs: [LayerID: [String: [Value]]] = [:]
            for (layer, ports) in driven {
                for (id, loop) in ports {
                    if let name = CustomViewUse.inputName(port: id) { inputs[layer, default: [:]][name] = loop }
                }
            }
            tree.setCustomInputs(inputs)
        }
        resolved = tree.laidOut()
        // Morph blends the two screens view by view, from where layout put each.
        if let move = navigation.move, move.style == .morph, navigation.hasPages, !showsEveryScreen {
            resolved.morph(over: move.over, under: move.under, shown: move.shown)
        }
        // A view an extension draws is drawn once its size is known. One that draws
        // every frame keeps the prototype running.
        if hasCustomViews, painter.paint(&resolved, registry: registry, time: time) { stillActive = true }
        // A playing video moves on; a paused one costs nothing.
        if hasVideos, advanceVideos(dt: dt) { stillActive = true }
        if let focus, !resolved.markEditing(focus) {
            // The field went away.
            self.focus = nil
        }
        // A loop that changed length changes how many values looped Interactions report.
        let counts = resolved.instanceCounts()
        if counts != instanceCounts {
            instanceCounts = counts
            stillActive = true
        }
        // Video Time patches report where each video was at the end of this frame.
        for (index, node) in nodes.enumerated() where !stillActive {
            if case let .videoTime(layer) = node.role, videoRows(of: layer, asking: frameCount + 1) != outputs[index] { stillActive = true }
        }
        // View Size patches and views' frame outputs report this frame's layout on the next
        // one. Only a frame that changed asks for that frame, so a still prototype idles.
        if !framedLayers.isEmpty {
            laidOut = frames(in: resolved)
            for (index, node) in nodes.enumerated() where !stillActive {
                switch node.role {
                case let .layerSize(layer):
                    if sizeRows(of: layer) != outputs[index] { stillActive = true }
                case let .view(layer, _, _):
                    if let slot = node.frameSlot, frameRows(at: index, slot: slot, of: layer) != outputs[index] { stillActive = true }
                default:
                    break
                }
            }
        }
        // A request answered at once, as when there is nobody to make it, is handed over
        // on the next frame.
        if responses.keys.contains(where: { scriptRequests[$0] != nil }) { stillActive = true }
        needsFrame = stillActive
        return stillActive
    }

    /// Turns what arrived on a view patch's inputs into property loops. A property input is
    /// taken as it is. The four numbers are put together with the other half of the
    /// position or size, which is the cabled `position`/`size` if there is one and the
    /// stored value otherwise: the longest loop sets how many, shorter ones repeat, and an
    /// empty one leaves none.
    private func apply(_ ports: [String: [Value]], to layer: LayerID, in overrides: inout [LayerID: [LayerProperty: [Value]]]) {
        var result = overrides[layer] ?? [:]
        for (id, loop) in ports {
            if let input = ViewInput(id: id), input.part == nil { result[input.property] = loop }
        }
        for (first, second) in [(ViewInput.Part.x, ViewInput.Part.y), (.width, .height)] {
            let parts = [first, second].compactMap { part in ports[part.rawValue].map { (ViewInput(part), $0) } }
            guard !parts.isEmpty else { continue }
            let property = first.property
            let stored = layersByID[layer]?.value(property) ?? property.defaultValue(for: .view)
            let whole = result[property] ?? [stored]
            let counts = parts.map(\.1.count) + [whole.count]
            guard !counts.contains(0) else {
                result[property] = []
                continue
            }
            result[property] = (0..<(counts.max() ?? 1)).map { index in
                parts.reduce(whole[index % whole.count]) { value, part in
                    part.0.setting(part.1[index % part.1.count], in: value)
                }
            }
        }
        overrides[layer] = result
    }

    /// The frames of the layers something reads, in one walk of the laid-out tree.
    private func frames(in tree: ResolvedLayer) -> [LayerID: [LaidOutFrame]] {
        guard !framedLayers.isEmpty else { return [:] }
        var found: [LayerID: [(copy: Int, frame: LaidOutFrame)]] = [:]
        // Not a number would never equal last frame's and keep the prototype awake.
        func finite(_ value: Double) -> Double { value.isFinite ? value : 0 }
        func walk(_ node: ResolvedLayer) {
            if framedLayers.contains(node.id) {
                let position = node.position
                let size = node.size
                found[node.id, default: []].append((node.instance, LaidOutFrame(
                    x: finite(position.x), y: finite(position.y), width: finite(size.width), height: finite(size.height)
                )))
            }
            node.children.forEach(walk)
        }
        walk(tree)
        // Row k is copy k: a copy left out (`visible` off) gives a row of zeros, so the
        // rows after it stay with their own copies.
        return found.mapValues { copies in
            let indices = copies.map(\.copy)
            guard Set(indices).count == indices.count, let last = indices.max(), last < 10_000 else { return copies.map(\.frame) }
            var rows = [LaidOutFrame](repeating: LaidOutFrame(), count: last + 1)
            for copy in copies { rows[copy.copy] = copy.frame }
            return rows
        }
    }

    /// A layer's frames in the last layout: one per repetition, and one of zeros when it
    /// is not there.
    private func laidOutFrames(of layer: LayerID) -> [LaidOutFrame] {
        let frames = laidOut[layer] ?? []
        return frames.isEmpty ? [LaidOutFrame()] : frames
    }

    /// Output rows of a Layer Size patch: one per repetition of the layer.
    private func sizeRows(of layer: LayerID) -> [[Value]] {
        laidOutFrames(of: layer).map { frame in
            [.size(Size2(width: frame.width, height: frame.height)), .number(frame.width), .number(frame.height)]
        }
    }

    /// Output rows of a view's patch with its frame outputs filled in: one per repetition
    /// of the view, each keeping the other outputs (a scroll view's offset) of the first row.
    private func frameRows(at index: Int, slot: Int, of layer: LayerID) -> [[Value]] {
        let base = outputs[index].first ?? nodes[index].ports.outputs.map(\.defaultValue)
        guard slot + 3 < base.count else { return outputs[index] }
        return laidOutFrames(of: layer).map { frame in
            var row = base
            row[slot] = .number(frame.x)
            row[slot + 1] = .number(frame.y)
            row[slot + 2] = .number(frame.width)
            row[slot + 3] = .number(frame.height)
            return row
        }
    }

    /// Moves every video's playhead on by `dt` and puts it on the resolved tree: a change
    /// to `time` jumps there, a playing video advances at its rate, and at an end it starts
    /// over or stops. Returns whether any is moving or just reached an end.
    private func advanceVideos(dt: Double) -> Bool {
        func finite(_ value: Double) -> Double { value.isFinite ? value : 0 }
        var moving = false
        resolved.eachVideo { node in
            let hit = ResolvedLayer.Hit(layer: node.id, instance: node.instance)
            let source = node.value(.video).textValue
            let asked = finite(node.value(.time).numberValue)
            let rate = finite(node.value(.playbackRate).numberValue)
            let playing = node.value(.playing).boolValue && !source.isEmpty && !unplayableVideos.contains(source)
            let duration = videoDurations[source]
            var state = videos[hit] ?? VideoState(time: asked, asked: asked)
            if asked != state.asked {
                state.time = asked
                state.asked = asked
                state.stopped = false
            } else if playing, !state.wasPlaying, state.stopped {
                // Played again after it stopped at an end: from the other end, as a player does.
                state.time = rate < 0 ? (duration ?? 0) : 0
                state.stopped = false
            }
            if playing, state.stopped, let duration {
                // Stopped at an end, and now looping or headed the other way: it plays on.
                let away = rate > 0 ? state.time < duration : rate < 0 ? state.time > 0 : false
                if node.value(.loops).boolValue || away { state.stopped = false }
            }
            let advancing = playing && !state.stopped && rate != 0
            if advancing { state.time += dt * rate }
            var ended = false
            if let duration {
                let loops = node.value(.loops).boolValue
                if state.time >= duration {
                    if advancing, rate > 0, loops {
                        state.time = state.time.truncatingRemainder(dividingBy: duration)
                        ended = true
                    } else {
                        if advancing, rate > 0 {
                            ended = true
                            state.stopped = true
                        }
                        state.time = duration
                    }
                } else if state.time < 0 {
                    if advancing, rate < 0, loops {
                        state.time = duration + state.time.truncatingRemainder(dividingBy: duration)
                        ended = true
                    } else {
                        if advancing, rate < 0 {
                            ended = true
                            state.stopped = true
                        }
                        state.time = 0
                    }
                }
            } else {
                state.time = max(state.time, 0)
            }
            if ended { state.endedFrame = frameCount }
            state.wasPlaying = playing
            let isPlaying = playing && !state.stopped && rate != 0
            videos[hit] = state
            node.playhead = Playhead(time: state.time, isPlaying: isPlaying)
            if isPlaying || ended { moving = true }
        }
        return moving
    }

    /// Output rows of a Video Time patch, one per repetition of the video, for the patch's
    /// turn in frame `frame`: where the playhead was when the frame before it ended.
    private func videoRows(of layer: LayerID, asking frame: Int) -> [[Value]] {
        var rows: [[Value]] = []
        func walk(_ node: ResolvedLayer) {
            if node.id == layer {
                let duration = node.kind == .video ? videoDurations[node.value(.video).textValue] ?? 0 : 0
                let time = node.playhead?.time ?? 0
                let ended = videos[ResolvedLayer.Hit(layer: layer, instance: node.instance)]?.endedFrame == frame - 1
                rows.append([
                    .number(time), .number(duration), .number(duration > 0 ? min(max(time / duration, 0), 1) : 0),
                    .bool(node.playhead?.isPlaying ?? false), .pulse(ended),
                ])
            }
            node.children.forEach(walk)
        }
        walk(resolved)
        if rows.isEmpty { rows = [[.number(0), .number(0), .number(0), .bool(false), .pulse(false)]] }
        return rows
    }

    /// Per input port, every value arriving on it this frame: one for a literal or a plain
    /// cable, one per index for a loop.
    private func gatherInputs(for node: CompiledNode) -> [[Value]] {
        var values: [[Value]] = []
        values.reserveCapacity(node.sources.count)
        for (slot, source) in node.sources.enumerated() {
            let port = node.ports.inputs[slot]
            switch source {
            case let .literal(value):
                values.append([value])
            case let .cable(sourceNode, output):
                values.append(outputs[sourceNode].map { $0[output].coerced(to: port.type) ?? port.defaultValue })
            }
        }
        return values
    }

    private func evaluate(_ definition: PatchDefinition, at index: Int, inputs: [[Value]], dt: Double) {
        let valueType = nodes[index].valueType

        if let evaluateLoop = definition.evaluateLoop {
            var context = LoopContext(
                inputs: inputs, outputs: outputs[index], state: states[index].first ?? nil,
                dt: dt, time: time, valueType: valueType
            )
            evaluateLoop(&context)
            outputs[index] = context.outputs
            states[index] = [context.state]
            wantsFrame[index] = context.wantsNextFrame
            return
        }

        // Loop lifting: the patch runs once per index with that index's inputs, outputs, and
        // state. The longest loop sets the count; shorter ones repeat; an empty one empties it.
        let count = inputs.contains(where: \.isEmpty) ? 0 : (inputs.map(\.count).max() ?? 1)
        var rows = outputs[index]
        var rowStates = states[index]
        let defaults = nodes[index].ports.outputs.map(\.defaultValue)
        rows.removeLast(max(rows.count - count, 0))
        rowStates.removeLast(max(rowStates.count - count, 0))
        while rows.count < count { rows.append(defaults) }
        while rowStates.count < count { rowStates.append(nil) }

        // An item that left a loop takes its script with it, and what that was waiting for.
        let node = nodes[index].id
        let arrived = scriptReplies.removeValue(forKey: node) ?? []
        if scriptRequests.contains(where: { $0.value.node == node && $0.value.row >= count }) {
            forgetScriptRequests { $0.node == node && $0.row >= count }
        }

        var wants = false
        for row in 0..<count {
            var context = EvalContext(
                inputs: inputs.map { $0[row % $0.count] },
                outputs: rows[row],
                state: rowStates[row],
                dt: dt,
                time: time,
                valueType: valueType
            )
            context.script = nodes[index].script
            context.replies = arrived.filter { $0.row == row }.map(\.reply)
            definition.evaluate(&context)
            effects.append(contentsOf: context.effects)
            for asked in context.requests {
                let request = NetworkRequest(
                    url: asked.url, method: asked.method, body: asked.body, headers: asked.headers,
                    origin: definition.origin?.id, timeout: asked.timeout
                )
                openRequests.insert(request.id)
                scriptRequests[request.id] = (node, row, asked.token)
                if let requestHandler {
                    requestHandler(request)
                } else {
                    responses[request.id] = NetworkResponse(status: 0, error: "This player cannot make network requests.")
                }
            }
            rows[row] = context.outputs
            rowStates[row] = context.state
            wants = wants || context.wantsNextFrame
        }
        outputs[index] = rows
        states[index] = rowStates
        wantsFrame[index] = wants
    }

    /// The output rows of a patch attached to a layer: one per repetition of the layer, and
    /// one (idle) row when a loop has removed it.
    private func rows(at index: Int, for layer: LayerID) -> [[Value]] {
        let count = max(instanceCounts[layer] ?? 0, 1)
        var rows = outputs[index]
        let defaults = nodes[index].ports.outputs.map(\.defaultValue)
        rows.removeLast(max(rows.count - count, 0))
        while rows.count < count { rows.append(defaults) }
        return rows
    }

    private func evaluateTextInput(at index: Int, layer: LayerID, inputs: [[Value]]) {
        // Inputs: focus, dismiss, clear. Outputs: text, editing, changed, submitted.
        var rows = rows(at: index, for: layer)
        func pulsed(_ port: Int, _ row: Int) -> Bool {
            guard port < inputs.count, !inputs[port].isEmpty else { return false }
            return inputs[port][row % inputs[port].count].pulseValue
        }
        for row in rows.indices {
            let hit = ResolvedLayer.Hit(layer: layer, instance: row)
            if pulsed(0, row) { focus = hit }
            if pulsed(1, row), focus == hit { focus = nil }
            var changed = fieldChanged.contains(hit)
            let shown = text(of: hit)
            if pulsed(2, row), !shown.isEmpty {
                // The field empties now, but Text gives what was there for this one frame
                // more: a Clear that comes from the field's own Return (through a cycle, which
                // may be ordered either way) must not empty the words the same Return sends.
                fieldText[hit] = ""
                changed = true
                needsFrame = true
            }
            rows[row][0] = .text(shown)
            rows[row][1] = .bool(focus == hit)
            rows[row][2] = .pulse(changed)
            rows[row][3] = .pulse(fieldSubmitted.contains(hit))
        }
        outputs[index] = rows
    }

    private func evaluateInteraction(at index: Int, layer: LayerID) {
        // Outputs: down, tap, drag, position, velocity. One row per repetition of the layer.
        // A layer that an empty loop has removed still reports one (idle) touch state.
        // Otherwise its own empty outputs, wired back into its properties, would keep it
        // removed for good.
        let count = max(instanceCounts[layer] ?? 0, 1)
        var rows = outputs[index]
        let defaults = nodes[index].ports.outputs.map(\.defaultValue)
        rows.removeLast(max(rows.count - count, 0))
        while rows.count < count { rows.append(defaults) }
        for row in 0..<count {
            let reading = arena.reading(owner: index, hit: ResolvedLayer.Hit(layer: layer, instance: row))
            rows[row][1] = .pulse(reading?.tapped == true)
            rows[row][5] = .pulse(reading?.doubleTapped == true)
            rows[row][6] = .pulse(reading?.longPressed == true)
            // With no finger on it, it keeps what the last one left.
            guard let reading else {
                rows[row][0] = .bool(false)
                continue
            }
            rows[row][0] = .bool(reading.isActive)
            rows[row][2] = .point(reading.translation)
            rows[row][3] = .point(reading.position)
            rows[row][4] = .point(reading.velocity)
        }
        outputs[index] = rows
    }

    private struct NetworkState {
        var pending: UUID?
        var started = false
    }

    /// Returns whether the outputs changed in a way later frames need to see.
    private func evaluateNetwork(at index: Int, inputs: [Value]) -> Bool {
        // Inputs: url, method, body, send, auto, headers, query.
        // Outputs: loading, response, text, done, failed, hasError, error, status, image.
        var state = states[index].first as? NetworkState ?? NetworkState()
        var row = outputs[index].first ?? nodes[index].ports.outputs.map(\.defaultValue)
        var changed = false

        let wantsSend = inputs[3].pulseValue || (!state.started && inputs[4].boolValue)
        state.started = true
        if wantsSend, !inputs[0].textValue.isEmpty {
            func text(_ slot: Int) -> String { inputs.count > slot ? inputs[slot].textValue : "" }
            let request = NetworkRequest.forPatch(
                url: text(0), method: text(1), body: text(2), headers: text(5), query: text(6)
            )
            if let superseded = state.pending {
                openRequests.remove(superseded)
                responses[superseded] = nil
            }
            openRequests.insert(request.id)
            state.pending = request.id
            row[0] = .bool(true)
            row[5] = .bool(false)
            row[6] = .text("")
            if let requestHandler {
                requestHandler(request)
            } else {
                responses[request.id] = NetworkResponse(status: 0, error: "This player cannot make network requests.")
            }
            changed = true
        }

        if let pending = state.pending, let response = responses.removeValue(forKey: pending) {
            state.pending = nil
            openRequests.remove(pending)
            row[0] = .bool(false)
            row[7] = .number(Double(response.status))
            let text = String(data: response.body, encoding: .utf8) ?? ""
            let failure = response.error ?? ((200..<300).contains(response.status) ? nil : "The server answered \(response.status).")
            if let failure {
                if row.count > 8 { row[8] = .text("") }
                row[4] = .pulse(true)
                row[5] = .bool(true)
                row[6] = .text(failure)
            } else if response.headers["content-type"]?.lowercased().hasPrefix("image/") == true {
                // A picture: the host keeps it under this name, and an Image view shows it.
                if row.count > 8 { row[8] = .text(NetworkRequest.pictureName(for: pending)) }
                row[1] = .object([:])
                row[2] = .text("")
                row[3] = .pulse(true)
            } else {
                if row.count > 8 { row[8] = .text("") }
                row[1] = Value.parseJSON(response.body) ?? .text(text)
                row[2] = .text(text)
                row[3] = .pulse(true)
            }
            changed = true
        }
        outputs[index] = [row]
        states[index] = [state]
        return changed
    }

    /// Scroll physics: follow the finger (rubber-banding past the ends), then coast with
    /// friction on release and spring back if the content was left past an end.
    private func evaluateScroll(at index: Int, layer: LayerID, inputs: [Value], dt: Double) {
        // Inputs: axis, min, max, page size. Outputs: offset, velocity, dragging.
        let page = inputs.count > 3 ? inputs[3].numberValue : 0
        var state = states[index].first as? ScrollState ?? ScrollState()
        let horizontal = inputs[0].textValue == "Horizontal"
        let low = min(inputs[1].numberValue, inputs[2].numberValue)
        let high = max(inputs[1].numberValue, inputs[2].numberValue)
        state.low = low
        state.high = high

        func rubber(_ distance: Double) -> Double { (1 - 1 / (distance * 0.55 / 500 + 1)) * 500 }
        func banded(_ value: Double) -> Double {
            if value > high { return high + rubber(value - high) }
            if value < low { return low - rubber(low - value) }
            return value
        }

        // The finger that scrolls it, once the arena has given it the touch: how far it
        // has gone since then.
        let finger = arena.reading(owner: scrollOwners[layer] ?? index, hit: ResolvedLayer.Hit(layer: layer, instance: 0))
        var moving = false
        if let finger, finger.isActive {
            let travel = finger.translation
            let distance = horizontal ? travel.x : travel.y
            // The travel is counted from where the scrolling began, so the content starts
            // from where it was.
            let grab = state.grab ?? state.offset
            state.grab = grab
            state.pageTarget = nil
            state.raw = grab + distance
            let next = banded(state.raw)
            if dt > 0 { state.velocity = state.velocity * 0.5 + (next - state.offset) / dt * 0.5 }
            state.offset = next
            moving = true
        } else {
            state.grab = nil
            if page > 0 {
                // Paging: pick the page the flick was heading for, once, and spring to it.
                let target = state.pageTarget ?? min(max(((state.offset + state.velocity * 0.18) / page).rounded() * page, low), high)
                state.pageTarget = target
                let next = Spring.step(
                    position: state.offset, velocity: state.velocity, target: target,
                    response: 0.4, dampingRatio: 1, dt: dt
                )
                state.offset = next.position
                state.velocity = next.velocity
                if abs(state.offset - target) < 0.05, abs(state.velocity) < 1 {
                    state.offset = target
                    state.velocity = 0
                } else {
                    moving = true
                }
            } else if state.offset < low - 0.01 || state.offset > high + 0.01 {
                let target = min(max(state.offset, low), high)
                let next = Spring.step(
                    position: state.offset, velocity: state.velocity, target: target,
                    response: 0.45, dampingRatio: 1, dt: dt
                )
                state.offset = next.position
                state.velocity = next.velocity
                if abs(state.offset - target) < 0.05, abs(state.velocity) < 1 {
                    state.offset = target
                    state.velocity = 0
                } else {
                    moving = true
                }
            } else if abs(state.velocity) > 4 {
                state.velocity *= pow(0.998, dt * 1000)
                state.offset += state.velocity * dt
                moving = true
            } else {
                state.velocity = 0
            }
        }

        states[index] = [state]
        wantsFrame[index] = moving
        // Only the first three outputs are the scroll's: a scroll view's patch has its
        // frame outputs after them.
        var row = outputs[index].first ?? nodes[index].ports.outputs.map(\.defaultValue)
        let values: [Value] = [
            .number(state.offset),
            .number(state.velocity),
            .bool(finger?.isActive == true),
        ]
        for (slot, value) in values.enumerated() where slot < row.count { row[slot] = value }
        outputs[index] = [row]
    }

    // MARK: Inspection

    private func inspected(_ ref: PortRef) -> PortRef {
        let mapped = inspectionMap.map { PortRef(node: $0(ref.node), port: ref.port) } ?? ref
        return expanded.aliases[mapped] ?? mapped
    }

    /// The resolved layer the editor means by `id`.
    public func resolvedLayer(_ id: LayerID) -> ResolvedLayer? {
        resolved.find(inspectionMap?(id) ?? id)
    }

    /// The current value of an output port, for showing live values in the Patch Editor.
    public func outputValue(_ ref: PortRef) -> Value? {
        let ref = inspected(ref)
        guard let index = indexByID[ref.node],
              let output = nodes[index].ports.outputs.firstIndex(where: { $0.id == ref.port })
        else { return nil }
        return outputs[index].first?[output]
    }

    /// Every value on an output port: more than one when the patch is running in a loop.
    public func outputValues(_ ref: PortRef) -> [Value] {
        let ref = inspected(ref)
        guard let index = indexByID[ref.node],
              let output = nodes[index].ports.outputs.firstIndex(where: { $0.id == ref.port })
        else { return [] }
        return outputs[index].map { $0[output] }
    }

    /// Every value that arrived on an input port on the last tick.
    public func inputValues(_ ref: PortRef) -> [Value] {
        let ref = inspected(ref)
        guard let index = indexByID[ref.node],
              let input = nodes[index].ports.inputs.firstIndex(where: { $0.id == ref.port }),
              let values = lastInputs[index], input < values.count
        else { return [] }
        return values[input]
    }

    /// The value an input port received on the last tick.
    public func inputValue(_ ref: PortRef) -> Value? {
        let ref = inspected(ref)
        guard let index = indexByID[ref.node],
              let input = nodes[index].ports.inputs.firstIndex(where: { $0.id == ref.port }),
              let values = lastInputs[index], input < values.count
        else { return nil }
        return values[input].first
    }

    /// Runs `seconds` of prototype time in fixed steps. For tests and previews.
    public func advance(seconds: Double, step: Double = 1.0 / 60.0) {
        var remaining = seconds
        while remaining > 1e-9 {
            tick(dt: min(step, remaining))
            remaining -= step
        }
    }

    /// Runs in fixed steps until nothing wants another frame, as a host pauses its clock, for
    /// `seconds` at most. True when it came to rest. For tests that wait for motion to end:
    /// unlike `advance` it does not run on through time in which nothing moves, so it is not
    /// for waiting out a delay that counts time (two taps one second apart).
    @discardableResult
    public func settle(within seconds: Double, step: Double = 1.0 / 60.0) -> Bool {
        var remaining = seconds
        while remaining > 1e-9, needsFrame {
            tick(dt: min(step, remaining))
            remaining -= step
        }
        return !needsFrame
    }
}
