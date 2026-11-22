import CoreGraphics
import Foundation
import PaperEngine
import PaperModel

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The pictures a running prototype shows, by the name a view's `image` gives: the
/// document's assets, pictures a Network Request or an AI patch brought (which live with
/// whoever runs the prototype, not in the document), photos the Camera took, and the files
/// of extensions. A renderer's `imageProvider` asks here.
public final class PictureStore {
    public init() {}

    // MARK: Decoding

    /// A picture file's bytes as a picture, or nil when they are not one.
    public nonisolated static func decode(_ data: Data) -> CGImage? {
        #if canImport(AppKit)
        return NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        return UIImage(data: data)?.cgImage
        #endif
    }

    // MARK: Finding a picture

    /// Photos the Camera patch took (`capture:N`) are kept by the device services.
    public var captured: ((String) -> CGImage?)?

    /// The picture `name` stands for, or nil.
    public func picture(named name: String, assets: [String: Data], registry: PatchRegistry?) -> CGImage? {
        // Photos taken by the Camera patch live with the host, not in the document.
        if name.hasPrefix("capture:") { return captured?(name) }
        // So do pictures a Network Request fetched or an AI patch made.
        if name.hasPrefix("fetched:") || name.hasPrefix("ai:") { return kept(named: name) }
        // A picture a view of an extension draws is one of the extension's own files.
        if let image = ExtensionImages.image(name, in: registry) { return image }
        return asset(named: name, in: assets)
    }

    // MARK: Assets

    private var decoded: [String: (data: Data, picture: CGImage?)] = [:]
    /// How many decoded assets are remembered before those the document no longer has go.
    static let mostDecoded = 256

    /// How many times an asset's bytes were made into a picture; for tests.
    private(set) var decodes = 0

    /// An asset of the document as a picture. A renderer asks on every frame it draws, so
    /// the bytes are decoded once and again only when the asset's bytes change.
    public func asset(named name: String, in assets: [String: Data]) -> CGImage? {
        guard let data = assets[name] else { return nil }
        if let known = decoded[name], known.data.count == data.count,
           Self.sameStorage(known.data, data) || known.data == data {
            return known.picture
        }
        if decoded.count >= Self.mostDecoded {
            decoded = decoded.filter { assets[$0.key] != nil }
            if decoded.count >= Self.mostDecoded { decoded.removeAll() }
        }
        decodes += 1
        let picture = Self.decode(data)
        decoded[name] = (data, picture)
        return picture
    }

    private nonisolated static func sameStorage(_ a: Data, _ b: Data) -> Bool {
        a.withUnsafeBytes { first in b.withUnsafeBytes { second in first.baseAddress == second.baseAddress } }
    }

    // MARK: Kept pictures

    private var keptPictures: [String: CGImage] = [:]
    private var keptOrder: [String] = []
    /// How many fetched and made pictures are kept; the one shown longest ago goes first.
    public static let mostKept = 64

    /// A kept picture, which now counts as just shown.
    public func kept(named name: String) -> CGImage? {
        guard let picture = keptPictures[name] else { return nil }
        if keptOrder.last != name {
            keptOrder.removeAll { $0 == name }
            keptOrder.append(name)
        }
        return picture
    }

    public func keep(_ picture: CGImage, named name: String) {
        keptPictures[name] = picture
        keptOrder.removeAll { $0 == name }
        keptOrder.append(name)
        while keptOrder.count > Self.mostKept {
            keptPictures[keptOrder.removeFirst()] = nil
        }
    }

    /// What a Network Request patch is told of an answer. One labelled a picture is kept
    /// under the name the patch's Image output gives; one labelled a picture that is not
    /// one (a broken file, an error mislabelled) reaches the patch as text, rather than as
    /// an Image naming nothing.
    public func settle(_ response: NetworkResponse, for id: UUID, keepsPicture: Bool = true) -> NetworkResponse {
        var response = response
        guard keepsPicture, response.error == nil,
              response.headers["content-type"]?.lowercased().hasPrefix("image/") == true else { return response }
        if let picture = Self.decode(response.body) {
            keep(picture, named: NetworkRequest.pictureName(for: id))
        } else {
            response.headers["content-type"] = "application/octet-stream"
        }
        return response
    }
}

/// The pictures that views of extensions draw. A drawing names one as
/// `ext:<extension id>/<path>`, and it is looked for among that extension's files only.
public enum ExtensionImages {
    private static let cache = NSCache<NSString, CGImage>()

    public static func image(_ name: String, in registry: PatchRegistry?) -> CGImage? {
        guard name.hasPrefix("ext:"), let registry else { return nil }
        let rest = name.dropFirst(4)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let id = String(rest[..<slash]), path = String(rest[rest.index(after: slash)...])
        guard let member = registry.extensions.member(id), member.isAvailable, let data = member.package.files[path] else { return nil }
        let key = "\(id) \(member.package.version) \(path) \(data.count)" as NSString
        if let known = cache.object(forKey: key) { return known }
        guard let image = PictureStore.decode(data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
