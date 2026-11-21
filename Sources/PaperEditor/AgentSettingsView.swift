import AppKit
import PaperEngine
import SwiftUI

/// The Settings window: whether recordings show touches, the API keys of the AI patches,
/// the switch for the MCP server, and how to connect a coding agent to it.
struct AgentSettingsView: View {
    @Bindable var service: AgentService
    @AppStorage(ViewerView.recordsTouchesKey) private var recordsTouches = true

    var body: some View {
        Form {
            Section("Recording") {
                Toggle("Show touches in recordings", isOn: $recordsTouches)
            }
            AIKeysSection(keys: .shared)
            Section {
                Toggle("Let coding agents control tango", isOn: $service.isEnabled)
                LabeledContent("Status") { Text(status).foregroundStyle(.secondary) }
            } header: {
                Text("Agents")
            } footer: {
                Text("Agents such as Claude Code and Codex can read and edit the documents you have open, on this Mac only. Their edits can be undone like your own.")
            }
            if let address = service.address {
                Section("Connect") {
                    command("Claude Code", "claude mcp add --transport http tango \(address)")
                    command("Codex", "codex mcp add tango --url \(address)")
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
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
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
                .help("Copy this command, then run it in Terminal")
            }
        }
    }
}

/// The API keys the AI patches use, one per provider, saved in the keychain.
struct AIKeysSection: View {
    let keys: AIKeys
    @AppStorage(AIKeys.asksFirstKey) private var asksFirst = true

    var body: some View {
        Section {
            ForEach(AIProvider.allCases, id: \.self) { provider in
                AIKeyRow(keys: keys, provider: provider)
            }
            Toggle("Ask before a prototype uses a key", isOn: $asksFirst)
        } header: {
            Text("AI")
        } footer: {
            Text("Generate Text uses Claude or OpenAI; Generate Image, Speak and Transcribe use OpenAI. Keys stay in this Mac's keychain and are sent only to api.anthropic.com and api.openai.com. Requests are charged to your account.")
        }
    }
}

private struct AIKeyRow: View {
    let keys: AIKeys
    let provider: AIProvider
    @State private var entry = ""
    @State private var problem: String?

    var body: some View {
        LabeledContent(provider == .anthropic ? "Claude API Key" : "OpenAI API Key") {
            HStack {
                if let hint = keys.hints[provider] {
                    Text("Saved, ends in \(hint)")
                        .foregroundStyle(.secondary)
                    Button("Remove", role: .destructive) {
                        do {
                            try keys.remove(provider)
                            problem = nil
                        } catch {
                            problem = error.localizedDescription
                        }
                    }
                } else {
                    SecureField("Paste a key", text: $entry)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .disabled(entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Link("Get a Key", destination: AIKeys.consoleURL(for: provider))
                }
            }
        }
        if let problem {
            Text(problem).font(.caption).foregroundStyle(.red)
        }
    }

    private func save() {
        do {
            try keys.set(entry, for: provider)
            entry = ""
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}
