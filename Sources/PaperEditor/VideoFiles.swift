import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Where a Video view's `video` is: a file of the document's assets, or a web address.
/// Players read files, and an asset is bytes in memory, so each one is written once to a
/// temporary folder under a name made from what is in it.
enum VideoFiles {
    /// The kinds of file a Video view can play.
    static let types: [UTType] = [.movie]

    private static var written: [String: (data: Data, url: URL)] = [:]

    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Tango Videos", isDirectory: true)
    }

    /// The file or address `source` names, or nil when it names neither.
    static func url(for source: String, assets: [String: Data]) -> URL? {
        if let data = assets[source] { return file(named: source, data: data) }
        guard let url = URL(string: source), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }

    private static func sameStorage(_ a: Data, _ b: Data) -> Bool {
        a.withUnsafeBytes { first in b.withUnsafeBytes { second in first.baseAddress == second.baseAddress } }
    }

    private static func file(named name: String, data: Data) -> URL? {
        // Asked every frame while a video plays: the same bytes in memory are known at once,
        // without comparing a whole movie.
        if let known = written[name], known.data.count == data.count,
           sameStorage(known.data, data) || known.data == data {
            written[name] = (data, known.url)
            return known.url
        }
        let digest = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        // The asset's own name keeps its extension, which tells the player what it is.
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let url = folder.appendingPathComponent("\(digest)-\(safe)")
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                return nil
            }
        }
        written[name] = (data, url)
        return url
    }
}
