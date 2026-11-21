import PaperEngine
import PaperModel
import SwiftUI

/// Something the Patch Library can add: a view, which is a patch, or a patch that works on values.
enum LibraryItem: Identifiable, Equatable {
    case view(ViewType)
    case patch(PatchDefinition)
    /// A view an extension adds.
    case custom(CustomViewDefinition)
    /// A ready-made component from a shelf: the iOS controls, or an extension's.
    case component(ComponentDefinition, shelf: String)
    /// A ready-made container that is copied in as plain views.
    case template(ViewTemplate)

    var id: String {
        switch self {
        case let .view(type): "view." + type.rawValue
        case let .patch(definition): definition.kind
        case let .custom(view): "view." + view.kind
        case let .component(definition, _): "component." + definition.id.uuidString
        case let .template(template): "template." + template.id
        }
    }

    var name: String {
        switch self {
        case let .view(type): type.displayName
        case let .patch(definition): definition.name
        case let .custom(view): view.name
        case let .component(definition, _): definition.name
        case let .template(template): template.name
        }
    }

    var summary: String {
        switch self {
        case let .view(type): type.summary
        case let .patch(definition): definition.summary
        case let .custom(view): view.summary
        case let .component(definition, _): definition.summary ?? "A component."
        case let .template(template): template.summary
        }
    }

    var kind: String? {
        switch self {
        case .view: nil
        case let .patch(definition): definition.kind
        case let .custom(view): view.kind
        case .component, .template: nil
        }
    }

    static func == (a: LibraryItem, b: LibraryItem) -> Bool { a.id == b.id }

    /// The views a person can add. A screen is given; a component comes from its own menu.
    static let views: [LibraryItem] = ViewType.allCases
        .filter { $0 != .screen && $0 != .component && $0 != .custom }
        .map(LibraryItem.view)
}

extension ViewType {
    /// One sentence for the Patch Library.
    var summary: String {
        switch self {
        case .screen: "The device's screen: the view everything else is in."
        case .view: "A box with a fill, corner radius, border and shadow. It can hold other views, each placed by its own x and y."
        case .stack: "Arranges the views in it in a row or a column, with spacing, padding, alignment and distribution."
        case .grid: "Arranges the views in it in equal columns."
        case .scrollView: "A stack that scrolls when its content is longer than it is. Reports its offset, velocity and whether it is being dragged."
        case .ellipse: "An oval or a circle, with a fill, border and shadow."
        case .text: "A piece of text."
        case .image: "A picture from a file, or one a patch provides."
        case .symbol: "A glyph from the system symbol set, such as a chevron or a tab icon."
        case .textField: "A box the person can type in. Attach a Text Input patch to read what is typed."
        case .camera: "Shows the player's camera."
        case .video: "Plays a movie from a file or the web. Playing, Loop, Rate and Time control it; attach a Video Time patch to know where it is."
        case .component: "A use of a component."
        case .shader: "A view drawn by Metal shader code you write. The shader's inputs are ports on its patch, and it can draw from scratch or change the look of the views inside it."
        case .custom: "A view an extension draws."
        }
    }
}

/// A row of the Patch Library's sidebar.
enum LibraryCategory: Hashable, Identifiable {
    case all
    case views
    case patches(PatchCategory)
    /// What one extension adds, by its id.
    case package(String)
    /// A shelf of ready-made components, by its name.
    case shelf(String)

    var id: Self { self }

    var symbolName: String {
        switch self {
        case .all: "square.grid.2x2"
        case .views: "square.on.square"
        case let .patches(category): category.symbolName
        case .package: "puzzlepiece.extension"
        case .shelf: "iphone.gen3"
        }
    }
}

