import CoreGraphics
import Foundation
import ImageIO
import Observation
import PaperHost
import PaperLink
import PaperModel
import UniformTypeIdentifiers

/// The prototypes kept on the phone: what the Mac sent and what was opened from a file.
/// Each is a `.tango` package, as the Mac saves one, with a picture of its first screen
/// beside it, so it plays with no Mac around.
@Observable
public final class PlayerLibrary {
    public struct Entry: Identifiable, Codable, Equatable {
        /// The prototype's id on the link, or one made for a file.
        public let id: String
        public var name: String
        public var saved: Date
    }

    public private(set) var entries: [Entry] = []
    /// A problem reading or writing, in words for the person.
    public private(set) var problem: String?

    private let folder: URL
    /// Runs something later; replaced in tests so nothing waits.
    private let later: (Double, @escaping @MainActor () -> Void) -> Void
    private var waiting: [String: (name: String, package: DocumentPackage, turn: Int)] = [:]
    private var turn = 0

    /// How long after the last change a prototype is written: a drag on the Mac sends
    /// many, and only where it ends is worth keeping.
    public static let pause = 0.8

    public init(
        folder: URL = URL.applicationSupportDirectory.appendingPathComponent("Prototypes", isDirectory: true),
        later: @escaping (Double, @escaping @MainActor () -> Void) -> Void = { seconds, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { work() } }
        }
    ) {
        self.folder = folder
        self.later = later
        if let data = try? Data(contentsOf: index), let read = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = read.filter { FileManager.default.fileExists(atPath: packageURL($0.id).path) }
        }
    }

    private var index: URL { folder.appendingPathComponent("library.json") }

    /// A name for a file made from an id, which comes from outside: only what cannot
    /// leave the folder.
    private func safe(_ id: String) -> String {
        let kept = id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
        return String(String.UnicodeScalarView(kept)).prefix(80).description
    }

    private func packageURL(_ id: String) -> URL { folder.appendingPathComponent("\(safe(id)).tango", isDirectory: true) }
    public func pictureURL(_ id: String) -> URL { folder.appendingPathComponent("\(safe(id)).png") }

    // MARK: Keeping

    /// A prototype arrived from the Mac. It is written once things have been quiet for a
    /// moment; one that is not to be kept (a component's preview) is not.
    public func received(_ update: LinkMessage.Update, _ package: DocumentPackage) {
        guard update.keeps else { return }
        let id = update.prototype
        turn += 1
        let turn = turn
        waiting[id] = (update.name, package, turn)
        later(Self.pause) { [weak self] in self?.settle(id, turn: turn) }
    }

    /// Writes what waits for `id`, unless something newer arrived since `turn`: then that
    /// one's own wait decides. Writing a prototype (its videos, its picture) is work, and
    /// through a drag on the Mac none of it would be kept.
    private func settle(_ id: String, turn: Int? = nil) {
        guard let pending = waiting[id], turn == nil || pending.turn == turn else { return }
        waiting[id] = nil
        save(pending.package, id: id, name: pending.name)
    }

    /// Writes what is waiting now, as when the app goes to the background.
    public func flush() {
        for id in Array(waiting.keys) { settle(id) }
    }

    /// Keeps a prototype, replacing the one with the same id.
    @discardableResult
    public func save(_ package: DocumentPackage, id: String, name: String, at date: Date = Date()) -> Bool {
        guard !safe(id).isEmpty else { return false }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try package.write(to: packageURL(id))
            if let picture = Self.picture(of: package) { try? picture.write(to: pictureURL(id), options: .atomic) }
            entries.removeAll { $0.id == id }
            entries.insert(Entry(id: id, name: name, saved: date), at: 0)
            try JSONEncoder().encode(entries).write(to: index, options: .atomic)
            problem = nil
            return true
        } catch {
            problem = "“\(name)” could not be kept on this iPhone."
            return false
        }
    }

    /// A `.tango` file opened from Files or AirDrop: a copy is kept, under an id made from
    /// what is in it, so the same file opened again is the same entry.
    public func add(fileAt url: URL) -> Entry? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let package = read(url) else { return nil }
        let id = "file-" + String(LinkCoding.hash((try? package.document.encoded()) ?? Data(UUID().uuidString.utf8)).prefix(24))
        guard save(package, id: id, name: url.deletingPathExtension().lastPathComponent) else { return nil }
        return entries.first
    }

    // MARK: Reading

    /// The package an entry holds. One made with a newer tango cannot be read, and says so.
    public func package(for entry: Entry) -> DocumentPackage? {
        read(packageURL(entry.id), name: entry.name)
    }

    private func read(_ url: URL, name: String? = nil) -> DocumentPackage? {
        let name = name ?? url.deletingPathExtension().lastPathComponent
        do {
            let package = try DocumentPackage(contentsOf: url)
            problem = nil
            return package
        } catch Document.LoadError.unsupportedVersion {
            problem = "“\(name)” was made with a newer tango. Update this app to play it."
        } catch {
            problem = "“\(name)” could not be read."
        }
        return nil
    }

    public func delete(_ entry: Entry) {
        waiting[entry.id] = nil
        try? FileManager.default.removeItem(at: packageURL(entry.id))
        try? FileManager.default.removeItem(at: pictureURL(entry.id))
        entries.removeAll { $0.id == entry.id }
        try? JSONEncoder().encode(entries).write(to: index, options: .atomic)
    }

    // MARK: Pictures

    /// A small picture of a prototype's first frame, as a PNG. It sends nothing.
    static func picture(of package: DocumentPackage) -> Data? {
        let host = PrototypeHost(package: package, sendsRequests: false)
        let size = host.screenSize
        guard size.width >= 1, size.height >= 1, size.width <= 4096, size.height <= 4096 else { return nil }
        host.layout(in: CGRect(origin: .zero, size: size), fills: true, backingScale: 1)
        host.step(dt: 1.0 / 60)
        guard let image = host.picture(scale: min(1, 360 / size.width)) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
