import CoreGraphics
import Foundation
import PaperModel

/// A layer with every property resolved to its final value for one frame: the layer's own
/// values, with graph-driven values on top.
public struct ResolvedLayer: Sendable, Hashable, Identifiable {
    public let id: LayerID
    /// Which repetition this is when a loop repeats the layer (or a group it is in); 0 otherwise.
    public let instance: Int
    public let kind: LayerKind
    public let name: String
    /// Whether this is one of the prototype's screens: the root's layout makes it fill the device.
    public let isPage: Bool
    public var overrides: [LayerProperty: Value]
    private let stored: [LayerProperty: Value]
    public var children: [ResolvedLayer]
    /// Set on the text field the person is typing in.
    public var isEditing = false
    /// For a stack, after layout: how long its content is along its axis, padding included.
    public internal(set) var contentLength = 0.0
    /// Set on a shader view: its source and what its inputs are this frame.
    public var shader: ResolvedShader?
    /// Set on a view an extension draws: which view, and what its inputs are this frame.
    public var custom: ResolvedCustom?
    /// Set on a scene view: the scene as it is this frame, with what cables bring.
    public var scene: SceneUse?
    /// What such a view drew this frame, once a `ViewPainter` has been over the tree.
    public var drawing: Drawing?
    /// Set on a video by the runtime: where it is this frame and whether it is moving.
    /// Without one (the Canvas) a video shows the frame its `time` names.
    public var playhead: Playhead?

    /// Calls `body` on every video in the tree, so the runtime can give each its playhead.
    mutating func eachVideo(_ body: (inout ResolvedLayer) -> Void) {
        if kind == .video { body(&self) }
        for index in children.indices { children[index].eachVideo(body) }
    }

    /// Gives views drawn by extensions the values cables bring to their inputs
    /// (`driven`: by layer, then input id, one value per repetition).
    public mutating func setCustomInputs(_ driven: [LayerID: [String: [Value]]]) {
        if var own = custom {
            for (name, loop) in driven[id] ?? [:] where !loop.isEmpty {
                own.values[name] = loop[instance % loop.count]
            }
            custom = own
        }
        for index in children.indices { children[index].setCustomInputs(driven) }
    }

    /// Gives scene views the values cables bring to their inputs (`driven`: by layer, then
    /// port id, one value per repetition).
    public mutating func setSceneInputs(_ driven: [LayerID: [String: [Value]]]) {
        if var own = scene {
            for (port, loop) in driven[id] ?? [:] where !loop.isEmpty {
                if let key = SceneUse.key(port: port) { own.set(loop[instance % loop.count], for: key) }
            }
            scene = own
        }
        for index in children.indices { children[index].setSceneInputs(driven) }
    }

    /// Gives shader views the values cables bring to their inputs (`driven`: by layer, then
    /// input name, one value per repetition), and the time to those that read it.
    /// `code` is the source a cable brings, which replaces the view's own while it is not
    /// empty. Returns whether any shader in the tree reads the time.
    @discardableResult
    public mutating func setShaderInputs(_ driven: [LayerID: [String: [Value]]], code: [LayerID: [Value]] = [:], time: Double) -> Bool {
        var moving = false
        if var own = shader {
            if let loop = code[id], !loop.isEmpty, case let text = loop[instance % loop.count].textValue, !text.isEmpty {
                own.source = text
            }
            for (name, loop) in driven[id] ?? [:] where !loop.isEmpty {
                own.values[name] = loop[instance % loop.count]
            }
            if ShaderSource.interface(of: own.source).animates {
                own.time = time
                moving = true
            }
            shader = own
        }
        for index in children.indices where children[index].setShaderInputs(driven, code: code, time: time) { moving = true }
        return moving
    }

    /// Draws one screen over the others (and under whatever floats over every screen):
    /// the one arriving, or the one leaving when going back.
    mutating func bringPageToFront(_ page: LayerID) {
        guard let last = children.lastIndex(where: \.isPage) else { return }
        let moved = children.enumerated().filter { $0.element.id == page && $0.offset < last }
        guard !moved.isEmpty else { return }
        children.insert(contentsOf: moved.map(\.element), at: last + 1)
        for index in moved.map(\.offset).reversed() { children.remove(at: index) }
    }

    /// Draws these children over all the others, in the order they have.
    mutating func liftToTop(_ ids: [LayerID]) {
        let lifted = children.filter { ids.contains($0.id) }
        guard !lifted.isEmpty else { return }
        children.removeAll { ids.contains($0.id) }
        children.append(contentsOf: lifted)
    }

    /// Marks the text field being typed in. Returns whether it was found.
    @discardableResult
    public mutating func markEditing(_ hit: Hit) -> Bool {
        if id == hit.layer, instance == hit.instance {
            isEditing = true
            return true
        }
        for index in children.indices where children[index].markEditing(hit) { return true }
        return false
    }

