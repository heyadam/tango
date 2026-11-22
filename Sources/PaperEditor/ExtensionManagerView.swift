import AppKit
import PaperEngine
import PaperModel
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// An extension: a package directory with `extension.json` and what it names.
    public nonisolated static let paperExtension = UTType(exportedAs: "com.tango.extension", conformingTo: .package)
}

/// An extension someone is about to install or update, for the sheet that asks first.
struct ExtensionReview: Identifiable {
    let package: PaperExtension
    /// The folder it is being installed from, remembered so a newer version can be found there.
    var source: URL?
    /// Set when the copy came inside a document rather than from a folder the person chose.
    var fromDocument = false
    /// Set to use the extension from its folder instead of copying it, for writing one.
    var links = false

    var id: String { "\(package.id) \(package.version)" }
}

extension PaperExtension {
    /// What installing this over `old` would change, in sentences. `widens` marks those
    /// that let the extension reach or ask for more than before.
    func changes(from old: PaperExtension) -> [(text: String, widens: Bool)] {
        var found: [(String, Bool)] = []
        let before = old.manifest, after = manifest
        for host in after.network where !before.network.contains(host) { found.append(("Can now contact \(host)", true)) }
        for host in before.network where !after.network.contains(host) { found.append(("No longer contacts \(host)", false)) }
        for secret in after.secrets {
            guard let was = before.secret(secret.id) else {
                found.append(("Asks for a new key: \(secret.name)", true))
                continue
            }
            let added = secret.hosts.filter { !was.hosts.contains($0) }
            if !added.isEmpty { found.append(("Would also send the key \(secret.name) to \(added.joined(separator: ", "))", true)) }
        }
        func names(_ manifest: ExtensionManifest) -> [String: String] {
            var all: [String: String] = [:]
            for patch in manifest.patches { all[patch.id] = "the patch \(patch.name)" }
            for view in manifest.views { all[view.id] = "the view \(view.name)" }
            return all
        }
        let had = names(before), has = names(after)
        for id in has.keys.sorted() where had[id] == nil { found.append(("Adds \(has[id]!)", false)) }
        for id in had.keys.sorted() where has[id] == nil { found.append(("Removes \(had[id]!)", false)) }
        return found
    }
}

// MARK: - What an extension adds and may do

/// The sections that say what an extension adds, what it may contact and which keys it
/// asks for. The install sheet and the manager show the same ones, so what was agreed to
/// can be looked up later in the same words.
struct ExtensionContents: View {
    let package: PaperExtension
    /// The installed version, when this one would replace it: what is new is marked.
    var replacing: PaperExtension?
    /// Off where the keys are shown with their fields instead, in the manager.
    var listsKeys = true

    private var manifest: ExtensionManifest { package.manifest }

    var body: some View {
        Section("Adds") {
            ForEach(manifest.patches, id: \.id) { patch in
                item(patch.name, patch.summary, symbol: "square.on.square.dashed", kind: "Patch")
            }
            ForEach(manifest.views, id: \.id) { view in
                item(view.name, view.summary, symbol: view.shader == nil ? "paintbrush.pointed" : "sparkles.rectangle.stack", kind: view.shader == nil ? "View" : "Shader View")
            }
            // A component goes by the name it has inside its file, which is only read, not
            // run; one whose file cannot be read is listed by the file's name.
            let components = package.components().found
            if components.count == manifest.components.count {
                ForEach(components) { component in
                    item(component.name, component.summary ?? "", symbol: "shippingbox", kind: "Component")
                }
            } else {
                ForEach(manifest.components, id: \.self) { path in
                    item(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, "", symbol: "shippingbox", kind: "Component")
                }
            }
            if manifest.patches.isEmpty, manifest.views.isEmpty, manifest.components.isEmpty {
                Text("Nothing").foregroundStyle(.secondary)
            }
        }
        Section {
            if manifest.network.isEmpty {
                Label("Nothing. It makes no web requests.", systemImage: "network.slash")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manifest.network, id: \.self) { host in
                    LabeledContent {
                        if let replacing, !replacing.manifest.network.contains(host) { Text("New").foregroundStyle(.orange) }
                    } label: {
                        Label(host, systemImage: "network").monospaced()
                    }
                }
            }
        } header: {
            Text("Can Contact")
        } footer: {
            Text("Its scripts run in a sandbox with no access to files or other apps. They can send requests to these hosts and nowhere else.")
        }
        if !manifest.secrets.isEmpty, listsKeys {
            Section {
                ForEach(manifest.secrets, id: \.id) { secret in
                    LabeledContent {
                        Text("Sent only to \(secret.hosts.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label(secret.name, systemImage: "key")
                    }
                }
            } header: {
                Text("Asks For")
            } footer: {
                Text("A key is kept in your keychain. The extension's code never sees it: the app adds it to requests bound for the hosts shown.")
            }
        }
    }

