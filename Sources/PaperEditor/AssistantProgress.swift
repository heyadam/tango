import Foundation

/// What the assistant's status line says while the model writes a tool call, which for a
/// big batch takes a minute. The sidecar hands over each operation (or step) as soon as it
/// is written out; this says it in a few words. Nothing here changes the document: the
/// batch is applied whole, as one undo step, when the call arrives.
public enum AssistantProgress {
    /// The line shown as soon as a call begins, before any of it is written.
    public static func starting(_ tool: String) -> String {
        switch tool {
        case "get_document": "Reading the document…"
        case "edit_document": "Planning changes…"
        case "view_prototype": "Getting ready to look…"
        case "interact_prototype": "Planning how to use the prototype…"
        default: "Working…"
        }
    }

    /// The line for the `count`th item of a call: "12 steps planned · Adding text “Temperature”".
    /// `resolve` turns a ref or id the model wrote into the name a person knows it by.
    public static func line(tool: String, item: [String: Any], count: Int,
                            resolve: (String) -> String? = { _ in nil }) -> String {
        let what = tool == "interact_prototype" ? touch(item) : operation(item, resolve: resolve)
        let tally = tool == "interact_prototype"
            ? (count == 1 ? "1 step" : "\(count) steps")
            : (count == 1 ? "1 change" : "\(count) changes")
        return "\(tally) planned · \(what)…"
    }

    /// One `edit_document` operation, as a person would say it.
    public static func operation(_ op: [String: Any], resolve: (String) -> String? = { _ in nil }) -> String {
        func string(_ key: String) -> String? {
            guard var value = op[key] as? String, !value.isEmpty else { return nil }
            // What points at something else is said by that thing's name.
            if ["view", "patch", "from", "to"].contains(key), let name = resolve(value), !name.isEmpty { value = name }
            return value.count > 32 ? String(value.prefix(31)) + "…" : value
        }
        func named(_ key: String) -> String { string(key).map { " “\($0)”" } ?? "" }
        let kind = string("kind").map(spaced)
        switch op["op"] as? String ?? "" {
        case "add_view":
            if kind == "screen" { return "Adding a screen" + named("name") }
            return "Adding " + (kind.map { $0 == "text" ? $0 : article($0) } ?? "a view") + named("name")
        case "add_patch": return "Adding " + (kind.map { article($0) + " patch" } ?? "a patch") + named("name")
        case "insert_component": return "Inserting a component" + named("name")
        case "insert_template": return "Adding " + (string("template").map { "a " + $0 } ?? "a template")
        case "add_flow":
            if op["back"] as? Bool == true { return "Adding a way back" + named("from") }
            return "Adding a flow" + (string("to").map { " to “\($0)”" } ?? "")
        case "connect":
            guard let from = string("from"), let to = string("to") else { return "Connecting patches" }
            return "Connecting \(from) → \(to)"
        case "disconnect": return "Removing a cable"
        case "set_properties", "change_view": return "Styling" + named("view")
        case "set_inputs", "set_component_inputs": return "Setting inputs" + named("patch")
        case "set_shader": return "Writing a shader" + named("view")
        case "set_script": return "Writing a script" + named("patch")
        case "rename_view", "rename_patch", "rename_port": return "Renaming"
        case "delete_view": return "Removing" + named("view")
        case "delete_patch": return "Removing" + named("patch")
        case "move_view": return "Moving" + named("view")
        case "group_views": return "Grouping views"
        case "publish_port": return "Publishing a port"
        case "add_comment": return "Adding a comment"
        case "set_ports": return "Choosing ports"
        default: return "Editing"
        }
    }

    /// One `interact_prototype` step.
    public static func touch(_ step: [String: Any]) -> String {
        switch step["do"] as? String ?? "" {
        case "tap": "Tapping"
        case "drag": "Dragging"
        case "down", "move", "up": "Moving a finger"
        case "wait": "Waiting"
        case "type": "Typing"
        case "press": "Pressing a key"
        case "pinch": "Pinching"
        case "hover": "Hovering"
        case "look": "Looking"
        default: "Using the prototype"
        }
    }

    private static func article(_ noun: String) -> String {
        ("aeiou".contains(noun.first ?? "x") ? "an " : "a ") + noun
    }

    /// "textField" and "text_field" read as "text field".
    private static func spaced(_ name: String) -> String {
        var out = ""
        for c in name {
            if c == "_" { out.append(" ") } else if c.isUppercase { out += " " + c.lowercased() } else { out.append(c) }
        }
        return out
    }
}

/// Where the time of one answer went, so a slow answer says why: "Took 52 s · writing
/// changes 24 s · thinking 18 s · …". The session moves it from phase to phase as events
/// arrive; it reads no clock of its own, so tests give it times.
public struct AssistantTiming: Equatable {
    public enum Phase: CaseIterable, Equatable {
        /// Between a request or a tool's answer and the model's first word.
        case waiting
        case thinking
        /// Writing words to the person.
        case answering
        /// Writing an edit_document call.
        case writingChanges
        /// Writing any other call.
        case planning
        /// The app looking at or using the prototype for the model.
        case looking
        /// The app doing anything else the model asked (applying the rest of a batch).
        case applying

        var label: String {
            switch self {
            case .waiting: "waiting for Claude"
            case .thinking: "thinking"
            case .answering: "writing"
            case .writingChanges: "writing changes"
            case .planning: "planning"
            case .looking: "using the prototype"
            case .applying: "applying"
            }
        }
    }

    public private(set) var totals: [Phase: TimeInterval] = [:]
    private var current: Phase?
    private var since: TimeInterval = 0
    private var began: TimeInterval?

    public init() {}

    public mutating func enter(_ phase: Phase, at time: TimeInterval) {
        if began == nil { began = time }
        if let current { totals[current, default: 0] += max(0, time - since) }
        current = phase
        since = time
    }

    /// An answer quicker than this needs no account of its time.
    public static let worthSaying: TimeInterval = 10

    /// Ends the answer and says where its time went; nil when nothing was timed, or when it
    /// was quick.
    public mutating func finish(at time: TimeInterval) -> String? {
        guard let began else { return nil }
        if let current { totals[current, default: 0] += max(0, time - since) }
        current = nil
        guard time - began >= Self.worthSaying else { return nil }
        let parts = totals
            .filter { $0.value >= 1 }
            .sorted { $0.value > $1.value }
            .map { "\($0.key.label) \(Self.duration($0.value))" }
        return (["Took " + Self.duration(time - began)] + parts).joined(separator: " · ")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let whole = Int(max(0, seconds).rounded())
        return whole < 60 ? "\(whole) s" : "\(whole / 60) min \(whole % 60) s"
    }
}
