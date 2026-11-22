import Foundation
import PaperModel

// AI patches: text from Claude, OpenAI or Apple's on-device model, pictures from OpenAI,
// speech both ways, structured answers and translation. Like Network Request, the runtime
// only says what it wants: the host makes the call (with the person's API key, or on the
// device for Apple's models) and reports back with `Runtime.update(ai:_:)`.

/// Who answers a request, which follows from the model's name.
public enum AIProvider: String, Sendable, CaseIterable {
    case anthropic
    case openAI
    /// Apple's models, on the device that runs the prototype: no key and nothing sent.
    case apple

    public static func of(model: String) -> AIProvider {
        let model = model.lowercased()
        if model.hasPrefix("claude") { return .anthropic }
        if model.hasPrefix("apple") { return .apple }
        return .openAI
    }

    public var name: String {
        switch self {
        case .anthropic: "Claude"
        case .openAI: "OpenAI"
        case .apple: "Apple Intelligence"
        }
    }

    /// Whether requests need the person's API key.
    public var needsKey: Bool { self != .apple }

    /// The providers whose keys Settings holds.
    public static let keyed = allCases.filter(\.needsKey)
}

/// What an AI patch wants done.
public struct AIRequest: Sendable, Hashable {
    public enum Task: String, Sendable { case text, image, speech, transcription, object, translation }
    public enum Phase: String, Sendable {
        /// Make the request now.
        case send
        /// Transcription only: start recording from the microphone.
        case startRecording
        /// Transcription only: stop recording and transcribe what was heard.
        case stopRecording
        /// Forget the request: the patch no longer waits for it. Speech stops playing.
        case cancel
    }

    public let id: UUID
    public var task: Task
    public var phase: Phase
    public var model: String
    /// The prompt, or for speech the words to say.
    public var prompt: String
    /// A system prompt for text; how to say it for speech.
    public var instructions: String
    /// For text: how hard the model thinks, `low`, `medium` or `high`.
    public var effort: String
    /// The name of a picture to show the model (text) or to start from (image).
    public var picture: String
    /// For text: the conversation so far, oldest first, before `prompt`.
    public var conversation: [AITurn]
    public var voice: String
    /// For images: `1024x1024`, `1024x1536`, `1536x1024`, or empty for the model's choice.
    public var size: String
    /// For objects: what to make, one field a line (`AIField.parse`).
    public var fields: String
    /// For translation: the language to translate into and the one it is in (empty to
    /// detect), as BCP 47 codes (`AIRequest.languageCode`).
    public var target: String
    public var source: String

    public init(
        id: UUID = UUID(), task: Task, phase: Phase = .send, model: String, prompt: String = "",
        instructions: String = "", effort: String = "", picture: String = "", conversation: [AITurn] = [],
        voice: String = "", size: String = "", fields: String = "", target: String = "", source: String = ""
    ) {
        self.id = id
        self.task = task
        self.phase = phase
        self.model = model
        self.prompt = prompt
        self.instructions = instructions
        self.effort = effort
        self.picture = picture
        self.conversation = conversation
        self.voice = voice
        self.size = size
        self.fields = fields
        self.target = target
        self.source = source
    }

    public var provider: AIProvider { AIProvider.of(model: model) }

    /// The name under which the host keeps a picture made for request `id`.
    public static func pictureName(for id: UUID) -> String { "ai:" + id.uuidString }
}

public struct AITurn: Sendable, Hashable {
    public enum Role: String, Sendable { case user, assistant }
    public var role: Role
    public var text: String
    public var picture: String

    public init(_ role: Role, _ text: String, picture: String = "") {
        self.role = role
        self.text = text
        self.picture = picture
    }

    var value: Value {
        var object: [String: Value] = ["role": .text(role.rawValue), "text": .text(text)]
        if !picture.isEmpty { object["image"] = .text(picture) }
        return .object(object)
    }
}

/// What the host reports about a request.
public enum AIUpdate: Sendable, Hashable {
    /// Text so far, while it streams in: the whole of it, not just what is new. For an
    /// object, the JSON of what has been made so far.
    case partial(String)
    /// The microphone started or stopped recording for a transcription.
    case recording(Bool)
    /// Speech started or finished playing.
    case playing(Bool)
    /// The answer: text for text, transcription and translation, JSON for objects, a
    /// picture name for images. Speech
    /// finishes with empty text once it has been fetched; `.playing(false)` follows.
    case finished(text: String, picture: String)
    case failed(String)
}

