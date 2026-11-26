import AppKit
import PaperEngine
import PaperHost
import PaperModel
import PaperRender
import SwiftUI
import UniformTypeIdentifiers

extension ColorValue {
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    init(_ color: Color) {
        let converted = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(
            red: converted.redComponent, green: converted.greenComponent,
            blue: converted.blueComponent, alpha: converted.alphaComponent
        )
    }
}

/// One row of the Inspector: a single input, or several that read as one thing, such as
/// Position (X and Y) or the four sides of the padding. Each input of a row keeps its own
/// port; the letters say which field is which.
struct InspectorRow: Hashable {
    let label: String?
    let inputs: [String]
    let suffixes: [String]

    static func one(_ id: String) -> InspectorRow { InspectorRow(label: nil, inputs: [id], suffixes: [""]) }
    static func group(_ label: String, _ inputs: [String], _ suffixes: [String]) -> InspectorRow {
        InspectorRow(label: label, inputs: inputs, suffixes: suffixes)
    }
}

/// The Inspector's sections and the rows in each, by port id. A row whose inputs a view
/// does not have is left out; a group keeps the ones it has.
let inspectorSections: [(title: String, symbol: String, rows: [InspectorRow])] = [
    ("Frame", "rectangle.dashed", [
        .group("Position", ["x", "y"], ["X", "Y"]),
        .group("Size", ["width", "height"], ["W", "H"]),
        .one("anchor"), .one("rotation"), .one("scale"),
    ]),
    ("In a Stack or Grid", "rectangle.split.3x1", [.one("widthMode"), .one("heightMode"), .one("absolute")]),
    ("Children", "square.grid.2x2", [
        .one("layout"), .one("axis"), .one("columns"), .one("alignment"), .one("distribution"), .one("spacing"),
        .group("Padding", ["paddingHorizontal", "paddingVertical"], ["H", "V"]),
        .group("Sides", ["paddingTop", "paddingRight", "paddingBottom", "paddingLeft"], ["T", "R", "B", "L"]),
        .one("pageSize"),
    ]),
    ("Appearance", "paintpalette", [
        .one("visible"), .one("opacity"), .one("fill"), .one("backgroundBlur"), .one("cornerRadius"),
        .group("Stroke", ["strokeColor", "strokeWidth"], ["", "W"]),
        .one("clips"),
    ]),
    ("Text", "textformat", [
        .one("text"), .one("placeholder"), .one("fontFamily"),
        .group("Size & Weight", ["fontSize", "fontWeight"], ["pt", "wt"]), .one("italic"),
        .one("textColor"), .one("textAlignment"), .one("singleLine"), .one("padding"),
    ]),
    ("Image", "photo", [.one("image")]),
    ("Video", "play.rectangle", [
        .one("video"), .one("contentMode"), .one("playing"), .one("loops"), .one("time"), .one("playbackRate"),
        .one("muted"), .one("volume"),
    ]),
    ("Symbol", "star", [.one("symbol")]),
    ("Shadow", "shadow", [.one("shadowColor"), .one("shadowRadius"), .one("shadowOffset")]),
    ("Interaction", "hand.tap", [.one("enabled")]),
]

/// SF Symbols for the choices of a property that has a few, so they can be a segmented
/// control of icons. Alignment and distribution are drawn along the stack's own axis.
func optionSymbols(for property: LayerProperty, in layer: Layer) -> [String: String]? {
    let vertical = layer.value(.axis).textValue != "Horizontal"
    switch property {
    case .layout:
        return ["None": "rectangle.dashed", "Stack": "rectangle.split.1x2", "Grid": "square.grid.2x2"]
    case .axis:
        return ["Vertical": "arrow.down", "Horizontal": "arrow.right"]
    case .alignment:
        return vertical
            ? ["Start": "align.horizontal.left", "Center": "align.horizontal.center", "End": "align.horizontal.right"]
            : ["Start": "align.vertical.top", "Center": "align.vertical.center", "End": "align.vertical.bottom"]
    case .distribution:
        return vertical
            ? ["Start": "align.vertical.top", "Center": "align.vertical.center", "End": "align.vertical.bottom", "Space Between": "distribute.vertical.center"]
            : ["Start": "align.horizontal.left", "Center": "align.horizontal.center", "End": "align.horizontal.right", "Space Between": "distribute.horizontal.center"]
    case .contentMode:
        return ["Fill": "rectangle.fill", "Fit": "rectangle.center.inset.filled"]
    case .textAlignment:
        return ["Left": "text.alignleft", "Center": "text.aligncenter", "Right": "text.alignright"]
    case .widthMode:
        return ["Fixed": "lock", "Grow": "arrow.left.and.right", "Auto": "arrow.right.and.line.vertical.and.arrow.left"]
    case .heightMode:
        return ["Fixed": "lock", "Grow": "arrow.up.and.down", "Auto": "arrow.down.and.line.horizontal.and.arrow.up"]
    default:
        return nil
    }
}

