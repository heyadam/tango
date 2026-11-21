import Foundation
import Observation
import PaperModel
import Security
import Synchronization

/// Where the values of keys are kept. Nothing but a value goes in: what a key is for is
/// written down beside it, in `ExtensionKeys`.
public nonisolated protocol KeyVault: Sendable {
    func value(for account: String) -> String?
    func set(_ value: String, for account: String) throws
    func remove(_ account: String) throws
}

/// The Mac's keychain: one generic password per key, in the login keychain, for this app.
///
/// The app is signed ad hoc while it is developed, and the keychain ties an item to the
/// signature of the app that made it. A build made after the key was saved is, to the
/// keychain, another app: macOS then asks before handing the key over.
public nonisolated struct KeychainVault: KeyVault {
    public static let service = "com.tango.extension-keys"
    /// Where the keys of the AI patches are kept, apart from extensions' keys.
    public static let aiService = "com.tango.ai-keys"
    public let service: String
    public let label: String

    public init(service: String = KeychainVault.service, label: String = "tango extension key") {
        self.service = service
        self.label = label
    }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func value(for account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ value: String, for account: String) throws {
        SecItemDelete(query(account) as CFDictionary)
        var item = query(account)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrLabel as String] = label
        // This Mac only: a key entered here is not carried to other devices.
        item[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyProblem(status) }
    }

    public func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeyProblem(status) }
    }
}

public struct KeyProblem: LocalizedError, Sendable {
    public let message: String
    init(_ status: OSStatus) {
        let said = SecCopyErrorMessageString(status, nil) as String?
        message = "The keychain did not take the key" + (said.map { ": \($0)" } ?? ".")
    }
    public var errorDescription: String? { message }
}

/// Keys kept in memory, for tests and for anything that must not touch the keychain.
public nonisolated final class MemoryVault: KeyVault {
    private let values = Mutex<[String: String]>([:])

    public init() {}

    public func value(for account: String) -> String? { values.withLock { $0[account] } }
    public func set(_ value: String, for account: String) throws { values.withLock { $0[account] = value } }
    public func remove(_ account: String) throws { values.withLock { $0[account] = nil } }
    public var isEmpty: Bool { values.withLock { $0.isEmpty } }
}

/// The keys people have entered for extensions: which extension's key each is and where
/// it may be sent. The values are in the vault; this is everything else, kept in a file so
/// that listing keys never opens the keychain.
///
/// A key belongs to one key of one extension, and is bound to the hosts that extension
/// declared for it when the key was entered. An extension's id is only a name: anyone can
/// make another with the same one. So if what goes by that id later declares more hosts
/// for the key than were agreed to, the key is not handed over until it is entered again.
@Observable
public final class ExtensionKeys {
    public nonisolated struct Entry: Codable, Hashable, Sendable, Identifiable {
        public var extensionID: String
        public var secretID: String
        /// The hosts the key was entered for. It is never sent to any other.
        public var hosts: [String]
        public var savedAt: Date
        /// The name the value is kept under in the vault.
        var account: String

        public var id: String { account }
    }

    /// The part that hands out values. It is read from whatever thread sends a request.
    private nonisolated final class Core: Sendable {
        let vault: any KeyVault
        let state = Mutex<(entries: [Entry], values: [String: String])>(([], [:]))

        init(vault: any KeyVault) {
            self.vault = vault
        }

        func entry(_ extensionID: String, _ secretID: String) -> Entry? {
            state.withLock { $0.entries.first { $0.extensionID == extensionID && $0.secretID == secretID } }
        }

        func value(_ extensionID: String, _ secret: ExtensionManifest.Secret) -> String? {
            guard let entry = entry(extensionID, secret.id), Set(secret.hosts).isSubset(of: entry.hosts) else { return nil }
            if let known = state.withLock({ $0.values[entry.account] }) { return known }
            // Read from the keychain once in a launch, and only when a request needs it.
            guard let value = vault.value(for: entry.account) else { return nil }
            state.withLock { $0.values[entry.account] = value }
            return value
        }
    }