extension AIRequest {
    /// Apple's model on the device: Foundation Models for text and objects, the system's
    /// voices for speech, SpeechAnalyzer for transcription.
    public static let onDevice = "apple-on-device"
    public static let textModels = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "gpt-6.2-astra", "gpt-6.2-sol", "gpt-6-luna", onDevice]
    public static let objectModels = [onDevice]
    public static let imageModels = ["gpt-image-2.6-flare", "gpt-image-2.6-sunburst"]
    public static let speechModels = ["gpt-4o-mini-tts", onDevice]
    public static let transcriptionModels = ["gpt-transcribe", onDevice]
    /// The languages Translate offers by name, with their codes. A code typed in also works.
    public static let languages: [(name: String, code: String)] = [
        ("English", "en"), ("Spanish", "es"), ("French", "fr"), ("German", "de"), ("Italian", "it"),
        ("Portuguese", "pt-BR"), ("Dutch", "nl"), ("Polish", "pl"), ("Russian", "ru"), ("Ukrainian", "uk"),
        ("Turkish", "tr"), ("Arabic", "ar"), ("Hindi", "hi"), ("Japanese", "ja"), ("Korean", "ko"),
        ("Chinese", "zh-Hans"), ("Chinese (Traditional)", "zh-Hant"), ("Vietnamese", "vi"), ("Thai", "th"),
        ("Indonesian", "id"),
    ]
    /// What Translate's From says to detect the language.
    public static let detect = "Detect"

    /// The code for a language named on a Translate input: one of `languages` by name
    /// (in any case), else what was typed, trimmed. Empty or Detect is empty.
    public static func languageCode(_ named: String) -> String {
        let named = named.trimmingCharacters(in: .whitespacesAndNewlines)
        if named.isEmpty || named.caseInsensitiveCompare(detect) == .orderedSame { return "" }
        return languages.first { $0.name.caseInsensitiveCompare(named) == .orderedSame }?.code ?? named
    }
    public static let voices = ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer", "verse"]
    public static let efforts = ["low", "medium", "high"]
    /// Image sizes as the Size input names them, and what the API calls them.
    public static let sizes: [(name: String, value: String)] = [
        ("Auto", ""), ("Square", "1024x1024"), ("Portrait", "1024x1536"), ("Landscape", "1536x1024"),
    ]
}

extension StandardPatches {
    /// Patch kinds the runtime runs as AI requests, by task.
    static let aiTasks: [String: AIRequest.Task] = [
        "aiText": .text, "aiImage": .image, "aiSpeech": .speech, "aiTranscribe": .transcription,
        "aiObject": .object, "aiTranslate": .translation,
    ]

