import Foundation
import PaperModel

/// Prebuilt components. Each is an ordinary component — layers and patches — so it can be
/// entered, studied and changed like one made in the document.
public enum ComponentLibrary {
    /// A part of the shelf, as it is listed where components are picked.
    public struct Group: Identifiable, Sendable {
        public let name: String
        public let components: [ComponentDefinition]
        public let templates: [ViewTemplate]
        public var id: String { name }
    }

    /// The shelf in the order it is shown.
    public static let groups: [Group] = [
        Group(name: "Controls", components: [
            button, toggle, slider, stepper, segmentedControl,
            textField, searchField, menuButton, progressBar, activityIndicator, pageControl,
        ], templates: []),
        Group(name: "Bars", components: [statusBar, navigationBar, largeTitleBar, tabBar, toolbar, homeIndicator], templates: []),
        Group(name: "Lists", components: [listRow, swipeActionsRow], templates: [listSection, form]),
        Group(name: "Presentations", components: [alert, actionSheet, contextMenu, keyboard], templates: [sheet]),
        Group(name: "Materials", components: [], templates: [glassPane]),
    ]

    /// Controls that look and behave like the standard iOS ones.
    public static let iOS: [ComponentDefinition] = groups.flatMap(\.components)

    public static func iOS(_ name: String) -> ComponentDefinition {
        iOS.first { $0.name == name }!
    }

    // MARK: Palette (the light values of `SystemStyle`, which a control starts with)

    static let blue = SystemStyle.blue.light
    static let green = SystemStyle.green.light
    static let controlFill = SystemStyle.controlFill.light
    static let secondaryLabel = SystemStyle.secondaryLabel.light
    static let tertiaryLabel = SystemStyle.tertiaryLabel.light
    static let bar = SystemStyle.bar.light
    static let pressed = SystemStyle.pressed.light
    static let knobShadow: [LayerProperty: Value] = [
        .shadowColor: .color(ColorValue(white: 0, alpha: 0.22)),
        .shadowRadius: .number(4),
        .shadowOffset: .point(Point2(x: 0, y: 2)),
    ]

    /// The knob of a switch: a pill two points in from the track.
    static func switchKnob() -> Layer {
        var properties: [LayerProperty: Value] = [
            .position: .point(Point2(x: 2, y: 2)), .size: .size(SystemStyle.knobSize),
            .cornerRadius: .number(SystemStyle.knobSize.height / 2), .fill: .color(.white),
        ]
        properties.merge(knobShadow) { _, new in new }
        return Layer(name: "Knob", kind: .view, properties: properties)
    }

    /// Where the knob stands when the switch is on.
    static let switchTravel = SystemStyle.switchSize.width - SystemStyle.knobSize.width - 2

    // MARK: Building

    typealias Builder = SampleDocuments.Builder

    /// Where patch number (`column`, `row`) goes in a component's graph.
    static func at(_ column: Double, _ row: Double) -> Point2 {
        Point2(x: 40 + column * 230, y: 50 + row * 150)
    }

    static func group(_ name: String, _ properties: [LayerProperty: Value], _ children: [Layer] = []) -> Layer {
        Layer(name: name, kind: .view, properties: properties, children: children)
    }

    static func text(_ name: String, _ string: String, size: Double = 17, weight: Double = 400,
                     color: ColorValue = .black, _ extra: [LayerProperty: Value] = [:]) -> Layer {
        var properties: [LayerProperty: Value] = [
            .text: .text(string), .fontSize: .number(size), .fontWeight: .number(weight),
            .textColor: .color(color), .widthMode: .text("Auto"), .heightMode: .text("Auto"),
            // Control labels stay on one line, like the system's.
            .singleLine: .bool(true),
        ]
        properties.merge(extra) { _, new in new }
        return Layer(name: name, kind: .text, properties: properties)
    }

    static func symbol(_ name: String, _ glyph: String, width: Double, height: Double, color: ColorValue,
                       weight: Double = 500, _ extra: [LayerProperty: Value] = [:]) -> Layer {
        var properties: [LayerProperty: Value] = [
            .symbol: .text(glyph), .size: .size(Size2(width: width, height: height)),
            .fill: .color(color), .fontWeight: .number(weight),
        ]
        properties.merge(extra) { _, new in new }
        return Layer(name: name, kind: .symbol, properties: properties)
    }

    static func size(_ width: Double, _ height: Double) -> Value { .size(Size2(width: width, height: height)) }

    /// `shippedViews` is for the eight controls that shipped before a patch's id stopped
    /// depending on how many views its component has: the number of views each had then.
    static func make(
        _ name: String, _ summary: String, root: Layer, placement: ComponentDefinition.Placement? = nil,
        shippedViews: Int = 0, _ build: (inout Builder) -> Void
    ) -> ComponentDefinition {
        var builder = Builder(screen: root)
        build(&builder)
        return stabilized(ComponentDefinition(
            name: name, root: builder.document.screen, graph: builder.document.graph,
            library: "iOS", summary: summary, placement: placement
        ), seed: "iOS/\(name)", shippedViews: shippedViews)
    }

