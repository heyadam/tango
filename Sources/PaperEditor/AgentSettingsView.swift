import AppKit
import PaperEngine
import PaperHost
import SwiftUI

/// The Settings window: three panes in its toolbar, as a Mac app's settings are. General
/// has what recordings show, AI has who answers and with which key, and Agents has the MCP
/// server and how to connect a coding agent to it.
struct AgentSettingsView: View {
    @Bindable var service: AgentService
    /// The pane last shown, which the window opens on again.
    @AppStorage("settingsPane") private var pane = SettingsPane.general

    var body: some View {
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: SettingsPane.general) {
                GeneralSettingsPane().settingsPane()
            }
            Tab("AI", systemImage: "sparkles", value: SettingsPane.ai) {
                // The longest pane: it scrolls where the others are as tall as what is in them,
                // so it fits a small display.
                AISettingsPane(keys: .shared)
                    .formStyle(.grouped)
                    .frame(width: 560, height: 620)
            }
            Tab("Agents", systemImage: "terminal", value: SettingsPane.agents) {
                AgentsSettingsPane(service: service).settingsPane()
            }
        }
    }
}

enum SettingsPane: String {
    case general, ai, agents
}

private extension View {
    /// How every pane is laid out: one width, as tall as what is in it.
    func settingsPane() -> some View {
        formStyle(.grouped)
            .frame(width: 560)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

struct GeneralSettingsPane: View {
    @AppStorage(ViewerView.recordsTouchesKey) private var recordsTouches = true
    @AppStorage(ViewerView.showsAssistantTouchesKey) private var showsAssistantTouches = true

    var body: some View {
        Form {
            Section {
                Toggle("Show touches in recordings", isOn: $recordsTouches)
            } header: {
                Text("Recording")
            } footer: {
                Text("Each finger is drawn where it touched, so a recording shows what was tapped.")
            }
            Section {
                Toggle("Show the assistant using the prototype", isOn: $showsAssistantTouches)
            } header: {
                Text("Viewer")
            } footer: {
                Text("When the assistant tries what it built, the Viewer plays its taps and drags back for you.")
            }
            Section("iPhone") {
                DeviceLinkPanel(link: .shared)
            }
        }
    }
}

// MARK: - AI

/// Who can answer, one section each: Claude, OpenAI, Gemini, and a server for local
/// models. Each says what uses it and whether it is ready.
struct AISettingsPane: View {
    let keys: AIKeys
    @AppStorage(AIKeys.asksFirstKey) private var asksFirst = true
    @AppStorage(AssistantSettings.claudeUsesKeyKey) private var claudeUsesKey = false
    /// Read once when the pane opens: whether Apple's model can answer on this Mac.
    @State private var apple = AppleIntelligence.status

    var body: some View {
        Form {
            Section {
                Picker("Assistant signs in with", selection: $claudeUsesKey) {
                    Text("Claude Account").tag(false)
                    Text("API Key").tag(true)
                }
                APIKeyRow(keys: keys, account: AssistantProvider.claude.keyAccount)
            } header: {
                ProviderHeader("Claude", status: claudeStatus)
            } footer: {
                ProviderFooter(
                    claudeUsesKey
                        ? "Answers in the assistant and in Generate Text patches."
                        : "The assistant uses the Claude account signed in on this Mac. Generate Text patches use the API key.",
                    provider: .claude
                )
            }
            Section {
                APIKeyRow(keys: keys, account: AssistantProvider.openAI.keyAccount)
            } header: {
                ProviderHeader("OpenAI", status: status(of: .openAI))
            } footer: {
                ProviderFooter("Answers in the assistant and in Generate Text, Generate Image, Speak and Transcribe patches.", provider: .openAI)
            }
            Section {
                APIKeyRow(keys: keys, account: AssistantProvider.gemini.keyAccount)
            } header: {
                ProviderHeader("Gemini", status: status(of: .gemini))
            } footer: {
                ProviderFooter("Answers in the assistant.", provider: .gemini)
            }
            LocalModelsSection(keys: keys)
            Section {
                APIKeyRow(keys: keys, account: AIKeys.unsplash, prompt: "Paste access key")
            } header: {
                ProviderHeader("Unsplash", status: keys.hasKey(account: AIKeys.unsplash) ? .ready("Ready") : .off("No access key"))
            } footer: {
                Text("Finds photos for Unsplash Photo patches. A free key from an Unsplash developer app allows 50 searches an hour. [Get an access key](https://unsplash.com/oauth/applications)")
            }
            Section {
                LabeledContent("Model", value: apple.available ? apple.detail : "Not available")
            } header: {
                ProviderHeader("Apple Intelligence", status: apple.available ? .ready("On this Mac") : .off("Not available"))
            } footer: {
                Text(apple.available
                    ? "Answers in Generate Text, Generate Object, Speak, Transcribe and Translate patches with the apple-on-device model, on this Mac and on the iPhone player. No key, no cost, and nothing leaves the device."
                    : "\(apple.detail) Generate Text, Generate Object, Speak, Transcribe and Translate patches use it with the apple-on-device model.")
            }
            Section {
                Toggle("Ask before a prototype uses a key", isOn: $asksFirst)
            } header: {
                Text("Privacy")
            } footer: {
                Text("API keys are kept in the keychain on this Mac and sent only to their own provider. Usage is billed to your account with that provider.")
            }
        }
    }

    private func status(of provider: AssistantProvider) -> ProviderStatus {
        keys.hasKey(account: provider.keyAccount) ? .ready("Ready") : .off("No API key")
    }

    /// With its account Claude needs no key, and whether it is signed in is not known here.
    private var claudeStatus: ProviderStatus? {
        claudeUsesKey ? status(of: .claude) : nil
    }
}

/// Whether a provider can answer, in a few words beside its name.
enum ProviderStatus: Equatable {
    case ready(String)
    case off(String)
}

private struct ProviderHeader: View {
    let name: String
    let status: ProviderStatus?

    init(_ name: String, status: ProviderStatus?) {
        self.name = name
        self.status = status
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
            Spacer()
            Group {
                switch status {
                case let .ready(text):
                    // A shape as well as a color, for those who cannot tell green from gray.
                    Label(text, systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.green)
                case let .off(text):
                    Text(text).foregroundStyle(.secondary)
                case nil:
                    EmptyView()
                }
            }
            .font(.subheadline)
        }
    }
}

/// What a provider is used for, and where its keys are made.
private struct ProviderFooter: View {
    let text: String
    let provider: AssistantProvider