    static let ai: [PatchDefinition] = [
        PatchDefinition(
            kind: "aiText",
            name: "Generate Text",
            category: .ai,
            summary: "Asks Claude or an OpenAI model and streams the answer into Text. It keeps the conversation, so it can be a chat.",
            inputs: [
                PortSpec("prompt", "Prompt", .text),
                PortSpec("instructions", "Instructions", .text),
                PortSpec("model", "Model", .text, .text(AIRequest.textModels[0]), options: AIRequest.textModels),
                PortSpec("effort", "Effort", .text, .text("low"), options: AIRequest.efforts),
                PortSpec("image", "Image", .text),
                PortSpec("send", "Send", .pulse),
                PortSpec("remember", "Remember", .bool, .bool(true)),
                PortSpec("reset", "Reset", .pulse),
            ],
            outputs: [
                PortSpec("text", "Text", .text),
                PortSpec("loading", "Loading", .bool),
                PortSpec("done", "Done", .pulse),
                PortSpec("failed", "Failed", .pulse),
                PortSpec("error", "Error", .text),
                PortSpec("conversation", "Conversation", .array),
            ]
        ),
        PatchDefinition(
            kind: "aiImage",
            name: "Generate Image",
            category: .ai,
            summary: "Makes a picture from a prompt with OpenAI, or changes the picture in Reference. Image goes straight into an Image view.",
            inputs: [
                PortSpec("prompt", "Prompt", .text),
                PortSpec("model", "Model", .text, .text(AIRequest.imageModels[0]), options: AIRequest.imageModels),
                PortSpec("size", "Size", .text, .text("Auto"), options: AIRequest.sizes.map(\.name)),
                PortSpec("reference", "Reference", .text),
                PortSpec("send", "Send", .pulse),
            ],
            outputs: [
                PortSpec("image", "Image", .text),
                PortSpec("loading", "Loading", .bool),
                PortSpec("done", "Done", .pulse),
                PortSpec("failed", "Failed", .pulse),
                PortSpec("error", "Error", .text),
            ]
        ),
        PatchDefinition(
            kind: "aiSpeech",
            name: "Speak",
            category: .ai,
            summary: "Says Text out loud in a natural voice with OpenAI. Speaking is on while it talks.",
            inputs: [
                PortSpec("text", "Text", .text),
                PortSpec("voice", "Voice", .text, .text(AIRequest.voices[0]), options: AIRequest.voices),
                PortSpec("instructions", "Instructions", .text),
                PortSpec("model", "Model", .text, .text(AIRequest.speechModels[0]), options: AIRequest.speechModels),
                PortSpec("speak", "Speak", .pulse),
                PortSpec("stop", "Stop", .pulse),
            ],
            outputs: [
                PortSpec("speaking", "Speaking", .bool),
                PortSpec("loading", "Loading", .bool),
                PortSpec("done", "Done", .pulse),
                PortSpec("failed", "Failed", .pulse),
                PortSpec("error", "Error", .text),
            ]
        ),
        PatchDefinition(
            kind: "aiTranscribe",
            name: "Transcribe",
            category: .ai,
            summary: "Listens while Record is on, then turns what it heard into text with OpenAI.",
            inputs: [
                PortSpec("record", "Record", .bool),
                PortSpec("model", "Model", .text, .text(AIRequest.transcriptionModels[0]), options: AIRequest.transcriptionModels),
            ],
            outputs: [
                PortSpec("text", "Text", .text),
                PortSpec("recording", "Recording", .bool),
                PortSpec("loading", "Loading", .bool),
                PortSpec("done", "Done", .pulse),
                PortSpec("failed", "Failed", .pulse),
                PortSpec("error", "Error", .text),
            ]
        ).device(.microphone, outputs: []),
        PatchDefinition(
            kind: "aiObject",
            name: "Generate Object",
            category: .ai,
            summary: "Asks Apple's on-device model for an object with the fields you list, filled in as it streams. Free, private, no key.",
            inputs: [
                PortSpec("prompt", "Prompt", .text),
                PortSpec("instructions", "Instructions", .text),
                PortSpec("fields", "Fields", .text, .text("title: text\nsummary: text")),
                PortSpec("model", "Model", .text, .text(AIRequest.objectModels[0]), options: AIRequest.objectModels),
                PortSpec("image", "Image", .text),
                PortSpec("send", "Send", .pulse),
            ],
            outputs: [
                PortSpec("object", "Object", .json),
                PortSpec("loading", "Loading", .bool),
                PortSpec("done", "Done", .pulse),
                PortSpec("failed", "Failed", .pulse),
                PortSpec("error", "Error", .text),
            ]
        ),
        PatchDefinition(
            kind: "aiTranslate",
            name: "Translate",
            category: .ai,
            summary: "Translates Text on the device with Apple's translation models. Free, private, no key.",
            inputs: [
                PortSpec("text", "Text", .text),
                PortSpec("to", "To", .text, .text("Spanish"), options: AIRequest.languages.map(\.name)),
                PortSpec("from", "From", .text, .text(AIRequest.detect), options: [AIRequest.detect] + AIRequest.languages.map(\.name)),
                PortSpec("send", "Send", .pulse),
            ],
            outputs: [
                PortSpec("text", "Text", .text),
                PortSpec("loading", "Loading", .bool),
                PortSpec("done", "Done", .pulse),
                PortSpec("failed", "Failed", .pulse),
                PortSpec("error", "Error", .text),
            ]
        ),
    ]
}

// MARK: - Fields

/// One field of what Generate Object makes, as a line of its Fields input says it:
/// `name: kind - what it is`. The kind and the words after it are optional.
///
/// Kinds: `text` (the default), `number`, `whole` (or `integer`, `int`), `yes/no` (or
/// `bool`, `boolean`), `list` (of text) or `list of <kind>`, and choices written with bars,
/// `happy | sad | calm`. A list can say how many: `list of 3 text`, `3 numbers`.
public struct AIField: Sendable, Hashable {
    public indirect enum Kind: Sendable, Hashable {
        case text, number, whole, bool
        case choice([String])
        case list(Kind, count: Int?)
    }

