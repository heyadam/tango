import AppKit
import Testing
@testable import PaperEditor

@MainActor
@Suite struct ViewerCursorTests {
    @Test func touchCursorsPointAtTheirCenter() {
        for cursor in [ViewerView.touchCursor, ViewerView.pressedTouchCursor] {
            let size = cursor.image.size
            #expect(size.width == size.height)
            #expect(cursor.hotSpot == NSPoint(x: size.width / 2, y: size.height / 2))
        }
        #expect(ViewerView.touchCursor !== ViewerView.pressedTouchCursor)
    }

    @Test func viewerFollowsThePointerEvenWhenItsWindowIsNotActive() throws {
        let view = ViewerView(store: DocumentStore())
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 400)
        view.updateTrackingAreas()
        let area = try #require(view.trackingAreas.first { $0.owner === view })
        #expect(area.options.contains(.activeAlways))
        #expect(area.options.contains(.cursorUpdate))
        #expect(area.options.contains(.mouseMoved))
    }
}