/// The icon a patch is shown with: its category's, unless the patch says something its
/// category's icon would not (Navigate is a State patch, but a switch is not what it is).
func patchSymbol(_ kind: String, category: PatchCategory?) -> String {
    switch kind {
    case PatchKind.navigate: return "arrow.right.square"
    case PatchKind.navigateBack: return "arrow.uturn.backward.square"
    default: return category?.symbolName ?? "square.dashed"
    }
}

/// The icon for one of the prototype's screens: a page with something on it, apart from
/// the empty rectangle of a plain view and the phone of the device that holds them.
let screenSymbol = "rectangle.portrait.inset.filled"

extension PatchCategory {
    var symbolName: String {
        switch self {
        case .input: "hand.tap"
        case .state: "switch.2"
        case .logic: "arrow.triangle.branch"
        case .math: "plus.forwardslash.minus"
        case .animation: "point.bottomleft.forward.to.point.topright.scurvepath"
        case .loop: "repeat"
        case .data: "curlybraces"
        case .ai: "sparkles"
        case .device: "iphone"
        case .utility: "wrench.and.screwdriver"
        case .component: "puzzlepiece"
        case .layer: "square.on.square"
        }
    }
}

/// One port as the Patch Library describes it.
struct LibraryPort: Identifiable {
    let id: String
    let name: String
    /// The type's name, or "Any" for a port that follows the patch's chosen type.
    let typeName: String
    let type: PortType?
    let note: String?
}

extension LibraryItem {
    var guide: PatchGuide? {
        switch self {
        case let .view(type): .view(type)
        case let .patch(definition): .patch(definition.kind)
        case .custom, .component, .template: nil
        }
    }

    var tags: [String] {
        switch self {
        case let .component(_, shelf): [shelf.lowercased(), "component", "control"]
        case .template: ["ios", "template", "container"]
        default: guide?.tags ?? []
        }
    }

    /// Where it is listed in the sidebar.
    var category: LibraryCategory {
        switch self {
        case .view: .views
        case let .custom(view): .package(view.origin.id)
        case let .patch(definition): definition.origin.map { .package($0.id) } ?? .patches(definition.category)
        case let .component(_, shelf): .shelf(shelf)
        case .template: .shelf("iOS")
        }
    }

    /// The name of its category as the detail pane shows it above the title.
    var categoryName: String {
        switch self {
        case .view: "View"
        case let .custom(view): view.origin.name
        case let .patch(definition): definition.origin?.name ?? definition.category.rawValue
        case let .component(_, shelf): "\(shelf) Component"
        case .template: "iOS Template"
        }
    }

    var color: Color {
        switch self {
        case .view, .custom, .template: Color(nsColor: PatchStyle.color(for: .layer))
        case .component: Color(nsColor: PatchStyle.color(for: .component))
        case let .patch(definition): Color(nsColor: PatchStyle.color(for: definition.category))
        }
    }

    var inputs: [LibraryPort] {
        switch self {
        case let .view(type):
            return type.preset.compactMap { id in
                ViewInput(id: id).map {
                    LibraryPort(id: id, name: $0.name, typeName: $0.type.displayName, type: $0.type, note: PatchGuide.viewInputs[id])
                }
            }
        case let .custom(view):
            return view.inputs.map { LibraryPort(id: $0.id, name: $0.name, typeName: $0.type.displayName, type: $0.type, note: nil) }
        case let .component(definition, _):
            return definition.inputs.map {
                LibraryPort(id: $0.id, name: $0.name, typeName: $0.type.displayName, type: $0.type, note: $0.options.isEmpty ? nil : $0.options.joined(separator: ", "))
            }
        case let .template(template):
            return template.publishedInputs.map {
                LibraryPort(id: $0.id, name: $0.name, typeName: $0.type.displayName, type: $0.type, note: $0.options.isEmpty ? nil : $0.options.joined(separator: ", "))
            }
        case let .patch(definition):
            return definition.inputs.enumerated().map { index, spec in
                var port = Self.port(spec, of: definition, note: guide?.inputs[spec.id])
                // A patch whose last input repeats lists it once, as a family.
                if definition.variableInputs != nil, index == definition.inputs.count - 1 {
                    port = LibraryPort(id: port.id, name: "\(port.name) 0, 1, 2…", typeName: port.typeName, type: port.type, note: port.note)
                }
                return port
            }
        }
    }

