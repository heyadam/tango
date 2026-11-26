import Foundation

public typealias LayerID = UUID

/// What a layer is stored as. In the interface a layer is a view, and several kinds of view
/// are one stored kind with different settings: see `ViewType`.
public enum LayerKind: String, Codable, Sendable, CaseIterable {
    /// The root view: the device's screen.
    case screen
    /// A box that can hold other views. With `layout` set it is a stack or a grid.
    case view
    case ellipse
    case text
    case image
    /// A glyph from the system symbol set, such as a chevron or a tab icon.
    case symbol
    /// Shows the player's camera.
    case camera
    /// Plays a movie from the document's assets or the web.
    case video
    /// A box the person can type in.
    case textField
    /// A use of a component. Its content comes from the component's definition.
    case component

    public var displayName: String {
        switch self {
        case .screen: "Screen"
        case .view: "View"
        case .ellipse: "Ellipse"
        case .text: "Text"
        case .image: "Image"
        case .symbol: "Symbol"
        case .camera: "Camera"
        case .video: "Video"
        case .textField: "Text Field"
        case .component: "Component"
        }
    }

    public var canHaveChildren: Bool { self == .screen || self == .view }

    /// Names from before views were patches (document version 2). A rectangle was a box
    /// that could not hold anything; it is a view now.
    static let legacyNames: [String: LayerKind] = [
        "artboard": .screen, "group": .view, "rectangle": .view, "oval": .ellipse,
    ]

    public init(from decoder: Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        guard let kind = LayerKind(rawValue: name) ?? LayerKind.legacyNames[name] else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown layer kind \(name)"))
        }
        self = kind
    }
}

extension LayerProperty {
    /// Which case this is, as a number. A property is the key of every lookup layout and
    /// the runtime make, thousands a frame; hashing and comparing its name each time,
    /// which is what an enum with text for raw values does unless told otherwise, was a
    /// large share of a frame.
    @inline(__always) var ordinal: UInt8 { unsafeBitCast(self, to: UInt8.self) }

    public func hash(into hasher: inout Hasher) { hasher.combine(ordinal) }

    public static func == (a: LayerProperty, b: LayerProperty) -> Bool { a.ordinal == b.ordinal }
}

/// A configurable aspect of a layer. Every property can be set in the Inspector or driven
/// by a cable through a layer property patch.
///
/// Coordinate convention: logical points, origin at the parent's top-left, y down.
/// `position` places the layer's anchor; `anchor` is in unit coordinates of the layer's own
/// bounds (0,0 = top-left, the default). Scale and rotation pivot around the layer's center.
public enum LayerProperty: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable {
    case position
    case size
    case anchor
    case opacity
    case scale
    case rotation
    case fill
    case cornerRadius
    case strokeColor
    case strokeWidth
    case shadowColor
    case shadowRadius
    case shadowOffset
    /// How much what is behind a view is blurred where the view covers it, in points: what
    /// makes a translucent fill a material. 0 leaves it sharp.
    case backgroundBlur
    case text
    case fontSize
    case fontWeight
    /// The typeface: empty for the system's (SF Pro), one of the Apple families every
    /// device has (`FontBook.systemFamilies`), or a Google Fonts family, fetched when a
    /// document first uses it and then kept in its assets.
    case fontFamily
    /// Whether text is set in the italic of its typeface.
    case italic
    case textColor
    case textAlignment
    case singleLine
    /// What a text field shows while it is empty.
    case placeholder
    case image
    case symbol
    // A video: what it plays and how. Where it is (its playhead) belongs to the runtime.
    /// An asset's file name or a web address.
    case video
    /// Fill or Fit: how a picture of another shape sits in the view.
    case contentMode
    case playing
    /// Whether a video starts over when it reaches its end.
    case loops
    case muted
    case volume
    /// How fast a video plays: 1 is as recorded, 2 twice as fast, -1 backwards.
    case playbackRate
    /// Where a video is, in seconds. Changing it makes the video jump there.
    case time
    case clips
    case enabled
    /// Whether the view is there at all. One that is not is not drawn, takes no room in a
    /// stack or grid, and cannot be touched: what `if` does to a view in code.
    case visible
    // Layout: what a container does with its children, then how a child takes part.
    /// Whether a view arranges its children: None, Stack or Grid. This is what makes a
    /// view a stack or a grid.
    case layout
    case axis
    case spacing
    /// The inset of a text field's text. Containers have a padding for each direction.
    case padding
    case paddingHorizontal
    case paddingVertical
    /// One side's padding. Until a side is given its own value it follows the horizontal
    /// or vertical padding (`follows`).
    case paddingTop
    case paddingBottom
    case paddingLeft
    case paddingRight
    case alignment
    /// What a stack does with space its children leave along its axis.
    case distribution
    case columns
    /// Whether a stack scrolls when its content is longer than it is: a scroll view.
    case scrolls
    case pageSize
    /// How far a scroll view's content has moved. Set by the runtime, never stored or shown.
    case contentOffset
    case widthMode
    case heightMode
    case absolute

