import AppKit
import AVFoundation
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

@MainActor
@Suite struct RecordingTouchTests {
    private func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: NSPoint(x: x, y: y), modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    private func viewer(_ document: PaperModel.Document = PaperModel.Document()) -> ViewerView {
        let view = ViewerView(store: DocumentStore(package: DocumentPackage(document: document)))
        view.fillsWindow = true
        view.frame = NSRect(x: 0, y: 0, width: 390, height: 844)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func movie() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("touch-\(UUID().uuidString.prefix(8)).mov")
    }

    @Test func aRecordingShowsFingersWhileTheyTouchAndFadesThemOut() async throws {
        let view = viewer()
        let url = movie()
        try view.startRecording(to: url, wallClock: false, touches: true)
        #expect(view.recordedTouches(advancing: 0).isEmpty)

        // A pointer that only rests over the Viewer is not a touch.
        view.mouseMoved(with: event(.mouseMoved, 100, 300))
        #expect(view.recordedTouches(advancing: 0).isEmpty)

        view.mouseDown(with: event(.leftMouseDown, 100, 300))
        #expect(view.recordedTouches(advancing: 0) == [.init(position: CGPoint(x: 100, y: 300), opacity: 1)])
        view.mouseDragged(with: event(.leftMouseDragged, 140, 320))
        #expect(view.recordedTouches(advancing: 0).first?.position == CGPoint(x: 140, y: 320))

        view.mouseUp(with: event(.leftMouseUp, 140, 320))
        let justLifted = view.recordedTouches(advancing: ViewerView.touchLinger / 2)
        #expect(justLifted == [.init(position: CGPoint(x: 140, y: 320), opacity: 1)])
        let fading = view.recordedTouches(advancing: ViewerView.touchLinger)
        #expect(abs((fading.first?.opacity ?? 0) - 0.5) < 0.001)
        #expect(view.recordedTouches(advancing: 0).isEmpty)

        // Two fingers: both are in the picture.
        view.mouseDown(with: event(.leftMouseDown, 245, 422, .option))
        #expect(view.recordedTouches(advancing: 0).map(\.position) == [CGPoint(x: 245, y: 422), CGPoint(x: 145, y: 422)])
        view.mouseUp(with: event(.leftMouseUp, 245, 422, .option))
        #expect(view.recordedTouches(advancing: 1).count == 2)
        _ = await view.stopRecording()
        try? FileManager.default.removeItem(at: url)
    }

    @Test func touchesCanBeLeftOut() async throws {
        let view = viewer()
        let url = movie()
        try view.startRecording(to: url, wallClock: false, touches: false)
        view.mouseDown(with: event(.leftMouseDown, 100, 300))
        #expect(view.recordedTouches(advancing: 0).isEmpty)
        view.mouseUp(with: event(.leftMouseUp, 100, 300))
        #expect(view.recordedTouches(advancing: 0).isEmpty)
        _ = await view.stopRecording()
        try? FileManager.default.removeItem(at: url)

        // Out of a recording nothing lingers either.
        view.mouseDown(with: event(.leftMouseDown, 100, 300))
        view.mouseUp(with: event(.leftMouseUp, 100, 300))
        #expect(view.recordedTouches(advancing: 0).isEmpty)
    }

    /// The color in the middle of a recorded tap, a few frames in. The screen is white.
    private func tappedPixel(touches: Bool) async throws -> (red: Int, green: Int, blue: Int) {
        let view = viewer()
        let url = movie()
        defer { try? FileManager.default.removeItem(at: url) }
        try view.startRecording(to: url, wallClock: false, touches: touches)
        view.advance(by: 1.0 / 60.0)
        view.tap(at: Point2(x: 195, y: 422))
        for _ in 0..<30 { view.advance(by: 1.0 / 60.0) }
        #expect(await view.stopRecording() != nil)

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: 3.0 / 60.0, preferredTimescale: 600)).image
        let bitmap = NSBitmapImageRep(cgImage: image)
        let color = try #require(bitmap.colorAt(x: image.width / 2, y: image.height / 2)?.usingColorSpace(.sRGB))
        return (Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }

    @Test func theMovieItselfHasTheFingerInItOrNot() async throws {
        let with = try await tappedPixel(touches: true)
        let without = try await tappedPixel(touches: false)
        // White screen: untouched it stays white, touched it is greyed by the finger.
        #expect(without.red > 245 && without.green > 245 && without.blue > 245)
        #expect(with.red < 225 && with.red > 100)
    }

    @Test func touchesAreShownUnlessTheSettingSaysOtherwise() {
        let defaults = UserDefaults.standard
        let before = defaults.object(forKey: ViewerView.recordsTouchesKey)
        defer { defaults.set(before, forKey: ViewerView.recordsTouchesKey) }
        defaults.removeObject(forKey: ViewerView.recordsTouchesKey)
        #expect(ViewerView.recordsTouchesByDefault)
        defaults.set(false, forKey: ViewerView.recordsTouchesKey)
        #expect(!ViewerView.recordsTouchesByDefault)
    }
}