    var outputs: [LibraryPort] {
        switch self {
        case let .view(type):
            // Every view reports its frame; a scroll view also how it scrolls.
            let frame = PatchRegistry.frameOutputs.map {
                LibraryPort(id: $0.id, name: $0.name, typeName: $0.type.displayName, type: $0.type, note: PatchGuide.frameOutputs[$0.id])
            }
            guard type == .scrollView else { return frame }
            return PatchRegistry.scrollOutputs.map {
                LibraryPort(id: $0.id, name: $0.name, typeName: $0.type.displayName, type: $0.type, note: PatchGuide.scrollOutputs[$0.id])
            } + frame
        case .custom:
            return []
        case let .component(definition, _):
            return definition.outputs.map { LibraryPort(id: $0.id, name: $0.name, typeName: $0.type.displayName, type: $0.type, note: nil) }
        case let .template(template):
            return template.publishedOutputs.map { LibraryPort(id: $0.id, name: $0.name, typeName: $0.type.displayName, type: $0.type, note: nil) }
        case let .patch(definition):
            return definition.outputs.map { Self.port($0, of: definition, note: guide?.outputs[$0.id]) }
        }
    }

    private static func port(_ spec: PortSpec, of definition: PatchDefinition, note: String?) -> LibraryPort {
        switch spec.type {
        case let .fixed(type):
            LibraryPort(id: spec.id, name: spec.name, typeName: type.displayName, type: type, note: note)
        case .generic:
            LibraryPort(id: spec.id, name: spec.name, typeName: "Any", type: nil, note: note)
        }
    }

    /// The items that match a search, best first. Every word must match somewhere: the name
    /// counts most, then the tags, then the category and kind, then what the guide says.
    static func search(_ query: String, in items: [LibraryItem]) -> [LibraryItem] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return items }
        func score(_ word: String, _ item: LibraryItem) -> Int? {
            let name = item.name.lowercased()
            if name == word { return 0 }
            if name.hasPrefix(word) || name.split(separator: " ").contains(where: { $0.hasPrefix(word) }) { return 1 }
            if name.contains(word) { return 2 }
            if item.tags.contains(word) { return 3 }
            if item.tags.contains(where: { $0.hasPrefix(word) || $0.split(separator: " ").contains { $0.hasPrefix(word) } }) { return 4 }
            if item.categoryName.lowercased().hasPrefix(word) || (item.kind ?? "").lowercased().contains(word) { return 5 }
            if item.tags.contains(where: { $0.contains(word) }) { return 6 }
            if item.summary.lowercased().contains(word) { return 7 }
            if (item.guide?.details ?? "").lowercased().contains(word) { return 8 }
            return nil
        }
        let scored: [(item: LibraryItem, score: Int, order: Int)] = items.enumerated().compactMap { order, item in
            var total = 0
            for word in words {
                guard let points = score(word, item) else { return nil }
                total += points
            }
            return (item, total, order)
        }
        return scored.sorted { ($0.score, $0.order) < ($1.score, $1.order) }.map(\.item)
    }
}

/// Finds views and patches and explains each one: a sidebar of categories, the list, and a
/// pane that says what the selected one does, how to use it, and what each of its ports
/// means. Shown as a popover in the Patch Editor.
struct PatchLibraryView: View {
    let registry: PatchRegistry
    /// The shelves of ready-made components: the iOS controls, then each extension's.
    var shelves: [ComponentShelf] = []
    /// The view an Interaction patch would attach to, if one is selected.
    let selectedLayerName: String?
    /// What the selected view is, for the patches that attach to one kind only.
    var selectedLayerKind: LayerKind?
    var selectedLayerIsScreen = false
    /// Where a new view would go, to say so.
    var containerName = "Screen"
    /// The category it opens on.
    var startsIn: LibraryCategory = .all
    let onPick: (LibraryItem) -> Void

