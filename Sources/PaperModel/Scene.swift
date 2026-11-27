import Foundation

/// One input of a scene or of an object in it: a number, a color, a switch or a choice.
/// The same list says what is stored, what the Inspector shows and which ports the view's
/// patch has.
public struct SceneInput: Sendable, Hashable, Identifiable {
    /// The key a value is stored under, and the end of the port's id.
    public var id: String
    public var name: String
    public var type: PortType
    public var defaultValue: Value
    public var options: [String]

    public init(_ id: String, _ name: String, _ defaultValue: Value, options: [String] = []) {
        self.id = id
        self.name = name
        self.type = defaultValue.type
        self.defaultValue = defaultValue
        self.options = options
    }
}

/// One thing in a scene: a shape, or a model from the document's assets, with where it
/// stands and what it is made of.
public struct SceneObject: Codable, Hashable, Sendable, Identifiable {
    public enum Shape: String, Codable, Sendable, CaseIterable {
        case box, roundedBox, sphere, cylinder, cone, capsule, torus, plane
        /// A model file among the document's assets, named by `SceneObject.model`.
        case model

        public var displayName: String {
            switch self {
            case .box: "Box"
            case .roundedBox: "Rounded Box"
            case .sphere: "Sphere"
            case .cylinder: "Cylinder"
            case .cone: "Cone"
            case .capsule: "Capsule"
            case .torus: "Torus"
            case .plane: "Plane"
            case .model: "Model"
            }
        }

        /// The shapes made in code, which need no file.
        public static let builtIn: [Shape] = allCases.filter { $0 != .model }

        public init?(named name: String) {
            let wanted = name.lowercased().filter { $0.isLetter }
            guard let found = Shape.allCases.first(where: {
                $0.rawValue.lowercased() == wanted || $0.displayName.lowercased().filter(\.isLetter) == wanted
            }) else { return nil }
            self = found
        }
    }

    /// Short and never changed: the object's ports are named after it, so a cable survives
    /// the object being renamed. It holds only letters and digits.
    public var id: String
    public var name: String
    public var shape: Shape
    /// For a model: the name of the asset it is read from.
    public var model: String?
    /// Stored values by input id (`SceneObject.inputs`); one that is not here has its default.
    public var values: [String: Value]

    public init(id: String = SceneObject.newID(), name: String? = nil, shape: Shape, model: String? = nil, values: [String: Value] = [:]) {
        self.id = id
        self.name = name ?? shape.displayName
        self.shape = shape
        self.model = model
        self.values = values
    }

    public static func newID() -> String {
        String(UUID().uuidString.filter { $0.isLetter || $0.isNumber }.prefix(8)).lowercased()
    }

    /// What every object has. Distances are in the scene's units (a shape is one unit
    /// across), angles in degrees, y is up.
    public static let inputs: [SceneInput] = [
        SceneInput("x", "X", .number(0)),
        SceneInput("y", "Y", .number(0)),
        SceneInput("z", "Z", .number(0)),
        SceneInput("rotationX", "Rotation X", .number(0)),
        SceneInput("rotationY", "Rotation Y", .number(0)),
        SceneInput("rotationZ", "Rotation Z", .number(0)),
        SceneInput("scale", "Scale", .number(1)),
        SceneInput("color", "Color", .color(ColorValue(white: 0.8))),
        SceneInput("metalness", "Metalness", .number(0)),
        SceneInput("roughness", "Roughness", .number(0.45)),
        SceneInput("visible", "Visible", .bool(true)),
        // Light of its own, added to what it reflects before the picture is toned: a lamp,
        // the sun, lightning. With the scene's Bloom it glows, and it lights what is near.
        SceneInput("emission", "Emission", .number(0)),
        SceneInput("emissionColor", "Emission Color", .color(ColorValue(white: 0.8))),
    ]

    public static func input(_ id: String) -> SceneInput? { inputs.first { $0.id == id } }

    /// Inputs that take another's value until they are stored themselves, as a side of a
    /// stack's padding follows its horizontal or vertical padding.
    public static let follows: [String: String] = [
        "emissionColor": "color",
    ]

    public func value(_ input: String) -> Value {
        if let stored = values[input] { return stored }
        if let leader = SceneObject.follows[input] { return value(leader) }
        return SceneObject.input(input)?.defaultValue ?? .number(0)
    }

    public func number(_ input: String) -> Double { value(input).numberValue }

    private enum CodingKeys: String, CodingKey { case id, name, shape, model, values }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Object"
        // A shape from a newer app is shown as a box rather than refusing the document.
        shape = (try? container.decode(Shape.self, forKey: .shape)) ?? .box
        model = try container.decodeIfPresent(String.self, forKey: .model)
        values = try container.decodeIfPresent([String: Value].self, forKey: .values) ?? [:]
    }
}

/// What makes a view a scene view: things in three dimensions, a camera that looks at
/// them and the light they stand in. The scene is drawn under the views inside the view,
/// over its fill. Like a shader's inputs, everything here is an input on the view's patch.
public struct SceneUse: Codable, Hashable, Sendable {
    public var objects: [SceneObject]
    /// Stored values of the scene's own inputs (`SceneUse.inputs`), by id.
    public var values: [String: Value]

    public init(objects: [SceneObject] = [], values: [String: Value] = [:]) {
        self.objects = objects
        self.values = values
    }

    public static let environments = ["Studio", "Daylight", "Sunset", "Night"]

