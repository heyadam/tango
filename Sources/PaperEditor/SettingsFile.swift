import Foundation

/// A small JSON file the app keeps its own settings in, such as which extensions are
/// switched on and what is known about their keys.
///
/// Reading one that is there but cannot be understood (cut short, or written by a newer
/// version) must not lose it: the next save would write an empty list over it. So such a
/// file is set aside under a name that says so, next to where it was, and the problem is
/// reported. If it cannot even be moved, saving is refused instead (`isLocked`), so it is
/// never overwritten.
nonisolated struct SettingsFile {
    let url: URL
    /// Set when a file that could not be read could not be set aside either.
    private(set) var isLocked = false

    init(_ url: URL) {
        self.url = url
    }

    enum Problem: Error, LocalizedError {
        case setAside(URL)
        case locked(String)
        case notSaved(String)

        var errorDescription: String? {
            switch self {
            case .setAside(let url): "It could not be read, so it was kept as \(url.lastPathComponent) and the app started over without it."
            case .locked(let reason): "It could not be read (\(reason)), so nothing will be saved over it until it is fixed or removed."
            case .notSaved(let reason): "The change could not be saved: \(reason)"
            }
        }
    }

    /// What is in the file: nil when there is none, or when it could not be read (`problem`
    /// then says what was done about it).
    mutating func read<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) -> (value: T?, problem: Problem?) {
        isLocked = false
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, nil) }
        do {
            return (try decoder.decode(type, from: Data(contentsOf: url)), nil)
        } catch {
            let kept = Self.setAsideURL(for: url)
            do {
                try FileManager.default.moveItem(at: url, to: kept)
                return (nil, .setAside(kept))
            } catch {
                isLocked = true
                return (nil, .locked(error.localizedDescription))
            }
        }
    }

    /// Writes `value` in place of the file, all at once. Refused while `isLocked`.
    func write<T: Encodable>(_ value: T, encoder: JSONEncoder) throws {
        if isLocked { throw Problem.locked("an earlier version of it is still there") }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            throw Problem.notSaved(error.localizedDescription)
        }
    }

    static let setAsideMark = ".unreadable-"

    /// `state.json` becomes `state.unreadable-20261118-101500.json`, numbered if that is taken.
    static func setAsideURL(for url: URL, at date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = url.deletingPathExtension().lastPathComponent + setAsideMark + formatter.string(from: date)
        let folder = url.deletingLastPathComponent()
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(url.pathExtension)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)-\(number)").appendingPathExtension(url.pathExtension)
            number += 1
        }
        return candidate
    }

    /// Whether `url` is a settings file that was set aside.
    static func isSetAside(_ url: URL) -> Bool {
        url.lastPathComponent.contains(setAsideMark) && url.pathExtension == "json"
    }
}