/// Edits the selected view's inputs in a standard grouped form. The dot beside an input
/// shows or hides it as a port on the view's patch; a cable can also be dropped on a row.
struct InspectorView: View {
    let store: DocumentStore
    /// The sections the person folded away, by title, remembered between launches.
    @AppStorage("inspectorCollapsedSections") private var collapsed = ""

    private func expanded(_ title: String) -> Binding<Bool> {
        Binding(
            get: { !collapsed.split(separator: "|").contains { $0 == title } },
            set: { isExpanded in
                var titles = Set(collapsed.split(separator: "|").map(String.init))
                if isExpanded { titles.remove(title) } else { titles.insert(title) }
                collapsed = titles.sorted().joined(separator: "|")
            }
        )
    }

    var body: some View {
        if let layer = store.selectedLayer {
            let inputs = layer.inputs
            Form {
                Section {
                    LabeledContent {
                        // What it is, unless its name already says so ("Device").
                        if layer.kind != .view || layer.id == store.document.screen.id || layer.isPage, layer.typeName != layer.name {
                            Text(layer.typeName).foregroundStyle(.secondary)
                        }
                    } label: {
                        Label(layer.name, systemImage: LayerRow.symbol(for: layer))
                            .font(.headline)
                    }
                    // A view, a stack, a grid and a scroll view are one thing with different
                    // settings, so one becomes another without losing its cables or children.
                    // A screen is arranged from its Arrange Children section instead.
                    if layer.kind == .view, layer.id != store.document.screen.id, !layer.isPage {
                        Picker("Type", selection: Binding(
                            get: { layer.type }, set: { store.convert(layer.id, to: $0) }
                        )) {
                            ForEach(DocumentStore.convertibleTypes, id: \.self) { Text($0.displayName).tag($0) }
                            // What an extension draws is not something to change to, but it
                            // is what this view is until it is changed.
                            if layer.type == .custom {
                                Text(store.customView(of: layer)?.name ?? ViewType.custom.displayName).tag(ViewType.custom)
                            }
                        }
                    }
                }
                if layer.isPage || (layer.kind == .screen && !layer.pages.isEmpty) {
                    Section {
                        EmptyView()
                    } footer: {
                        Text(layer.isPage
                             ? "One of the prototype's screens. It fills the device; the first screen is where the prototype starts. Draw a flow to it from a view on the Canvas."
                             : "The device the screens are shown on: its size is every screen's size, and its fill shows behind screens while they move.")
                    }
                }
                if let component = store.component(of: layer) {
                    Section {
                        ForEach(component.inputs) { port in
                            ComponentInputRow(store: store, layer: layer, port: port)
                        }
                        Button("Edit Component", systemImage: "square.and.pencil") {
                            store.enterComponent(component.id)
                        }
                    } header: {
                        Text(component.name)
                    } footer: {
                        if let summary = component.summary { Text(summary) }
                    }
                }
                if let custom = layer.custom {
                    let view = store.registry.view(custom.kind)
                    Section {
                        ForEach(view?.inputs ?? []) { port in
                            CustomInputRow(store: store, layer: layer, port: port)
                        }
                    } header: {
                        Text(view?.name ?? ViewType.custom.displayName)
                    } footer: {
                        if let patch = store.viewNode(for: layer.id), let missing = store.missingExtension(for: patch) {
                            Label("This view is drawn by the extension \(missing), which is not installed or is switched off.", systemImage: "puzzlepiece.extension")
                                .foregroundStyle(.orange)
                        } else if let view {
                            Text(view.summary.isEmpty ? "Drawn by the extension \(view.origin.name). Its inputs are ports on the view's patch." : view.summary)
                        }
                    }
                }
                if let scene = layer.scene {
                    SceneSections(store: store, layer: layer, scene: scene)
                }
                if let shader = layer.shader {
                    Section {
                        ForEach(ShaderSource.uniforms(of: shader), id: \.name) { uniform in
                            ShaderInputRow(store: store, layer: layer, uniform: uniform)
                        }
                        Button("Edit Shader…", systemImage: "chevron.left.forwardslash.chevron.right") {
                            store.editingShader = layer.id
                        }
                    } header: {
                        Text("Shader")
                    } footer: {
                        if let problem = ShaderCompiler.error(in: shader.source) {
                            Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        } else {
                            Text("Metal code draws this view. It can read the views inside it, and its inputs are ports on the view's patch.")
                        }
                    }
                }
                if let patch = store.viewNode(for: layer.id), let published = patch.published, !published.isEmpty {
                    Section {
                        ForEach(published) { port in
                            LabeledContent {
                                TextValueField(text: port.name) { store.renamePublished(port.id, on: patch.id, to: $0) }
                                Button("Unpublish", systemImage: "minus.circle") { store.unpublish(port.id, on: patch.id) }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.borderless)
                            } label: {
                                Label(port.isOutput ? "Output" : "Input", systemImage: port.isOutput ? "arrow.right.circle" : "arrow.left.circle")
                            }
                        }
                    } header: {
                        Text("Published Ports")
                    } footer: {
                        Text("Ports from inside this view that show on its patch. Step into the view and right-click a port to publish another.")
                    }
                }
                if let source = layer.source {
                    Section {
                        LabeledContent("Source") { Text(source).textSelection(.enabled) }
                    } footer: {
                        Text("Where this view comes from in code. The agent that sketched it uses this to carry your changes back.")
                    }
                }
                ForEach(inspectorSections, id: \.title) { section in
                    let rows: [(row: InspectorRow, inputs: [ViewInput], suffixes: [String])] = section.rows.compactMap { row in
                        let present = row.inputs.indices.filter { index in inputs.contains { $0.id == row.inputs[index] } }
                        guard !present.isEmpty else { return nil }
                        return (row, present.compactMap { index in inputs.first { $0.id == row.inputs[index] } }, present.map { row.suffixes[$0] })
                    }
                    if !rows.isEmpty {
                        Section(isExpanded: expanded(section.title)) {
                            ForEach(rows, id: \.row) { item in
                                if let label = item.row.label, item.inputs.count > 1 {
                                    InputGroupRow(store: store, layer: layer, label: label, inputs: item.inputs, suffixes: item.suffixes)
                                } else {
                                    InputRow(store: store, layer: layer, input: item.inputs[0])
                                }
                            }
                        } header: {
                            Text(title(of: section.title, for: layer))
                        }
                    }
                }
                if layer.id != store.document.screen.id, !layer.isPage {
                    Section {
                        ForEach(ViewOutput.allCases) { output in
                            FrameOutputRow(store: store, layer: layer, output: output)
                        }
                    } header: {
                        Text("Frame Outputs")
                    } footer: {
                        Text("Where layout put this view on the last frame, as outputs of its patch. Click a dot to show one as a port.")
                    }
                }
            }
            .formStyle(.grouped)
            // Its own fields per view, so an address half typed for one never lands on another.
            .id(layer.id)
        } else if let patch = store.selectedPatch {
            PatchInspector(store: store, node: patch)
                // Its own fields per patch, so a name half typed for one never lands on another.
                .id(patch.id)
        } else {
            ContentUnavailableView(
                store.selectedNodes.count > 1 ? "\(store.selectedNodes.count) Patches Selected" : "No Selection",
                systemImage: "slider.horizontal.3",
                description: Text("Select a view to edit its properties and choose its ports, or a patch to edit its inputs.")
            )
        }
    }

    /// The Children section is named for what the view does with them.
    private func title(of section: String, for layer: Layer) -> String {
        if section == "Frame", layer.kind == .screen, !layer.pages.isEmpty { return "Size of Every Screen" }
        guard section == "Children" else { return section }
        if layer.isPage { return "Arrange Children" }
        switch layer.arrangement {
        case .stack: return layer.kind == .screen ? "Arrange Children" : "Stack"
        case .grid: return layer.kind == .screen ? "Arrange Children" : "Grid"
        case .scrollView: return "Scroll View"
        default: return "Arrange Children"
        }
    }
}