    /// Shows what was typed into text fields. A field whose text a cable drives keeps the
    /// cable's value.
    public mutating func setTyped(_ typed: [Hit: String]) {
        if kind == .textField, overrides[.text] == nil, let text = typed[Hit(layer: id, instance: instance)] {
            overrides[.text] = .text(text)
        }
        for index in children.indices { children[index].setTyped(typed) }
    }

    public init(_ layer: Layer, overrides: [LayerID: [LayerProperty: Value]] = [:]) {
        id = layer.id
        instance = 0
        kind = layer.kind
        name = layer.name
        isPage = layer.isPage
        stored = layer.properties
        shader = layer.shader.map { ResolvedShader(source: $0.source, values: $0.inputs) }
        custom = layer.custom.map { ResolvedCustom(kind: $0.kind, values: $0.inputs) }
        scene = layer.scene
        self.overrides = overrides[layer.id] ?? [:]
        children = layer.children.map { ResolvedLayer($0, overrides: overrides) }.filter(\.isThere)
    }

    /// Resolves a tree whose properties may be driven by loops. A layer with a looped
    /// property appears once per loop value; everything inside a repeated group is repeated
    /// with it and reads its own loops at the group's index.
    /// `repeats` repeats a layer a number of times without driving any property: a
    /// component whose input receives a loop.
    public init(_ layer: Layer, loops: [LayerID: [LayerProperty: [Value]]], repeats: [LayerID: Int] = [:]) {
        self.init(layer, loops: loops, repeats: repeats, index: 0, inherited: false, isRoot: true)
    }

    private init(
        _ layer: Layer, loops: [LayerID: [LayerProperty: [Value]]], repeats: [LayerID: Int],
        index: Int, inherited: Bool, isRoot: Bool
    ) {
        id = layer.id
        instance = index
        kind = layer.kind
        name = layer.name
        isPage = layer.isPage
        stored = layer.properties
        shader = layer.shader.map { ResolvedShader(source: $0.source, values: $0.inputs) }
        custom = layer.custom.map { ResolvedCustom(kind: $0.kind, values: $0.inputs) }
        scene = layer.scene
        var values: [LayerProperty: Value] = [:]
        var repeated = inherited || (repeats[layer.id] ?? 1) > 1
        for (property, loop) in loops[layer.id] ?? [:] where !loop.isEmpty {
            values[property] = loop[index % loop.count]
            if loop.count > 1 { repeated = true }
        }
        overrides = values
        let inside = repeated && !isRoot
        children = layer.children.flatMap { child in
            ResolvedLayer.instances(of: child, loops: loops, repeats: repeats, index: index, inherited: inside)
        }
    }

    private static func instances(
        of layer: Layer, loops: [LayerID: [LayerProperty: [Value]]], repeats: [LayerID: Int],
        index: Int, inherited: Bool
    ) -> [ResolvedLayer] {
        if inherited {
            return [ResolvedLayer(layer, loops: loops, repeats: repeats, index: index, inherited: true, isRoot: false)].filter(\.isThere)
        }
        // The longest loop decides how often the layer repeats; an empty loop removes it.
        let driven = loops[layer.id] ?? [:]
        var counts = driven.values.map(\.count)
        if let extra = repeats[layer.id] { counts.append(extra) }
        let count = counts.contains(0) ? 0 : (counts.max() ?? 1)
        return (0..<count).map {
            ResolvedLayer(layer, loops: loops, repeats: repeats, index: $0, inherited: false, isRoot: false)
        }.filter(\.isThere)
    }

    /// How many rows each layer's patches have: one per copy, counted to the last copy in
    /// the tree, so a copy left out (`visible` off) keeps its row and the copies after it
    /// keep theirs. Counted by appearances, it gave a tap on the copy after a hidden one
    /// no row to land in.
    public func instanceCounts() -> [LayerID: Int] {
        var counts: [LayerID: Int] = [:]
        func walk(_ layer: ResolvedLayer) {
            counts[layer.id] = max(counts[layer.id] ?? 0, min(layer.instance, 9_999) + 1)
            layer.children.forEach(walk)
        }
        walk(self)
        return counts
    }

    public func value(_ property: LayerProperty) -> Value {
        if let own = overrides[property] ?? stored[property] { return own }
        if let followed = property.follows { return value(followed) }
        return property.defaultValue(for: kind)
    }

    public var position: Point2 { kind == .screen ? .zero : value(.position).pointValue }
    public var size: Size2 { value(.size).sizeValue }
    public var anchor: Point2 { value(.anchor).pointValue }
    public var opacity: Double { value(.opacity).numberValue }
    public var scale: Double { kind == .screen ? 1 : value(.scale).numberValue }
    public var rotation: Double { kind == .screen ? 0 : value(.rotation).numberValue }
    public var isEnabled: Bool { value(.enabled).boolValue }
    /// A view whose `visible` is off is left out of the tree: not drawn, not laid out, not touched.
    var isThere: Bool { value(.visible).boolValue }
    public var clips: Bool { value(.clips).boolValue }