    public var name: String
    public var kind: Kind
    public var about: String

    public init(_ name: String, _ kind: Kind = .text, about: String = "") {
        self.name = name
        self.kind = kind
        self.about = about
    }

    /// The fields of a Fields input, in order. Blank lines, lines that name nothing and
    /// names given twice (after the first) are left out.
    public static func parse(_ text: String) -> [AIField] {
        var fields: [AIField] = []
        var seen = Set<String>()
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("-") || line.hasPrefix("•") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            guard !line.isEmpty else { continue }
            var about = ""
            for mark in [" — ", " – ", " - ", " // ", " # "] {
                if let range = line.range(of: mark) {
                    about = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                    line = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                    break
                }
            }
            var name = line, kindText = ""
            if let colon = line.firstIndex(of: ":") {
                name = line[..<colon].trimmingCharacters(in: .whitespaces)
                kindText = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            fields.append(AIField(name, kind(kindText), about: about))
        }
        return fields
    }

    static func kind(_ text: String) -> Kind {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.contains("|") {
            let choices = text.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return choices.isEmpty ? .text : .choice(choices)
        }
        var words = text.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return .text }
        var listed = false
        var count: Int?
        if ["list", "array", "lists"].contains(words[0]) {
            listed = true
            words.removeFirst()
            if words.first == "of" { words.removeFirst() }
        }
        if let first = words.first, let number = Int(first) {
            count = min(max(number, 1), 100)
            listed = true
            words.removeFirst()
        }
        var single = words.joined(separator: " ")
        // "3 numbers", "list of words": a plural names the kind.
        if listed, single.hasSuffix("s"), single.count > 1 { single.removeLast() }
        let element: Kind = switch single {
        case "number", "double", "float", "decimal": .number
        case "whole", "integer", "int", "count", "whole number": .whole
        case "bool", "boolean", "yes/no", "yes or no", "flag": .bool
        default: .text
        }
        return listed ? .list(element, count: count) : element
    }
}

// MARK: - Running

/// What an AI patch remembers between frames.
struct AIState {
    var pending: UUID?
    var conversation: [AITurn] = []
    /// The turn sent with `pending`, added to the conversation when the answer comes.
    var asked: AITurn?
    var partial = ""
    var recordingWanted = false
    var playing: UUID?
    /// A recording that was let go and is being transcribed, while a new one may record.
    var transcribing: UUID?

    /// Every request the patch still waits on.
    var waitingOn: Set<UUID> { Set([pending, playing, transcribing].compactMap { $0 }) }
}