    /// An id that is the same every time the app runs, so documents keep pointing at the
    /// same library component and the same published ports.
    static func stableID(_ text: String) -> UUID {
        func hash(_ seed: UInt64) -> UInt64 {
            var value = seed
            for byte in text.utf8 {
                value ^= UInt64(byte)
                value = value &* 0x0000_0100_0000_01B3
            }
            return value
        }
        var bytes = [UInt8]()
        for part in [hash(0xCBF2_9CE4_8422_2325), hash(0x8422_2325_CBF2_9CE4)] {
            withUnsafeBytes(of: part) { bytes.append(contentsOf: $0) }
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Gives a definition ids that are the same on every launch. A view's patch is named
    /// after its view, and every other patch after its place among those, so a control can
    /// be given another view later without the ids of its ports changing. Add patches after
    /// the ones a shipped control has; views can go anywhere.
    static func stabilized(_ definition: ComponentDefinition, seed: String, shippedViews: Int = 0) -> ComponentDefinition {
        var layerIDs: [UUID: UUID] = [:]
        var counter = 0
        func remap(_ layer: Layer) -> Layer {
            var copy = layer
            copy.id = stableID("\(seed)/layer/\(counter)")
            layerIDs[layer.id] = copy.id
            counter += 1
            copy.children = layer.children.map(remap)
            return copy
        }
        let root = remap(definition.root)
        var nodeIDs: [UUID: UUID] = [:]
        var placeAmongPatches = shippedViews
        let nodes = definition.graph.nodes.map { node in
            var copy = node
            copy.layerID = node.layerID.flatMap { layerIDs[$0] }
            if node.kind == PatchKind.view, let layer = copy.layerID {
                copy.id = stableID("\(seed)/view/\(layer.uuidString)")
            } else {
                copy.id = stableID("\(seed)/node/\(placeAmongPatches)")
                placeAmongPatches += 1
            }
            nodeIDs[node.id] = copy.id
            return copy
        }
        let connections = definition.graph.connections.compactMap { connection -> Connection? in
            guard let from = nodeIDs[connection.from.node], let to = nodeIDs[connection.to.node] else { return nil }
            return Connection(
                from: PortRef(node: from, port: connection.from.port), to: PortRef(node: to, port: connection.to.port)
            )
        }
        var result = definition
        result.id = stableID(seed)
        result.root = root
        result.graph = Graph(nodes: nodes, connections: connections)
        return result
    }
}

extension SampleDocuments.Builder {
    /// Publishes an input of the component being built.
    @discardableResult
    public mutating func input(_ name: String, _ type: PortType, _ value: Value, at position: Point2, options: [String] = []) -> NodeID {
        var inputs = ["value": value]
        // A text input that picks from a list says what is on it.
        if !options.isEmpty { inputs["options"] = .text(options.joined(separator: ", ")) }
        return document.graph.add(PatchNode(
            kind: PatchKind.componentInput, position: PatchGrid.snap(position), name: name, inputs: inputs, valueType: type
        ))
    }

    /// Publishes an output of the component being built.
    @discardableResult
    public mutating func output(_ name: String, _ type: PortType, at position: Point2) -> NodeID {
        document.graph.add(PatchNode(kind: PatchKind.componentOutput, position: PatchGrid.snap(position), name: name, valueType: type))
    }

    /// Adds a patch that attaches to a layer (Scroll, Layer Size).
    @discardableResult
    public mutating func bound(_ kind: String, to layer: LayerID, at position: Point2, inputs: [String: Value] = [:]) -> NodeID {
        document.graph.add(PatchNode(kind: kind, position: PatchGrid.snap(position), inputs: inputs, layerID: layer))
    }

    /// Places a component in the document: its definition, a layer using it, and the patch
    /// that exposes its ports. Input values are given by port name.
    public mutating func place(
        _ definition: ComponentDefinition, name: String? = nil, in parent: LayerID? = nil, at position: Point2 = .zero,
        width: Double? = nil, inputs: [String: Value] = [:], properties: [LayerProperty: Value] = [:],
        patchAt: Point2? = nil
    ) -> (layer: LayerID, node: NodeID?) {
        document.adopt(definition)
        var values: [String: Value] = [:]
        for (portName, value) in inputs {
            if let port = definition.input(named: portName) { values[port] = value }
        }
        var layer = definition.instance(name: name, at: position, inputs: values)
        if let width {
            layer.set(.size, .size(Size2(width: width, height: layer.value(.size).sizeValue.height)))
        }
        for (property, value) in properties { layer.set(property, value) }
        document.screen.insert(layer, into: parent ?? document.screen.id)
        let node = patchAt.map { view(layer.id, at: $0) }
        return (layer.id, node)
    }

    /// Connects by published port name on either end; plain port ids work for other patches.
    public mutating func wire(_ from: NodeID, _ output: String, to: NodeID, _ input: String) {
        func component(_ node: NodeID) -> ComponentDefinition? {
            guard let patch = document.graph.node(node), patch.isInstance else { return nil }
            return patch.componentID.flatMap { document.component($0) }
        }
        connect(
            from, component(from)?.output(named: output) ?? output,
            to: to, component(to)?.input(named: input) ?? input
        )
    }
}
