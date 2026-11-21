import Foundation

/// The kind of a patch or view that an extension adds: `<extension id>/<item id>`.
/// No built-in kind contains a slash, so the two never meet.
public enum ExtensionKind {
    public static func make(_ extensionID: String, _ item: String) -> String { "\(extensionID)/\(item)" }

    public static func split(_ kind: String) -> (extensionID: String, item: String)? {
        guard let slash = kind.firstIndex(of: "/") else { return nil }
        let id = String(kind[..<slash]), item = String(kind[kind.index(after: slash)...])
        return id.isEmpty || item.isEmpty ? nil : (id, item)
    }

    /// The extension a kind belongs to; nil for a built-in kind.
    public static func extensionID(of kind: String) -> String? { split(kind)?.extensionID }
}

/// A version such as `1.4.2`, compared number by number.
public struct ExtensionVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count) else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard piece.count <= 6, !piece.isEmpty, piece.allSatisfy(\.isASCIIDigit), let number = Int(piece) else { return nil }
            parts.append(number)
        }
        self.parts = parts
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: ExtensionVersion, b: ExtensionVersion) -> Bool {
        for index in 0..<max(a.parts.count, b.parts.count) {
            let left = index < a.parts.count ? a.parts[index] : 0
            let right = index < b.parts.count ? b.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (a: ExtensionVersion, b: ExtensionVersion) -> Bool { !(a < b) && !(b < a) }

    public func hash(into hasher: inout Hasher) {
        var trimmed = parts
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// Why an extension could not be read, in words for the person who made or installed it.
public struct ExtensionProblem: LocalizedError, Hashable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// What an extension says about itself: `extension.json`. Reading it runs nothing, so it
/// is what the app shows before anything is installed, and what stands in for the patches
/// of an extension that is missing.
public struct ExtensionManifest: Hashable, Sendable {
    public static let fileName = "extension.json"
    /// The manifest format this version of the app reads.
    public static let currentFormat = 1

    /// A port of a patch or an input of a view, declared rather than found by running code.
    public struct PortItem: Hashable, Sendable {
        public var id: String
        /// nil shows the id as words.
        public var name: String?
        public var type: PortType
        public var defaultValue: Value?
        public var options: [String]
    }

    public struct PatchItem: Hashable, Sendable {
        public var id: String
        public var name: String
        public var summary: String
        /// The name of one of the Patch Library's sections, which also colors the patch.
        public var category: String?
        /// The path of its script.
        public var script: String
        public var inputs: [PortItem]
        public var outputs: [PortItem]
    }

    public struct ViewItem: Hashable, Sendable {
        public var id: String
        public var name: String
        public var summary: String
        /// The path of a script with a `draw` function, for a view drawn in JavaScript.
        public var draw: String?
        /// The path of Metal code, for a shader view.
        public var shader: String?
        public var inputs: [PortItem]
        /// The size a new one starts with.
        public var size: Size2?
    }

    /// An API key the extension asks the person for. The extension never sees its value:
    /// the app fills it in on requests to `hosts` and nowhere else.
    public struct Secret: Hashable, Sendable {
        public var id: String
        public var name: String
        public var hosts: [String]
        /// Where to get one, shown beside the field.
        public var help: String?
    }

    public var format: Int
    public var id: String
    public var name: String
    public var version: ExtensionVersion
    public var author: String?
    public var summary: String?
    public var homepage: String?
    /// The hosts its scripts may send requests to: exact names, or `*.example.com`.
    public var network: [String]
    public var secrets: [Secret]
    public var patches: [PatchItem]
    public var views: [ViewItem]
    /// Paths of component files.
    public var components: [String]

    public func kind(of patch: PatchItem) -> String { ExtensionKind.make(id, patch.id) }
    public func kind(of view: ViewItem) -> String { ExtensionKind.make(id, view.id) }

    public func secret(_ id: String) -> Secret? { secrets.first { $0.id == id } }

    /// Whether a request to `host` is one this extension said it would make.
    public func allows(host: String) -> Bool {
        let host = host.lowercased()
        return network.contains { ExtensionManifest.host(host, matches: $0) }
    }

    static func host(_ host: String, matches pattern: String) -> Bool {
        if pattern.hasPrefix("*.") { return host.hasSuffix(String(pattern.dropFirst())) && host.count > pattern.count - 1 }
        return host == pattern
    }

    /// Names that reach this Mac itself, where plain http is allowed.
    public static func isLoopback(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
    }
}

// MARK: - Reading

extension ExtensionManifest {
    /// Reads and checks a manifest. Anything wrong is reported in one go, a line each.
    public init(data: Data) throws {
        let raw: Raw
        do {
            raw = try JSONDecoder().decode(Raw.self, from: data)
        } catch let error as DecodingError {
            throw ExtensionProblem("\(ExtensionManifest.fileName): \(ExtensionManifest.describe(error))")
        } catch {
            throw ExtensionProblem("\(ExtensionManifest.fileName) is not JSON.")
        }
        guard raw.format <= ExtensionManifest.currentFormat else {
            throw ExtensionProblem("This extension needs a newer version of tango (format \(raw.format)).")
        }
        var problems: [String] = []
        func check(_ condition: Bool, _ message: @autoclosure () -> String) {
            if !condition { problems.append(message()) }
        }

        check(raw.format >= 1, "format must be 1.")
        check(ExtensionManifest.isExtensionID(raw.id),
              "id \"\(raw.id)\" must be lowercase letters, digits, dots and hyphens, like com.example.weather.")
        check(!raw.name.trimmingCharacters(in: .whitespaces).isEmpty && raw.name.count <= 80, "name is missing or too long.")
        let version = ExtensionVersion(raw.version)
        check(version != nil, "version \"\(raw.version)\" must be numbers separated by dots, like 1.2.0.")

        let network = (raw.network ?? []).map { $0.lowercased() }
        for host in network {
            check(ExtensionManifest.isHostPattern(host), "network: \"\(host)\" is not a host name. Write a name such as api.example.com or *.example.com, with no https:// and no path.")
        }
        check(Set(network).count == network.count, "network lists a host twice.")

        var secrets: [Secret] = []
        for item in raw.secrets ?? [] {
            let hosts = item.hosts.map { $0.lowercased() }
            check(ExtensionManifest.isItemID(item.id), "secrets: id \"\(item.id)\" must be letters, digits, - and _.")
            check(!hosts.isEmpty, "secrets.\(item.id): hosts must name where the key may be sent.")
            for host in hosts {
                check(!host.contains("*"), "secrets.\(item.id): \"\(host)\" must be an exact host name; a key is never sent to a pattern.")
                check(network.contains { ExtensionManifest.host(host, matches: $0) },
                      "secrets.\(item.id): \"\(host)\" is not in network.")
                check(!ExtensionManifest.isLoopback(host), "secrets.\(item.id): a key cannot be sent to this Mac.")
            }
            secrets.append(Secret(id: item.id, name: item.name ?? item.id, hosts: hosts, help: item.help))
        }
        check(Set(secrets.map(\.id)).count == secrets.count, "secrets has the same id twice.")

        func ports(_ items: [Raw.Port]?, in place: String) -> [PortItem] {
            var seen: Set<String> = []
            return (items ?? []).map { item in
                check(ExtensionManifest.isPortID(item.id), "\(place): port id \"\(item.id)\" must be a plain name such as amount or fill_color.")
                check(seen.insert(item.id).inserted, "\(place): port \"\(item.id)\" is declared twice.")
                var value: Value?
                if let given = item.default {
                    value = Value.fromPlain(given.value, as: item.type)
                    check(value != nil, "\(place).\(item.id): the default does not fit the type \(item.type.rawValue).")
                }
                check(item.options == nil || item.type == .text, "\(place).\(item.id): only a text port can have options.")
                return PortItem(id: item.id, name: item.name, type: item.type, defaultValue: value, options: item.options ?? [])
            }
        }

        var items: Set<String> = []
        var patches: [PatchItem] = []
        for item in raw.patches ?? [] {
            check(ExtensionManifest.isItemID(item.id), "patches: id \"\(item.id)\" must be letters, digits, - and _.")
            check(items.insert(item.id).inserted, "\"\(item.id)\" is used for more than one patch or view.")
            check(ExtensionManifest.isPath(item.script), "patches.\(item.id): script \"\(item.script)\" is not a path inside the extension.")
            patches.append(PatchItem(
                id: item.id, name: item.name ?? item.id, summary: item.summary ?? "", category: item.category, script: item.script,
                inputs: ports(item.inputs, in: "patches.\(item.id).inputs"),
                outputs: ports(item.outputs, in: "patches.\(item.id).outputs")
            ))
        }
        var views: [ViewItem] = []
        for item in raw.views ?? [] {
            check(ExtensionManifest.isItemID(item.id), "views: id \"\(item.id)\" must be letters, digits, - and _.")
            check(items.insert(item.id).inserted, "\"\(item.id)\" is used for more than one patch or view.")
            check((item.draw == nil) != (item.shader == nil), "views.\(item.id): give either draw (a script) or shader (Metal code).")
            for path in [item.draw, item.shader].compactMap({ $0 }) {
                check(ExtensionManifest.isPath(path), "views.\(item.id): \"\(path)\" is not a path inside the extension.")
            }
            check(item.shader == nil || (item.inputs ?? []).isEmpty, "views.\(item.id): a shader view's inputs come from its code, not from the manifest.")
            var size: Size2?
            if let given = item.size {
                check(given.count == 2 && given.allSatisfy { $0.isFinite && $0 > 0 && $0 <= 4000 }, "views.\(item.id): size must be [width, height].")
                if given.count == 2 { size = Size2(width: given[0], height: given[1]) }
            }
            views.append(ViewItem(
                id: item.id, name: item.name ?? item.id, summary: item.summary ?? "", draw: item.draw, shader: item.shader,
                inputs: ports(item.inputs, in: "views.\(item.id).inputs"), size: size
            ))
        }
        let components = raw.components ?? []
        for path in components {
            check(ExtensionManifest.isPath(path), "components: \"\(path)\" is not a path inside the extension.")
        }

        guard problems.isEmpty, let version else {
            throw ExtensionProblem(problems.map { "\(ExtensionManifest.fileName): \($0)" }.joined(separator: "\n"))
        }
        self.init(
            format: raw.format, id: raw.id, name: raw.name, version: version, author: raw.author, summary: raw.summary,
            homepage: raw.homepage, network: network, secrets: secrets, patches: patches, views: views, components: components
        )
    }

    /// The JSON as written, before it is checked.
    private struct Raw: Decodable {
        struct Port: Decodable {
            var id: String
            var name: String?
            var type: PortType
            var `default`: Plain?
            var options: [String]?
        }
        struct Patch: Decodable {
            var id: String
            var name: String?
            var summary: String?
            var category: String?
            var script: String
            var inputs: [Port]?
            var outputs: [Port]?
        }
        struct View: Decodable {
            var id: String
            var name: String?
            var summary: String?
            var draw: String?
            var shader: String?
            var inputs: [Port]?
            var size: [Double]?
        }
        struct Secret: Decodable {
            var id: String
            var name: String?
            var hosts: [String]
            var help: String?
        }
        var format: Int
        var id: String
        var name: String
        var version: String
        var author: String?
        var summary: String?
        var homepage: String?
        var network: [String]?
        var secrets: [Secret]?
        var patches: [Patch]?
        var views: [View]?
        var components: [String]?
    }

    /// Any JSON, read as values: what a default is written as in a manifest.
    private struct Plain: Decodable {
        let value: Value
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let flag = try? container.decode(Bool.self) { value = .bool(flag) }
            else if let number = try? container.decode(Double.self) { value = .number(number) }
            else if let text = try? container.decode(String.self) { value = .text(text) }
            else if let items = try? container.decode([Plain].self) { value = .array(items.map(\.value)) }
            else if let fields = try? container.decode([String: Plain].self) { value = .object(fields.mapValues(\.value)) }
            else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a value") }
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }
            return keys.isEmpty ? "" : " at \(keys.joined(separator: "."))"
        }
        switch error {
        case let .keyNotFound(key, context): return "\"\(key.stringValue)\" is missing\(path(context))."
        case let .typeMismatch(_, context), let .valueNotFound(_, context): return "the wrong kind of value\(path(context))."
        case let .dataCorrupted(context):
            return context.codingPath.isEmpty ? "it is not JSON." : "a value that cannot be read\(path(context))."
        @unknown default: return "it could not be read."
        }
    }

    // MARK: What a name may be

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// An extension's id becomes a folder name, so it is kept to what is safe as one.
    public static func isExtensionID(_ text: String) -> Bool {
        text.count <= 100 && matches(text, #"^[a-z0-9]+([.-][a-z0-9]+)*$"#)
    }

    static func isItemID(_ text: String) -> Bool { text.count <= 64 && matches(text, #"^[A-Za-z][A-Za-z0-9_-]*$"#) }
    static func isPortID(_ text: String) -> Bool { text.count <= 64 && matches(text, #"^[A-Za-z_][A-Za-z0-9_]*$"#) }

    static func isHostPattern(_ text: String) -> Bool {
        if isLoopback(text) { return true }
        return text.count <= 253 && matches(text, #"^(\*\.)?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"#)
    }

    /// A path of plain names inside the package: nothing that climbs out of it.
    public static func isPath(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 200, !text.hasPrefix("/") else { return false }
        return text.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && !part.hasPrefix(".") && matches(String(part), #"^[A-Za-z0-9 ._@+-]+$"#)
        }
    }
}

extension Value {
    /// A value written plainly in a manifest (`20`, `"#FF0000"`, `[10, 20]`), read as the
    /// type its port has. nil when it does not fit.
    public static func fromPlain(_ plain: Value, as type: PortType) -> Value? {
        func pair(_ first: String, _ second: String) -> (Double, Double)? {
            switch plain {
            case let .array(items) where items.count == 2:
                guard case let .number(a) = items[0], case let .number(b) = items[1] else { return nil }
                return (a, b)
            case let .object(fields):
                guard case let .number(a)? = fields[first], case let .number(b)? = fields[second] else { return nil }
                return (a, b)
            default: return nil
            }
        }
        switch (type, plain) {
        case (.number, .number(let number)): return number.isFinite ? plain : nil
        case (.bool, .bool), (.text, .text), (.array, .array), (.json, .object), (.json, .array): return plain
        case (.pulse, .bool): return .pulse(false)
        case (.color, .text(let hex)): return ColorValue(hex: hex).map(Value.color)
        case (.point, _): return pair("x", "y").map { .point(Point2(x: $0.0, y: $0.1)) }
        case (.size, _): return pair("width", "height").map { .size(Size2(width: $0.0, height: $0.1)) }
        default: return nil
        }
    }
}

// MARK: - The package

/// An extension as it is on disk: its manifest and every file in its folder, by path.
public struct PaperExtension: Hashable, Sendable, Identifiable {
    public static let fileExtension = "paperextension"
    /// A package larger than this, or with more files, is refused.
    public static let largestSize = 50_000_000
    public static let mostFiles = 500

    public let manifest: ExtensionManifest
    public let files: [String: Data]

    public var id: String { manifest.id }
    public var name: String { manifest.name }
    public var version: ExtensionVersion { manifest.version }

    /// Reads an extension from its files. The paths are checked, and every file the
    /// manifest names must be there.
    public init(files: [String: Data]) throws {
        guard let data = files[ExtensionManifest.fileName] else {
            throw ExtensionProblem("There is no \(ExtensionManifest.fileName) in this folder.")
        }
        guard files.count <= PaperExtension.mostFiles else {
            throw ExtensionProblem("An extension can hold at most \(PaperExtension.mostFiles) files.")
        }
        guard files.values.reduce(0, { $0 + $1.count }) <= PaperExtension.largestSize else {
            throw ExtensionProblem("An extension can be at most \(PaperExtension.largestSize / 1_000_000) MB.")
        }
        if let bad = files.keys.sorted().first(where: { !ExtensionManifest.isPath($0) }) {
            throw ExtensionProblem("\"\(bad)\" is not a file name an extension can have.")
        }
        let manifest = try ExtensionManifest(data: data)
        var missing: [String] = []
        for path in manifest.patches.map(\.script) + manifest.views.compactMap(\.draw) + manifest.views.compactMap(\.shader) + manifest.components
        where files[path] == nil {
            missing.append("\(ExtensionManifest.fileName): \"\(path)\" is not in the extension.")
        }
        guard missing.isEmpty else { throw ExtensionProblem(missing.joined(separator: "\n")) }
        self.manifest = manifest
        self.files = files
    }

    /// Reads the folder at `url`. Hidden files are left out; a link to somewhere else is
    /// refused, since it would be copied into every document that uses the extension.
    public init(contentsOf url: URL) throws {
        var files: [String: Data] = [:]
        var total = 0
        func read(_ directory: URL, prefix: String) throws {
            let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            } catch {
                throw ExtensionProblem("\(url.lastPathComponent) is not a folder that can be read.")
            }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = prefix + child.lastPathComponent
                let info = try child.resourceValues(forKeys: Set(keys))
                if info.isSymbolicLink == true { throw ExtensionProblem("\"\(name)\" is a link. An extension holds only its own files.") }
                if info.isDirectory == true {
                    try read(child, prefix: name + "/")
                } else if info.isRegularFile == true {
                    // Its size is asked for first: a folder with one enormous file in it is
                    // refused without that file being read.
                    total += info.fileSize ?? 0
                    guard files.count < PaperExtension.mostFiles, total <= PaperExtension.largestSize else {
                        throw ExtensionProblem("This folder is too large to be an extension.")
                    }
                    files[name] = try Data(contentsOf: child)
                }
            }
        }
        try read(url, prefix: "")
        try self.init(files: files)
    }

    /// Writes the extension as a folder at `url`, replacing what is there.
    public func write(to url: URL) throws {
        let manager = FileManager.default
        let staging = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for (path, data) in files {
                let file = staging.appendingPathComponent(path)
                try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file)
            }
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
            try manager.moveItem(at: staging, to: url)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    /// The text of one of its files.
    public func text(_ path: String) -> String? { files[path].flatMap { String(data: $0, encoding: .utf8) } }
}

/// On a view an extension draws: which view of which extension, and the values of its
/// inputs. Like a shader's, the inputs are ports on the view's patch, under a prefix so
/// that one called `opacity` is not the view's own.
public struct CustomViewUse: Codable, Hashable, Sendable {
    /// `<extension id>/<view id>`.
    public var kind: String
    /// Stored values, by input id; an input that is not here has its default.
    public var inputs: [String: Value]
    /// How many inputs the view had when it was made, for finding room for its patch.
    public var inputCount: Int

    public init(kind: String, inputs: [String: Value] = [:], inputCount: Int = 0) {
        self.kind = kind
        self.inputs = inputs
        self.inputCount = inputCount
    }

    public static let portPrefix = "ext."

    /// The id of the port for the input called `name`.
    public static func portID(_ name: String) -> String { portPrefix + name }

    /// The input a port stands for; nil for a port that is not one of an extension view's.
    public static func inputName(port: String) -> String? {
        port.hasPrefix(portPrefix) ? String(port.dropFirst(portPrefix.count)) : nil
    }

    private enum CodingKeys: String, CodingKey { case kind, inputs, inputCount }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        inputs = try container.decodeIfPresent([String: Value].self, forKey: .inputs) ?? [:]
        inputCount = try container.decodeIfPresent(Int.self, forKey: .inputCount) ?? 0
    }
}

extension Document {
    /// The ids of the extensions this document needs: those whose patches and views are
    /// in it, on the screen or inside a component.
    public var usedExtensionIDs: Set<String> {
        var ids: Set<String> = []
        for graph in [graph] + components.map(\.graph) {
            for node in graph.nodes {
                if let id = ExtensionKind.extensionID(of: node.kind) { ids.insert(id) }
            }
        }
        for root in [screen] + components.map(\.root) {
            for layer in root.flattened {
                if let id = layer.custom.flatMap({ ExtensionKind.extensionID(of: $0.kind) }) { ids.insert(id) }
            }
        }
        return ids
    }
}