/// One published input of a component instance: edit its value here, or click its name to
/// show the instance's patch so a cable can drive it.
struct ComponentInputRow: View {
    let store: DocumentStore
    let layer: Layer
    let port: ComponentPort

    private var patch: PatchNode? { store.componentPatch(for: layer.id) }

    private var isDriven: Bool {
        guard let patch else { return false }
        return store.document.graph.connection(into: PortRef(node: patch.id, port: port.id)) != nil
    }

    private var value: Value {
        layer.component?.inputs[port.id]?.coerced(to: port.type) ?? port.defaultValue
    }

    var body: some View {
        LabeledContent {
            if isDriven, let patch {
                let _ = store.liveTick
                Text(store.runtime?.inputValue(PortRef(node: patch.id, port: port.id))?.summary ?? "–")
                    .monospacedDigit()
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                    .help("Driven by the patch graph")
            } else {
                ValueEditor(value: value, type: port.type, options: port.options, name: port.name) { new, interactive in
                    store.setComponentInput(port.id, of: layer.id, to: new, interactive: interactive)
                    if interactive { store.endInteractiveSoon("Change \(port.name)") }
                }
            }
        } label: {
            Button {
                store.revealComponentPatch(for: layer.id)
            } label: {
                Label(port.name, systemImage: isDriven ? "circle.fill" : patch == nil ? "circle" : "circle.inset.filled")
                    .foregroundStyle(isDriven ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            }
            .buttonStyle(.plain)
            .help("Click to show this component's patch, to drive \(port.name) with a cable")
        }
    }
}

/// A standard control for a value of any type.
struct ValueEditor: View {
    let value: Value
    let type: PortType
    let options: [String]
    let name: String
    /// Called with the new value and whether it is one of a stream of changes.
    let set: (Value, Bool) -> Void