    public var displayName: String {
        switch self {
        case .position: "Position"
        case .size: "Size"
        case .anchor: "Anchor"
        case .opacity: "Opacity"
        case .scale: "Scale"
        case .rotation: "Rotation"
        case .fill: "Fill"
        case .cornerRadius: "Corner Radius"
        case .strokeColor: "Stroke Color"
        case .strokeWidth: "Stroke Width"
        case .shadowColor: "Shadow Color"
        case .shadowRadius: "Shadow Radius"
        case .shadowOffset: "Shadow Offset"
        case .backgroundBlur: "Background Blur"
        case .text: "Text"
        case .fontSize: "Font Size"
        case .fontWeight: "Font Weight"
        case .fontFamily: "Font"
        case .italic: "Italic"
        case .textColor: "Text Color"
        case .textAlignment: "Text Alignment"
        case .singleLine: "Single Line"
        case .placeholder: "Placeholder"
        case .image: "Image"
        case .symbol: "Symbol"
        case .video: "Video"
        case .contentMode: "Content Mode"
        case .playing: "Playing"
        case .loops: "Loop"
        case .muted: "Muted"
        case .volume: "Volume"
        case .playbackRate: "Playback Rate"
        case .time: "Time"
        case .clips: "Clip Content"
        case .enabled: "Enabled"
        case .visible: "Visible"
        case .layout: "Arrange Children"
        case .axis: "Axis"
        case .spacing: "Spacing"
        case .padding: "Padding"
        case .paddingHorizontal: "Horizontal Padding"
        case .paddingVertical: "Vertical Padding"
        case .paddingTop: "Top Padding"
        case .paddingBottom: "Bottom Padding"
        case .paddingLeft: "Left Padding"
        case .paddingRight: "Right Padding"
        case .alignment: "Alignment"
        case .distribution: "Distribution"
        case .columns: "Columns"
        case .scrolls: "Scrolls"
        case .pageSize: "Page Size"
        case .contentOffset: "Content Offset"
        case .widthMode: "Width Sizing"
        case .heightMode: "Height Sizing"
        case .absolute: "Ignore Layout"
        }
    }

    /// The fixed choices of a text property, or empty when it is free text.
    public var options: [String] {
        switch self {
        case .layout: ["None", "Stack", "Grid"]
        case .axis: ["Vertical", "Horizontal"]
        case .alignment: ["Start", "Center", "End"]
        case .distribution: ["Start", "Center", "End", "Space Between"]
        case .textAlignment: ["Left", "Center", "Right"]
        case .widthMode, .heightMode: ["Fixed", "Grow", "Auto"]
        case .contentMode: ["Fill", "Fit"]
        default: []
        }
    }

    public var type: PortType {
        switch self {
        case .position, .anchor, .shadowOffset: .point
        case .size: .size
        case .opacity, .scale, .rotation, .cornerRadius, .strokeWidth, .shadowRadius, .backgroundBlur, .fontSize, .fontWeight,
             .spacing, .padding, .paddingHorizontal, .paddingVertical, .paddingTop, .paddingBottom, .paddingLeft, .paddingRight,
             .columns, .pageSize, .contentOffset, .volume, .playbackRate, .time: .number
        case .fill, .strokeColor, .shadowColor, .textColor: .color
        case .text, .placeholder, .image, .symbol, .fontFamily, .video, .contentMode, .textAlignment, .layout, .axis, .alignment, .distribution,
             .widthMode, .heightMode: .text
        case .clips, .enabled, .visible, .absolute, .singleLine, .italic, .scrolls, .playing, .loops, .muted: .bool
        }
    }

