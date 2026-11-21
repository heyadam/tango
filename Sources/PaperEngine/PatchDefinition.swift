import Foundation
import PaperModel

public enum PatchCategory: String, Sendable, CaseIterable {
    case input = "Input"
    case state = "State"
    case logic = "Logic"
    case math = "Math"
    case animation = "Animation"
    case loop = "Loop"
    case data = "Data"
    case ai = "AI"
    case device = "Device"
    case utility = "Utility"
    case component = "Component"
    case layer = "Layer"
}

/// Hardware or system services a prototype can ask its player for. A player that lacks
/// one simply never supplies its values, and the patches report that it is unavailable.
public enum DeviceCapability: String, Sendable, CaseIterable {
    case camera, microphone, location, clock, appearance
}

/// Something a patch asks the player to do in the physical world.
public enum DeviceEffect: Sendable, Equatable {
    case haptic(style: String)
    case sound(name: String, volume: Double)
    case capturePhoto
}

/// The declared type of a port: fixed, or following the patch's chosen value type.
public enum PortTypeSpec: Sendable, Hashable {
    case fixed(PortType)
    case generic
}

/// A port as declared by a patch definition.
public struct PortSpec: Sendable {
    public let id: String
    public let name: String
    public let type: PortTypeSpec
    /// nil uses the neutral value of the resolved type.
    public let defaultValue: Value?
    /// For text inputs that pick from a fixed list.
    public let options: [String]

    public init(_ id: String, _ name: String, _ type: PortType, _ defaultValue: Value? = nil, options: [String] = []) {
        self.id = id
        self.name = name
        self.type = .fixed(type)
        self.defaultValue = defaultValue
        self.options = options
    }

    /// A port that follows the patch's chosen type. `defaultValue` is used when it converts
    /// to that type (a number default works for number, point, and size).
    public static func generic(_ id: String, _ name: String, _ defaultValue: Value? = nil) -> PortSpec {
        PortSpec(id: id, name: name, type: .generic, defaultValue: defaultValue, options: [])
    }

    private init(id: String, name: String, type: PortTypeSpec, defaultValue: Value?, options: [String]) {
        self.id = id
        self.name = name
        self.type = type
        self.defaultValue = defaultValue
        self.options = options
    }
}

/// A port on a concrete patch, with its type resolved.
public struct Port: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let type: PortType
    public let defaultValue: Value
    public let options: [String]

    public init(id: String, name: String, type: PortType, defaultValue: Value? = nil, options: [String] = []) {
        self.id = id
        self.name = name
        self.type = type
        self.defaultValue = defaultValue?.coerced(to: type) ?? Value.defaultValue(for: type)
        self.options = options
    }
}

public struct NodePorts: Sendable, Hashable {
    public var inputs: [Port]
    public var outputs: [Port]

    public init(inputs: [Port] = [], outputs: [Port] = []) {
        self.inputs = inputs
        self.outputs = outputs
    }

    public func input(_ id: String) -> Port? { inputs.first { $0.id == id } }
    public func output(_ id: String) -> Port? { outputs.first { $0.id == id } }
}

/// Everything a patch sees during one evaluation. Values are scalars: the runtime owns port
/// storage and calls `evaluate` once per loop index, so definitions never deal with loops.
public struct EvalContext {
    /// Input values in declaration order, already coerced to each port's type.
    public let inputs: [Value]
    /// Output values in declaration order. Starts as the previous outputs (pulses cleared).
    public var outputs: [Value]
    /// State kept between evaluations of this patch instance.
    public var state: (any Sendable)?
    /// Seconds since the previous frame.
    public let dt: Double
    /// Seconds since the prototype started.
    public let time: Double
    /// The chosen type for generic patches.
    public let valueType: PortType
    /// Set to be evaluated again next frame even if no input changes.
    public var wantsNextFrame = false
    /// The source of a JavaScript patch; nil for every other patch.
    public var script: String?
    /// Things to ask the player to do, such as a haptic tap. Append to request one.
    public var effects: [DeviceEffect] = []
    /// Web requests an extension's script asks for. The runtime passes them to its host.
    public var requests: [ScriptRequest] = []
    /// Answers to earlier requests of this patch, for this loop index.
    public var replies: [ScriptReply] = []

    public init(inputs: [Value], outputs: [Value], state: (any Sendable)?, dt: Double, time: Double, valueType: PortType) {
        self.inputs = inputs
        self.outputs = outputs
        self.state = state
        self.dt = dt
        self.time = time
        self.valueType = valueType
    }