    var body: some View {
        switch type {
        case .number:
            NumberField(label: nil, value: value.numberValue) { set(.number($0), false) }
        case .point:
            let point = value.pointValue
            HStack(spacing: 6) {
                NumberField(label: "X", value: point.x) { set(.point(Point2(x: $0, y: point.y)), false) }
                NumberField(label: "Y", value: point.y) { set(.point(Point2(x: point.x, y: $0)), false) }
            }
        case .size:
            let size = value.sizeValue
            HStack(spacing: 6) {
                NumberField(label: "W", value: size.width) { set(.size(Size2(width: max($0, 0), height: size.height)), false) }
                NumberField(label: "H", value: size.height) { set(.size(Size2(width: size.width, height: max($0, 0))), false) }
            }
        case .color:
            ColorPicker("", selection: Binding(get: { value.colorValue.color }, set: { set(.color(ColorValue($0)), true) }))
                .labelsHidden()
        case .bool:
            Toggle("", isOn: Binding(get: { value.boolValue }, set: { set(.bool($0), false) }))
                .labelsHidden()
                .toggleStyle(.checkbox)
        case .text:
            if options.isEmpty {
                TextValueField(text: value.textValue) { set(.text($0), false) }
            } else {
                Picker(name, selection: Binding(get: { value.textValue }, set: { set(.text($0), false) })) {
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }
        case .pulse, .array, .json:
            Text("Connect a cable").foregroundStyle(.secondary)
        }
    }
}

/// One input of the selected view: its value, and whether its patch shows it as a port.
struct InputRow: View {
    let store: DocumentStore
    let layer: Layer
    let input: ViewInput

    /// Whether a cable currently drives this input. A cable into the whole position or
    /// size drives each of its numbers too.
    private var isDriven: Bool {
        guard let patch = store.viewNode(for: layer.id) else { return false }
        let ports = input.part == nil ? [input.id] : [input.id, input.property.rawValue]
        return ports.contains { store.document.graph.connection(into: PortRef(node: patch.id, port: $0)) != nil }
    }

    private var isShown: Bool { store.showsPort(input, of: layer.id) }

    /// A stack or grid places its children, so their x and y are not theirs to set.
    private var isPlacedByParent: Bool {
        (input.part == .x || input.part == .y) && store.isPlacedByParent(layer.id)
    }

    var body: some View {
        LabeledContent {
            if isDriven {
                DrivenValue(store: store, layerID: layer.id, input: input)
            } else if input.part != nil {
                NumberField(label: nil, value: input.value(in: layer).numberValue) {
                    store.setInput(input, of: layer.id, to: .number($0))
                }
                .disabled(isPlacedByParent)
                .help(isPlacedByParent ? "The stack or grid this view is in places it." : "")
            } else {
                PropertyEditor(store: store, layer: layer, property: input.property)
            }
        } label: {
            Button {
                if isDriven {
                    store.revealPropertyPatch(input.property, of: layer.id)
                } else {
                    store.setPort(input, of: layer.id, shown: !isShown)
                }
            } label: {
                Label(
                    input.name,
                    systemImage: isDriven ? "circle.fill" : isShown ? "circle.inset.filled" : "circle"
                )
                .foregroundStyle(isDriven ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            }
            .buttonStyle(.plain)
            .help(isDriven
                ? "A cable drives \(input.name). Click to show it in the graph."
                : isShown ? "Click to hide the \(input.name) port on this view's patch"
                : "Click to show \(input.name) as a port on this view's patch")
        }
        .listRowBackground(store.cableDropProperty == input ? Color.accentColor.opacity(0.25) : nil)
        .background(DropTargetReporter(store: store, input: input))
    }
}

/// Several inputs that read as one, such as Position: a field for each, one label. Clicking
/// the label shows or hides all their ports at once; each field's context menu does one.
struct InputGroupRow: View {
    let store: DocumentStore
    let layer: Layer
    let label: String
    let inputs: [ViewInput]
    let suffixes: [String]