    public func defaultValue(for kind: LayerKind) -> Value {
        switch self {
        case .position: return .point(.zero)
        case .size:
            switch kind {
            case .screen: return .size(Size2(width: 390, height: 844))
            case .text: return .size(Size2(width: 200, height: 28))
            case .symbol: return .size(Size2(width: 24, height: 24))
            case .textField: return .size(Size2(width: 300, height: 44))
            case .video: return .size(Size2(width: 320, height: 180))
            default: return .size(Size2(width: 100, height: 100))
            }
        case .anchor: return .point(.zero)
        case .opacity: return .number(1)
        case .scale: return .number(1)
        case .rotation: return .number(0)
        case .fill:
            switch kind {
            case .screen: return .color(.white)
            case .view, .text, .image, .component: return .color(.clear)
            case .symbol: return .color(.black)
            case .textField: return .color(ColorValue(white: 0.93))
            case .video: return .color(.black)
            default: return .color(ColorValue(white: 0.85))
            }
        case .cornerRadius: return .number(kind == .textField ? 10 : 0)
        case .strokeColor: return .color(.black)
        case .strokeWidth: return .number(0)
        case .shadowColor: return .color(ColorValue(white: 0, alpha: 0.25))
        case .shadowRadius, .backgroundBlur: return .number(0)
        case .shadowOffset: return .point(Point2(x: 0, y: 2))
        case .text: return .text(kind == .textField ? "" : "Text")
        case .placeholder: return .text("Placeholder")
        case .fontSize: return .number(17)
        case .fontWeight: return .number(400)
        case .fontFamily: return .text("")
        case .italic: return .bool(false)
        case .textColor: return .color(.black)
        case .textAlignment: return .text("Left")
        case .singleLine: return .bool(false)
        case .image: return .text("")
        case .symbol: return .text("star.fill")
        case .video: return .text("")
        case .contentMode: return .text("Fill")
        case .playing, .loops: return .bool(true)
        case .muted: return .bool(false)
        case .volume, .playbackRate: return .number(1)
        case .time: return .number(0)
        case .clips: return .bool(kind == .screen)
        case .enabled, .visible: return .bool(true)
        case .layout: return .text("None")
        case .axis: return .text("Vertical")
        case .spacing: return .number(0)
        case .padding: return .number(kind == .textField ? 12 : 0)
        case .paddingHorizontal, .paddingVertical, .paddingTop, .paddingBottom, .paddingLeft, .paddingRight: return .number(0)
        case .alignment: return .text("Start")
        case .distribution: return .text("Start")
        case .columns: return .number(2)
        case .scrolls: return .bool(false)
        case .pageSize, .contentOffset: return .number(0)
        case .widthMode, .heightMode: return .text("Fixed")
        case .absolute: return .bool(false)
        }
    }

    /// The padding a side follows until it has a value of its own; nil for any other property.
    public var follows: LayerProperty? {
        switch self {
        case .paddingTop, .paddingBottom: .paddingVertical
        case .paddingLeft, .paddingRight: .paddingHorizontal
        default: nil
        }
    }

    static let paddings: [LayerProperty] = [.paddingHorizontal, .paddingVertical, .paddingTop, .paddingBottom, .paddingLeft, .paddingRight]
    static let stackSettings: [LayerProperty] = [.axis, .spacing] + paddings + [.alignment, .distribution]
    static let gridSettings: [LayerProperty] = [.columns, .spacing] + paddings + [.alignment]

    /// The properties a type of view shows, in Inspector order. A stack, a grid and a
    /// scroll view are views with their own settings added.
    public static func properties(for type: ViewType) -> [LayerProperty] {
        let geometry: [LayerProperty] = [.position, .size, .anchor, .opacity, .scale, .rotation]
        let look: [LayerProperty] = [.fill, .backgroundBlur, .cornerRadius, .strokeColor, .strokeWidth, .shadowColor, .shadowRadius, .shadowOffset, .clips, .enabled]
        let child: [LayerProperty] = [.visible, .widthMode, .heightMode, .absolute]
        switch type {
        case .screen: return [.size, .fill, .cornerRadius, .layout]
        case .view: return geometry + look + child
        case .stack: return geometry + look + stackSettings + child
        case .scrollView: return geometry + look + stackSettings + [.pageSize] + child
        case .grid: return geometry + look + gridSettings + child
        case .shader, .custom, .scene: return geometry + look + child
        case .ellipse: return properties(for: LayerKind.ellipse)
        case .text: return properties(for: LayerKind.text)
        case .image: return properties(for: LayerKind.image)
        case .symbol: return properties(for: LayerKind.symbol)
        case .textField: return properties(for: LayerKind.textField)
        case .camera: return properties(for: LayerKind.camera)
        case .video: return properties(for: LayerKind.video)
        case .component: return instanceOwned
        }
    }

