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
        let json = try (payload as NSData).decompressed(using: .zlib) as Data
        guard json.count <= largestDocument else { throw LinkError.tooLarge }
        return try Document.decode(from: json)
    }

    public static let largestDocument = 64 << 20
}

public enum LinkError: Error, Equatable {
    case tooLarge
    case invalid
}
