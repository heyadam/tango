import Foundation
import PaperModel
import Synchronization

/// The extensions a registry is built with. One that is installed and switched on is
/// available; one a document only carries a copy of, or that is switched off, is not: its
/// patches keep their ports, so cables stay where they are, but none of its code runs.
public struct ExtensionSet: Sendable, Hashable {
    public struct Member: Sendable, Hashable {
        public var package: PaperExtension
        public var isAvailable: Bool
    }

    public private(set) var members: [Member] = []

    public static let empty = ExtensionSet()

    /// An extension named in both lists is taken from `available`.
    public init(_ available: [PaperExtension] = [], unavailable: [PaperExtension] = []) {
        var seen: Set<String> = []
        for package in available where seen.insert(package.id).inserted {
            members.append(Member(package: package, isAvailable: true))
        }
        for package in unavailable where seen.insert(package.id).inserted {
            members.append(Member(package: package, isAvailable: false))
        }
    }

    public func member(_ id: String) -> Member? { members.first { $0.package.id == id } }

    /// The extensions whose code may run.
    public var available: [PaperExtension] { members.filter(\.isAvailable).map(\.package) }

    public var isEmpty: Bool { members.isEmpty }
}

/// A view an extension adds: what it is called, the inputs its patch has, and the script
/// that draws it.
public struct CustomViewDefinition: Sendable, Hashable, Identifiable {
    /// `<extension id>/<view id>`.
    public let kind: String
    public let name: String
    public let summary: String
    /// Its inputs, by the ids the script knows them by.
    public let inputs: [Port]
    /// The script with its `draw` function; nil for a view that cannot be drawn here.
    public let script: String?
    /// Metal code, for a view that is a packaged shader rather than a drawn one.
    public let shader: String?
    /// The size a new one starts with.
    public let size: Size2
    public let origin: PatchOrigin
    /// False when the extension is missing or switched off.
    public let isAvailable: Bool

    public var id: String { kind }

    /// A new view of this kind, at the size it starts with. A drawn view refers to the
    /// extension; a packaged shader is an ordinary shader view with the code copied in.
    public func layer(named name: String) -> Layer {
        var layer = Layer.new(shader != nil ? .shader : .custom, name: name)
        layer.set(.size, .size(size))
        if let shader {
            layer.shader = ShaderUse(source: shader)
        } else {
            layer.custom = CustomViewUse(kind: kind, inputCount: inputs.count)
        }
        return layer
    }

    /// The inputs as ports of the view's patch, under the prefix that keeps them apart
    /// from the view's own.
    public var ports: [Port] {
        inputs.map { Port(id: CustomViewUse.portID($0.id), name: $0.name, type: $0.type, defaultValue: $0.defaultValue, options: $0.options) }
    }
}

/// The components one extension ships: a shelf of the library, beside the iOS controls.
public struct ComponentShelf: Sendable, Hashable, Identifiable {
    public let name: String
    /// The extension the components come from; nil for the app's own.
    public let extensionID: String?
    public let components: [ComponentDefinition]

    public var id: String { extensionID ?? name }

    public init(name: String, extensionID: String? = nil, components: [ComponentDefinition]) {
        self.name = name
        self.extensionID = extensionID
        self.components = components
    }
}

extension PatchRegistry {
    /// This registry with the patches, views and components of `set`.
    public func adding(_ set: ExtensionSet) -> PatchRegistry {
        var copy = self
        copy.extensions = set
        copy.shelves = []
        for member in set.members {
            if member.isAvailable {
                let components = member.package.components().found
                if !components.isEmpty {
                    copy.shelves.append(ComponentShelf(name: member.package.name, extensionID: member.package.id, components: components))
                }
            }
            for definition in member.package.definitions(available: member.isAvailable) { copy.register(definition) }
            for view in member.package.views(available: member.isAvailable) {
                if copy.views[view.kind] == nil { copy.orderedViews.append(view.kind) }
                copy.views[view.kind] = view
            }
        }
        return copy
    }

