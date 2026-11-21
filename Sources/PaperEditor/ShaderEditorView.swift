import PaperEngine
import PaperModel
import PaperRender
import SwiftUI

/// The code of a shader view, in a pane under the patch graph. It stays open while the
/// Viewer runs: what is typed is compiled a moment later and drawn at once. While the code
/// does not compile, the view keeps drawing with the last code that did.
struct ShaderEditorPane: View {
    let store: DocumentStore
    let layerID: LayerID
    @State private var text = ""
    /// What this pane last put in the document, to tell its own edits from someone else's.
    @State private var sent: String?
    @State private var problem: String?
    @State private var pending: Task<Void, Never>?

    private var layer: Layer? { store.document.layer(layerID) }

    var body: some View {
        let stored = layer?.shader?.source
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label(layer?.name ?? "Shader", systemImage: ViewType.shader.symbolName)
                    .font(.headline)
                Spacer()
                Button("Done") { store.editingShader = nil }
                    .keyboardShortcut(.cancelAction)
                    .help("Close the shader's code (Escape)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            CodeTextView(text: $text, errorLine: ShaderHighlighter.line(in: problem))
            Divider()
            Group {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .help("The view keeps drawing with the last code that compiled.")
                } else {
                    let names = ShaderSource.interface(of: text).ports.map(\.name).joined(separator: ", ")
                    Label("Inputs: \(names.isEmpty ? "none" : names)", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(2)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.background)
        .onAppear { load(stored) }
        .onChange(of: layerID) { _, _ in load(layer?.shader?.source) }
        .onChange(of: stored) { _, new in
            // Changed from elsewhere: undo, or the assistant rewriting it.
            if let new, new != sent, new != text { load(new) }
            if new == nil { store.editingShader = nil }
        }
        .onChange(of: text) { _, new in
            guard new != sent else { return }
            pending?.cancel()
            pending = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                commit(new)
            }
        }
        .onDisappear {
            pending?.cancel()
            if text != sent { commit(text) }
        }
    }

    private func load(_ source: String?) {
        pending?.cancel()
        sent = source
        text = source ?? ""
        problem = source.flatMap(ShaderCompiler.error(in:))
    }

    private func commit(_ source: String) {
        sent = source
        problem = ShaderCompiler.error(in: source)
        store.setShader(source, of: layerID, interactive: true)
        store.endInteractiveSoon("Edit Shader")
    }
}

/// One input of a shader view: its value, or what a cable brings.
struct ShaderInputRow: View {
    let store: DocumentStore
    let layer: Layer
    let uniform: ShaderSource.Uniform

    private var patch: PatchNode? { store.viewNode(for: layer.id) }

    private var isDriven: Bool {
        guard let patch else { return false }
        return store.document.graph.connection(into: PortRef(node: patch.id, port: uniform.port.id)) != nil
    }

    var body: some View {
        let port = uniform.port
        LabeledContent {
            if isDriven, let patch {
                let _ = store.liveTick
                Text(store.runtime?.inputValue(PortRef(node: patch.id, port: port.id))?.summary ?? "–")
                    .monospacedDigit()
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                    .help("Driven by the patch graph")
            } else {
                ValueEditor(
                    value: ShaderSource.value(of: uniform, stored: layer.shader?.inputs ?? [:]),
                    type: port.type, options: [], name: port.name
                ) { new, interactive in
                    store.setShaderInput(uniform.name, of: layer.id, to: new, interactive: interactive)
                    if interactive { store.endInteractiveSoon("Change \(port.name)") }
                }
            }
        } label: {
            Button {
                if let patch { store.show(patch.id) }
            } label: {
                Label(port.name, systemImage: isDriven ? "circle.fill" : "circle.inset.filled")
                    .foregroundStyle(isDriven ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            }
            .buttonStyle(.plain)
            .help("Click to show this view's patch, to drive \(port.name) with a cable")
        }
    }
}
