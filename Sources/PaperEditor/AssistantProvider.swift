import Foundation
import PaperEngine

/// Who can answer in the assistant. Claude runs through the Agent SDK in the Node program
/// (`ProcessTransport`); everyone else is spoken to directly, in the Chat Completions
/// dialect they all understand (`ChatTransport`).
public enum AssistantProvider: String, CaseIterable, Identifiable, Sendable {
    case claude
    case openAI
    case gemini
    /// A server on this Mac or this network that speaks OpenAI's API: oMLX, Ollama, LM Studio.
    case local

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .claude: "Claude"
        case .openAI: "OpenAI"
        case .gemini: "Gemini"
        case .local: "Local"
        }
    }

    /// The account its key is saved under in `AIKeys`. Claude and OpenAI share theirs with
    /// the AI patches.
    var keyAccount: String {
        switch self {
        case .claude: AIProvider.anthropic.rawValue
        case .openAI: AIProvider.openAI.rawValue
        case .gemini: AIKeys.gemini
        case .local: AIKeys.local
        }
    }

    /// Where a person gets a key.
    var consoleURL: URL? {
        switch self {
        case .claude: AIKeys.consoleURL(for: .anthropic)
        case .openAI: AIKeys.consoleURL(for: .openAI)
        case .gemini: URL(string: "https://aistudio.google.com/apikey")
        case .local: nil
        }
    }

    /// How it is spoken to. OpenAI's newer models take tools only through Responses; Gemini
    /// and local servers speak Chat Completions.
    var dialect: ChatTransport.Dialect { self == .openAI ? .responses : .completions }

    /// What to call it while waiting for its first word.
    var waitName: String { self == .local ? "the local model" : name }

    /// Where its API is. Claude has none here: it is not spoken to this way.
    func baseURL(defaults: UserDefaults = .standard) -> URL? {
        switch self {
        case .claude: nil
        case .openAI: URL(string: "https://api.openai.com/v1")
        case .gemini: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")
        case .local: AssistantSettings.localURL(defaults)
        }
    }

    /// A line to a model that is not Claude, for a caller that has the key and the address
    /// itself (papertool, which reads them from its environment and options). Nil for Claude.
    public static func chatTransport(
        for model: AssistantSession.Model, base: URL? = nil, key: String?, seesPictures: Bool = true
    ) -> AssistantTransport? {
        guard model.provider != .claude, let base = base ?? model.provider.baseURL() else { return nil }
        return ChatTransport(ChatTransport.Config(
            name: model.provider == .local ? "The local model" : model.provider.name, base: base, key: key,
            model: model.rawValue, sendsPictures: seesPictures, sendsEffort: model.provider != .local,
            dialect: model.provider.dialect
        ))
    }

    /// The line a chat with this model talks over.
    static func transport(
        for model: AssistantSession.Model, keys: AIKeys = .shared, defaults: UserDefaults = .standard
    ) -> AssistantTransport {
        let provider = model.provider
        let key = keys.key(account: provider.keyAccount)
        switch provider {
        case .claude:
            guard AssistantSettings.claudeUsesKey(defaults) else { return ProcessTransport() }
            return ProcessTransport(apiKey: key, needsKey: true)
        case .openAI, .gemini, .local:
            var problem: String?
            if provider != .local, key == nil {
                problem = "Add \(provider == .openAI ? "an" : "a") \(provider.name) API key in Settings (Command-comma), then send your message again."
            }
            let base = provider.baseURL(defaults: defaults)
            if base == nil { problem = "The local server's address in Settings (Command-comma) is not one that can be reached." }
            let transport = ChatTransport(
                ChatTransport.Config(
                    name: provider == .local ? "The local model" : provider.name,
                    base: base ?? URL(string: "http://localhost")!, key: key, model: model.rawValue,
                    sendsPictures: provider != .local || AssistantSettings.localSeesPictures(defaults),
                    sendsEffort: provider != .local, dialect: provider.dialect
                ),
                problem: problem
            )
            transport.currentKey = { keys.key(account: provider.keyAccount) }
            return transport
        }
    }
}

/// What the assistant keeps in the defaults.
enum AssistantSettings {
    /// Whether Claude answers on the saved API key and not on this Mac's Claude login.
    static let claudeUsesKeyKey = "assistantClaudeUsesKey"
    static let localURLKey = "assistantLocalURL"
    static let localSeesPicturesKey = "assistantLocalSeesPictures"
    /// The models the local server listed when it was last asked, so the menu has them
    /// without asking again.
    static let localModelsKey = "assistantLocalModels"
    /// The model the last chat was given, as `Model.id`.
    static let modelKey = "assistantModel"

    /// Servers people run, and where each listens unless told otherwise.
    static let localPresets: [(name: String, url: String)] = [
        ("oMLX", "http://localhost:8000/v1"),
        ("Ollama", "http://localhost:11434/v1"),
        ("LM Studio", "http://localhost:1234/v1"),
    ]