    /// Every property a stored kind can hold, whichever type of view it is at the moment.
    public static func properties(for kind: LayerKind) -> [LayerProperty] {
        let geometry: [LayerProperty] = [.position, .size, .anchor, .opacity, .scale, .rotation]
        let shadow: [LayerProperty] = [.shadowColor, .shadowRadius, .shadowOffset]
        let container: [LayerProperty] = [.layout, .axis, .columns, .spacing] + paddings + [.alignment, .distribution]
        let child: [LayerProperty] = [.visible, .widthMode, .heightMode, .absolute]
        switch kind {
        case .screen:
            return [.size, .fill, .cornerRadius] + container
        case .view:
            return geometry + [.fill, .backgroundBlur, .cornerRadius, .strokeColor, .strokeWidth] + shadow + [.clips, .enabled]
                + container + [.scrolls, .pageSize] + child
        case .ellipse:
            return geometry + [.fill, .strokeColor, .strokeWidth] + shadow + [.enabled] + child
        case .text:
            return geometry + [.text, .fontFamily, .fontSize, .fontWeight, .italic, .textColor, .textAlignment, .singleLine, .enabled] + child
        case .image:
            return geometry + [.image, .cornerRadius] + shadow + [.enabled] + child
        case .symbol:
            return geometry + [.symbol, .fill, .fontWeight, .enabled] + child
        case .camera:
            return geometry + [.cornerRadius, .enabled] + child
        case .video:
            return geometry + [.video, .contentMode, .playing, .loops, .time, .playbackRate, .muted, .volume,
                               .fill, .cornerRadius, .enabled] + child
        case .textField:
            return geometry + [.text, .placeholder, .fontFamily, .fontSize, .fontWeight, .italic, .textColor, .textAlignment,
                               .fill, .cornerRadius, .strokeColor, .strokeWidth, .padding, .enabled] + child
        case .component:
            return LayerProperty.instanceOwned
        }
    }

    /// The properties a component instance sets for itself. Everything else about how it
    /// looks comes from the component's definition.
    public static let instanceOwned: [LayerProperty] = [
        .position, .size, .anchor, .opacity, .scale, .rotation, .enabled, .visible, .widthMode, .heightMode, .absolute,
    ]

}

/// What a view is to the person building with it. Several types are one stored kind with
/// different settings: a stack is a view that arranges its children along an axis, a grid
/// one that arranges them in columns.
public enum ViewType: String, Sendable, CaseIterable {
    case screen, view, stack, grid, scrollView, ellipse, text, image, symbol, textField, camera, video, component
    /// A view drawn through a Metal shader: stored as a view with `Layer.shader` set.
    case shader
    /// A view an extension draws: stored as a view with `Layer.custom` set. What it is
    /// called, and its inputs, come from the extension.
    case custom
    /// A view that shows things in three dimensions: stored as a view with `Layer.scene` set.
    case scene

    public var displayName: String {
        switch self {
        case .screen: "Screen"
        case .view: "View"
        case .stack: "Stack"
        case .grid: "Grid"
        case .scrollView: "Scroll View"
        case .ellipse: "Ellipse"
        case .text: "Text"
        case .image: "Image"
        case .symbol: "Symbol"
        case .textField: "Text Field"
        case .camera: "Camera"
        case .video: "Video"
        case .component: "Component"
        case .shader: "Shader"
        case .custom: "Extension View"
        case .scene: "Scene"
        }
    }