    @State private var query = ""
    @State private var category: LibraryCategory? = .all
    @State private var selection: LibraryItem.ID?
    @FocusState private var searchFocused: Bool

    /// Everything the library offers, in the order the sidebar lists categories.
    private var everything: [LibraryItem] {
        categories.filter { $0 != .all }.flatMap(members)
    }

    private var categories: [LibraryCategory] {
        var list: [LibraryCategory] = [.all, .views]
        list += shelves.filter { !$0.components.isEmpty }.map { .shelf($0.name) }
        list += PatchCategory.allCases.filter { category in
            registry.library.contains { $0.category == category && $0.origin == nil }
        }.map(LibraryCategory.patches)
        list += registry.extensions.available.filter { package in
            registry.viewLibrary.contains { $0.origin.id == package.id } || registry.library.contains { $0.origin?.id == package.id }
        }.map { .package($0.id) }
        return list
    }

    private func members(_ category: LibraryCategory) -> [LibraryItem] {
        switch category {
        case .all: everything
        case .views: LibraryItem.views
        case let .patches(patchCategory):
            registry.library.filter { $0.category == patchCategory && $0.origin == nil }.map(LibraryItem.patch)
        case let .package(id):
            registry.viewLibrary.filter { $0.origin.id == id }.map(LibraryItem.custom)
                + registry.library.filter { $0.origin?.id == id }.map(LibraryItem.patch)
        case let .shelf(name):
            groups(of: name).flatMap(\.items)
        }
    }

    /// A shelf in the parts it is listed in. The app's own has groups, with the templates
    /// of each after its components; an extension's is one list.
    private func groups(of shelf: String) -> [(name: String, items: [LibraryItem])] {
        guard let found = shelves.first(where: { $0.name == shelf }) else { return [] }
        guard found.extensionID == nil, shelf == "iOS" else {
            return [(shelf, found.components.map { .component($0, shelf: shelf) })]
        }
        return ComponentLibrary.groups.map { group in
            (group.name, group.components.map { .component($0, shelf: shelf) } + group.templates.map(LibraryItem.template))
        }
    }

    private func name(of category: LibraryCategory) -> String {
        switch category {
        case .all: "All"
        case .views: "Views"
        case let .patches(patchCategory): patchCategory.rawValue
        case let .package(id): registry.extensions.available.first { $0.id == id }?.name ?? id
        case let .shelf(name): name
        }
    }

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The list as shown, top to bottom.
    private var shown: [LibraryItem] {
        isSearching ? LibraryItem.search(query, in: everything) : members(category ?? .all)
    }

    private var selected: LibraryItem? {
        let shown = self.shown
        return shown.first { $0.id == selection } ?? shown.first
    }

    private func isAvailable(_ item: LibraryItem) -> Bool {
        guard let kind = item.kind, DocumentStore.touchPatchKinds.contains(kind) else { return true }
        // Text Input only means something on a text field, Video Time on a video.
        if let needed = DocumentStore.viewKind(for: kind) { return selectedLayerKind == needed }
        if kind == PatchKind.navigate { return selectedLayerIsScreen }
        return selectedLayerName != nil
    }

