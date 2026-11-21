import Foundation
import Testing
@testable import PaperEngine
import PaperModel

/// Documents store the ids of the library components they use and of the ports they cable,
/// so those must never change. `Tests/Fixtures/library/ids.json` holds every id that has
/// shipped; a component or port may be added to it and never altered.
///
/// After adding a component or a port, record them:
/// `TANGO_LIBRARY_IDS_OUT=1 swift test --filter LibraryIDTests`
@Suite struct LibraryIDTests {
    struct Entry: Codable, Equatable {
        var id: String
        var inputs: [String: String]
        var outputs: [String: String]
    }

    static let file = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/library/ids.json")

    static func current() -> [String: Entry] {
        var result: [String: Entry] = [:]
        for component in ComponentLibrary.iOS {
            result[component.name] = Entry(
                id: component.id.uuidString,
                inputs: Dictionary(component.inputs.map { ($0.name, $0.id) }) { first, _ in first },
                outputs: Dictionary(component.outputs.map { ($0.name, $0.id) }) { first, _ in first }
            )
        }
        return result
    }

    @Test func everyIDThatShippedIsStillTheSame() throws {
        let now = Self.current()
        let shipped = (try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: Self.file))) ?? [:]

        if ProcessInfo.processInfo.environment["TANGO_LIBRARY_IDS_OUT"] != nil {
            // Recording only ever adds: what shipped stays as it was written.
            var merged = now
            for (name, entry) in shipped {
                var kept = entry
                kept.inputs = (now[name]?.inputs ?? [:]).merging(entry.inputs) { _, old in old }
                kept.outputs = (now[name]?.outputs ?? [:]).merging(entry.outputs) { _, old in old }
                merged[name] = kept
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(merged).write(to: Self.file)
        }

        #expect(!shipped.isEmpty, "Tests/Fixtures/library/ids.json is missing")
        for (name, entry) in shipped {
            guard let component = now[name] else {
                Issue.record("\(name) left the library; documents that use it would lose it")
                continue
            }
            #expect(component.id == entry.id, "\(name) changed its id")
            for (port, id) in entry.inputs {
                #expect(component.inputs[port] == id, "\(name): input \(port) changed its id or is gone")
            }
            for (port, id) in entry.outputs {
                #expect(component.outputs[port] == id, "\(name): output \(port) changed its id or is gone")
            }
        }
        for name in now.keys where shipped[name] == nil {
            Issue.record("\(name) is not recorded; run with TANGO_LIBRARY_IDS_OUT=1")
        }
    }
}