    /// The inputs a new patch of this type shows. The Inspector shows and hides the rest.
    public var preset: [String] {
        switch self {
        case .screen: ["fill"]
        case .view, .ellipse: ["x", "y", "width", "height", "fill"]
        case .stack, .grid: ["x", "y", "width", "height", "spacing"]
        case .scrollView: ["x", "y", "width", "height"]
        case .text: ["x", "y", "text"]
        case .image: ["x", "y", "width", "height", "image"]
        case .symbol: ["x", "y", "symbol"]
        case .textField: ["x", "y", "width", "text"]
        case .camera: ["x", "y", "width", "height"]
        case .video: ["x", "y", "width", "height", "playing"]
        case .component: ["x", "y"]
        case .shader, .custom: ["x", "y", "width", "height"]
        case .scene: ["x", "y", "width", "height"] + SceneUse.presetPorts
        }
    }
}

/// One input of a view's patch: a property, or one half of its position or size. A view is
/// placed by four numbers (x, y, width, height); they are stored as `position` and `size`.
public struct ViewInput: Hashable, Sendable, Identifiable {
    public enum Part: String, Sendable, CaseIterable {
        case x, y, width, height

        public var property: LayerProperty { self == .x || self == .y ? .position : .size }
    }

    public let property: LayerProperty
    public let part: Part?

    public init(_ property: LayerProperty) {
        self.property = property
        self.part = nil
    }

    public init(_ part: Part) {
        self.property = part.property
        self.part = part
    }

    /// The input with this port id: "x", "y", "width", "height" or a property's name.
    public init?(id: String) {
        if let part = Part(rawValue: id) {
            self.init(part)
        } else if let property = LayerProperty(rawValue: id) {
            self.init(property)
        } else {
            return nil
        }
    }

    public var id: String { part?.rawValue ?? property.rawValue }

    public var name: String {
        switch part {
        case .x: "X"
        case .y: "Y"
        case .width: "Width"
        case .height: "Height"
        case nil: property.displayName
        }
    }

    public var type: PortType { part == nil ? property.type : .number }
    public var options: [String] { part == nil ? property.options : [] }

    /// This input's share of a whole property value.
    public func value(from whole: Value) -> Value {
        switch part {
        case .x: .number(whole.pointValue.x)
        case .y: .number(whole.pointValue.y)
        case .width: .number(whole.sizeValue.width)
        case .height: .number(whole.sizeValue.height)
        case nil: whole
        }
    }

    /// The whole property value with this input's share replaced.
    public func setting(_ value: Value, in whole: Value) -> Value {
        let number = value.numberValue
        switch part {
        case .x: return .point(Point2(x: number, y: whole.pointValue.y))
        case .y: return .point(Point2(x: whole.pointValue.x, y: number))
        case .width: return .size(Size2(width: number, height: whole.sizeValue.height))
        case .height: return .size(Size2(width: whole.sizeValue.width, height: number))
        case nil: return value
        }
    }

    public func value(in layer: Layer) -> Value { value(from: layer.value(property)) }

    public func set(_ value: Value, on layer: inout Layer) {
        guard let coerced = value.coerced(to: type) else { return }
        layer.set(property, setting(coerced, in: layer.value(property)))
    }

    /// Every input a view's patch can have: the four numbers first, then each property.
    public static let all: [ViewInput] = Part.allCases.map(ViewInput.init)
        + LayerProperty.allCases.filter { $0 != .contentOffset }.map(ViewInput.init)
}

/// An output every view's patch has: where layout put the view on the last frame. x and y
/// are its position in the view it is in (what the x and y inputs set, so a stack's child
/// reports where it was placed), width and height its laid-out size. Like inputs, they
/// show on the patch only when chosen (`PatchNode.shownPorts`) or cabled. The ids differ
/// from the inputs' so one list of shown ports can hold both.
public enum ViewOutput: String, CaseIterable, Sendable, Identifiable {
    case x = "frameX"
    case y = "frameY"
    case width = "frameWidth"
    case height = "frameHeight"

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .x: "X"
        case .y: "Y"
        case .width: "Width"
        case .height: "Height"
        }
    }

    public var type: PortType { .number }

    /// The input with the same name, which sets what this output reports.
    public var input: ViewInput {
        switch self {
        case .x: ViewInput(.x)
        case .y: ViewInput(.y)
        case .width: ViewInput(.width)
        case .height: ViewInput(.height)
        }
    }

    public static let ids: Set<String> = Set(allCases.map(\.rawValue))

    /// The frame outputs a view's patch shows: the chosen ones and the cabled ones, in order.
    public static func shown(chosen: [String]?, cabled: Set<String>) -> [ViewOutput] {
        let chosen = Set(chosen ?? [])
        return allCases.filter { chosen.contains($0.id) || cabled.contains($0.id) }
    }
}