    private func isDriven(_ input: ViewInput) -> Bool {
        guard let patch = store.viewNode(for: layer.id) else { return false }
        let ports = input.part == nil ? [input.id] : [input.id, input.property.rawValue]
        return ports.contains { store.document.graph.connection(into: PortRef(node: patch.id, port: $0)) != nil }
    }

    private func isShown(_ input: ViewInput) -> Bool { store.showsPort(input, of: layer.id) }

    /// Two boxes take the width of two ordinary ones; four share it.
    private var fieldWidth: CGFloat {
        inputs.count <= 2 ? NumberField.width : (NumberField.width * 2 + 6 - CGFloat(inputs.count - 1) * 4) / CGFloat(inputs.count)
    }

    var body: some View {
        let driven = inputs.filter(isDriven)
        let allShown = inputs.allSatisfy(isShown)
        let anyShown = inputs.contains(where: isShown)
        LabeledContent {
            HStack(spacing: inputs.count <= 2 ? 6 : 4) {
                ForEach(Array(inputs.enumerated()), id: \.element) { index, input in
                    field(input, suffix: suffixes[index])
                        .overlay {
                            if store.cableDropProperty == input {
                                RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2)
                            }
                        }
                        .background(DropTargetReporter(store: store, input: input))
                        .contextMenu {
                            if isDriven(input) {
                                Button("Show \(input.name) Cable in Graph") { store.revealPropertyPatch(input.property, of: layer.id) }
                            } else {
                                Button(isShown(input) ? "Hide \(input.name) Port" : "Show \(input.name) as Port") {
                                    store.setPort(input, of: layer.id, shown: !isShown(input))
                                }
                            }
                        }
                }
            }
        } label: {
            Button {
                if let first = driven.first {
                    store.revealPropertyPatch(first.property, of: layer.id)
                } else {
                    for input in inputs { store.setPort(input, of: layer.id, shown: !allShown) }
                }
            } label: {
                Label(label, systemImage: !driven.isEmpty ? "circle.fill" : allShown ? "circle.inset.filled" : anyShown ? "circle.lefthalf.filled" : "circle")
                    .foregroundStyle(driven.isEmpty ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
            }
            .buttonStyle(.plain)
            .help(!driven.isEmpty
                ? "A cable drives \(label). Click to show it in the graph."
                : allShown ? "Click to hide the \(label) ports on this view's patch"
                : "Click to show \(label) as ports on this view's patch. Right-click a field for one port.")
        }
    }

    @ViewBuilder private func field(_ input: ViewInput, suffix: String) -> some View {
        if isDriven(input) {
            DrivenValue(store: store, layerID: layer.id, input: input)
                .frame(width: fieldWidth, alignment: .leading)
        } else if input.part != nil {
            let placed = (input.part == .x || input.part == .y) && store.isPlacedByParent(layer.id)
            NumberField(label: suffix, value: input.value(in: layer).numberValue, width: fieldWidth) {
                store.setInput(input, of: layer.id, to: .number($0))
            }
            .disabled(placed)
            .help(placed ? "The stack or grid this view is in places it." : input.name)
        } else if input.type == .number {
            NumberField(label: suffix, value: input.value(in: layer).numberValue, width: fieldWidth) {
                store.setProperty(input.property, of: layer.id, to: .number($0))
            }
            .help(input.name)
        } else {
            PropertyEditor(store: store, layer: layer, property: input.property)
                .help(input.name)
        }
    }
}

/// The live value of an input that the graph controls.
struct DrivenValue: View {
    let store: DocumentStore
    let layerID: LayerID
    let input: ViewInput

    var body: some View {
        // Reading liveTick re-renders this a few times a second while the prototype runs.
        let _ = store.liveTick
        Text(store.liveValue(input.property, of: layerID).map { input.value(from: $0).summary } ?? "–")
            .monospacedDigit()
            .foregroundStyle(.tint)
            .lineLimit(1)
            .help("Driven by the patch graph")
    }
}

struct PropertyEditor: View {
    let store: DocumentStore
    let layer: Layer
    let property: LayerProperty

    private var value: Value { layer.value(property) }

    private func set(_ value: Value) {
        store.setProperty(property, of: layer.id, to: value)
    }

