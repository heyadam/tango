import Foundation
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

/// The app's own small settings files are never lost by being read wrong.
@MainActor
@Suite struct SettingsFileTests {
    @Test func anUnreadableStateFileIsSetAsideNotOverwritten() throws {
        let folder = Fixture.Folder()
        let directory = folder.url.appendingPathComponent("Installed")
        let first = ExtensionStore(directory: directory)
        try first.install(try Fixture.package())
        first.setEnabled("com.example.counter", false)

        // Cut short, as by a crash mid-write or a disk that filled.
        let state = directory.appendingPathComponent("state.json")
        let original = try Data(contentsOf: state)
        try original.prefix(original.count / 2).write(to: state)

        let store = ExtensionStore(directory: directory)
        #expect(store.problem?.contains("could not be read") == true)
        let kept = try #require(store.broken.first { SettingsFile.isSetAside($0.url) })
        #expect(try Data(contentsOf: kept.url) == original.prefix(original.count / 2))
        // A change after that saves a new file and leaves the old one alone.
        store.setEnabled("com.example.counter", false)
        #expect(FileManager.default.fileExists(atPath: kept.url.path))
        #expect(ExtensionStore(directory: directory).installed.first?.isEnabled == false)
        // Removing it from the list deletes the copy.
        try store.remove(kept)
        #expect(!FileManager.default.fileExists(atPath: kept.url.path))
        #expect(!store.broken.contains { SettingsFile.isSetAside($0.url) })
    }

    @Test func anUnreadableKeysFileIsSetAside() throws {
        let folder = Fixture.Folder()
        let file = folder.url.appendingPathComponent("keys.json")
        try Data("[{\"extensionID\": 3".utf8).write(to: file)
        let keys = ExtensionKeys(file: file)
        #expect(keys.entries.isEmpty)
        #expect(keys.problem?.hasPrefix("Keys:") == true)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let kept = try FileManager.default.contentsOfDirectory(at: folder.url, includingPropertiesForKeys: nil)
        #expect(kept.contains { SettingsFile.isSetAside($0) })
    }

    @Test func aFileThatCannotBeMovedIsNeverWrittenOver() throws {
        let folder = Fixture.Folder()
        let inner = folder.url.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let file = inner.appendingPathComponent("state.json")
        try Data("not json".utf8).write(to: file)
        // A folder that cannot be written to: nothing can be moved out of it.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: inner.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inner.path) }

        var settings = SettingsFile(file)
        let (value, problem) = settings.read([String: Int].self)
        #expect(value == nil)
        guard case .locked = problem else { Issue.record("expected locked, got \(String(describing: problem))"); return }
        #expect(settings.isLocked)
        #expect(throws: SettingsFile.Problem.self) { try settings.write(["a": 1], encoder: JSONEncoder()) }
        #expect(try Data(contentsOf: file) == Data("not json".utf8))
    }

    @Test func aFailedSaveIsReportedAndClearedByTheNextGoodOne() throws {
        let folder = Fixture.Folder()
        let file = folder.url.appendingPathComponent("keys.json")
        let keys = ExtensionKeys(file: file)
        let secret = try ExtensionKeyTests.package().manifest.secrets[0]
        // A folder where the file should be: the write fails.
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        try keys.set("abc", for: secret, of: "com.example.x")
        #expect(keys.problem?.contains("could not be saved") == true)
        try FileManager.default.removeItem(at: file)
        try keys.set("abcd", for: secret, of: "com.example.x")
        #expect(keys.problem == nil)
        #expect(ExtensionKeys(file: file).entries.count == 1)
    }

    @Test func setAsideNamesNeverCollide() throws {
        let folder = Fixture.Folder()
        let url = folder.url.appendingPathComponent("state.json")
        let date = Date(timeIntervalSince1970: 0)
        let first = SettingsFile.setAsideURL(for: url, at: date)
        try Data().write(to: first)
        let second = SettingsFile.setAsideURL(for: url, at: date)
        #expect(first != second)
        #expect(SettingsFile.isSetAside(first) && SettingsFile.isSetAside(second))
        #expect(!SettingsFile.isSetAside(url))
    }
}