    /// The view an extension adds under this kind.
    public func view(_ kind: String) -> CustomViewDefinition? { views[kind] }

    /// The extension views a person can add, in the order their extensions list them.
    public var viewLibrary: [CustomViewDefinition] {
        orderedViews.compactMap { views[$0] }.filter(\.isAvailable)
    }

    /// The extension a patch of this kind comes from, and whether it can be used.
    public func extensionMember(for kind: String) -> ExtensionSet.Member? {
        ExtensionKind.extensionID(of: kind).flatMap { extensions.member($0) }
    }
}

extension ExtensionManifest.PortItem {
    var spec: PortSpec { PortSpec(id, name ?? Script.title(id), type, defaultValue, options: options) }
    var port: Port { Port(id: id, name: name ?? Script.title(id), type: type, defaultValue: defaultValue, options: options) }
}

extension ExtensionManifest.PatchItem {
    /// The Patch Library section the patch is colored as. One that names none, or one
    /// there is not, is a Utility.
    public var patchCategory: PatchCategory {
        category.flatMap { name in ExtensionManifest.categories.first { $0.rawValue.lowercased() == name.lowercased() } } ?? .utility
    }
}

extension ExtensionManifest {
    /// The sections a patch from an extension can be filed under.
    public static let categories: [PatchCategory] = PatchCategory.allCases.filter { $0 != .component && $0 != .layer }
}

extension PaperExtension {
    public var origin: PatchOrigin { PatchOrigin(id: id, name: name) }

    /// One patch definition per patch in the manifest. An unavailable one has the ports
    /// and nothing else.
    func definitions(available: Bool) -> [PatchDefinition] {
        manifest.patches.map { patch in
            let kind = manifest.kind(of: patch)
            let ports = NodePorts(inputs: patch.inputs.map(\.port), outputs: patch.outputs.map(\.port))
            let source = available ? text(patch.script) : nil
            let origin = origin
            let name = patch.name
            return PatchDefinition(
                kind: kind, name: patch.name, category: patch.patchCategory, summary: patch.summary,
                inputs: patch.inputs.map(\.spec), outputs: patch.outputs.map(\.spec)
            ) { ctx in
                guard let source = ctx.script else { return }
                let instance = ctx.state(as: Script.Instance.self) ?? Script.Instance(source: source, ports: ports) { message, isError in
                    ExtensionLog.shared.note(message, from: name, in: origin.id, isError: isError)
                }
                ctx.state = instance
                let result = instance.step(inputs: ctx.inputs, outputs: ctx.outputs, time: ctx.time, replies: ctx.replies)
                ctx.outputs = result.outputs
                ctx.requests = result.requests
                // One that was stopped for running too long is not run again, so it must
                // not go on asking for frames either.
                ctx.wantsNextFrame = instance.interface.everyFrame && instance.interface.error == nil
            }
            .from(origin, script: source, available: available)
        }
    }

    /// The components in the extension's files, each read as it was saved, and what is
    /// wrong with those that could not be. They are data: reading them runs nothing.
    public func components() -> (found: [ComponentDefinition], problems: [String]) {
        var found: [ComponentDefinition] = []
        var problems: [String] = []
        for path in manifest.components {
            guard let data = files[path] else { continue }
            do {
                var component = try JSONDecoder().decode(ComponentDefinition.self, from: data)
                guard !found.contains(where: { $0.id == component.id }) else {
                    problems.append("\(path): another component of this extension has the same id.")
                    continue
                }
                component.library = name
                found.append(component)
            } catch {
                problems.append("\(path) is not a component that can be read.")
            }
        }
        return (found, problems)
    }