    init(_ text: String, provider: AssistantProvider) {
        self.text = text
        self.provider = provider
    }

    var body: some View {
        if let url = provider.consoleURL {
            Text("\(text) [Get an API key](\(url.absoluteString))")
        } else {
            Text(text)
        }
    }
}

/// One key: a field to paste it into, or the end of the one that is saved.
private struct APIKeyRow: View {
    let keys: AIKeys
    let account: String
    var prompt = "Paste API key"
    @State private var entry = ""
    @State private var problem: String?

    var body: some View {
        LabeledContent("API key") {
            HStack {
                if let hint = keys.hints[account] {
                    Text("Ends in \(hint)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button("Remove", role: .destructive) {
                        do {
                            try keys.remove(account: account)
                            problem = nil
                        } catch {
                            problem = error.localizedDescription
                        }
                    }
                } else {
                    // The words go inside the field: as a label they stand beside it and wrap.
                    SecureField("API key", text: $entry, prompt: Text(prompt))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .disabled(entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        if let problem {
            Text(problem).font(.caption).foregroundStyle(.red)
        }
    }

    private func save() {
        do {
            try keys.set(entry, account: account)
            entry = ""
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// A server on this Mac or network that runs models: which one, where, and what it has.
struct LocalModelsSection: View {
    let keys: AIKeys
    @AppStorage(AssistantSettings.localURLKey) private var address = AssistantSettings.localPresets[0].url
    @AppStorage(AssistantSettings.localSeesPicturesKey) private var seesPictures = false
    @AppStorage(AssistantSettings.localModelsKey) private var listed = ""
    @State private var checking = false
    @State private var problem: String?

    private static let other = "Other"

    private var models: [String] { AssistantSettings.models(in: listed) }

    /// The app whose usual address is the one entered, or Other.
    private var server: Binding<String> {
        Binding(
            get: { AssistantSettings.localPresets.first { $0.url == address }?.name ?? Self.other },
            set: { name in
                guard let preset = AssistantSettings.localPresets.first(where: { $0.name == name }) else { return }
                address = preset.url
                connect()
            }
        )
    }

    var body: some View {
        Section {
            Picker("Server", selection: server) {
                ForEach(AssistantSettings.localPresets, id: \.name) { Text($0.name).tag($0.name) }
                Divider()
                Text(Self.other).tag(Self.other)
            }
            LabeledContent("Address") {
                TextField("Address", text: $address, prompt: Text(AssistantSettings.localPresets[0].url))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onSubmit(connect)
            }
            APIKeyRow(keys: keys, account: AIKeys.local, prompt: "Optional")
            LabeledContent("Models") {
                HStack {
                    if checking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(summary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                    Button(models.isEmpty ? "Connect" : "Refresh", action: connect)
                        .disabled(checking)
                }
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            Toggle("Send pictures to local models", isOn: $seesPictures)
        } header: {
            ProviderHeader("Local Models", status: models.isEmpty ? .off("Not connected") : .ready("Ready"))
        } footer: {
            Text("Answers in the assistant, from a server that speaks the OpenAI API. Send pictures only to a model that can see them. Small models may not manage the assistant's tools.")
        }
        // The models listed are another server's once the address changes.
        .onChange(of: address) {
            listed = ""
            problem = nil
        }
    }

    private var summary: String {
        switch models.count {
        case 0: "None found yet"
        case 1: models[0]
        default: "\(models.count) models"
        }
    }

    private func connect() {
        guard let base = AssistantSettings.url(from: address) else {
            problem = "Enter an address such as \(AssistantSettings.localPresets[0].url)."
            return
        }
        checking = true
        problem = nil
        Task {
            defer { checking = false }
            do {
                let found = try await ChatTransport.models(base: base, key: keys.key(account: AIKeys.local))
                // Still the address that was asked: an answer for an earlier one is not this one's.
                guard AssistantSettings.url(from: address) == base else { return }
                listed = found.joined(separator: "\n")
                if found.isEmpty { problem = "The server answered, but it has no models loaded." }
            } catch {
                let config = ChatTransport.Config(name: "The server", base: base, key: nil, model: "")
                problem = ChatTransport.words(for: error, config: config)
            }
        }
    }
}

// MARK: - Agents

/// Coding agents outside the app: the switch for the MCP server, and what to tell them.
struct AgentsSettingsPane: View {
    @Bindable var service: AgentService

    var body: some View {
        Form {
            Section {
                Toggle("Let coding agents control tango", isOn: $service.isEnabled)
                LabeledContent("Status") { Text(status).foregroundStyle(.secondary) }
            } footer: {
                Text("Agents such as Claude Code and Codex can read and edit the documents you have open, on this Mac only. Their edits can be undone like your own.")
            }
            if let address = service.address {
                Section {
                    command("Claude Code", "claude mcp add --transport http tango \(address)")
                    command("Codex", "codex mcp add tango --url \(address)")
                } header: {
                    Text("Connect")
                } footer: {
                    Text("Run one of these in Terminal, once.")
                }
                Section {
                    command("Bring a screen in", "Sketch <file or view> in tango: read get_reference, build it, and mark the baseline.")
                    command("Carry changes back", "Apply what I changed in tango: call get_changes and write it into the code.")
                } header: {
                    Text("Sketch from Code")
                } footer: {
                    Text("Ask a connected agent to build a screen here from your code. Play with it, then ask the agent to write your changes back. The code stays the source of truth.")
                }
            }
        }
    }

    private var status: String {
        switch service.state {
        case nil: "Off"
        case .starting: "Starting…"
        case let .listening(port): "Listening on port \(port)"
        case let .failed(problem): "Could not start: \(problem)"
        }
    }

    private func command(_ name: String, _ text: String) -> some View {
        // The command sits under its name: side by side, a long one wraps and a short one does not.
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
            HStack {
                Text(text)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Copy")
            }
        }
    }
}