    var body: some View {
        switch property.type {
        case .number:
            NumberField(label: nil, value: value.numberValue) { set(.number($0)) }
        case .point:
            let point = value.pointValue
            HStack(spacing: 6) {
                NumberField(label: "X", value: point.x) { set(.point(Point2(x: $0, y: point.y))) }
                NumberField(label: "Y", value: point.y) { set(.point(Point2(x: point.x, y: $0))) }
            }
        case .size:
            let size = value.sizeValue
            HStack(spacing: 6) {
                NumberField(label: "W", value: size.width) { set(.size(Size2(width: max($0, 0), height: size.height))) }
                NumberField(label: "H", value: size.height) { set(.size(Size2(width: size.width, height: max($0, 0)))) }
            }
        case .color:
            HStack(spacing: 6) {
                ColorPicker("", selection: Binding(
                    get: { value.colorValue.color },
                    set: { newColor in
                        // The picker reports continuously; fold the stream into one undo step.
                        store.setProperty(property, of: layer.id, to: .color(ColorValue(newColor)), interactive: true)
                        store.endInteractiveSoon("Change \(property.displayName)")
                    }
                ))
                .labelsHidden()
            }
        case .bool:
            Toggle("", isOn: Binding(get: { value.boolValue }, set: { set(.bool($0)) }))
                .labelsHidden()
                .toggleStyle(.checkbox)
        case .text:
            if property == .image {
                ImageField(store: store, layer: layer)
            } else if property == .fontFamily {
                FontField(family: value.textValue) { set(.text($0)) }
            } else if property == .symbol {
                SymbolField(symbol: value.textValue) { set(.text($0)) }
            } else if property == .video {
                VideoField(store: store, layer: layer)
            } else if let symbols = optionSymbols(for: property, in: layer) {
                Picker(property.displayName, selection: Binding(get: { value.textValue }, set: { set(.text($0)) })) {
                    ForEach(property.options, id: \.self) { option in
                        Label(option, systemImage: symbols[option] ?? "questionmark")
                            .labelStyle(.iconOnly)
                            .help(option)
                            .tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } else if !property.options.isEmpty {
                Picker(property.displayName, selection: Binding(get: { value.textValue }, set: { set(.text($0)) })) {
                    ForEach(property.options, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            } else {
                TextValueField(text: value.textValue) { set(.text($0)) }
            }
        case .pulse, .array, .json:
            EmptyView()
        }
    }
}

/// A compact number box that commits on Return or when focus leaves. A label, such as X
/// or W, sits inside the box after the number, as in Xcode's and Keynote's inspectors.
struct NumberField: View {
    /// The width every number box has unless a row asks for narrower ones, so boxes line up
    /// in columns down the Inspector.
    static let width: CGFloat = 76

    let label: String?
    let value: Double
    var width: CGFloat = NumberField.width
    let commit: (Double) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label ?? "Value", text: $draft)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.leading)
            .monospacedDigit()
            .focused($focused)
            .onSubmit(apply)
            .onChange(of: focused) { _, isFocused in
                if !isFocused { apply() }
            }
            .overlay(alignment: .trailing) {
                if let label, !label.isEmpty {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 6)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: width)
            .onAppear { draft = Value.format(value) }
            .onChange(of: value) { _, newValue in
                if !focused { draft = Value.format(newValue) }
            }
    }

    private func apply() {
        let cleaned = draft.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        if let parsed = Double(cleaned), parsed.isFinite {
            if parsed != value { commit(parsed) }
            draft = Value.format(parsed)
        } else {
            draft = Value.format(value)
        }
    }
}

struct TextValueField: View {
    let text: String
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Text", text: $draft)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit { if draft != text { commit(draft) } }
            .onChange(of: focused) { _, isFocused in
                if !isFocused, draft != text { commit(draft) }
            }
            .onAppear { draft = text }
            .onChange(of: text) { _, newValue in
                if !focused { draft = newValue }
            }
    }
}

/// Picks an image file and stores it in the document's assets.
struct ImageField: View {
    let store: DocumentStore
    let layer: Layer

    var body: some View {
        let name = layer.value(.image).textValue
        HStack(spacing: 6) {
            Text(name.isEmpty ? "None" : name)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button("Choose…") { choose() }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        store.setProperty(.image, of: layer.id, to: .text(store.addAsset(data, named: url.lastPathComponent)))
    }
}

/// Picks a movie file and stores it in the document's assets, or takes a web address typed
/// into the box.
struct VideoField: View {
    let store: DocumentStore
    let layer: Layer

    var body: some View {
        HStack(spacing: 6) {
            TextValueField(text: layer.value(.video).textValue) { store.setProperty(.video, of: layer.id, to: .text($0)) }
                .help("A movie in the document, or a web address")
            Button("Choose…") { choose() }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = VideoFiles.types
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        store.setProperty(.video, of: layer.id, to: .text(store.addAsset(data, named: url.lastPathComponent)))
    }
}

/// Tells the store where an input's row is on screen, so a cable dragged out of the Patch
/// Editor can be dropped on it.
struct DropTargetReporter: NSViewRepresentable {
    let store: DocumentStore
    let input: ViewInput