    public func number(_ index: Int) -> Double { inputs[index].numberValue }
    public func bool(_ index: Int) -> Bool { inputs[index].boolValue }
    public func pulse(_ index: Int) -> Bool { inputs[index].pulseValue }
    public func text(_ index: Int) -> String { inputs[index].textValue }
    public func point(_ index: Int) -> Point2 { inputs[index].pointValue }

    public func state<S>(as type: S.Type) -> S? { state as? S }
}

/// What a patch that works on whole loops sees. Most patches never deal with loops: the
/// runtime runs them once per index. A patch that makes a loop (Loop), or turns one into a
/// single value (Loop Select), reads and writes every index at once through this.
public struct LoopContext {
    /// Per input port, in declaration order, every value arriving on it: one value for a
    /// literal or a plain cable, several for a loop, none for an empty loop.
    public let inputs: [[Value]]
    /// One row of output values per loop index. Starts as the previous rows (pulses cleared).
    public var outputs: [[Value]]
    public var state: (any Sendable)?
    public let dt: Double
    public let time: Double
    public let valueType: PortType
    public var wantsNextFrame = false

    public init(inputs: [[Value]], outputs: [[Value]], state: (any Sendable)?, dt: Double, time: Double, valueType: PortType) {
        self.inputs = inputs
        self.outputs = outputs
        self.state = state
        self.dt = dt
        self.time = time
        self.valueType = valueType
    }

    /// The single value of an input that is not meant to carry a loop.
    public func first(_ index: Int) -> Value? { inputs[index].first }

    public func state<S>(as type: S.Type) -> S? { state as? S }
}

/// A patch whose last declared input repeats a chosen number of times (Loop Builder).
public struct VariableInputs: Sendable, Hashable {
    public let standard: Int
    public let range: ClosedRange<Int>

    public init(standard: Int, range: ClosedRange<Int>) {
        self.standard = standard
        self.range = range
    }
}

/// The extension a patch or view comes from.
public struct PatchOrigin: Sendable, Hashable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A patch: its ports and the function that turns inputs into outputs.
public struct PatchDefinition: Sendable {
    public let kind: String
    public let name: String
    public let category: PatchCategory
    /// One sentence shown in the Patch Library.
    public let summary: String
    public let inputs: [PortSpec]
    public let outputs: [PortSpec]
    /// Types a generic patch can work on; the first is the default. Empty for fixed patches.
    public let genericTypes: [PortType]
    public let evaluate: @Sendable (inout EvalContext) -> Void
    /// Set for patches that make or consume whole loops; used instead of `evaluate`.
    public private(set) var evaluateLoop: (@Sendable (inout LoopContext) -> Void)?
    /// For patches that report something from the player's hardware: per output, the
    /// name of the device value it shows (a device event for pulse outputs).
    public private(set) var deviceOutputs: [String]?
    /// The service this patch needs the player to run.
    public private(set) var capability: DeviceCapability?
    public let variableInputs: VariableInputs?
    /// For a patch an extension adds: its script, which the runtime hands to `evaluate`
    /// as it does the script a JavaScript patch carries.
    public private(set) var script: String?
    /// The extension a patch comes from; nil for one that is built in.
    public private(set) var origin: PatchOrigin?
    /// False when the extension is missing or switched off. The patch keeps its ports, so
    /// its cables stay, but it does nothing and is not offered in the Patch Library.
    public private(set) var isAvailable = true

    public init(
        kind: String,
        name: String,
        category: PatchCategory,
        summary: String,
        inputs: [PortSpec] = [],
        outputs: [PortSpec] = [],
        genericTypes: [PortType] = [],
        variableInputs: VariableInputs? = nil,
        evaluate: @escaping @Sendable (inout EvalContext) -> Void = { _ in }
    ) {
        self.kind = kind
        self.name = name
        self.category = category
        self.summary = summary
        self.inputs = inputs
        self.outputs = outputs
        self.genericTypes = genericTypes
        self.evaluate = evaluate
        self.variableInputs = variableInputs
    }

    /// Makes this a patch whose outputs come from the player's hardware.
    public func device(_ capability: DeviceCapability?, outputs keys: [String]) -> PatchDefinition {
        var copy = self
        copy.deviceOutputs = keys
        copy.capability = capability
        return copy
    }

    /// Makes this a patch that an extension adds.
    public func from(_ origin: PatchOrigin, script: String?, available: Bool = true) -> PatchDefinition {
        var copy = self
        copy.origin = origin
        copy.script = script
        copy.isAvailable = available
        return copy
    }

    /// Makes this a patch that reads and writes whole loops.
    public func wholeLoop(_ body: @escaping @Sendable (inout LoopContext) -> Void) -> PatchDefinition {
        var copy = self
        copy.evaluateLoop = body
        return copy
    }

    public var isGeneric: Bool { !genericTypes.isEmpty }
}