    private func item(_ name: String, _ summary: String, symbol: String, kind: String) -> some View {
        LabeledContent {
            Text(kind).font(.caption).foregroundStyle(.secondary)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                    if !summary.isEmpty {
                        Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } icon: {
                Image(systemName: symbol)
            }
        }
    }
}

/// The name, version and author of an extension, with its mark.
struct ExtensionHeading: View {
    let package: PaperExtension
    var title: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title ?? package.name).font(.title2.bold())
                Text(["Version \(package.version)", package.manifest.author.map { "by \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                if let summary = package.manifest.summary, !summary.isEmpty {
                    Text(summary).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Asking before installing

/// Shown before an extension is installed or updated: what it adds, where it may send
/// requests and which keys it asks for. Nothing of it has run when this is read.
public struct ExtensionReviewSheet: View {
    let review: ExtensionReview
    let extensions: ExtensionStore
    var done: (ExtensionStore.Installed?) -> Void = { _ in }

    /// The sheet for `package` alone, as `papertool` draws it.
    public init(package: PaperExtension, extensions: ExtensionStore, fromDocument: Bool = false) {
        review = ExtensionReview(package: package, fromDocument: fromDocument)
        self.extensions = extensions
    }

    init(review: ExtensionReview, extensions: ExtensionStore, done: @escaping (ExtensionStore.Installed?) -> Void = { _ in }) {
        self.review = review
        self.extensions = extensions
        self.done = done
    }

    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?

    private var installed: PaperExtension? { extensions.installed(review.package.id)?.package }
    private var isUpdate: Bool { installed.map { $0.version != review.package.version } ?? false }

    private var title: String {
        if review.links { return "Link \(review.package.name) for development?" }
        guard let installed else { return "Install \(review.package.name)?" }
        if review.package.version > installed.version { return "Update \(review.package.name) to \(review.package.version)?" }
        if review.package.version < installed.version { return "Go back to \(review.package.name) \(review.package.version)?" }
        return "Install \(review.package.name) again?"
    }

    private var action: String {
        if review.links { return "Link" }
        guard let installed else { return "Install" }
        return review.package.version > installed.version ? "Update" : "Install"
    }

    public var body: some View {
        // Only the manifest is read here. Looking for problems in the scripts would run
        // them, and nothing of an extension runs before it has been agreed to.
        VStack(spacing: 0) {
            Form {
                Section {
                    ExtensionHeading(package: review.package, title: title)
                    if review.fromDocument {
                        Label("This copy came inside the document. Install it only if you trust where the document came from.", systemImage: "doc.badge.gearshape")
                            .foregroundStyle(.secondary)
                    }
                    if review.links {
                        Label("It is used straight from its folder. Changes to its files take effect as you save them, with no further asking.", systemImage: "link")
                            .foregroundStyle(.secondary)
                    }
                    if let installed, isUpdate {
                        LabeledContent("Installed now", value: "Version \(installed.version)")
                    }
                }
                if let installed {
                    let changes = review.package.changes(from: installed)
                    if !changes.isEmpty {
                        Section("What Changes") {
                            ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                                Label(change.text, systemImage: change.widens ? "exclamationmark.triangle" : "arrow.triangle.2.circlepath")
                                    .foregroundStyle(change.widens ? .orange : .primary)
                            }
                        }
                    }
                }
                ExtensionContents(package: review.package, replacing: installed)
                if let failure {
                    Section { Label(failure, systemImage: "xmark.octagon").foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    done(nil)
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(action) {
                    do {
                        let entry = if review.links, let folder = review.source {
                            try extensions.link(folder)
                        } else {
                            try extensions.install(review.package, from: review.source)
                        }
                        done(entry)
                        dismiss()
                    } catch {
                        failure = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 540, height: 600)
    }
}

// MARK: - The manager

/// The Extensions window: what is installed, and for each one what it adds, what it may
/// contact, whether it is on, and how to update or remove it.
public struct ExtensionManagerView: View {
    public static let windowID = "extensions"
    /// What is selected when the list of all keys is shown; no extension has this id.
    public static let keysSelection = "#keys"

    @Bindable var extensions: ExtensionStore
    @State private var selection: String?
    @State private var search = ""
    @State private var review: ExtensionReview?
    @State private var importing = false
    /// Whether the folder being chosen is to be linked rather than installed.
    @State private var linking = false
    @State private var failure: String?
    @State private var isDropTarget = false

    /// `selected` and `reviewing` are given by `papertool`, to draw the window as it
    /// looks with an extension chosen or one about to be installed.
    public init(extensions: ExtensionStore = .shared, selected: String? = nil, reviewing: PaperExtension? = nil) {
        self.extensions = extensions
        _selection = State(initialValue: selected)
        _review = State(initialValue: reviewing.map { ExtensionReview(package: $0) })
    }

    private var shown: [ExtensionStore.Installed] {
        guard !search.isEmpty else { return extensions.installed }
        return extensions.installed.filter {
            $0.package.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search)
                || ($0.package.manifest.summary ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                if !shown.isEmpty {
                    Section("Installed") {
                        ForEach(shown) { entry in
                            ExtensionRow(
                                entry: entry, update: extensions.updates[entry.id],
                                needsKey: !extensions.keys.needed(by: entry.package).isEmpty
                            )
                            .tag(entry.id)
                        }
                    }
                }
                if let problem = extensions.problem, search.isEmpty {
                    Section("Settings") {
                        Label {
                            Text(problem).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                        .selectionDisabled()
                    }
                }
                if !extensions.broken.isEmpty, search.isEmpty {
                    Section("Could Not Be Read") {
                        ForEach(extensions.broken) { item in
                            BrokenRow(item: item) { remove(item) }
                        }
                    }
                }
                // Every key in one place, whichever extension it was entered for.
                Section("Keys") {
                    Label("API Keys", systemImage: "key").tag(ExtensionManagerView.keysSelection)
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search")
            .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
            .overlay {
                if extensions.installed.isEmpty, extensions.broken.isEmpty {
                    ContentUnavailableView {
                        Label("No Extensions", systemImage: "puzzlepiece.extension")
                    } description: {
                        Text("Extensions add patches and views. Install one from a folder, or drop it here.")
                    } actions: {
                        Button("Install Extension…") {
                            linking = false
                            importing = true
                        }
                    }
                } else if shown.isEmpty, !search.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
        } detail: {
            if selection == ExtensionManagerView.keysSelection {
                AllKeysView(extensions: extensions)
            } else if let entry = selection.flatMap({ extensions.installed($0) }) {
                ExtensionDetail(entry: entry, extensions: extensions) { review = $0 }
                    .id(entry.id)
            } else {
                ContentUnavailableView(
                    "No Extension Selected", systemImage: "puzzlepiece.extension",
                    description: Text("Select an extension to see what it adds and what it may contact.")
                )
            }
        }
        .navigationTitle("Extensions")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Check for Updates", systemImage: "arrow.triangle.2.circlepath") {
                    extensions.reload()
                    extensions.checkForUpdates()
                }
                .help("Look for newer versions where each extension was installed from")
                Menu("Add", systemImage: "plus") {
                    Button("Install Extension…") {
                        linking = false
                        importing = true
                    }
                    Button("Link Folder for Development…") {
                        linking = true
                        importing = true
                    }
                }
                .help("Install an extension from a folder, or use one from its folder while you write it")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.paperExtension, .folder], allowsMultipleSelection: false) { result in
            // Whether to link is decided here and then forgotten: a picker that was
            // cancelled must not decide what the next one, or a drop, does.
            let links = linking
            linking = false
            if case let .success(urls) = result, let url = urls.first { open(url, links: links) }
        } onCancellation: {
            linking = false
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            // What is dropped is installed. Linking is asked for by name.
            open(url, links: false)
            return true
        } isTargeted: { isDropTarget = $0 }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 10).strokeBorder(.tint, lineWidth: 3).padding(4).allowsHitTesting(false)
            }
        }
        .sheet(item: $review) { review in
            ExtensionReviewSheet(review: review, extensions: extensions) { entry in
                if let entry { selection = entry.id }
            }
        }
        .alert("The extension could not be read", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
        .onAppear {
            extensions.checkForUpdates()
            if selection == nil { selection = extensions.installed.first?.id }
        }
        .frame(minWidth: 720, minHeight: 440)
    }

    private func remove(_ item: ExtensionStore.Broken) {
        do { try extensions.remove(item) } catch { failure = error.localizedDescription }
    }

    /// Reads the folder at `url` and asks before installing it or linking it.
    private func open(_ url: URL, links: Bool) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            review = ExtensionReview(package: try PaperExtension(contentsOf: url), source: url, links: links)
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// Something among the extensions that could not be read. It has no detail to show, so
/// what can be done about it is on the row: its menu shows it in the Finder or removes it.
private struct BrokenRow: View {
    let item: ExtensionStore.Broken
    let remove: () -> Void

    private var removal: String { item.linkedID != nil ? "Remove Link" : "Remove" }

    var body: some View {
        HStack(alignment: .top) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                    Text(item.message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Spacer(minLength: 4)
            // In sight, since the row cannot be selected to find it elsewhere.
            Button(removal, systemImage: "trash", role: .destructive, action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(item.linkedID != nil ? "Remove the link. The folder is left as it is." : "Remove this folder from the installed extensions.")
        }
        .selectionDisabled()
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button(removal, role: .destructive, action: remove)
        }
    }
}

/// One installed extension in the list: its name, version and what needs attention.
private struct ExtensionRow: View {
    let entry: ExtensionStore.Installed
    let update: PaperExtension?
    var needsKey = false

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.package.name)
                HStack(spacing: 6) {
                    Text("Version \(entry.package.version.description)")
                    if entry.isLinked { badge("Development", .purple) }
                    if !entry.problems.isEmpty {
                        badge("Problem", .orange)
                    } else if !entry.isEnabled {
                        badge("Off", .secondary)
                    } else if update != nil {
                        badge("Update", .accentColor)
                    } else if needsKey {
                        badge("Needs Key", .orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: entry.isUsable ? "puzzlepiece.extension.fill" : "puzzlepiece.extension")
                .foregroundStyle(entry.isUsable ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .padding(.vertical, 2)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// Everything about one installed extension, and the controls to change it.
private struct ExtensionDetail: View {
    let entry: ExtensionStore.Installed
    let extensions: ExtensionStore
    let review: (ExtensionReview) -> Void

    @State private var confirmsRemoval = false
    @State private var failure: String?

    private var package: PaperExtension { entry.package }

    var body: some View {
        Form {
            Section {
                ExtensionHeading(package: package)
                Toggle("Enabled", isOn: Binding(
                    get: { entry.isEnabled },
                    set: { extensions.setEnabled(entry.id, $0) }
                ))
                if !entry.isEnabled {
                    Text("Its patches stay in your documents with their cables, and do nothing while it is off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if entry.isLinked {
                Section {
                    Label("Linked for development. It runs straight from its folder, and changes to its files take effect as you save them.", systemImage: "link")
                        .foregroundStyle(.secondary)
                }
            }
            if let update = extensions.updates[entry.id] {
                Section {
                    LabeledContent {
                        Button("Update…") { review(ExtensionReview(package: update, source: entry.source)) }
                    } label: {
                        Label("Version \(update.version.description) is available", systemImage: "arrow.down.circle")
                    }
                }
            }
            if !entry.problems.isEmpty {
                Section("Problems") {
                    ForEach(entry.problems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    Text("It does not run until these are fixed. Fix them in its folder and install it again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ExtensionContents(package: package, listsKeys: false)
            if !package.manifest.secrets.isEmpty {
                Section {
                    ForEach(package.manifest.secrets, id: \.id) { secret in
                        KeyRow(secret: secret, extensionID: entry.id, keys: extensions.keys)
                    }
                } header: {
                    Text("Keys")
                } footer: {
                    Text("A key is kept in your keychain on this Mac. The extension's code never sees it: the app adds it to requests bound for the hosts shown, and takes it out of what comes back.")
                }
            }
            ExtensionActivity(entry: entry, extensions: extensions)
            Section("About") {
                if let readme = package.text("README.md"), !readme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    AssistantMarkdown(text: String(readme.prefix(6000)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                LabeledContent("Identifier") { Text(entry.id).monospaced().textSelection(.enabled) }
                if let homepage = package.manifest.homepage, let url = URL(string: homepage), url.scheme == "https" {
                    LabeledContent("Website") { Link(url.host ?? homepage, destination: url) }
                }
                if let source = entry.source {
                    LabeledContent("Installed From") {
                        HStack(spacing: 6) {
                            Text(source.path).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                            Button("Show in Finder", systemImage: "magnifyingglass") {
                                NSWorkspace.shared.activateFileViewerSelecting([source])
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Show the folder it was installed from")
                        }
                    }
                }
            }
            Section {
                Button(entry.isLinked ? "Remove Link…" : "Uninstall…", role: .destructive) { confirmsRemoval = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(package.name)
        .confirmationDialog(entry.isLinked ? "Remove the link to \(package.name)?" : "Uninstall \(package.name)?", isPresented: $confirmsRemoval) {
            Button(entry.isLinked ? "Remove Link" : "Uninstall", role: .destructive) {
                do { try extensions.uninstall(entry.id) } catch { failure = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text((entry.isLinked ? "The folder and its files are left as they are. " : "")
                + "Documents that use it keep its patches and their cables. They do nothing until it is installed again."
                + (extensions.keys.entries.contains { $0.extensionID == entry.id } ? " The keys entered for it are removed from your keychain." : ""))
        }
        .alert("It could not be uninstalled", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }
}

/// One key an extension asks for: a field to enter it, or when it was saved and the
/// buttons to replace or remove it. The value is never shown again once saved.
private struct KeyRow: View {
    let secret: ExtensionManifest.Secret
    let extensionID: String
    let keys: ExtensionKeys

    @State private var draft = ""
    @State private var isReplacing = false
    @State private var failure: String?

    var body: some View {
        let status = keys.status(of: secret, in: extensionID)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(secret.name, systemImage: "key")
                Spacer()
                if case let .saved(date) = status, !isReplacing {
                    Text("Saved \(date.formatted(date: .abbreviated, time: .omitted))").foregroundStyle(.secondary)
                    Button("Replace…") { isReplacing = true }
                    Button("Remove", role: .destructive) {
                        if let entry = keys.entry(for: secret, of: extensionID) { keys.remove(entry) }
                    }
                }
            }
            if case let .outgrown(added) = status {
                Label(
                    "This extension now also sends the key to \(added.joined(separator: ", ")). Enter it again to allow that.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }
            if isReplacing || !isSaved(status) {
                HStack {
                    SecureField("Key", text: $draft, prompt: Text("Paste the key"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if isReplacing {
                        Button("Cancel") {
                            draft = ""
                            isReplacing = false
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text("Sent only to \(secret.hosts.joined(separator: ", ")).")
                if let help = secret.help, let url = URL(string: help), url.scheme == "https" {
                    Link("Where to get one", destination: url)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private func isSaved(_ status: ExtensionKeys.Status) -> Bool {
        if case .saved = status { return true }
        return false
    }

    private func save() {
        do {
            try keys.set(draft, for: secret, of: extensionID)
            draft = ""
            isReplacing = false
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// Every key that is kept, for whichever extension: what it is for, where it may be sent,
/// and a button to remove it.
private struct AllKeysView: View {
    let extensions: ExtensionStore

    var body: some View {
        let entries = extensions.keys.entries.sorted { $0.savedAt > $1.savedAt }
        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No Keys", systemImage: "key",
                    description: Text("A key you enter for an extension is kept in your keychain and listed here.")
                )
            } else {
                Form {
                    Section {
                        ForEach(entries) { entry in
                            let package = extensions.installed(entry.extensionID)?.package
                            LabeledContent {
                                Button("Remove", role: .destructive) { extensions.keys.remove(entry) }
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(package?.manifest.secret(entry.secretID)?.name ?? entry.secretID)
                                        Text("\(package?.name ?? entry.extensionID) · sent only to \(entry.hosts.joined(separator: ", "))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text("Saved \(entry.savedAt.formatted(date: .abbreviated, time: .omitted))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "key")
                                }
                            }
                        }
                    } footer: {
                        Text("Keys are kept in your keychain on this Mac and are never shown again. An extension's code does not see them: the app adds a key to requests bound for the hosts it was entered for.")
                    }
                }
                .formStyle(.grouped)
            }
        }
        .navigationTitle("API Keys")
    }
}

/// What an extension's scripts have said since the app started: errors and log lines.
private struct ExtensionActivity: View {
    let entry: ExtensionStore.Installed
    let extensions: ExtensionStore

    var body: some View {
        let _ = extensions.logRevision
        let entries = ExtensionLog.shared.entries(for: entry.id)
        if !entries.isEmpty {
            Section {
                ForEach(entries.suffix(20).reversed()) { item in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.message).font(.callout.monospaced()).textSelection(.enabled).lineLimit(4)
                            Text(item.count > 1 ? "\(item.item) · \(item.count) times" : item.item)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: item.isError ? "exclamationmark.circle" : "text.bubble")
                            .foregroundStyle(item.isError ? .red : .secondary)
                    }
                }
            } header: {
                HStack {
                    Text("Activity")
                    Spacer()
                    Button("Clear") { ExtensionLog.shared.clear(entry.id) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        }
    }
}

// MARK: - In a document window

/// A bar at the top of a document that uses an extension this Mac does not have, or has
/// switched off: what is missing, and the one thing to do about it.
struct ExtensionOfferBar: View {
    let offers: [ExtensionStore.Offer]
    let extensions: ExtensionStore
    let review: (ExtensionReview) -> Void
    let dismiss: (ExtensionStore.Offer) -> Void

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            ForEach(offers) { offer in
                HStack(spacing: 10) {
                    Image(systemName: "puzzlepiece.extension").foregroundStyle(.secondary)
                    Text(message(offer)).lineLimit(2)
                    Spacer(minLength: 12)
                    button(offer)
                    Button("Dismiss", systemImage: "xmark") { dismiss(offer) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Hide this until the document is opened again")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                Divider()
            }
        }
        .background(.bar)
    }

    private func message(_ offer: ExtensionStore.Offer) -> String {
        switch offer.action {
        case .install:
            return "This document uses \(offer.name), which is not installed. Its patches do nothing until it is."
        case let .update(package, from):
            return "This document was made with \(offer.name) \(package.version). Version \(from) is installed."
        case .switchOn:
            return "\(offer.name) is switched off, so its patches in this document do nothing."
        case .broken:
            return "\(offer.name) has a problem and is not running."
        case .missing:
            return "This document uses an extension that is not installed (\(offer.id)) and carries no copy of it."
        case let .needsKeys(names):
            return "\(offer.name) needs \(names.count == 1 ? "a key" : "keys") before its requests can be sent: \(names.joined(separator: ", "))."
        }
    }

    @ViewBuilder private func button(_ offer: ExtensionStore.Offer) -> some View {
        switch offer.action {
        case let .install(package):
            Button("Review…") { review(ExtensionReview(package: package, fromDocument: true)) }
        case let .update(package, _):
            Button("Review Update…") { review(ExtensionReview(package: package, fromDocument: true)) }
        case .switchOn:
            Button("Switch On") { extensions.setEnabled(offer.id, true) }
        case .broken:
            Button("Show…") { openWindow(id: ExtensionManagerView.windowID) }
        case .needsKeys:
            Button("Enter in Extensions…") { openWindow(id: ExtensionManagerView.windowID) }
        case .missing:
            EmptyView()
        }
    }
}
