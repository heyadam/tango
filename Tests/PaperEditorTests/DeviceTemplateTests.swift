import Foundation
import PaperEngine
import Testing
import PaperModel
@testable import PaperEditor

/// Device templates size the screen for a phone or a desktop window.
@MainActor
@Suite struct DeviceTemplateTests {
    @Test func templatesHaveTheirSizes() {
        #expect(DeviceTemplate.iPhone18Pro.size == Size2(width: 402, height: 874))
        #expect(DeviceTemplate.desktop.size == Size2(width: 1400, height: 900))
        #expect(DeviceTemplate.matching(Size2(width: 1400, height: 900)) == .desktop)
        #expect(DeviceTemplate.matching(Size2(width: 390, height: 844)) == nil)
    }

    @Test func choosingADeviceSizesTheScreenAsOneUndoStep() {
        let store = DocumentStore()
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        let before = store.document.screen.value(.size).sizeValue

        undo.beginUndoGrouping()
        store.setDevice(.desktop)
        undo.endUndoGrouping()
        #expect(store.document.screen.value(.size).sizeValue == DeviceTemplate.desktop.size)

        undo.beginUndoGrouping()
        store.setDevice(.iPhone18Pro)
        undo.endUndoGrouping()
        #expect(DeviceTemplate.matching(store.document.screen.value(.size).sizeValue) == .iPhone18Pro)

        undo.undo()
        undo.undo()
        #expect(store.document.screen.value(.size).sizeValue == before)
    }

    @Test func aNewDocumentIsSizedForTheIPhone18Pro() {
        let store = DocumentStore(package: DocumentPackage(document: .blank()))
        #expect(DeviceTemplate.matching(store.document.screen.value(.size).sizeValue) == .iPhone18Pro)
        // A document that never stored a size keeps the one it was made with.
        #expect(Document().screen.value(.size).sizeValue == Size2(width: 390, height: 844))
    }

    @Test func thePromptNamesTheDevices() {
        #expect(AssistantPrompt.reference(registry: .standard, components: []).contains("iPhone 18 Pro 402 × 874"))
    }
}