/// A node in the layer tree. Children later in the array draw on top of earlier ones.
public struct Layer: Codable, Identifiable, Hashable, Sendable {
    public var id: LayerID
    public var name: String
    public var kind: LayerKind
    /// Only values that differ from the kind's defaults are stored.
    public var properties: [LayerProperty: Value]
    public var children: [Layer]
    /// Set on layers of kind `.component`: which component, and this use's input values.
    public var component: ComponentUse?
    /// Set on a view drawn through a shader: the Metal source and the values of its inputs.
    public var shader: ShaderUse?
    /// Set on a view an extension draws: which of its views, and the values of its inputs.
    public var custom: CustomViewUse?
    /// Set on a scene view: the things in it, its camera and its light.
    public var scene: SceneUse?
    /// Set on a view directly in the root that is one of the prototype's screens: it
    /// fills the device, and only the one being shown is there while the prototype runs.
    /// A document with none has one screen, the root itself.
    public var page: Bool?
    /// Where this view came from when the screen was sketched from code: a note an agent
    /// writes, such as `ProfileHeader.swift:42`, and reads back when it carries changes home.
    public var source: String?

    /// The fill a new plain view is given so it can be seen. The stored default is clear,
    /// which is right for a stack, a grid and a component's root.
    public static let viewFill = ColorValue(white: 0.85)

    private enum CodingKeys: String, CodingKey { case id, name, kind, properties, children, component, shader, custom, scene, page, source }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(LayerID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(LayerKind.self, forKey: .kind)
        properties = try container.decode([LayerProperty: Value].self, forKey: .properties)
        children = try container.decodeIfPresent([Layer].self, forKey: .children) ?? []
        component = try container.decodeIfPresent(ComponentUse.self, forKey: .component)
        shader = try container.decodeIfPresent(ShaderUse.self, forKey: .shader)
        custom = try container.decodeIfPresent(CustomViewUse.self, forKey: .custom)
        scene = try container.decodeIfPresent(SceneUse.self, forKey: .scene)
        page = try container.decodeIfPresent(Bool.self, forKey: .page)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        // A version 2 rectangle was gray unless told otherwise.
        if try container.decode(String.self, forKey: .kind) == "rectangle", properties[.fill] == nil {
            properties[.fill] = .color(Layer.viewFill)
        }
        // Then the direction of a stack was the arrangement itself, and a container had one
        // padding for all four sides.
        if kind.canHaveChildren {
            if let layout = properties[.layout]?.textValue, layout == "Horizontal" || layout == "Vertical" {
                properties[.layout] = .text("Stack")
                properties[.axis] = layout == "Horizontal" ? .text(layout) : nil
            }
            if let padding = properties.removeValue(forKey: .padding) {
                properties[.paddingHorizontal] = padding
                properties[.paddingVertical] = padding
            }
        }
    }

    /// Keeps what is stored as it would be read back from a file, through the whole tree:
    /// a container's one `padding` (which reading turns into horizontal and vertical
    /// padding, as for version 2 files) is split the same way, and a number that is not
    /// finite, which JSON cannot write, is dropped so the property's default applies.
    /// `Document.normalize` runs it after every edit.
    public mutating func settleStoredValues() {
        if kind.canHaveChildren, let padding = properties.removeValue(forKey: .padding) {
            properties[.paddingHorizontal] = padding
            properties[.paddingVertical] = padding
        }
        for (property, value) in properties where !value.isFinite { properties[property] = nil }
        scene?.settleStoredValues()
        for index in children.indices { children[index].settleStoredValues() }
    }

    /// Keeps `page` only where it means something: on a plain view directly in the root.
    /// `inRoot` says whether this layer is the root (a component's root never is).
    public mutating func settlePages(inRoot: Bool) {
        page = nil
        for index in children.indices {
            let kept = inRoot && children[index].isPage
            children[index].settlePages(inRoot: false)
            if kept { children[index].page = true }
        }
    }