    final class Marker: NSView {
        var property: ViewInput?
        weak var store: DocumentStore?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            register()
        }

        func register() {
            guard let property, let store else { return }
            if window == nil {
                return
            }
            store.propertyDropTargets[property] = { [weak self] in
                guard let self, self.window != nil else { return nil }
                return self.convert(self.bounds, to: nil)
            }
        }
    }

    func makeNSView(context: Context) -> Marker {
        let marker = Marker()
        marker.property = input
        marker.store = store
        return marker
    }

    func updateNSView(_ marker: Marker, context: Context) {
        marker.property = input
        marker.store = store
        marker.register()
    }
}

/// One input of a view an extension draws: its value, or what the graph is driving it with.
struct CustomInputRow: View {
    let store: DocumentStore
    let layer: Layer
    let port: PaperEngine.Port

    private var patch: PatchNode? { store.viewNode(for: layer.id) }
    private var portID: String { CustomViewUse.portID(port.id) }

    private var isDriven: Bool {
        guard let patch else { return false }
        return store.document.graph.connection(into: PortRef(node: patch.id, port: portID)) != nil
    }

    var body: some View {
        LabeledContent {
            if isDriven, let patch {
                let _ = store.liveTick
                Text(store.runtime?.inputValue(PortRef(node: patch.id, port: portID))?.summary ?? "–")
                    .monospacedDigit()
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                    .help("Driven by the patch graph")
            } else {
                ValueEditor(
                    value: layer.custom?.inputs[port.id]?.coerced(to: port.type) ?? port.defaultValue,
                    type: port.type, options: port.options, name: port.name
                ) { new, interactive in
                    store.setCustomInput(port.id, of: layer.id, to: new, interactive: interactive)
                    if interactive { store.endInteractiveSoon("Change \(port.name)") }
                }
            }
        } label: {
            Text(port.name)
        }
    }
}

/// One frame output of the selected view: where layout put it, what it is cabled to, and a
/// dot that shows or hides it as a port on the view's patch.
struct FrameOutputRow: View {
    let store: DocumentStore
    let layer: Layer
    let output: ViewOutput

    var body: some View {
        let patch = store.viewNode(for: layer.id)
        let targets = patch.map { store.cableTargets(from: PortRef(node: $0.id, port: output.id)) } ?? []
        let shown = store.showsOutput(output, of: layer.id)
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                let _ = store.liveTick
                Text(store.liveFrame(output, of: layer.id)?.summary ?? "–")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Where the running prototype laid this view out")
                CableTargetList(store: store, targets: targets)
            }
        } label: {
            Button {
                if targets.isEmpty { store.setOutputPort(output, of: layer.id, shown: !shown) }
            } label: {
                Label(output.name, systemImage: !targets.isEmpty ? "circle.fill" : shown ? "circle.inset.filled" : "circle")
                    .foregroundStyle(targets.isEmpty ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
            }
            .buttonStyle(.plain)
            .help(!targets.isEmpty ? "A cable leaves \(output.name), so it shows on the patch."
                : shown ? "Click to hide the \(output.name) output on this view's patch"
                : "Click to show \(output.name) as an output on this view's patch")
        }
    }
}

/// The inputs each cable from an output goes to, each a link that shows that patch.
struct CableTargetList: View {
    let store: DocumentStore
    let targets: [DocumentStore.CableEnd]

    var body: some View {
        ForEach(targets, id: \.self) { target in
            CableLink(store: store, end: target, word: "to")
        }
    }
}

/// The other end of a cable, as a sentence: "from Row › Tapped" or "to Card › Height",
/// the name a link that shows that patch in the graph.
struct CableLink: View {
    let store: DocumentStore
    let end: DocumentStore.CableEnd
    /// "from" for where an input's cable comes from, "to" for where an output's goes.
    let word: String

    var body: some View {
        HStack(spacing: 4) {
            Text(word).foregroundStyle(.secondary)
            Button(end.shortName) { store.show(end.ref.node) }
                .buttonStyle(.link)
        }
        .lineLimit(1)
        .help("\(word == "from" ? "Comes from" : "Goes to") \(end.fullName). Click to show it in the graph.")
    }
}

/// The Inspector for one selected patch that is not a view: its name, its inputs as the
/// same controls the view properties use, and its outputs with their live values and where
/// they go. Edits go through the store, so each is an undo step.
struct PatchInspector: View {
    let store: DocumentStore
    let node: PatchNode

