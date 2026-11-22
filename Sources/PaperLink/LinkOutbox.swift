import Foundation
import PaperModel

/// A prototype ready to send: the update, the packed document, and its files by hash.
public struct LinkSnapshot: Sendable {
    public var update: LinkMessage.Update
    public var document: Data
    public var blobs: [String: Data]

    public init(update: LinkMessage.Update, document: Data, blobs: [String: Data]) {
        self.update = update
        self.document = document
        self.blobs = blobs
    }

    /// Makes a snapshot of a package. `hashes` remembers the hash of bytes it has seen, so
    /// a video is hashed once and not with every edit.
    public static func make(
        of package: DocumentPackage, prototype: String, name: String, revision: Int, restartToken: Int = 0,
        startScreen: String? = nil, keeps: Bool = true, hashes: inout LinkHashes
    ) throws -> LinkSnapshot {
        var update = LinkMessage.Update(
            prototype: prototype, name: name, revision: revision, restartToken: restartToken, startScreen: startScreen, keeps: keeps
        )
        var blobs: [String: Data] = [:]
        for (file, data) in package.assets {
            let hash = hashes.hash(of: data, named: "asset/\(file)")
            update.assets[file] = hash
            blobs[hash] = data
        }
        for (id, files) in package.extensions {
            for (path, data) in files {
                let hash = hashes.hash(of: data, named: "extension/\(id)/\(path)")
                update.extensions[id, default: [:]][path] = hash
                blobs[hash] = data
            }
        }
        // What could not be framed is said here, not found out by a phone that waits for it.
        // Neither one file too large for a frame, nor more together than a phone will hold.
        guard blobs.values.allSatisfy({ $0.count <= LinkFrame.largestPayload }),
              blobs.values.reduce(0, { $0 + $1.count }) <= LinkInbox.mostBytes else { throw LinkError.tooLarge }
        hashes.keep(only: Set(package.assets.keys.map { "asset/\($0)" })
            .union(package.extensions.flatMap { id, files in files.keys.map { "extension/\(id)/\($0)" } }))
        return LinkSnapshot(update: update, document: try LinkCoding.pack(package.document), blobs: blobs)
    }
}

/// The hashes of files already hashed, found again by name and by being the same bytes.
public struct LinkHashes: Sendable {
    private var known: [String: (data: Data, hash: String)] = [:]

    public init() {}

    /// How many files were hashed; for tests.
    public private(set) var hashed = 0

    public mutating func hash(of data: Data, named name: String) -> String {
        if let entry = known[name], entry.data.count == data.count, Self.sameStorage(entry.data, data) || entry.data == data {
            return entry.hash
        }
        hashed += 1
        let hash = LinkCoding.hash(data)
        known[name] = (data, hash)
        return hash
    }

    mutating func keep(only names: Set<String>) {
        known = known.filter { names.contains($0.key) }
    }

    private static func sameStorage(_ a: Data, _ b: Data) -> Bool {
        a.withUnsafeBytes { first in b.withUnsafeBytes { second in first.baseAddress == second.baseAddress } }
    }
}

/// What the Mac has for one phone: at most one update on its way, and the newest one
/// waiting behind it. A drag makes a document sixty times a second; the phone gets each
/// as fast as it shows them and never a queue of old ones.
public struct LinkOutbox: Sendable {
    /// The newest snapshot not yet sent.
    public private(set) var waiting: LinkSnapshot?
    /// The one the phone has not answered yet.
    public private(set) var inFlight: LinkSnapshot?
    /// The files of it already sent: each goes once, however often it is asked for.
    private var sent: Set<String> = []

    public init() {}

    /// A newer snapshot: it replaces whatever was waiting.
    public mutating func offer(_ snapshot: LinkSnapshot) {
        waiting = snapshot
    }

    /// The frame to send now, if the phone is ready for one.
    public mutating func next() -> LinkFrame? {
        guard inFlight == nil, let snapshot = waiting else { return nil }
        waiting = nil
        inFlight = snapshot
        sent = []
        return LinkFrame(.update(snapshot.update), payload: snapshot.document)
    }

    /// The phone answered (`applied` or `refused`) for a revision.
    public mutating func answered(revision: Int) {
        if inFlight?.update.revision == revision { inFlight = nil }
    }

    /// The files the phone asked for, of the update on its way. Hashes it made up get
    /// nothing, and one asked for again is not sent again.
    public mutating func blobs(for hashes: [String]) -> [LinkFrame] {
        var frames: [LinkFrame] = []
        for hash in hashes where !sent.contains(hash) {
            guard let data = inFlight?.blobs[hash] else { continue }
            sent.insert(hash)
            frames.append(LinkFrame(.blob(hash: hash), payload: data))
        }
        return frames
    }

    /// The Mac stopped sending this prototype: nothing of it goes out any more.
    public mutating func forget() {
        waiting = nil
        inFlight = nil
        sent = []
    }

    /// The connection was made again: what was on its way is sent again.
    public mutating func reset() {
        if let inFlight, waiting == nil { waiting = inFlight }
        inFlight = nil
        sent = []
    }
}

/// What a phone has received of an update: it is shown once every file it names is here.
public struct LinkInbox: Sendable {
    public private(set) var pending: (update: LinkMessage.Update, document: Document)?
    /// Files by hash, kept between updates so each crosses once.
    public private(set) var blobs: [String: Data] = [:]

    public init() {}

    /// An update arrived. Returns the hashes to ask for; when there are none it is ready.
    public mutating func receive(_ update: LinkMessage.Update, payload: Data) throws -> [String] {
        guard update.hasSafeNames else { throw LinkError.unsafeName }
        let document = try LinkCoding.unpack(payload)
        pending = (update, document)
        // Files no prototype names any more are let go.
        blobs = blobs.filter { update.hashes.contains($0.key) }
        return update.hashes.subtracting(blobs.keys).sorted()
    }

    /// The most a prototype's files may come to on a phone.
    public static let mostBytes = 2 << 30

    /// A file arrived. One that is not what its hash says, or that nobody asked for, is
    /// dropped. One that would make the files more than a phone should hold throws, and
    /// the update it belongs to is let go: it could never be whole, and the Mac has to be
    /// told (`refused`), or it would wait for an answer and send nothing more.
    public mutating func receive(blob data: Data, hash: String) throws {
        guard pending?.update.hashes.contains(hash) == true, blobs[hash] == nil else { return }
        guard blobs.values.reduce(data.count, { $0 + $1.count }) <= mostBytes else {
            pending = nil
            throw LinkError.tooLarge
        }
        guard LinkCoding.hash(data) == hash else { return }
        blobs[hash] = data
    }

    /// The limit in force; lower in tests.
    var mostBytes = LinkInbox.mostBytes

    /// The Mac closed a prototype: an update of it still waiting for files is let go.
    public mutating func close(prototype: String) {
        if pending?.update.prototype == prototype { pending = nil }
    }

    /// The package the pending update describes, once every file is here; taking it clears it.
    public mutating func takeReady() -> (update: LinkMessage.Update, package: DocumentPackage)? {
        guard let pending, pending.update.hashes.isSubset(of: Set(blobs.keys)) else { return nil }
        self.pending = nil
        var package = DocumentPackage(document: pending.document)
        for (file, hash) in pending.update.assets { package.assets[file] = blobs[hash] }
        for (id, files) in pending.update.extensions {
            for (path, hash) in files { package.extensions[id, default: [:]][path] = blobs[hash] }
        }
        return (pending.update, package)
    }
}
