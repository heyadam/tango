import Foundation

/// A document as it is stored on disk: a `.tango` package directory holding
/// `document.json`, an `assets` folder, and under `extensions` a copy of each extension
/// the document uses. The copies are for whoever opens the document without them: they
/// are offered for installing, and nothing is ever run from here.
public struct DocumentPackage: Sendable {
    public static let documentFileName = "document.json"
    public static let assetsDirectoryName = "assets"
    public static let fileExtension = "tango"
    public static let extensionsDirectoryName = "extensions"

    public var document: Document
    /// Imported files (images), keyed by file name.
    public var assets: [String: Data]
    /// The files of each extension the document carries a copy of, by extension id and
    /// then by path. Kept as they were read: a copy that cannot be made sense of is still
    /// written back unchanged.
    public var extensions: [String: [String: Data]]

    public init(document: Document = Document(), assets: [String: Data] = [:], extensions: [String: [String: Data]] = [:]) {
        self.document = document
        self.assets = assets
        self.extensions = extensions
    }

    /// The carried copies that are whole extensions, in order of id.
    public var carried: [PaperExtension] {
        extensions.keys.sorted().compactMap { id in
            guard let package = try? PaperExtension(files: extensions[id] ?? [:]), package.id == id else { return nil }
            return package
        }
    }

    public enum PackageError: Error {
        case missingDocument
    }

    public init(fileWrapper: FileWrapper) throws {
        guard let files = fileWrapper.fileWrappers,
              let data = files[DocumentPackage.documentFileName]?.regularFileContents
        else { throw PackageError.missingDocument }
        document = try Document.decode(from: data)
        assets = [:]
        if let folder = files[DocumentPackage.assetsDirectoryName]?.fileWrappers {
            for (name, wrapper) in folder {
                if let contents = wrapper.regularFileContents { assets[name] = contents }
            }
        }
        extensions = [:]
        for (id, wrapper) in files[DocumentPackage.extensionsDirectoryName]?.fileWrappers ?? [:]
        where wrapper.isDirectory && ExtensionManifest.isExtensionID(id) {
            var found: [String: Data] = [:]
            var total = 0
            func read(_ folder: FileWrapper, prefix: String) {
                for (name, child) in folder.fileWrappers ?? [:] where !name.hasPrefix(".") {
                    if child.isDirectory {
                        read(child, prefix: prefix + name + "/")
                    } else if child.isRegularFile, let contents = child.regularFileContents {
                        // A link is not followed, and a copy that is too large is cut short
                        // rather than read whole; it then fails to be an extension.
                        total += contents.count
                        guard found.count < PaperExtension.mostFiles, total <= PaperExtension.largestSize else { continue }
                        found[prefix + name] = contents
                    }
                }
            }
            read(wrapper, prefix: "")
            if !found.isEmpty { extensions[id] = found }
        }
    }

    public func fileWrapper() throws -> FileWrapper {
        let assetWrappers = assets.mapValues { FileWrapper(regularFileWithContents: $0) }
        var entries = [
            DocumentPackage.documentFileName: FileWrapper(regularFileWithContents: try document.encoded()),
            DocumentPackage.assetsDirectoryName: FileWrapper(directoryWithFileWrappers: assetWrappers),
        ]
        if !extensions.isEmpty {
            /// A folder from paths: `a/b.js` becomes a file `b.js` in a folder `a`.
            func folder(_ files: [String: Data]) -> FileWrapper {
                var here: [String: FileWrapper] = [:]
                var deeper: [String: [String: Data]] = [:]
                for (path, data) in files {
                    if let slash = path.firstIndex(of: "/") {
                        deeper[String(path[..<slash]), default: [:]][String(path[path.index(after: slash)...])] = data
                    } else {
                        here[path] = FileWrapper(regularFileWithContents: data)
                    }
                }
                for (name, inside) in deeper { here[name] = folder(inside) }
                return FileWrapper(directoryWithFileWrappers: here)
            }
            entries[DocumentPackage.extensionsDirectoryName] = FileWrapper(directoryWithFileWrappers: extensions.mapValues(folder))
        }
        return FileWrapper(directoryWithFileWrappers: entries)
    }

    public init(contentsOf url: URL) throws {
        try self.init(fileWrapper: FileWrapper(url: url, options: .immediate))
    }

    public func write(to url: URL) throws {
        try fileWrapper().write(to: url, options: .atomic, originalContentsURL: nil)
    }
}
