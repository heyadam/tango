import Foundation
import Testing
import PaperEngine
import PaperLink
import PaperModel
@testable import PaperPlayer

@Suite struct PlayerLibraryTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tango-library-\(UUID().uuidString)", isDirectory: true)
    }

    /// The waits a library asked for, which the test lets run out when it likes.
    final class Waits {
        var work: [@MainActor () -> Void] = []

        /// Every wait runs out.
        func run() {
            let all = work
            work = []
            for item in all { item() }
        }

        /// Every wait but the newest runs out, as when something arrives mid-wait.
        func runEarlier() {
            let earlier = work.dropLast()
            work = Array(work.suffix(1))
            for item in earlier { item() }
        }
    }

    private func library(at folder: URL) -> (PlayerLibrary, run: () -> Void) {
        let (library, waits) = waiting(at: folder)
        return (library, { waits.run() })
    }

    private func waiting(at folder: URL) -> (PlayerLibrary, Waits) {
        let waits = Waits()
        return (PlayerLibrary(folder: folder) { _, work in waits.work.append(work) }, waits)
    }

    @Test func aKeptPrototypeOpensLaterUnchangedWithNoMac() throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = Gallery.item("video")!.package()
        let (library, run) = library(at: folder)
        library.received(.init(prototype: "doc", name: "Video", revision: 1), package)
        // Not yet: it waits for things to be quiet.
        #expect(library.entries.isEmpty)
        run()
        #expect(library.entries.map(\.name) == ["Video"])

        // Another launch.
        let (again, _) = self.library(at: folder)
        let entry = try #require(again.entries.first)
        let read = try #require(again.package(for: entry))
        #expect(read.document == package.document)
        #expect(read.assets == package.assets)
        #expect(FileManager.default.fileExists(atPath: again.pictureURL(entry.id).path))
    }

    @Test func aDragWritesNothingUntilItEndsAndThenWhereItEnded() throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (library, waits) = waiting(at: folder)
        let run = { waits.run() }
        var document = Gallery.item("card")!.make()
        for step in 1...40 {
            document.screen.name = "Step \(step)"
            library.received(.init(prototype: "doc", name: "Card", revision: step), DocumentPackage(document: document))
            // The waits of earlier steps run out while the drag goes on: nothing is written.
            if step % 10 == 0 {
                waits.runEarlier()
                #expect(library.entries.isEmpty)
            }
        }
        run()
        #expect(library.entries.count == 1)
        #expect(library.package(for: library.entries[0])?.document.screen.name == "Step 40")
        // Leaving the app writes what is waiting at once.
        document.screen.name = "Last"
        library.received(.init(prototype: "doc", name: "Card", revision: 41), DocumentPackage(document: document))
        library.flush()
        #expect(library.package(for: library.entries[0])?.document.screen.name == "Last")
    }

    @Test func aPreviewIsNeverKeptAndTheSameIdReplaces() throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (library, run) = library(at: folder)
        let package = Gallery.item("card")!.package()
        library.received(.init(prototype: "doc", name: "Component", revision: 1, keeps: false), package)
        run()
        #expect(library.entries.isEmpty)
        library.save(package, id: "doc", name: "First")
        library.save(package, id: "other", name: "Other")
        library.save(package, id: "doc", name: "Renamed")
        #expect(library.entries.map(\.name) == ["Renamed", "Other"])
        library.delete(library.entries[0])
        #expect(library.entries.map(\.name) == ["Other"])
        #expect(self.library(at: folder).0.entries.map(\.name) == ["Other"])
    }

    @Test func anIdFromOutsideCannotLeaveTheFolder() throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().appendingPathComponent("escaped.tango")) }
        defer { try? FileManager.default.removeItem(at: folder) }
        let (library, _) = library(at: folder)
        #expect(library.save(Gallery.item("card")!.package(), id: "../escaped", name: "Sneaky"))
        #expect(!FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().appendingPathComponent("escaped.tango").path))
        #expect(!library.save(Gallery.item("card")!.package(), id: "../..", name: "Nothing left"))
    }

    @Test func aFileIsCopiedInAndOneFromANewerTangoIsRefusedWithAReason() throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (library, _) = library(at: folder)
        let file = folder.appendingPathComponent("Incoming/Sunset Scrubber.tango")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Gallery.item("video")!.package().write(to: file)
        let entry = try #require(library.add(fileAt: file))
        #expect(entry.name == "Sunset Scrubber")
        // Opened again, the same file is the same entry.
        #expect(library.add(fileAt: file)?.id == entry.id)
        #expect(library.entries.count == 1)
        #expect(library.package(for: entry)?.assets.isEmpty == false)

        let newer = folder.appendingPathComponent("Incoming/Future.tango")
        try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)
        try Data(#"{"version": 99}"#.utf8).write(to: newer.appendingPathComponent("document.json"))
        #expect(library.add(fileAt: newer) == nil)
        #expect(library.problem?.contains("newer tango") == true)
        #expect(library.entries.count == 1)
    }
}