    /// The camera turns round the middle of the scene: yaw round the vertical, pitch above
    /// the horizon, at a distance. The light is a direction, given the same way.
    public static let inputs: [SceneInput] = [
        SceneInput("cameraYaw", "Camera Yaw", .number(0)),
        SceneInput("cameraPitch", "Camera Pitch", .number(12)),
        SceneInput("cameraDistance", "Camera Distance", .number(3)),
        SceneInput("fieldOfView", "Field of View", .number(35)),
        SceneInput("lightYaw", "Light Yaw", .number(35)),
        SceneInput("lightPitch", "Light Pitch", .number(50)),
        SceneInput("lightIntensity", "Light Intensity", .number(3)),
        SceneInput("lightColor", "Light Color", .color(.white)),
        SceneInput("environment", "Environment", .text("Studio"), options: environments),
        SceneInput("exposure", "Exposure", .number(1)),
        SceneInput("rayTracing", "Ray Tracing", .bool(true)),
        // How much of what is brighter than white spills round it as a glow.
        SceneInput("bloom", "Bloom", .number(0)),
    ]

    public static func input(_ id: String) -> SceneInput? { inputs.first { $0.id == id } }

    public func value(_ input: String) -> Value {
        values[input] ?? SceneUse.input(input)?.defaultValue ?? .number(0)
    }

    public func number(_ input: String) -> Double { value(input).numberValue }

    public func object(_ id: String) -> SceneObject? { objects.first { $0.id == id } }

    /// The object called `name`, or with that id.
    public func object(named name: String) -> SceneObject? {
        objects.first { $0.name == name } ?? objects.first { $0.id == name }
            ?? objects.first { $0.name.lowercased() == name.lowercased() }
    }

    // MARK: Ports

    /// A scene's inputs are ports on its view's patch, under this prefix.
    public static let portPrefix = "scene."

    /// The port of one of the scene's own inputs.
    public static func portID(_ input: String) -> String { portPrefix + input }

    /// The port of one input of one object.
    public static func portID(object: String, _ input: String) -> String { portPrefix + object + "." + input }

    /// What a port of a view's patch names in a scene; nil when it is not a scene's.
    public struct Key: Hashable, Sendable {
        /// nil for one of the scene's own inputs.
        public var object: String?
        public var input: String

        public init(object: String? = nil, input: String) {
            self.object = object
            self.input = input
        }

        public var port: String {
            object.map { SceneUse.portID(object: $0, input) } ?? SceneUse.portID(input)
        }
    }

    public static func key(port id: String) -> Key? {
        guard id.hasPrefix(portPrefix) else { return nil }
        let parts = id.dropFirst(portPrefix.count).split(separator: ".", omittingEmptySubsequences: false)
        switch parts.count {
        case 1: return Key(input: String(parts[0]))
        case 2: return Key(object: String(parts[0]), input: String(parts[1]))
        default: return nil
        }
    }

    /// What an input is: its name, type and default. nil when the scene has no such input.
    public func input(for key: Key) -> SceneInput? {
        guard let object = key.object else { return SceneUse.input(key.input) }
        return self.object(object) == nil ? nil : SceneObject.input(key.input)
    }

    public func value(for key: Key) -> Value? {
        guard let input = input(for: key) else { return nil }
        if let object = key.object { return self.object(object)?.value(input.id) }
        return value(input.id)
    }

    /// Stores a value, made to fit the input's type. One that does not fit, or names
    /// nothing here, changes nothing.
    public mutating func set(_ value: Value, for key: Key) {
        guard let input = input(for: key), let fitted = value.coerced(to: input.type), fitted.isFinite else { return }
        if let id = key.object {
            guard let index = objects.firstIndex(where: { $0.id == id }) else { return }
            objects[index].values[input.id] = fitted
        } else {
            values[input.id] = fitted
        }
    }

    /// The ports a new scene view's patch shows; the rest show once chosen or cabled.
    public static let presetPorts = [portID("cameraYaw"), portID("cameraPitch")]

    /// What the view's patch needs to know of the scene to have its ports: the objects.
    public var entries: [SceneEntry] { objects.map { SceneEntry(id: $0.id, name: $0.name) } }

    /// Keeps what is stored as a file would read it back: a number that is not finite is
    /// dropped, an object's id holds only letters and digits and is its own.
    public mutating func settleStoredValues() {
        for (key, value) in values where !value.isFinite { values[key] = nil }
        var seen: Set<String> = []
        for index in objects.indices {
            for (key, value) in objects[index].values where !value.isFinite { objects[index].values[key] = nil }
            let id = objects[index].id
            if id.isEmpty || !id.allSatisfy({ $0.isLetter || $0.isNumber }) || seen.contains(id) {
                objects[index].id = SceneObject.newID()
            }
            seen.insert(objects[index].id)
        }
    }

    /// What a new scene view starts with: one rounded box, turned a little so it reads as solid.
    public static var template: SceneUse {
        SceneUse(
            objects: [SceneObject(name: "Box", shape: .roundedBox, values: [
                "rotationY": .number(30), "color": .color(ColorValue(red: 0.35, green: 0.5, blue: 1)),
            ])]
        )
    }

    private enum CodingKeys: String, CodingKey { case objects, values }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        objects = try container.decodeIfPresent([SceneObject].self, forKey: .objects) ?? []
        values = try container.decodeIfPresent([String: Value].self, forKey: .values) ?? [:]
    }
}

/// An object of a scene as the view's patch knows it, so the patch's ports do not need the
/// layer. Mirrors `SceneUse.objects`, as `PatchNode.script` mirrors a shader's source.
public struct SceneEntry: Codable, Hashable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
