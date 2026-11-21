import AppKit
import Foundation
import Observation
import PaperEngine
import PaperModel

/// The extensions installed on this Mac. They live in one folder, so installing, updating
/// or removing one here changes it for every document.
@Observable
public final class ExtensionStore {
    /// The app's own: the folder in Application Support.
    public static let shared: ExtensionStore = {
        let store = ExtensionStore(directory: ExtensionStore.defaultDirectory, vault: KeychainVault())
        // What scripts say arrives from whatever thread ran them.
        ExtensionLog.shared.observe { Task { @MainActor in store.logRevision += 1 } }
        // An extension that is being written is read again as its files are saved.
        store.watcher = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in store.refreshLinked() }
        }
        return store
    }()

    public static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Tango/Extensions", isDirectory: true)
    }

    /// One installed extension and how it is set up here.
    public struct Installed: Identifiable, Hashable, Sendable {
        public var package: PaperExtension
        public var isEnabled: Bool
        /// The folder it was installed from, where a newer version is looked for.
        public var source: URL?
        /// What is wrong with it besides its manifest, such as a script that does not load.
        public var problems: [String]
        /// Set for an extension used straight from the folder it is being written in:
        /// nothing was copied, and a change to its files is picked up as it is saved.
        public var isLinked = false

        public var id: String { package.id }
        /// Whether its code may run.
        public var isUsable: Bool { isEnabled && problems.isEmpty }
    }

    /// A folder among the installed ones that could not be read as an extension.
    public struct Broken: Identifiable, Hashable, Sendable {
        public var name: String
        public var message: String
        /// Where it is: a folder among the installed ones, or the folder a link points at.
        public var url: URL
        /// For a link: the extension it was a link to.
        public var linkedID: String?
        public var id: String { url.path }
    }

    public private(set) var installed: [Installed] = []
    public private(set) var broken: [Broken] = []
    /// Counts every change to what is installed or switched on.
    public private(set) var revision = 0
    /// Counts what extension scripts have said, so a list of it is drawn again.
    public fileprivate(set) var logRevision = 0
    /// Newer versions found where extensions were installed from, by extension id.
    public private(set) var updates: [String: PaperExtension] = [:]

    @ObservationIgnored public let directory: URL
    /// The keys entered for these extensions.
    @ObservationIgnored public let keys: ExtensionKeys

    private struct Record: Codable {
        var enabled = true
        var source: String?
        /// The folder a linked extension is read from, in place of a copy kept here.
        var linked: String?
    }
    @ObservationIgnored fileprivate var watcher: Timer?
    @ObservationIgnored private var linkedSignature = ""
    @ObservationIgnored private var records: [String: Record] = [:]
    @ObservationIgnored private var stateFile: SettingsFile
    /// What went wrong reading or saving which extensions are switched on, until a save succeeds.
    private var stateProblem: String?
    /// What went wrong with the app's own files here, for the Extensions window to say.
    public var problem: String? { stateProblem ?? keys.problem }

    /// `vault` is where the values of keys go. Only the app's own store uses the
    /// keychain; any other keeps them in memory.
    public init(directory: URL, vault: any KeyVault = MemoryVault()) {
        self.directory = directory
        stateFile = SettingsFile(directory.appendingPathComponent("state.json"))
        keys = ExtensionKeys(vault: vault, file: directory.appendingPathComponent("keys.json"))
        load()
    }

    // MARK: Reading

    private func folder(for id: String) -> URL {
        directory.appendingPathComponent("\(id).\(PaperExtension.fileExtension)", isDirectory: true)
    }

    /// Reads the folder again, as after something outside the app changed it.
    public func reload() {
        load()
        revision += 1
    }

    private func load() {
        let (read, problem) = stateFile.read([String: Record].self)
        records = read ?? [:]
        if let problem { stateProblem = "Extensions: \(problem.localizedDescription)" }
        var found: [Installed] = []
        var failed: [Broken] = []
        let children = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        // Settings files that could not be read were kept here, to be looked at or removed.
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where SettingsFile.isSetAside(child) {
            failed.append(Broken(name: child.lastPathComponent, message: "Settings that could not be read, kept in case they are wanted. The app no longer uses this file.", url: child))
        }
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where child.pathExtension == PaperExtension.fileExtension {
            do {
                let package = try PaperExtension(contentsOf: child)
                // A folder is known by the id inside it; one copied in under another name
                // would otherwise be installed twice.
                guard folder(for: package.id).lastPathComponent == child.lastPathComponent,
                      !found.contains(where: { $0.id == package.id }) else {
                    failed.append(Broken(name: child.lastPathComponent, message: "This folder is not named after the extension in it (\(package.id)).", url: child))
                    continue
                }
                found.append(entry(for: package))
            } catch {
                failed.append(Broken(name: child.lastPathComponent, message: error.localizedDescription, url: child))
            }
        }
        // Extensions that are linked are read from where they are being written.
        for (id, record) in records.sorted(by: { $0.key < $1.key }) {
            guard let path = record.linked, !found.contains(where: { $0.id == id }) else { continue }
            let url = URL(fileURLWithPath: path)
            do {
                let package = try PaperExtension(contentsOf: url)
                guard package.id == id else {
                    failed.append(Broken(name: url.lastPathComponent, message: "The linked folder now holds another extension (\(package.id)). Link it again.", url: url, linkedID: id))
                    continue
                }
                var entry = entry(for: package)
                entry.isLinked = true
                found.append(entry)
            } catch {
                failed.append(Broken(name: url.lastPathComponent, message: error.localizedDescription, url: url, linkedID: id))
            }
        }
        installed = found.sorted { $0.package.name.localizedCaseInsensitiveCompare($1.package.name) == .orderedAscending }
        broken = failed
        linkedSignature = signatureOfLinked()
    }

    /// What the linked folders hold, in a form that changes when any file in them does.
    private func signatureOfLinked() -> String {
        var parts: [String] = []
        for (id, record) in records.sorted(by: { $0.key < $1.key }) {
            guard let path = record.linked else { continue }
            parts.append(id)
            let root = URL(fileURLWithPath: path)
            let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
            var seen = 0
            for case let file as URL in files {
                seen += 1
                if seen > PaperExtension.mostFiles { break }
                guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                parts.append("\(file.path) \(values.contentModificationDate?.timeIntervalSince1970 ?? 0) \(values.fileSize ?? 0)")
            }
        }
        return parts.joined(separator: "\n")
    }

    /// Reads the linked extensions again if any of their files changed. The app does this
    /// once a second while it runs.
    public func refreshLinked() {
        guard records.values.contains(where: { $0.linked != nil }), signatureOfLinked() != linkedSignature else { return }
        load()
        for entry in installed where entry.isLinked { keys.settle(for: entry.package) }
        revision += 1
    }

    /// Uses the extension in `folder` from where it is, for writing one: nothing is
    /// copied, and what is saved there is what runs. A copy of it installed before is
    /// replaced by the link.
    @discardableResult
    public func link(_ folder: URL) throws -> Installed {
        let package = try PaperExtension(contentsOf: folder)
        let copy = self.folder(for: package.id)
        if FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.removeItem(at: copy) }
        var record = records[package.id] ?? Record()
        record.linked = folder.standardizedFileURL.path
        record.source = nil
        records[package.id] = record
        save()
        load()
        updates[package.id] = nil
        keys.settle(for: package)
        revision += 1
        guard let entry = installed(package.id) else { throw ExtensionProblem("The folder could not be linked.") }
        return entry
    }

    private func entry(for package: PaperExtension) -> Installed {
        let record = records[package.id] ?? Record()
        return Installed(
            package: package, isEnabled: record.enabled,
            source: record.source.map { URL(fileURLWithPath: $0) },
            problems: package.problems()
        )
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try stateFile.write(records, encoder: encoder)
            stateProblem = nil
        } catch {
            stateProblem = "Extensions: \(error.localizedDescription)"
        }
    }

    public func installed(_ id: String) -> Installed? { installed.first { $0.id == id } }

    // MARK: Changing

    /// Installs `package`, replacing a version of it that is already there. An extension
    /// that is switched off stays off through an update.
    @discardableResult
    public func install(_ package: PaperExtension, from source: URL? = nil) throws -> Installed {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try package.write(to: folder(for: package.id))
        var record = records[package.id] ?? Record()
        // Installing a copy ends a link: from here on the copy is what runs.
        record.linked = nil
        if let source { record.source = source.standardizedFileURL.path }
        records[package.id] = record
        save()
        load()
        if let known = updates[package.id], known.version <= package.version { updates[package.id] = nil }
        // A key entered for an earlier version is not passed on to one that would send it
        // to more places.
        keys.settle(for: package)
        revision += 1
        guard let entry = installed(package.id) else { throw ExtensionProblem("The extension could not be installed.") }
        return entry
    }

    /// Reads the folder or package at `url` and installs it.
    @discardableResult
    public func install(contentsOf url: URL) throws -> Installed {
        try install(PaperExtension(contentsOf: url), from: url)
    }

    public func uninstall(_ id: String) throws {
        guard ExtensionManifest.isExtensionID(id) else { return }
        let folder = folder(for: id)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        records[id] = nil
        save()
        load()
        ExtensionLog.shared.clear(id)
        updates[id] = nil
        keys.removeAll(of: id)
        revision += 1
    }

    /// Clears away something that could not be read. For a link that is the link alone:
    /// the folder it pointed at is someone's work and is left as it is. For a folder among
    /// the installed ones it is the folder, which is this app's own copy.
    public func remove(_ item: Broken) throws {
        if let id = item.linkedID {
            records[id] = nil
            keys.removeAll(of: id)
            save()
        } else if item.url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL {
            try FileManager.default.removeItem(at: item.url)
        }
        load()
        revision += 1
    }

    public func setEnabled(_ id: String, _ enabled: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == id }), installed[index].isEnabled != enabled else { return }
        var record = records[id] ?? Record()
        record.enabled = enabled
        records[id] = record
        save()
        installed[index].isEnabled = enabled
        revision += 1
    }

    // MARK: Making components for an extension

    /// Writes a component of a document into an extension's folder, as the file an
    /// extension ships: `components/<Name>.json`, with the pictures it shows copied to
    /// `assets/` and named by their path there. Components of the document that it is
    /// made of are written too. Returns the paths to list under `components` in the
    /// manifest.
    public static func export(component name: String, of package: DocumentPackage, to folder: URL) throws -> [String] {
        let all = package.document.components
        guard let wanted = all.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            let names = all.filter { $0.library == nil }.map(\.name).sorted().joined(separator: ", ")
            throw ExtensionProblem("The document has no component named \"\(name)\". Its components: \(names.isEmpty ? "none" : names).")
        }
        // The component, and the document's own components it is made of.
        var writing = [wanted], waiting = [wanted]
        while let next = waiting.popLast() {
            for layer in next.root.flattened {
                guard let id = layer.component?.id, !writing.contains(where: { $0.id == id }),
                      let inner = all.first(where: { $0.id == id }), inner.library == nil else { continue }
                writing.append(inner)
                waiting.append(inner)
            }
        }
        let manager = FileManager.default
        try manager.createDirectory(at: folder.appendingPathComponent("components"), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var paths: [String] = []
        for var component in writing {
            for layer in component.root.flattened {
                guard let image = layer.properties[.image]?.textValue, let data = package.assets[image] else { continue }
                let file = image.replacingOccurrences(of: "/", with: "-")
                guard ExtensionManifest.isPath("assets/\(file)") else {
                    throw ExtensionProblem("The picture \"\(image)\" has a name an extension cannot hold. Rename it and export again.")
                }
                try manager.createDirectory(at: folder.appendingPathComponent("assets"), withIntermediateDirectories: true)
                try data.write(to: folder.appendingPathComponent("assets/\(file)"))
                component.root.update(layer.id) { $0.properties[.image] = .text("assets/\(file)") }
            }
            component.library = nil
            let file = component.name.map { $0.isLetter || $0.isNumber ? $0 : "-" }
            let path = "components/\(String(file)).json"
            guard ExtensionManifest.isPath(path) else {
                throw ExtensionProblem("\"\(component.name)\" cannot be used as a file name. Rename the component and export again.")
            }
            try encoder.encode(component).write(to: folder.appendingPathComponent(path))
            paths.append(path)
        }
        return paths
    }

    // MARK: Updates

    /// Looks where each extension was installed from for a newer version. Everything is a
    /// local file for now, so this is how an update is found.
    public func checkForUpdates() {
        var found: [String: PaperExtension] = [:]
        for entry in installed {
            guard let source = entry.source, let candidate = try? PaperExtension(contentsOf: source),
                  candidate.id == entry.id, candidate.version > entry.package.version else { continue }
            found[entry.id] = candidate
        }
        if found != updates { updates = found }
    }

    // MARK: What a document needs

    /// Something to tell the person about an extension the open document uses.
    public struct Offer: Identifiable, Hashable, Sendable {
        public enum Action: Hashable, Sendable {
            /// The document carries a copy and it is not installed.
            case install(PaperExtension)
            /// The document carries a newer version than the installed one.
            case update(PaperExtension, from: ExtensionVersion)
            /// It is installed and switched off.
            case switchOn
            /// It is installed and something is wrong with it.
            case broken
            /// It is not installed and the document carries no copy.
            case missing
            /// It runs, but asks for keys that have not been entered.
            case needsKeys([String])
        }
        public var id: String
        public var name: String
        public var action: Action
    }

    /// What stands between a document and the extensions it uses.
    public func offers(used: Set<String>, carried: [PaperExtension]) -> [Offer] {
        _ = revision
        _ = keys.entries
        return used.sorted().compactMap { id in
            let copy = carried.first { $0.id == id }
            guard let entry = installed(id) else {
                return Offer(id: id, name: copy?.name ?? id, action: copy.map { .install($0) } ?? .missing)
            }
            if !entry.isEnabled { return Offer(id: id, name: entry.package.name, action: .switchOn) }
            if !entry.problems.isEmpty { return Offer(id: id, name: entry.package.name, action: .broken) }
            if let copy, copy.version > entry.package.version {
                return Offer(id: id, name: copy.name, action: .update(copy, from: entry.package.version))
            }
            let needed = keys.needed(by: entry.package).map(\.name)
            if !needed.isEmpty { return Offer(id: id, name: entry.package.name, action: .needsKeys(needed)) }
            return nil
        }
    }

    // MARK: What documents run with

    /// The extensions as a document sees them. One the document carries a copy of but
    /// that is not installed, and one that is switched off or broken, keeps its patches'
    /// ports and runs nothing.
    public func set(carrying carried: [PaperExtension] = []) -> ExtensionSet {
        _ = revision
        return ExtensionSet(
            installed.filter(\.isUsable).map(\.package),
            unavailable: installed.filter { !$0.isUsable }.map(\.package) + carried
        )
    }

    /// The patch definitions a document works with here.
    public func registry(carrying carried: [PaperExtension] = []) -> PatchRegistry {
        PatchRegistry.standard.adding(set(carrying: carried))
    }
}

/// The pictures that views of extensions draw. A drawing names one as
/// `ext:<extension id>/<path>`, and it is looked for among that extension's files only.
enum ExtensionImages {
    private static let cache = NSCache<NSString, CGImage>()

    static func image(_ name: String, in registry: PatchRegistry?) -> CGImage? {
        guard name.hasPrefix("ext:"), let registry else { return nil }
        let rest = name.dropFirst(4)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let id = String(rest[..<slash]), path = String(rest[rest.index(after: slash)...])
        guard let member = registry.extensions.member(id), member.isAvailable, let data = member.package.files[path] else { return nil }
        let key = "\(id) \(member.package.version) \(path) \(data.count)" as NSString
        if let known = cache.object(forKey: key) { return known }
        guard let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