    /// The top-left corner in the parent's coordinates, before scale and rotation.
    public var origin: Point2 {
        let size = self.size
        let anchor = self.anchor
        let position = self.position
        return Point2(x: position.x - anchor.x * size.width, y: position.y - anchor.y * size.height)
    }

    /// The unrotated, unscaled frame in the parent's coordinates.
    public var frame: CGRect {
        let origin = self.origin
        let size = self.size
        return CGRect(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    /// Maps the layer's own coordinates (0,0 at its top-left) into its parent's coordinates.
    /// Scale and rotation pivot around the layer's center.
    public var transformToParent: CGAffineTransform {
        let size = self.size
        let origin = self.origin
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        return CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(rotationAngle: rotation * .pi / 180))
            .concatenating(CGAffineTransform(translationX: center.x + origin.x, y: center.y + origin.y))
    }

    public func find(_ id: LayerID) -> ResolvedLayer? {
        if self.id == id { return self }
        for child in children {
            if let found = child.find(id) { return found }
        }
        return nil
    }

    /// Maps the coordinates of layer `id` into this layer's coordinates. nil when not found.
    public func transform(toRootFrom id: LayerID) -> CGAffineTransform? {
        if self.id == id { return .identity }
        for child in children {
            if let inner = child.transform(toRootFrom: id) {
                return inner.concatenating(child.transformToParent)
            }
        }
        return nil
    }

    // MARK: Hit testing

    public struct HitOptions: Sendable {
        /// Skip disabled and fully transparent layers (and everything inside them).
        public var interactiveOnly: Bool

        public init(interactiveOnly: Bool) {
            self.interactiveOnly = interactiveOnly
        }

        /// What a touch can reach in the running prototype.
        public static let touch = HitOptions(interactiveOnly: true)
        /// What a click on the Canvas can select.
        public static let editing = HitOptions(interactiveOnly: false)
    }

    /// The layers containing `point` (in this layer's parent coordinates), front to back.
    public func hitTest(_ point: Point2, options: HitOptions = .touch) -> [LayerID] {
        hits(at: point, options: options).map(\.layer)
    }

    /// A layer under a point, with which repetition of it was hit.
    public struct Hit: Sendable, Hashable {
        public let layer: LayerID
        public let instance: Int
    }

    /// Like `hitTest`, telling repeated layers apart.
    public func hits(at point: Point2, options: HitOptions = .touch) -> [Hit] {
        var result: [Hit] = []
        collectHits(CGPoint(x: point.x, y: point.y), options: options, into: &result)
        return result
    }

    private func collectHits(_ pointInParent: CGPoint, options: HitOptions, into result: inout [Hit]) {
        if options.interactiveOnly, !isEnabled || opacity <= 0 { return }
        let transform = transformToParent
        guard abs(transform.a * transform.d - transform.b * transform.c) > 1e-12 else { return }
        let local = pointInParent.applying(transform.inverted())
        let size = self.size
        let inside = local.x >= 0 && local.y >= 0 && local.x <= size.width && local.y <= size.height
        if clips, !inside { return }

        for child in children.reversed() {
            child.collectHits(local, options: options, into: &result)
        }
        if inside { result.append(Hit(layer: id, instance: instance)) }
    }
}

/// Where a video is in one frame. The runtime moves it; whoever draws the video follows it.
public struct Playhead: Sendable, Hashable {
    /// Seconds from the start of the video.
    public var time: Double
    /// Whether it is moving: playing, at a rate other than 0, and not stopped at an end.
    public var isPlaying: Bool

    public init(time: Double, isPlaying: Bool) {
        self.time = time
        self.isPlaying = isPlaying
    }
}

/// Which view an extension draws here, and the values of its inputs for one frame: what is
/// stored on the view, with what cables bring on top.
public struct ResolvedCustom: Sendable, Hashable {
    public var kind: String
    public var values: [String: Value]

    public init(kind: String, values: [String: Value] = [:]) {
        self.kind = kind
        self.values = values
    }
}

/// A shader view's source and the values of its inputs for one frame.
public struct ResolvedShader: Sendable, Hashable {
    public var source: String
    /// By input name: what is stored on the view, with what cables bring on top. An input
    /// that is not here has the value its source gives it.
    public var values: [String: Value]
    /// Seconds the prototype has run, for a shader that reads the time; 0 for one that does not.
    public var time = 0.0

    public init(source: String, values: [String: Value] = [:], time: Double = 0) {
        self.source = source
        self.values = values
        self.time = time
    }
}