    static func claudeUsesKey(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: claudeUsesKeyKey)
    }

    static func localSeesPictures(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: localSeesPicturesKey)
    }

    /// Kept as lines of text, so a view can follow them with `AppStorage`.
    static func localModels(_ defaults: UserDefaults = .standard) -> [String] {
        models(in: defaults.string(forKey: localModelsKey) ?? "")
    }

    static func models(in lines: String) -> [String] {
        lines.split(separator: "\n").map(String.init)
    }

    /// The local server's address, when what was typed is an http(s) address with a host.
    static func localURL(_ defaults: UserDefaults = .standard) -> URL? {
        url(from: defaults.string(forKey: localURLKey) ?? localPresets[0].url)
    }

    static func url(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else { return nil }
        // An address with no path is the server itself: its API is under /v1.
        return url.path.isEmpty ? url.appendingPathComponent("v1") : url
    }

    /// The model a new chat starts with: the last one chosen, or Opus.
    static func model(_ defaults: UserDefaults = .standard) -> AssistantSession.Model {
        defaults.string(forKey: modelKey).flatMap(AssistantSession.Model.init(stored:)) ?? .opus
    }

    static func remember(_ model: AssistantSession.Model, in defaults: UserDefaults = .standard) {
        defaults.set(model.id, forKey: modelKey)
    }
}

extension AssistantSession {
    /// A model that can answer: a provider and the id it knows the model by. Update the
    /// lists here when a new generation ships.
    public struct Model: Hashable, Identifiable, Sendable {
        public var provider: AssistantProvider
        /// The id sent to the provider. Empty is Claude's own default.
        public var rawValue: String

        public init(_ provider: AssistantProvider, _ id: String) {
            self.provider = provider
            rawValue = id
        }

        /// Whatever the signed-in Claude account uses when no model is named.
        public static let standard = Model(.claude, "")
        public static let fable = Model(.claude, "claude-fable-5-2")
        public static let opus = Model(.claude, "claude-opus-5-5")
        public static let sonnet = Model(.claude, "claude-sonnet-5-5")
        public static let haiku = Model(.claude, "claude-haiku-5-5")

        /// The Claude models on offer.
        public static let allCases: [Model] = [.standard, .fable, .opus, .sonnet, .haiku]
        /// OpenAI's are the ones the Generate Text patch offers.
        public static let openAI: [Model] = AIRequest.textModels
            .filter { AIProvider.of(model: $0) == .openAI }
            .map { Model(.openAI, $0) }
        public static let gemini: [Model] = ["gemini-4-argon", "gemini-3.8-flash", "gemini-3.1-flash-lite"]
            .map { Model(.gemini, $0) }

        /// What the menu lists for a provider. A local server's are the ones it last listed.
        static func models(for provider: AssistantProvider, defaults: UserDefaults = .standard) -> [Model] {
            switch provider {
            case .claude: allCases
            case .openAI: openAI
            case .gemini: gemini
            case .local: models(listed: AssistantSettings.localModels(defaults))
            }
        }

        static func models(listed ids: [String]) -> [Model] { ids.map { Model(.local, $0) } }

        public var id: String { "\(provider.rawValue):\(rawValue)" }

        public var title: String {
            guard provider == .claude else { return rawValue }
            return self == .standard ? "Default" : Self.name(of: rawValue)
        }

        /// A model as the command line names it: `fable`, `opus`, `sonnet` or `haiku` for
        /// Claude's, and `openai:<id>`, `gemini:<id>` or `local:<id>` for anyone else's.
        public init?(named name: String) {
            if let colon = name.firstIndex(of: ":") {
                let id = String(name[name.index(after: colon)...])
                guard !id.isEmpty else { return nil }
                switch name[..<colon].lowercased() {
                case "claude", "anthropic":
                    guard let match = Model(named: id) ?? Self.allCases.first(where: { $0.rawValue == id }) else { return nil }
                    self = match
                case "openai": self = Model(.openAI, id)
                case "gemini", "google": self = Model(.gemini, id)
                case "local": self = Model(.local, id)
                default: return nil
                }
                return
            }
            guard let match = Self.allCases.first(where: { $0 != .standard && $0.rawValue.contains("-\(name.lowercased())-") }) else {
                return nil
            }
            self = match
        }

        /// A model from its `id`, as the defaults keep it.
        init?(stored: String) {
            guard let colon = stored.firstIndex(of: ":"),
                  let provider = AssistantProvider(rawValue: String(stored[..<colon])) else { return nil }
            let id = String(stored[stored.index(after: colon)...])
            guard provider == .claude || !id.isEmpty else { return nil }
            self.init(provider, id)
        }

        /// A model id as people say it: `claude-opus-5-5` is "Opus 5.5". Other providers'
        /// ids are shown as they are.
        public static func name(of id: String) -> String {
            guard id.lowercased().hasPrefix("claude") else { return id }
            var parts = id.lowercased().split(whereSeparator: { $0 == "-" || $0 == "[" }).map(String.init)
            if parts.first == "claude" { parts.removeFirst() }
            let words = parts.prefix { Int($0) == nil }.map(\.capitalized)
            // Version numbers are short; a long run of digits is a release date.
            let version = parts.dropFirst(words.count).prefix { Int($0) != nil && $0.count <= 2 }
            guard !words.isEmpty else { return id }
            return (words + (version.isEmpty ? [] : [version.joined(separator: ".")])).joined(separator: " ")
        }
    }
}