    var body: some View {
        let shown = self.shown
        VStack(spacing: 0) {
            searchField(shown)
            Divider()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 168)
                Divider()
                itemList(shown)
                    .frame(width: 220)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 820, height: 540)
        .onAppear {
            searchFocused = true
            if startsIn != .all { category = startsIn }
        }
        .onChange(of: query) { _, _ in selection = self.shown.first?.id }
        .onChange(of: category) { _, _ in
            if isSearching { query = "" }
            selection = self.shown.first?.id
        }
    }

    private func searchField(_ shown: [LibraryItem]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $query, prompt: Text("Search views and patches"))
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .onSubmit { if let selected { pick(selected) } }
                .onKeyPress(.downArrow) { move(by: 1, in: shown) }
                .onKeyPress(.upArrow) { move(by: -1, in: shown) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func move(by step: Int, in shown: [LibraryItem]) -> KeyPress.Result {
        guard !shown.isEmpty else { return .handled }
        let current = shown.firstIndex { $0.id == selected?.id } ?? 0
        selection = shown[min(max(current + step, 0), shown.count - 1)].id
        return .handled
    }

    private var sidebar: some View {
        List(selection: Binding(
            get: { isSearching ? nil : category },
            set: { category = $0 ?? .all }
        )) {
            ForEach(categories) { category in
                Label(name(of: category), systemImage: category.symbolName)
                    .tag(category)
            }
        }
        .listStyle(.sidebar)
    }

    private func itemList(_ shown: [LibraryItem]) -> some View {
        ScrollViewReader { proxy in
            List(selection: Binding(get: { selected?.id }, set: { selection = $0 })) {
                if shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else if !isSearching, category == .all {
                    ForEach(categories.filter { $0 != .all }) { section in
                        Section(name(of: section)) {
                            ForEach(members(section)) { row($0) }
                        }
                    }
                } else if !isSearching, case let .shelf(name) = category, groups(of: name).count > 1 {
                    ForEach(groups(of: name), id: \.name) { group in
                        Section(group.name) {
                            ForEach(group.items) { row($0) }
                        }
                    }
                } else {
                    ForEach(shown) { row($0) }
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: LibraryItem.ID.self) { _ in } primaryAction: { ids in
                if let id = ids.first, let item = shown.first(where: { $0.id == id }) { pick(item) }
            }
            .onChange(of: selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func row(_ item: LibraryItem) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                if isSearching {
                    Text(item.categoryName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            icon(item)
        }
        .foregroundStyle(isAvailable(item) ? .primary : .secondary)
        .tag(item.id)
        .id(item.id)
    }

    @ViewBuilder private func icon(_ item: LibraryItem) -> some View {
        switch item {
        case let .view(type):
            Image(systemName: type.symbolName).foregroundStyle(item.color)
        case let .custom(view):
            Image(systemName: view.symbolName).foregroundStyle(item.color)
        case .patch:
            Image(systemName: "circle.fill").foregroundStyle(item.color).imageScale(.small)
        case .component:
            Image(systemName: "puzzlepiece.extension").foregroundStyle(item.color)
        case .template:
            Image(systemName: "rectangle.3.group").foregroundStyle(item.color)
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let item = selected {
            VStack(spacing: 0) {
                ScrollView {
                    LibraryDetail(item: item)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                }
                Divider()
                HStack {
                    Text(note(for: item))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button("Insert") { pick(item) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isAvailable(item))
                }
                .padding(12)
            }
            .id(item.id)
        } else {
            ContentUnavailableView("Nothing Selected", systemImage: "square.dashed")
        }
    }

    /// Where the item will go, or why it cannot be added yet.
    private func note(for item: LibraryItem) -> String {
        if !isAvailable(item) {
            if item.kind == PatchKind.navigate { return "Select a screen first: this patch shows the screen it is attached to." }
            switch item.kind.flatMap(DocumentStore.viewKind) {
            case .textField: return "Select a Text Field first: this patch attaches to one."
            case .video: return "Select a Video first: this patch attaches to one."
            default: return "Select a view first: this patch attaches to a view."
            }
        }
        if let kind = item.kind, DocumentStore.touchPatchKinds.contains(kind), let selectedLayerName {
            return "Attaches to \(selectedLayerName)."
        }
        switch item {
        case .view, .custom: return "Adds it inside \(containerName)."
        case .component: return "Adds it inside \(containerName). Its inputs and outputs are ports on its patch."
        case let .template(template):
            return template.contentName.map { "Adds a copy inside \(containerName). Your own views go in \($0)." } ?? "Adds a copy inside \(containerName)."
        case .patch: return ""
        }
    }

    private func pick(_ item: LibraryItem) {
        guard isAvailable(item) else { return }
        onPick(item)
    }
}

/// What the Patch Library says about one view or patch.
private struct LibraryDetail: View {
    let item: LibraryItem

    var body: some View {
        let guide = item.guide
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.categoryName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(item.color)
                Text(item.name)
                    .font(.largeTitle.weight(.semibold))
                    .textSelection(.enabled)
                Text(item.summary)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let picture = LibraryPreview.shared.picture(of: item) {
                Image(nsImage: picture)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: min(picture.size.width, 402), maxHeight: 260, alignment: .leading)
                    .clipShape(.rect(cornerRadius: 10))
                    .accessibilityLabel("How \(item.name) looks")
            }
            if let details = guide?.details, details != item.summary {
                Text(details)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let tip = guide?.tip {
                GroupBox {
                    Label {
                        Text(tip).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "lightbulb").foregroundStyle(.yellow)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }
            ports("Inputs", item.inputs)
            ports("Outputs", item.outputs)
            if let tags = guide?.tags, !tags.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Also found by")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(tags.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private func ports(_ title: String, _ ports: [LibraryPort]) -> some View {
        if !ports.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(ports) { port in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle()
                                .fill(port.type.map { Color(nsColor: PatchStyle.color(for: $0)) } ?? Color.secondary)
                                .frame(width: 7, height: 7)
                            Text(port.name).font(.body.weight(.semibold))
                            Text(port.typeName).font(.caption).foregroundStyle(.secondary)
                        }
                        if let note = port.note {
                            Text(note)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 13)
                        }
                    }
                }
            }
        }
    }
}

extension CustomViewDefinition {
    /// A drawn view has a brush; a packaged shader looks like any shader view.
    var symbolName: String { shader == nil ? "paintbrush.pointed" : ViewType.shader.symbolName }
}

/// Pictures of the shelf's components and templates for the Patch Library, each made once.
@MainActor
final class LibraryPreview {
    static let shared = LibraryPreview()
    private var pictures: [String: NSImage] = [:]

    /// The item on the grouped background a screen in Settings has, as it looks at rest.
    func picture(of item: LibraryItem) -> NSImage? {
        if let known = pictures[item.id] { return known }
        guard let document = Self.document(for: item),
              let bitmap = ViewerSnapshot.bitmaps(of: document, steps: [.look], scale: 2).first else { return nil }
        let size = document.screen.value(.size).sizeValue
        let image = NSImage(size: CGSize(width: size.width, height: size.height))
        image.addRepresentation(bitmap)
        pictures[item.id] = image
        return image
    }

    static func document(for item: LibraryItem) -> PaperModel.Document? {
        let margin = 20.0
        func screen(for size: Size2, _ children: [Layer]) -> Layer {
            Layer(name: "Screen", kind: .screen, properties: [
                .size: .size(Size2(width: size.width + margin * 2, height: size.height + margin * 2)),
                .fill: .color(SystemStyle.groupedBackground.light),
            ], children: children)
        }
        switch item {
        case let .component(definition, _):
            let size = definition.root.value(.size).sizeValue
            var document = PaperModel.Document(screen: screen(for: size, [definition.instance(at: Point2(x: margin, y: margin))]))
            document.adopt(definition)
            return document
        case let .template(template):
            var root = template.root
            root.set(.position, .point(Point2(x: margin, y: margin)))
            var document = PaperModel.Document(screen: screen(for: root.value(.size).sizeValue, [root]))
            for component in template.components { document.adopt(component) }
            return document
        case .view, .patch, .custom:
            return nil
        }
    }
}
