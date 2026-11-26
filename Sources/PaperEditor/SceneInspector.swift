import AppKit
import PaperEngine
import PaperHost
import PaperModel
import PaperRender
import SwiftUI
import UniformTypeIdentifiers

/// The Inspector's sections for a scene view: the scene's own inputs (camera, light,
/// surroundings), then a section for each thing in it, and a way to add one.
struct SceneSections: View {
    let store: DocumentStore
    let layer: Layer
    let scene: SceneUse

    var body: some View {
        Section {
            ForEach(SceneUse.inputs) { input in
                SceneInputRow(store: store, layer: layer, key: SceneUse.Key(input: input.id), input: input, name: input.name)
            }
        } header: {
            Text("Scene")
        } footer: {
            Text(LayerRenderer.tracesRays
                ? "Drawn in three dimensions over the view's fill and under the views inside it. With Ray Tracing on, things cast shadows and shiny ones mirror the others."
                : "Drawn in three dimensions over the view's fill and under the views inside it. This device traces no rays, so there are no shadows or mirrored things.")
        }
        ForEach(scene.objects) { object in
            Section {
                LabeledContent("Name") {
                    TextValueField(text: object.name) { store.renameSceneObject(object.id, to: $0, in: layer.id) }
                }
                if object.shape == .model {
                    LabeledContent("File") {
                        HStack(spacing: 6) {
                            Text(object.model ?? "None").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Button("Choose…") { SceneSections.chooseModel(store: store, layer: layer.id, replacing: object.id) }
                        }
                    }
                }
                ForEach(SceneObject.inputs) { input in
                    SceneInputRow(
                        store: store, layer: layer, key: SceneUse.Key(object: object.id, input: input.id), input: input, name: input.name
                    )
                }
                Button("Remove \(object.name)", systemImage: "trash", role: .destructive) {
                    store.removeSceneObject(object.id, from: layer.id)
                }
            } header: {
                Label(object.name, systemImage: object.shape == .model ? "shippingbox" : "cube")
            } footer: {
                if object.shape == .model, let problem = SceneSections.problem(with: object, store: store) {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if object.shape == .model {
                    Text("A model keeps the colors of its file until a Color, Metalness or Roughness is set here or cabled.")
                }
            }
        }
        Section {
            Menu("Add to Scene", systemImage: "plus") {
                ForEach(SceneObject.Shape.builtIn, id: \.self) { shape in
                    Button(shape.displayName) { store.addSceneObject(shape, to: layer.id) }
                }
                Divider()
                Button("Model from File…") { SceneSections.chooseModel(store: store, layer: layer.id, replacing: nil) }
            }
        }
    }

    /// The kinds of file a scene shows.
    static var modelTypes: [UTType] {
        LayerRenderer.modelExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
    }

    /// Why a model's file shows nothing, or nil. Asked of a renderer of its own, which
    /// reads the file the Viewer's has already read.
    static func problem(with object: SceneObject, store: DocumentStore) -> String? {
        guard let name = object.model, !name.isEmpty else { return "Choose a USDZ, USD or OBJ file." }
        let renderer = LayerRenderer()
        let assets = store.assets
        renderer.modelURL = { VideoFiles.assetURL(for: $0, assets: assets) }
        return renderer.modelProblem(name)
    }

    /// Copies a model file into the document's assets and shows it: as a new object, or in
    /// place of the file an object had.
    static func chooseModel(store: DocumentStore, layer: LayerID, replacing object: String?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = modelTypes
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        store.transaction("Add Model") {
            let name = store.addAsset(data, named: url.lastPathComponent)
            if let object {
                store.setScene(of: layer, named: "Change Model") { scene in
                    guard let index = scene.objects.firstIndex(where: { $0.id == object }) else { return }
                    scene.objects[index].shape = .model
                    scene.objects[index].model = name
                }
            } else {
                store.addSceneObject(.model, model: name, to: layer)
            }
        }
    }
}

/// One input of a scene or of a thing in it: its value or what a cable brings, and
/// whether the view's patch shows it as a port.
struct SceneInputRow: View {
    let store: DocumentStore
    let layer: Layer
    let key: SceneUse.Key
    let input: SceneInput
    let name: String

    private var patch: PatchNode? { store.viewNode(for: layer.id) }

    private var isDriven: Bool {
        guard let patch else { return false }
        return store.document.graph.connection(into: PortRef(node: patch.id, port: key.port)) != nil
    }

    private var isShown: Bool {
        guard let patch else { return false }
        return store.shownScenePorts(of: layer, on: patch).contains(key.port)
    }

    var body: some View {
        LabeledContent {
            if isDriven, let patch {
                let _ = store.liveTick
                Text(store.runtime?.inputValue(PortRef(node: patch.id, port: key.port))?.summary ?? "–")
                    .monospacedDigit()
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                    .help("Driven by the patch graph")
            } else {
                ValueEditor(
                    value: layer.scene?.value(for: key) ?? input.defaultValue,
                    type: input.type, options: input.options, name: name
                ) { new, interactive in
                    store.setSceneInput(key, of: layer.id, to: new, interactive: interactive)
                    if interactive { store.endInteractiveSoon("Change \(name)") }
                }
            }
        } label: {
            Button {
                if isDriven, let patch {
                    store.show(patch.id)
                } else {
                    store.setScenePort(key.port, of: layer.id, shown: !isShown)
                }
            } label: {
                Label(name, systemImage: isDriven ? "circle.fill" : isShown ? "circle.inset.filled" : "circle")
                    .foregroundStyle(isDriven ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            }
            .buttonStyle(.plain)
            .help(isDriven
                ? "A cable drives \(name). Click to show it in the graph."
                : isShown ? "Click to hide the \(name) port on this view's patch"
                : "Click to show \(name) as a port on this view's patch")
        }
    }
}