    @ObservationIgnored private let core: Core
    @ObservationIgnored private var file: SettingsFile?
    public private(set) var entries: [Entry] = []
    /// What went wrong reading or saving the file, until a save succeeds.
    public private(set) var problem: String?

    /// `file` is where what is known about the keys is written; nil keeps it in memory.
    public init(vault: any KeyVault = MemoryVault(), file: URL? = nil) {
        core = Core(vault: vault)
        guard let file else { return }
        var settings = SettingsFile(file)
        let (read, problem) = settings.read([Entry].self, decoder: ExtensionKeys.decoder)
        self.file = settings
        self.problem = problem.map { "Keys: \($0.localizedDescription)" }
        if let read {
            entries = read
            core.state.withLock { $0.entries = read }
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func save() {
        core.state.withLock { $0.entries = entries }
        guard let file else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try file.write(entries, encoder: encoder)
            problem = nil
        } catch {
            problem = "Keys: \(error.localizedDescription)"
        }
    }

    // MARK: Asking

    /// What is kept for a key of an extension, whether or not it can still be used.
    public func entry(for secret: ExtensionManifest.Secret, of extensionID: String) -> Entry? {
        entries.first { $0.extensionID == extensionID && $0.secretID == secret.id }
    }

    public enum Status: Hashable, Sendable {
        case missing
        /// Entered, and bound to hosts that cover what the extension declares now.
        case saved(Date)
        /// Entered for fewer hosts than the extension now declares: it must be entered again.
        case outgrown(added: [String])
    }

    public func status(of secret: ExtensionManifest.Secret, in extensionID: String) -> Status {
        guard let entry = entry(for: secret, of: extensionID) else { return .missing }
        let added = secret.hosts.filter { !entry.hosts.contains($0) }
        return added.isEmpty ? .saved(entry.savedAt) : .outgrown(added: added)
    }

    /// The keys of an extension that a request cannot use yet.
    public func needed(by package: PaperExtension) -> [ExtensionManifest.Secret] {
        package.manifest.secrets.filter {
            if case .saved = status(of: $0, in: package.id) { return false }
            return true
        }
    }

    /// Hands a key's value to whoever sends a request, when the request's extension and
    /// the hosts it declares are the ones the key was entered for. Safe from any thread.
    public var lookup: @Sendable (_ extensionID: String, _ secret: ExtensionManifest.Secret) -> String? {
        let core = core
        return { core.value($0, $1) }
    }

    // MARK: Changing

    /// Keeps `value` as the key `secret` of an extension, for the hosts it declares now.
    public func set(_ value: String, for secret: ExtensionManifest.Secret, of extensionID: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let account = entry(for: secret, of: extensionID)?.account ?? UUID().uuidString
        try core.vault.set(trimmed, for: account)
        core.state.withLock { $0.values[account] = trimmed }
        entries.removeAll { $0.account == account }
        entries.append(Entry(extensionID: extensionID, secretID: secret.id, hosts: secret.hosts, savedAt: Date(), account: account))
        save()
    }

    public func remove(_ entry: Entry) {
        try? core.vault.remove(entry.account)
        core.state.withLock { $0.values[entry.account] = nil }
        entries.removeAll { $0.account == entry.account }
        save()
    }

    /// Removes every key of an extension, as when it is uninstalled.
    public func removeAll(of extensionID: String) {
        for entry in entries where entry.extensionID == extensionID { remove(entry) }
    }

    /// Called when a version of an extension is installed: a key the new version no longer
    /// declares, or declares more hosts for, is forgotten rather than kept for it.
    public func settle(for package: PaperExtension) {
        for entry in entries where entry.extensionID == package.id {
            guard let secret = package.manifest.secret(entry.secretID), Set(secret.hosts).isSubset(of: entry.hosts) else {
                remove(entry)
                continue
            }
        }
    }
}
