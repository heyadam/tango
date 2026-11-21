import Foundation
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

@MainActor
struct PatchLibraryTests {
    let everything = LibraryItem.views + PatchRegistry.standard.library.map(LibraryItem.patch)

    @Test func everyViewAndPatchInTheLibraryHasAGuide() {
        for item in everything {
            #expect(item.guide != nil, "\(item.name) has no guide")
            #expect(!(item.guide?.tags.isEmpty ?? true), "\(item.name) has no tags")
            for tag in item.tags {
                #expect(tag == tag.lowercased(), "\(item.name): tag \(tag) is not lower case")
            }
        }
    }

    /// A guide describes exactly the ports its patch has, so renaming a port shows up here.
    @Test func everyPortIsDescribedAndNoneThatIsGone() {
        for definition in PatchRegistry.standard.library {
            guard let guide = PatchGuide.patch(definition.kind) else { continue }
            #expect(Set(guide.inputs.keys) == Set(definition.inputs.map(\.id)), "\(definition.name) inputs")
            #expect(Set(guide.outputs.keys) == Set(definition.outputs.map(\.id)), "\(definition.name) outputs")
        }
        for type in LibraryItem.views.compactMap({ if case let .view(type) = $0 { type } else { nil } }) {
            for id in type.preset {
                #expect(PatchGuide.viewInputs[id] != nil, "\(type.displayName) input \(id)")
            }
        }
        #expect(Set(PatchGuide.scrollOutputs.keys) == Set(PatchRegistry.scrollOutputs.map(\.id)))
        #expect(Set(PatchGuide.frameOutputs.keys) == Set(PatchRegistry.frameOutputs.map(\.id)))
    }

    @Test func theDetailPaneListsEachPortWithItsNote() {
        let spring = LibraryItem.patch(PatchRegistry.standard.definition("spring")!)
        #expect(spring.inputs.map(\.name) == ["Target", "Response", "Damping", "Hold", "Follow"])
        #expect(spring.inputs.allSatisfy { $0.note != nil })
        #expect(spring.outputs.map(\.typeName) == ["Number", "Number", "Boolean"])

        let builder = LibraryItem.patch(PatchRegistry.standard.definition("loopBuilder")!)
        #expect(builder.inputs.map(\.name) == ["Value 0, 1, 2…"])
        #expect(builder.inputs[0].typeName == "Any")

        #expect(LibraryItem.view(.scrollView).outputs.map(\.name) == ["Offset", "Velocity", "Dragging", "X", "Y", "Width", "Height"])
        #expect(LibraryItem.view(.text).outputs.map(\.id) == ["frameX", "frameY", "frameWidth", "frameHeight"])
        #expect(LibraryItem.view(.text).inputs.map(\.id) == ["x", "y", "text"])
    }

    /// People search with the words of other tools and of code, not only our names.
    @Test func searchFindsPatchesByWhatTheyAreFor() {
        func first(_ query: String) -> String? { LibraryItem.search(query, in: everything).first?.name }
        #expect(first("spring") == "Spring Animation")
        #expect(first("toggle") == "Switch")
        #expect(first("slider") == "Drag Value")
        #expect(first("http") == "Network Request")
        #expect(first("fetch") == "Network Request")
        #expect(first("long press") == "Long Press")
        #expect(first("uipangesturerecognizer") == "Pan")
        #expect(first("twist") == "Rotation")
        #expect(first("hstack") == "Stack")
        #expect(first("lerp") == "Transition")
        #expect(first("settimeout") == "Delay")
        #expect(first("icon") == "Symbol")
        #expect(first("vibrate") == "Haptic Feedback")
        #expect(LibraryItem.search("tween", in: everything).map(\.name).contains("Easing Animation"))
        #expect(LibraryItem.search("qqqzzz", in: everything).isEmpty)
        #expect(LibraryItem.search("  ", in: everything).count == everything.count)
    }

    @Test func aNameMatchOutranksATag() {
        // "Text" is a view's name, and a tag or word in many patches.
        #expect(LibraryItem.search("text", in: everything).first?.name == "Text")
        // Every word has to match: two words narrow the results.
        let both = LibraryItem.search("json path", in: everything).map(\.name)
        #expect(both.first == "JSON Value")
        #expect(!both.contains("Parse JSON"))
    }
}