    /// One view definition per view in the manifest.
    func views(available: Bool) -> [CustomViewDefinition] {
        manifest.views.map { view in
            CustomViewDefinition(
                kind: manifest.kind(of: view), name: view.name, summary: view.summary,
                inputs: view.inputs.map(\.port),
                script: available ? view.draw.flatMap { text($0) } : nil,
                shader: available ? view.shader.flatMap { text($0) } : nil,
                size: view.size ?? Size2(width: 200, height: 200), origin: origin, isAvailable: available
            )
        }
    }

    /// What is wrong with the extension beyond its manifest: a category there is not, a
    /// script that does not load. Loading a script runs it, within the usual time limit.
    public func problems() -> [String] {
        var found: [String] = []
        for patch in manifest.patches {
            if let category = patch.category,
               !ExtensionManifest.categories.contains(where: { $0.rawValue.lowercased() == category.lowercased() }) {
                let names = ExtensionManifest.categories.map(\.rawValue).joined(separator: ", ")
                found.append("patches.\(patch.id): there is no category \"\(category)\". Use one of: \(names).")
            }
            guard let source = text(patch.script) else {
                found.append("\(patch.script) is not text.")
                continue
            }
            let ports = NodePorts(inputs: patch.inputs.map(\.port), outputs: patch.outputs.map(\.port))
            if let error = Script.Instance(source: source, ports: ports).interface.error {
                found.append("\(patch.script): \(error)")
            }
        }
        for view in manifest.views {
            if let path = view.draw {
                guard let source = text(path) else {
                    found.append("\(path) is not text.")
                    continue
                }
                if let error = DrawScript(source: source, inputs: view.inputs.map(\.port), extensionID: id, report: nil).error {
                    found.append("\(path): \(error)")
                }
            }
            if let path = view.shader {
                guard let source = text(path) else {
                    found.append("\(path) is not text.")
                    continue
                }
                if let error = ShaderSource.interface(of: source).error { found.append("\(path): \(error)") }
            }
        }
        found += components().problems
        return found
    }
}

/// What extension scripts report: where they fail, and what they log. A JavaScript patch
/// that throws is silent; an extension is someone else's code, so the person who installed
/// it, and the one writing it, can see what it said.
public final class ExtensionLog: Sendable {
    public static let shared = ExtensionLog()

    public struct Entry: Sendable, Hashable, Identifiable {
        public let id: Int
        public let extensionID: String
        /// The patch or view that said it.
        public let item: String
        public let message: String
        public let isError: Bool
        /// How many times in a row it was said.
        public var count: Int
    }

    /// The most that is kept for one extension.
    public static let limit = 100

    private struct State {
        var entries: [Entry] = []
        var next = 0
        var onChange: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())

    public init() {}

    public func note(_ message: String, from item: String, in extensionID: String, isError: Bool) {
        let changed = state.withLock { state -> (@Sendable () -> Void)? in
            if let last = state.entries.lastIndex(where: { $0.extensionID == extensionID }),
               state.entries[last].item == item, state.entries[last].message == message, state.entries[last].isError == isError {
                // A script that fails every frame says so once, with a count.
                state.entries[last].count += 1
                return state.entries[last].count == 2 ? state.onChange : nil
            }
            state.next += 1
            state.entries.append(Entry(id: state.next, extensionID: extensionID, item: item, message: String(message.prefix(500)), isError: isError, count: 1))
            let own = state.entries.indices.filter { state.entries[$0].extensionID == extensionID }
            if own.count > ExtensionLog.limit { state.entries.remove(at: own[0]) }
            return state.onChange
        }
        changed?()
    }

    public func entries(for extensionID: String) -> [Entry] {
        state.withLock { $0.entries.filter { $0.extensionID == extensionID } }
    }

    public func clear(_ extensionID: String) {
        let changed = state.withLock { state -> (@Sendable () -> Void)? in
            state.entries.removeAll { $0.extensionID == extensionID }
            return state.onChange
        }
        changed?()
    }

    /// Called, from whatever thread a script ran on, when something is added or cleared.
    public func observe(_ change: (@Sendable () -> Void)?) {
        state.withLock { $0.onChange = change }
    }
}
