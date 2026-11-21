import Foundation
import Observation

/// The documents that have a window right now, so an outside agent can find the one to
/// work on. Each `EditorView` adds its store when it appears and removes it when it goes.
@Observable
public final class OpenDocuments {
    public static let shared = OpenDocuments()

    public struct Entry: Identifiable {
        /// Short and stable while the window is open; what an agent passes as `document`.
        public let id: String
        public var name: String
        fileprivate weak var held: DocumentStore?
    }

    public struct NotFound: Error {
        public let message: String
    }

    private var entries: [Entry] = []
    /// Documents whose window went off screen but may come back, so they keep their id.
    private var away: [Entry] = []
    private var frontID: String?
    private var nextID = 1

    public init() {}

    /// Every open document, oldest window first.
    public var all: [(entry: Entry, store: DocumentStore)] {
        entries.compactMap { entry in entry.held.map { (entry, $0) } }
    }

    /// The document whose window was used last.
    public var front: (entry: Entry, store: DocumentStore)? {
        let open = all
        return open.first { $0.entry.id == frontID } ?? open.last
    }

    public func isFront(_ entry: Entry) -> Bool { front?.entry.id == entry.id }

    public func open(_ store: DocumentStore, name: String) {
        entries.removeAll { $0.held == nil }
        away.removeAll { $0.held == nil }
        if let index = entries.firstIndex(where: { $0.held === store }) {
            entries[index].name = name
        } else if let index = away.firstIndex(where: { $0.held === store }) {
            // Back on screen (a window tab brought forward again): the same document, the same id.
            var entry = away.remove(at: index)
            entry.name = name
            entries.append(entry)
        } else {
            entries.append(Entry(id: "doc\(nextID)", name: name, held: store))
            nextID += 1
        }
    }

    public func close(_ store: DocumentStore) {
        away.append(contentsOf: entries.filter { $0.held === store })
        entries.removeAll { $0.held == nil || $0.held === store }
        away.removeAll { $0.held == nil }
    }

    public func bringToFront(_ store: DocumentStore) {
        frontID = entries.first { $0.held === store }?.id
    }

    /// The document an agent means: by id, by name, or the front one when it names none.
    public func find(_ key: String?) throws -> (entry: Entry, store: DocumentStore) {
        let open = all
        guard !open.isEmpty else {
            throw NotFound(message: "No document is open in tango. Ask the person to open or create one (File > New).")
        }
        guard let key, !key.isEmpty else { return front ?? open[0] }
        if let match = open.first(where: { $0.entry.id == key }) { return match }
        let named = open.filter { $0.entry.name.compare(key, options: .caseInsensitive) == .orderedSame }
        if named.count == 1 { return named[0] }
        let names = open.map { "\($0.entry.id) (\($0.entry.name))" }.joined(separator: ", ")
        throw NotFound(message: named.isEmpty
            ? "No open document is called \"\(key)\". Open documents: \(names)."
            : "More than one open document is called \"\(key)\". Use an id: \(names).")
    }
}