    var body: some View {
        let definition = store.registry.definition(node.kind)
        let ports = store.visiblePorts(for: node)
        Form {
            Section {
                LabeledContent("Name") {
                    TextValueField(text: store.title(for: node)) { store.renamePatch(node.id, to: $0) }
                }
                if let definition, definition.isGeneric {
                    Picker("Type", selection: Binding(
                        get: { store.registry.valueType(for: node) },
                        set: { store.setValueType($0, node: node.id) }
                    )) {
                        ForEach(definition.genericTypes, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
                if let count = store.registry.variableInputCount(for: node) {
                    LabeledContent("Inputs") {
                        Stepper("\(count.count)",
                                onIncrement: count.count < count.range.upperBound ? { store.changeInputCount(of: node.id, by: 1) } : nil,
                                onDecrement: count.count > count.range.lowerBound ? { store.changeInputCount(of: node.id, by: -1) } : nil)
                    }
                }
                if let layerID = node.layerID {
                    LabeledContent("View") {
                        Button(store.document.layer(layerID)?.name ?? "Missing View") {
                            if let patch = store.viewNode(for: layerID) { store.show(patch.id) }
                        }
                        .buttonStyle(.link)
                    }
                }
                if node.kind == PatchKind.javascript {
                    Button("Edit Script…", systemImage: "curlybraces") { store.editingScript = node.id }
                }
            } header: {
                // The icon in the patch's own color, as its header is in the graph.
                Label {
                    Text(definition?.name ?? store.registry.defaultTitle(for: node))
                } icon: {
                    Image(systemName: patchSymbol(node.kind, category: definition?.category))
                        .foregroundStyle(Color(nsColor: definition.map { PatchStyle.color(for: $0.category) } ?? .secondaryLabelColor))
                }
                .font(.headline)
            } footer: {
                if let missing = store.missingExtension(for: node) {
                    Label("This patch comes from the extension \(missing), which is not installed or is switched off.", systemImage: "puzzlepiece.extension")
                        .foregroundStyle(.orange)
                } else if let summary = definition?.summary, !summary.isEmpty {
                    Text(summary)
                }
            }
            if !ports.inputs.isEmpty {
                Section("Inputs") {
                    ForEach(ports.inputs) { port in
                        PatchInputRow(store: store, node: node, port: port)
                    }
                }
            }
            if !ports.outputs.isEmpty {
                Section("Outputs") {
                    ForEach(ports.outputs) { port in
                        PatchOutputRow(store: store, node: node, port: port)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// One input of the inspected patch: its value to edit, or where its cable comes from
/// and, while the prototype runs, what arrives on it.
struct PatchInputRow: View {
    let store: DocumentStore
    let node: PatchNode
    let port: PaperEngine.Port

    var body: some View {
        let ref = PortRef(node: node.id, port: port.id)
        let source = store.cableSource(into: ref)
        LabeledContent {
            if let source {
                VStack(alignment: .trailing, spacing: 2) {
                    CableLink(store: store, end: source, word: "from")
                    let _ = store.liveTick
                    if let live = PatchPortValue.shown(store.liveInputValues(of: ref), type: port.type) {
                        Text(live).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                            .help("What arrives while the prototype runs")
                    }
                }
            } else {
                ValueEditor(value: store.literal(for: port, of: node), type: port.type, options: port.options, name: port.name) { new, interactive in
                    store.setLiteral(new, node: node.id, port: port.id, interactive: interactive)
                    if interactive { store.endInteractiveSoon("Change \(port.name)") }
                }
            }
        } label: {
            Text(port.name).help(port.type.displayName)
        }
        .contextMenu {
            if source != nil {
                Button("Disconnect") { store.disconnect(input: ref) }
            }
        }
    }
}

/// One output of the inspected patch: where it goes, and its value while the prototype runs.
struct PatchOutputRow: View {
    let store: DocumentStore
    let node: PatchNode
    let port: PaperEngine.Port

    var body: some View {
        let ref = PortRef(node: node.id, port: port.id)
        let targets = store.cableTargets(from: ref)
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                let _ = store.liveTick
                if let live = PatchPortValue.shown(store.liveValues(of: ref), type: port.type) {
                    Text(live).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                        .help("The value while the prototype runs")
                }
                if targets.isEmpty {
                    Text("Not connected").foregroundStyle(.tertiary)
                } else {
                    CableTargetList(store: store, targets: targets)
                }
            }
        } label: {
            Text(port.name).help(port.type.displayName)
        }
    }
}

/// What the Inspector shows of a port's live value.
enum PatchPortValue {
    /// The value, or nil when there is nothing worth showing: the prototype is not
    /// running, or it is a pulse, which is there for a single frame and reads "–" the rest
    /// of the time.
    static func shown(_ values: [Value], type: PortType) -> String? {
        guard type != .pulse else { return nil }
        return Value.liveSummary(values)
    }
}
