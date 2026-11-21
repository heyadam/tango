import Foundation
import PaperModel

// AI patches: text from Claude or OpenAI, pictures and speech from OpenAI, and speech
// turned into text. Like Network Request, the runtime only says what it wants: the host
// makes the call with the person's API key and reports back with `Runtime.update(ai:_:)`.

/// Who answers a request, which follows from the model's name.
public enum AIProvider: String, Sendable, CaseIterable {
    case anthropic
    case openAI

    public static func of(model: String) -> AIProvider {
        model.lowercased().hasPrefix("claude") ? .anthropic : .openAI
    }

    public var name: String {
        switch self {
        case .anthropic: "Claude"
        case .openAI: "OpenAI"
        }
    }
}

/// What an AI patch wants done.
public struct AIRequest: Sendable, Hashable {
    public enum Task: String, Sendable { case text, image, speech, transcription }
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

    public init(
        id: UUID = UUID(), task: Task, phase: Phase = .send, model: String, prompt: String = "",
        instructions: String = "", effort: String = "", picture: String = "", conversation: [AITurn] = [],
        voice: String = "", size: String = ""
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
    /// Text so far, while it streams in: the whole of it, not just what is new.
    case partial(String)
    /// The microphone started or stopped recording for a transcription.
    case recording(Bool)
    /// Speech started or finished playing.
    case playing(Bool)
    /// The answer: text for text and transcription, a picture name for images. Speech
    /// finishes with empty text once it has been fetched; `.playing(false)` follows.
    case finished(text: String, picture: String)
    case failed(String)
}

extension AIRequest {
    public static let textModels = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "gpt-6.2-astra", "gpt-6.2-sol", "gpt-6-luna"]
    public static let imageModels = ["gpt-image-2.6-flare", "gpt-image-2.6-sunburst"]
    public static let speechModels = ["gpt-4o-mini-tts"]
    public static let transcriptionModels = ["gpt-transcribe"]
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
    ]
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
        }
    }
}