extension Runtime {
    /// Runs one AI patch for a frame. Returns whether it is still waiting on something.
    func evaluateAI(_ task: AIRequest.Task, state: inout AIState, inputs: [Value], row: inout [Value],
                    updates: (UUID) -> [AIUpdate], send: (AIRequest) -> Void) {
        func text(_ slot: Int) -> String { inputs.count > slot ? inputs[slot].textValue : "" }
        func pulse(_ slot: Int) -> Bool { inputs.count > slot && inputs[slot].pulseValue }
        func set(_ name: String, _ value: Value, in ports: [String]) {
            if let slot = ports.firstIndex(of: name), slot < row.count { row[slot] = value }
        }

        switch task {
        case .text:
            let ports = ["text", "loading", "done", "failed", "error", "conversation"]
            func publishConversation() {
                var turns = state.conversation
                if let asked = state.asked {
                    turns.append(asked)
                    turns.append(AITurn(.assistant, state.partial))
                }
                set("conversation", .array(turns.map(\.value)), in: ports)
            }
            if pulse(7) {
                if let pending = state.pending { send(AIRequest(id: pending, task: .text, phase: .cancel, model: text(2))) }
                state = AIState()
                set("text", .text(""), in: ports)
                set("loading", .bool(false), in: ports)
                set("error", .text(""), in: ports)
                publishConversation()
            }
            let prompt = text(0), picture = text(4)
            if pulse(5), !prompt.isEmpty || !picture.isEmpty {
                if let pending = state.pending { send(AIRequest(id: pending, task: .text, phase: .cancel, model: text(2))) }
                let remembers = inputs.count > 6 ? inputs[6].boolValue : true
                if !remembers { state.conversation = [] }
                let request = AIRequest(
                    task: .text, model: text(2), prompt: prompt, instructions: text(1), effort: text(3),
                    picture: picture, conversation: state.conversation
                )
                state.pending = request.id
                state.asked = AITurn(.user, prompt, picture: picture)
                state.partial = ""
                set("text", .text(""), in: ports)
                set("loading", .bool(true), in: ports)
                set("error", .text(""), in: ports)
                publishConversation()
                send(request)
            }
            if let pending = state.pending {
                for update in updates(pending) {
                    switch update {
                    case let .partial(so):
                        state.partial = so
                        set("text", .text(so), in: ports)
                    case let .finished(answer, _):
                        state.partial = answer
                        set("text", .text(answer), in: ports)
                        // An empty answer is left out: the API refuses an empty turn.
                        if let asked = state.asked, !answer.isEmpty, inputs.count > 6 ? inputs[6].boolValue : true {
                            state.conversation += [asked, AITurn(.assistant, answer)]
                        }
                        state.asked = nil
                        state.pending = nil
                        set("loading", .bool(false), in: ports)
                        set("done", .pulse(true), in: ports)
                    case let .failed(problem):
                        state.asked = nil
                        state.pending = nil
                        set("loading", .bool(false), in: ports)
                        set("failed", .pulse(true), in: ports)
                        set("error", .text(problem), in: ports)
                    default:
                        break
                    }
                    if state.pending == nil { break }
                }
                publishConversation()
            }

        case .image:
            let ports = ["image", "loading", "done", "failed", "error"]
            if pulse(4), !text(0).isEmpty {
                if let pending = state.pending { send(AIRequest(id: pending, task: .image, phase: .cancel, model: text(1))) }
                let size = AIRequest.sizes.first { $0.name == text(2) }?.value ?? ""
                let request = AIRequest(task: .image, model: text(1), prompt: text(0), picture: text(3), size: size)
                state.pending = request.id
                set("loading", .bool(true), in: ports)
                set("error", .text(""), in: ports)
                send(request)
            }
            if let pending = state.pending {
                for update in updates(pending) {
                    switch update {
                    case let .finished(_, picture):
                        state.pending = nil
                        set("image", .text(picture), in: ports)
                        set("loading", .bool(false), in: ports)
                        set("done", .pulse(true), in: ports)
                    case let .failed(problem):
                        state.pending = nil
                        set("loading", .bool(false), in: ports)
                        set("failed", .pulse(true), in: ports)
                        set("error", .text(problem), in: ports)
                    default:
                        break
                    }
                }
            }

        case .speech:
            let ports = ["speaking", "loading", "done", "failed", "error"]
            func stop() {
                for id in Set([state.pending, state.playing].compactMap({ $0 })) {
                    send(AIRequest(id: id, task: .speech, phase: .cancel, model: text(3)))
                }
                state.pending = nil
                state.playing = nil
                set("speaking", .bool(false), in: ports)
                set("loading", .bool(false), in: ports)
            }
            if pulse(5) { stop() }
            if pulse(4), !text(0).isEmpty {
                stop()
                let request = AIRequest(task: .speech, model: text(3), prompt: text(0), instructions: text(2), voice: text(1))
                state.pending = request.id
                state.playing = request.id
                set("loading", .bool(true), in: ports)
                set("error", .text(""), in: ports)
                send(request)
            }
            if let playing = state.playing {
                for update in updates(playing) {
                    switch update {
                    case .finished:
                        state.pending = nil
                        set("loading", .bool(false), in: ports)
                    case .playing(true):
                        set("speaking", .bool(true), in: ports)
                    case .playing(false):
                        state.playing = nil
                        set("speaking", .bool(false), in: ports)
                        set("done", .pulse(true), in: ports)
                    case let .failed(problem):
                        state.pending = nil
                        state.playing = nil
                        set("speaking", .bool(false), in: ports)
                        set("loading", .bool(false), in: ports)
                        set("failed", .pulse(true), in: ports)
                        set("error", .text(problem), in: ports)
                    default:
                        break
                    }
                }
            }

        case .transcription:
            let ports = ["text", "recording", "loading", "done", "failed", "error"]
            let wanted = inputs.first?.boolValue ?? false
            if wanted, !state.recordingWanted {
                if let pending = state.pending { send(AIRequest(id: pending, task: .transcription, phase: .cancel, model: text(1))) }
                let request = AIRequest(task: .transcription, phase: .startRecording, model: text(1))
                state.pending = request.id
                set("error", .text(""), in: ports)
                send(request)
            } else if !wanted, state.recordingWanted, let pending = state.pending {
                set("loading", .bool(true), in: ports)
                send(AIRequest(id: pending, task: .transcription, phase: .stopRecording, model: text(1)))
                // Recording again before this is heard does not lose it.
                if let older = state.transcribing { send(AIRequest(id: older, task: .transcription, phase: .cancel, model: text(1))) }
                state.transcribing = pending
                state.pending = nil
            }
            state.recordingWanted = wanted
            for id in [state.transcribing, state.pending].compactMap({ $0 }) {
                let recording = id == state.pending
                func ended() {
                    if recording { state.pending = nil } else { state.transcribing = nil }
                    if recording || state.pending == nil { set("recording", .bool(false), in: ports) }
                    set("loading", .bool(state.transcribing != nil), in: ports)
                }
                for update in updates(id) {
                    switch update {
                    case let .recording(on):
                        // A let-go recording saying it stopped speaks for the patch only
                        // when no new one has started.
                        if recording || state.pending == nil { set("recording", .bool(on), in: ports) }
                    case let .finished(heard, _):
                        ended()
                        set("text", .text(heard), in: ports)
                        set("done", .pulse(true), in: ports)
                    case let .failed(problem):
                        ended()
                        set("failed", .pulse(true), in: ports)
                        set("error", .text(problem), in: ports)
                    default:
                        break
                    }
                }
            }

        case .object:
            let ports = ["object", "loading", "done", "failed", "error"]
            let prompt = text(0), picture = text(4)
            if pulse(5), !prompt.isEmpty || !picture.isEmpty {
                if let pending = state.pending { send(AIRequest(id: pending, task: .object, phase: .cancel, model: text(3))) }
                let request = AIRequest(task: .object, model: text(3), prompt: prompt, instructions: text(1), picture: picture, fields: text(2))
                state.pending = request.id
                set("loading", .bool(true), in: ports)
                set("error", .text(""), in: ports)
                send(request)
            }
            if let pending = state.pending {
                for update in updates(pending) {
                    switch update {
                    case let .partial(json):
                        if let object = Value.parseJSON(Data(json.utf8)) { set("object", object, in: ports) }
                    case let .finished(json, _):
                        state.pending = nil
                        if let object = Value.parseJSON(Data(json.utf8)) { set("object", object, in: ports) }
                        set("loading", .bool(false), in: ports)
                        set("done", .pulse(true), in: ports)
                    case let .failed(problem):
                        state.pending = nil
                        set("loading", .bool(false), in: ports)
                        set("failed", .pulse(true), in: ports)
                        set("error", .text(problem), in: ports)
                    default:
                        break
                    }
                    if state.pending == nil { break }
                }
            }

        case .translation:
            let ports = ["text", "loading", "done", "failed", "error"]
            if pulse(3), !text(0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let pending = state.pending { send(AIRequest(id: pending, task: .translation, phase: .cancel, model: AIRequest.onDevice)) }
                let request = AIRequest(
                    task: .translation, model: AIRequest.onDevice, prompt: text(0),
                    target: AIRequest.languageCode(text(1)), source: AIRequest.languageCode(text(2))
                )
                state.pending = request.id
                set("loading", .bool(true), in: ports)
                set("error", .text(""), in: ports)
                send(request)
            }
            if let pending = state.pending {
                for update in updates(pending) {
                    switch update {
                    case let .finished(translated, _):
                        state.pending = nil
                        set("text", .text(translated), in: ports)
                        set("loading", .bool(false), in: ports)
                        set("done", .pulse(true), in: ports)
                    case let .failed(problem):
                        state.pending = nil
                        set("loading", .bool(false), in: ports)
                        set("failed", .pulse(true), in: ports)
                        set("error", .text(problem), in: ports)
                    default:
                        break
                    }
                    if state.pending == nil { break }
                }
            }
        }
    }
}