    public init(
        id: LayerID = LayerID(),
        name: String? = nil,
        kind: LayerKind,
        properties: [LayerProperty: Value] = [:],
        children: [Layer] = [],
        component: ComponentUse? = nil,
        shader: ShaderUse? = nil
    ) {
        self.id = id
        self.name = name ?? kind.displayName
        self.kind = kind
        self.properties = properties
        self.children = children
        self.component = component
        self.shader = shader
    }

    public func value(_ property: LayerProperty) -> Value {
        if let own = properties[property] { return own }
        if let followed = property.follows { return value(followed) }
        return property.defaultValue(for: kind)
    }

    public mutating func set(_ property: LayerProperty, _ value: Value) {
        if let coerced = value.coerced(to: property.type) {
            properties[property] = coerced
        }
    }

    // MARK: As a view

    /// A new view of a type, set up the way that type starts out.
    public static func new(_ type: ViewType, name: String? = nil) -> Layer {
        let kind: LayerKind
        var properties: [LayerProperty: Value] = [:]
        switch type {
        case .screen: kind = .screen
        case .view:
            kind = .view
            properties[.fill] = .color(Layer.viewFill)
        case .stack:
            kind = .view
            properties[.layout] = .text("Stack")
        case .scrollView:
            kind = .view
            properties[.layout] = .text("Stack")
            properties[.scrolls] = .bool(true)
            properties[.clips] = .bool(true)
        case .grid:
            kind = .view
            properties[.layout] = .text("Grid")
        case .ellipse: kind = .ellipse
        case .text: kind = .text
        case .image: kind = .image
        case .symbol: kind = .symbol
        case .textField: kind = .textField
        case .camera: kind = .camera
        case .video: kind = .video
        case .component: kind = .component
        case .shader, .custom:
            kind = .view
            properties[.size] = .size(Size2(width: 200, height: 200))
        case .scene:
            kind = .view
            properties[.size] = .size(Size2(width: 240, height: 240))
        }
        var layer = Layer(name: name ?? type.displayName, kind: kind, properties: properties)
        if type == .shader { layer.shader = ShaderUse(source: ShaderUse.template) }
        if type == .scene { layer.scene = SceneUse.template }
        return layer
    }

    /// Whether this is one of the prototype's screens (see `page`).
    public var isPage: Bool { page == true && kind == .view }

    /// A new screen: a plain view that fills the device, white like the root.
    public static func newPage(name: String) -> Layer {
        var layer = Layer(name: name, kind: .view, properties: [.fill: .color(.white), .clips: .bool(true)])
        layer.page = true
        return layer
    }

    /// The inputs this view's patch shows until others are chosen. A screen fills the
    /// device, so where and how large it is are not shown.
    public var preset: [String] { isPage ? ViewType.screen.preset : type.preset }

    /// What this view is to the person: a Screen, the Device that holds screens, or its type.
    public var typeName: String {
        if isPage { return "Screen" }
        if kind == .screen, !pages.isEmpty { return "Device" }
        return type.displayName
    }

    /// The screens directly in this view, in order. The first is where a prototype starts.
    public var pages: [Layer] { children.filter(\.isPage) }

    public var type: ViewType {
        switch kind {
        case .screen: return .screen
        case .view: return shader != nil ? .shader : (custom != nil ? .custom : (scene != nil ? .scene : arrangement))
        case .ellipse: return .ellipse
        case .text: return .text
        case .image: return .image
        case .symbol: return .symbol
        case .camera: return .camera
        case .video: return .video
        case .textField: return .textField
        case .component: return .component
        }
    }

    /// What this view does with its children: `.view` (nothing), `.stack`, `.scrollView`
    /// or `.grid`. For a plain view that is its type; a screen can arrange its children too.
    public var arrangement: ViewType {
        guard kind.canHaveChildren else { return .view }
        switch value(.layout).textValue {
        case "Stack", "Horizontal", "Vertical": return value(.scrolls).boolValue ? .scrollView : .stack
        case "Grid": return .grid
        default: return .view
        }
    }

