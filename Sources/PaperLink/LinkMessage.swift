import Compression
import Foundation
import PaperModel

/// What the Mac and a phone say to each other over the link. Each message travels as a
/// frame (`LinkFrame`): this, as JSON, and for some a payload of bytes.
///
/// The Mac sends `update` with the whole document every time it changes; the phone asks
/// for the files it lacks (`need`), gets them (`blob`), and says `applied` once the
/// prototype shows that revision. The Mac sends the next update only then.
public enum LinkMessage: Codable, Equatable, Sendable {
    /// First from each side.
    case hello(Hello)
    /// The prototype as it is now. The payload is the document (`LinkCoding.pack`).
    case update(Update)
    /// From the phone: the files it does not have, by hash.
    case need([String])
    /// A file the phone asked for. The payload is its bytes.
    case blob(hash: String)
    /// From the phone: it shows this revision of this prototype.
    case applied(prototype: String, revision: Int)
    /// From the phone: an update it could not show, and why, in words for the person.
    case refused(prototype: String, revision: Int, reason: String)
    /// From the phone: where its prototype is.
    case status(Status)
    /// The Mac stopped sending this prototype.
    case close(prototype: String)

    public struct Hello: Codable, Equatable, Sendable {
        /// The version of this protocol. Sides that differ do not talk.
        public var link: Int
        /// The newest document version this side reads (`Document.currentVersion`).
        public var documentVersion: Int
        /// A hash of the kinds of patch and view this side knows: when the two differ, the
        /// phone's app is older or newer than the Mac's and may show a prototype wrongly.
        public var kinds: String
        /// What the person calls the device.
        public var name: String
        /// The phone's screen in points; zero from the Mac.
        public var width: Double
        public var height: Double

        public init(link: Int = LinkMessage.version, documentVersion: Int = Document.currentVersion, kinds: String, name: String, width: Double = 0, height: Double = 0) {
            self.link = link
            self.documentVersion = documentVersion
            self.kinds = kinds
            self.name = name
            self.width = width
            self.height = height
        }
    }

    public struct Update: Codable, Equatable, Sendable {
        /// Which prototype: the same for every update from one document, and for the same
        /// file opened again.
        public var prototype: String
        public var name: String
        /// Counts up with every update the Mac makes.
        public var revision: Int
        /// When it changes, the prototype starts over (on `startScreen`), as the Viewer's
        /// Restart does. It rides in every update: updates are skipped when newer ones
        /// are waiting, and a restart sent alone could be lost with one.
        public var restartToken: Int
        /// The screen to start on, as an id, or nil for the first.
        public var startScreen: String?
        /// Whether the phone should keep this prototype. Off while a component is being
        /// edited: what is sent then is a preview made for the Viewer, not the document.
        public var keeps: Bool
        /// The document's assets: file name to hash.
        public var assets: [String: String]
        /// The extensions the document carries: id, then path, to hash.
        public var extensions: [String: [String: String]]

        public init(
            prototype: String, name: String, revision: Int, restartToken: Int = 0, startScreen: String? = nil,
            keeps: Bool = true, assets: [String: String] = [:], extensions: [String: [String: String]] = [:]
        ) {
            self.prototype = prototype
            self.name = name
            self.revision = revision
            self.restartToken = restartToken
            self.startScreen = startScreen
            self.keeps = keeps
            self.assets = assets
            self.extensions = extensions
        }

        /// The most files one prototype names.
        public static let mostFiles = 4000

        /// Whether every name in it is one a file can safely be written under: an asset is
        /// a plain file name, an extension's file a path of plain names. These names come
        /// from the other side and end up on disk, so `..` and `/` must not get there.
        public var hasSafeNames: Bool {
            func plain(_ name: String) -> Bool {
                !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255
                    && !name.contains("/") && !name.contains("\\") && !name.unicodeScalars.contains { $0.value < 32 }
            }
            return assets.count + extensions.values.reduce(0) { $0 + $1.count } <= Self.mostFiles
                && assets.keys.allSatisfy(plain)
                && extensions.allSatisfy { id, files in
                    plain(id) && files.keys.allSatisfy { $0.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { plain(String($0)) } }
                }
        }

        /// Every file this update names, by hash.
        public var hashes: Set<String> {
            Set(assets.values).union(extensions.values.flatMap(\.values))
        }
    }

    public struct Status: Codable, Equatable, Sendable {
        public var prototype: String
        /// The screen the prototype is on, as an id.
        public var screen: String?

        public init(prototype: String, screen: String?) {
            self.prototype = prototype
            self.screen = screen
        }
    }

    public static let version = 1
}

/// How documents and files are put on the wire.
public enum LinkCoding {
    /// The hash a file is known by.
    public static func hash(_ data: Data) -> String {
        SHA256Digest.hex(of: data)
    }

    /// A document as a payload: compact JSON, compressed.
    public static func pack(_ document: Document) throws -> Data {
        let json = try JSONEncoder().encode(document)
        return try (json as NSData).compressed(using: .zlib) as Data
    }

    /// The document in a payload. One from a newer version of the app is refused, as a
    /// file would be (`Document.decode`). What it unpacks to is limited, so a small payload
    /// cannot ask for all the memory there is.
    public static func unpack(_ payload: Data) throws -> Document {
        try Document.decode(from: inflate(payload, limit: largestDocument))
    }

    public static let largestDocument = 64 << 20

    /// Decompresses what `pack` compressed, stopping with an error once more than `limit`
    /// bytes have come out: a few kilobytes of zeros compressed must not become gigabytes.
    static func inflate(_ data: Data, limit: Int) throws -> Data {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw LinkError.invalid
        }
        defer { compression_stream_destroy(stream) }
        let chunk = 64 << 10
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        var output = Data()
        return try data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Data in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { throw LinkError.invalid }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = source.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status != COMPRESSION_STATUS_ERROR else { throw LinkError.invalid }
                output.append(buffer, count: chunk - stream.pointee.dst_size)
                guard output.count <= limit else { throw LinkError.tooLarge }
                if status == COMPRESSION_STATUS_END { return output }
                // No more to read and nothing came out: the payload ends mid-stream.
                if stream.pointee.src_size == 0, stream.pointee.dst_size == chunk { throw LinkError.invalid }
            }
        }
    }
}

public enum LinkError: Error, Equatable {
    case tooLarge
    case invalid
    /// A file name that could leave the folder it is written in.
    case unsafeName
}
