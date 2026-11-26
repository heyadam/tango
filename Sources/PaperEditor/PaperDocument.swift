import PaperModel
import SwiftUI
import Synchronization
import UniformTypeIdentifiers

extension UTType {
    /// A tango prototype: a package directory with `document.json` and assets.
    public nonisolated static let tango = UTType(exportedAs: "com.tango.document", conformingTo: .package)
}

/// Bridges a `DocumentStore` to SwiftUI's document system.
public nonisolated final class PaperDocument: ReferenceFileDocument {
    public static let readableContentTypes: [UTType] = [.tango]

    /// The latest contents, readable from any thread: SwiftUI takes save snapshots off the
    /// main thread.
    private let latest: Mutex<DocumentPackage>
    /// Created on first use, on the main actor.
    @MainActor public private(set) lazy var store: DocumentStore = {
        let package = latest.withLock { $0 }
        // What the document carries tells the registry about extensions that are not
        // installed here; it must be known before the store first settles the document.
        let store = DocumentStore(package: package, registry: ExtensionStore.shared.registry(carrying: package.carried))
        store.onPackageChange = { [weak self] package in
            self?.latest.withLock { $0 = package }
        }
        // Fonts and icons fetched from the web travel in the document.
        store.keepsWebAssets = true
        return store
    }()

    public init(package: DocumentPackage = DocumentPackage()) {
        latest = Mutex(package)
    }

    public init(configuration: ReadConfiguration) throws {
        latest = Mutex(try DocumentPackage(fileWrapper: configuration.file))
    }

    public func snapshot(contentType: UTType) throws -> DocumentPackage {
        latest.withLock { $0 }
    }

    public func fileWrapper(snapshot: DocumentPackage, configuration: WriteConfiguration) throws -> FileWrapper {
        try snapshot.fileWrapper()
    }
}