    /// The properties this view shows, in Inspector order.
    public var applicable: [LayerProperty] {
        // One of the prototype's screens fills the device: where it is and how large are not
        // its own, and nor is anything that only means something to a view inside another.
        if isPage {
            let settings: [LayerProperty] = switch arrangement {
            case .stack: LayerProperty.stackSettings
            case .scrollView: LayerProperty.stackSettings + [.pageSize]
            case .grid: LayerProperty.gridSettings
            default: []
            }
            return [.fill, .layout] + settings
        }
        // The device that holds screens only gives them its size, and shows its fill behind
        // them while they move.
        if kind == .screen, !pages.isEmpty { return [.size, .fill] }
        // A screen, a shader view, a scene view and a view an extension draws can arrange what is in them too.
        guard kind == .screen || type == .shader || type == .custom || type == .scene else { return LayerProperty.properties(for: type) }
        let settings: [LayerProperty]
        switch arrangement {
        case .stack: settings = LayerProperty.stackSettings
        case .scrollView: settings = LayerProperty.stackSettings + (kind == .screen ? [] : [.pageSize])
        case .grid: settings = LayerProperty.gridSettings
        default: settings = []
        }
        guard kind == .screen else {
            var all = LayerProperty.properties(for: ViewType.shader)
            all.insert(contentsOf: [.layout] + settings, at: all.count - 3)
            return all
        }
        return LayerProperty.properties(for: ViewType.screen) + settings
    }

    /// The inputs this view has, in Inspector order: position and size as four numbers.
    public var inputs: [ViewInput] {
        applicable.flatMap { property -> [ViewInput] in
            switch property {
            case .position: [ViewInput(.x), ViewInput(.y)]
            case .size: [ViewInput(.width), ViewInput(.height)]
            default: [ViewInput(property)]
            }
        }
    }

    /// The inputs this view's patch shows: the ones chosen for it (or its type's usual
    /// set), and every one with a cable, including a whole `position` or `size`.
    public func shownInputs(chosen: [String]?, cabled: Set<String>) -> [ViewInput] {
        let chosen = Set(chosen ?? preset)
        var result: [ViewInput] = []
        for input in inputs where chosen.contains(input.id) || cabled.contains(input.id) {
            result.append(input)
        }
        let listed = Set(result.map(\.id))
        for id in cabled.sorted() where !listed.contains(id) {
            if let input = ViewInput(id: id) { result.append(input) }
        }
        return result
    }

    // MARK: Tree queries

    public func find(_ id: LayerID) -> Layer? {
        if self.id == id { return self }
        for child in children {
            if let found = child.find(id) { return found }
        }
        return nil
    }

    public func contains(_ id: LayerID) -> Bool { find(id) != nil }

    /// The chain of layers from this one down to `id`, inclusive. Empty when not found.
    public func path(to id: LayerID) -> [Layer] {
        if self.id == id { return [self] }
        for child in children {
            let rest = child.path(to: id)
            if !rest.isEmpty { return [self] + rest }
        }
        return []
    }

    public func parent(of id: LayerID) -> Layer? {
        let chain = path(to: id)
        return chain.count >= 2 ? chain[chain.count - 2] : nil
    }

    /// This layer and all descendants, depth first, parents before children.
    public var flattened: [Layer] {
        [self] + children.flatMap(\.flattened)
    }

    // MARK: Tree edits

    /// Applies `change` to the layer with `id`. Returns false when it does not exist.
    @discardableResult
    public mutating func update(_ id: LayerID, _ change: (inout Layer) -> Void) -> Bool {
        if self.id == id {
            change(&self)
            return true
        }
        for index in children.indices {
            if children[index].update(id, change) { return true }
        }
        return false
    }

    /// Removes and returns the descendant with `id`.
    @discardableResult
    public mutating func remove(_ id: LayerID) -> Layer? {
        if let index = children.firstIndex(where: { $0.id == id }) {
            return children.remove(at: index)
        }
        for index in children.indices {
            if let removed = children[index].remove(id) { return removed }
        }
        return nil
    }

    /// Inserts `layer` into the container `parentID` at `index` (nil appends, i.e. on top).
    @discardableResult
    public mutating func insert(_ layer: Layer, into parentID: LayerID, at index: Int? = nil) -> Bool {
        update(parentID) { parent in
            guard parent.kind.canHaveChildren else { return }
            let position = min(max(index ?? parent.children.count, 0), parent.children.count)
            parent.children.insert(layer, at: position)
        } && (find(layer.id) != nil)
    }
}
