import Foundation
import Security

/// The secret a Mac and the phones paired with it share. The Mac makes it once and shows
/// it as a QR code; a phone scans it once. It keys the link's TLS session, so nothing is
/// sent to, or taken from, a device that does not have it.
///
/// It is 32 random bytes and never a code short enough to type: a short code used as a TLS
/// pre-shared key can be guessed from one recorded handshake.
public struct LinkKey: Equatable, Sendable {
    public let bytes: Data

    public static let length = 32
    static let prefix = "tango-link:"

    public init?(bytes: Data) {
        guard bytes.count == Self.length else { return nil }
        self.bytes = bytes
    }

    /// A new key from the system's random numbers.
    public static func random() -> LinkKey {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        precondition(status == errSecSuccess, "No random numbers")
        return LinkKey(bytes: Data(bytes))!
    }

    /// The key as text: what the QR code holds.
    public var text: String {
        Self.prefix + bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public init?(text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(Self.prefix) else { return nil }
        var base = text.dropFirst(Self.prefix.count)
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard base.count <= 64 else { return nil }
        while base.count % 4 != 0 { base += "=" }
        guard let bytes = Data(base64Encoded: base) else { return nil }
        self.init(bytes: bytes)
    }
}

/// Where a link key is kept between launches.
public protocol LinkKeyStore: Sendable {
    func load() -> LinkKey?
    func save(_ key: LinkKey?)
    /// Whether there may be a key that could not be read just now (the keychain said no).
    /// Making a new one then would unpair every phone for nothing.
    var isUnreadable: Bool { get }
}

extension LinkKeyStore {
    public var isUnreadable: Bool { false }
}

/// The keychain, on this device only.
public struct KeychainLinkKeyStore: LinkKeyStore {
    public let service: String
    public init(service: String = "com.tango.device-link") { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "key"]
    }

    public var isUnreadable: Bool {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status != errSecSuccess && status != errSecItemNotFound
    }

    public func load() -> LinkKey? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return LinkKey(bytes: data)
    }

    public func save(_ key: LinkKey?) {
        SecItemDelete(query as CFDictionary)
        guard let key else { return }
        var item = query
        item[kSecValueData as String] = key.bytes
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = "tango device link"
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// A key kept only while the app runs; for tests.
public final class MemoryLinkKeyStore: LinkKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: LinkKey?
    public init(_ key: LinkKey? = nil) { self.key = key }
    public func load() -> LinkKey? { lock.withLock { key } }
    public func save(_ key: LinkKey?) { lock.withLock { self.key = key } }
}
