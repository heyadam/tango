import AppKit
import Foundation
import Testing
import PaperEngine
import PaperHost
import PaperModel
import PaperRender
@testable import PaperEditor

/// Video views in the editor, in pictures and for agents (spec 7.7).
@MainActor
@Suite struct VideoViewTests {
    private func call(_ store: DocumentStore, _ name: String, _ input: [String: Any]) -> AssistantToolResult {
        AssistantToolbox(store: store).call(name, input: input)
    }

    private func png(_ bitmap: NSBitmapImageRep?) -> Data? { bitmap?.representation(using: .png, properties: [:]) }

    @Test func aVideoIsAddedWithItsPatchAndAVideoTimeAttachesOnlyToOne() throws {
        let store = DocumentStore()
        let id = store.addView(.video)
        let video = try #require(store.document.layer(id))
        #expect(video.type == .video)
        #expect(store.document.graph.viewNode(layer: id) != nil)
        let shown = try #require(store.document.graph.viewNode(layer: id)).shownPorts ?? ViewType.video.preset
        #expect(shown.contains("playing"))
        #expect(LibraryItem.views.contains(.view(.video)))
        #expect(DocumentStore.touchPatchKinds.contains(PatchKind.videoTime))
        #expect(DocumentStore.viewKind(for: PatchKind.videoTime) == .video)
        store.addTouchPatch(PatchKind.videoTime, for: id)
        #expect(store.document.graph.nodes.contains { $0.kind == PatchKind.videoTime && $0.layerID == id })
    }

    @Test func anAgentCanAddAVideoAndFollowIt() throws {
        let store = DocumentStore()
        let built = call(store, "edit_document", ["operations": [
            ["op": "add_view", "kind": "video", "name": "Clip", "ref": "clip", "properties": [
                "video": "Sunset.mov", "playing": false, "time": 1.5, "contentMode": "Fit",
            ]],
            ["op": "add_view", "kind": "text", "name": "Label", "ref": "label"],
            ["op": "add_patch", "kind": "videoTime", "view": "clip", "ref": "time"],
            // A Video Time only fits a video.
            ["op": "add_patch", "kind": "videoTime", "view": "label"],
        ] as [[String: Any]]])
        #expect(built.text.contains("attaches to a view of kind video"))
        let clip = try #require(store.document.screen.children.first)
        #expect(clip.kind == .video)
        #expect(clip.value(.time).numberValue == 1.5)
        #expect(clip.value(.contentMode).textValue == "Fit")
        #expect(!clip.value(.playing).boolValue)
        #expect(store.document.graph.nodes.count { $0.kind == PatchKind.videoTime } == 1)

        let reference = AssistantPrompt.reference(registry: .standard, components: [])
        for word in ["`video`", "`videoTime`", "playbackRate", "jump there"] {
            #expect(reference.contains(word), "\(word)")
        }
    }

    @Test func picturesShowTheFrameAtThePlayheadEveryTime() throws {
        let item = try #require(Gallery.item("video"))
        let package = item.package()
        #expect(package.assets[SampleDocuments.VideoScrubbing.clipName] != nil)
        // The clip ships small.
        #expect((package.assets.values.first?.count ?? .max) < 1_000_000)

        let steps: [ViewerSnapshot.Step] = [.wait(0.5), .look, .wait(1.5), .look]
        let first = ViewerSnapshot.bitmaps(of: package.document, assets: package.assets, steps: steps).map(png)
        let again = ViewerSnapshot.bitmaps(of: package.document, assets: package.assets, steps: steps).map(png)
        #expect(first.count == 2)
        #expect(first[0] != first[1])
        #expect(first == again)

        // The renderer was told how long the clip is, so the knob follows it.
        let store = DocumentStore(package: package)
        let view = ViewerView(store: store, sendsRequests: false)
        view.advance(by: 1.0 / 60)
        #expect(view.runtime.videoDuration(of: SampleDocuments.VideoScrubbing.clipName).map { abs($0 - 4) < 0.05 } == true)
    }

    @Test func aVideoWithNothingToPlayOrFromTheWebShowsAPlaceholderInPictures() {
        var screen = Layer(kind: .screen)
        var missing = Layer.new(.video, name: "Missing")
        missing.set(.video, .text("nowhere.mov"))
        var web = Layer.new(.video, name: "Web")
        web.set(.video, .text("https://example.com/clip.mp4"))
        web.set(.position, .point(Point2(x: 0, y: 200)))
        screen.children = [Layer.new(.video), missing, web]
        // Nothing is fetched, and nothing goes wrong.
        let picture = ViewerSnapshot.bitmap(of: PaperModel.Document(screen: screen))
        #expect(picture != nil)
        #expect(VideoFiles.url(for: "https://example.com/clip.mp4", assets: [:])?.host == "example.com")
        #expect(VideoFiles.url(for: "nowhere.mov", assets: [:]) == nil)
        #expect(VideoFiles.url(for: "file:///etc/hosts", assets: [:]) == nil)
    }

    @Test func theRendererOnlyPlaysInAViewerOnScreen() throws {
        let package = try #require(Gallery.item("video")).package()
        let renderer = LayerRenderer()
        #expect(!renderer.playsVideo)
        var durations: [String: Double] = [:]
        renderer.videoURL = { VideoFiles.url(for: $0, assets: package.assets) }
        renderer.onVideoDuration = { durations[$0] = $1 }
        let runtime = Runtime(document: package.document)
        runtime.tick(dt: 1.0 / 60)
        renderer.render(runtime.resolved)
        let clip = SampleDocuments.videoScrubbing().clip
        let layer = try #require(renderer.layer(for: package.document.screen.children.first { $0.kind == .video }?.id ?? clip))
        #expect(layer.sublayers?.first?.contents != nil)
        #expect(durations[SampleDocuments.VideoScrubbing.clipName] != nil)
    }
}
