import Testing
import PaperModel
@testable import PaperEditor

@MainActor
struct InspectorLayoutTests {
    /// Every row names real inputs, a letter for each, and no input appears twice.
    @Test func everyRowNamesRealInputsOnce() {
        var seen: Set<String> = []
        for section in inspectorSections {
            for row in section.rows {
                #expect(row.inputs.count == row.suffixes.count, "\(section.title): \(row.inputs)")
                for id in row.inputs {
                    #expect(ViewInput(id: id) != nil, "\(id) is not an input")
                    #expect(seen.insert(id).inserted, "\(id) is in the Inspector twice")
                }
            }
        }
    }

    /// Each choice of a property shown as icons has an icon, whichever way its stack runs.
    @Test func everyChoiceShownAsIconsHasOne() {
        for axis in ["Vertical", "Horizontal"] {
            var layer = Layer.new(.stack)
            layer.set(.axis, .text(axis))
            for property in LayerProperty.allCases {
                guard let symbols = optionSymbols(for: property, in: layer) else { continue }
                #expect(Set(symbols.keys) == Set(property.options), "\(property) \(axis)")
            }
        }
    }
}
