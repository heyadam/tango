import Foundation
import Testing
import PaperModel
@testable import PaperEngine

/// Video views (spec 7.7): the runtime keeps the playhead, so it moves with the prototype's
/// own time and costs nothing while paused.
@Suite struct VideoTests {
    let frame = 1.0 / 60.0

    struct Setup {
        let document: Document
        let video: LayerID
        let time: NodeID
    }

    func make(_ properties: [LayerProperty: Value] = [:]) -> Setup {
        var video = Layer.new(.video, name: "Clip")
        video.set(.video, .text("clip.mov"))
        for (property, value) in properties { video.set(property, value) }
        var b = SampleDocuments.Builder(screen: Layer(kind: .screen, children: [video]))
        let time = b.attach(PatchKind.videoTime, to: video.id, at: Point2(x: 40, y: 40))
        return Setup(document: b.document, video: video.id, time: time)
    }

    func playhead(_ runtime: Runtime, _ setup: Setup) -> Playhead? { runtime.resolved.find(setup.video)?.playhead }

    func output(_ runtime: Runtime, _ setup: Setup, _ port: String) -> Value? {
        runtime.outputValue(PortRef(node: setup.time, port: port))
    }

    @Test func aVideoIsAViewOfItsOwn() throws {
        let video = Layer.new(.video)
        #expect(video.kind == .video && video.type == .video)
        #expect(video.applicable.contains(.playing) && video.applicable.contains(.time) && video.applicable.contains(.contentMode))
        #expect(video.value(.playing).boolValue && video.value(.loops).boolValue)
        #expect(video.value(.volume).numberValue == 1 && video.value(.playbackRate).numberValue == 1)
        #expect(LayerProperty.contentMode.options == ["Fill", "Fit"])
        // Every property is an input of every view patch.
        #expect(ViewInput.all.contains(ViewInput(.time)))
        let copy = try JSONDecoder().decode(Layer.self, from: try JSONEncoder().encode(video))
        #expect(copy == video)
    }

    @Test func thePlayheadMovesWithThePrototypesTime() {
        let setup = make()
        let runtime = Runtime(document: setup.document)
        runtime.setVideoDuration(4, for: "clip.mov")
        runtime.advance(seconds: 1)
        #expect(abs((playhead(runtime, setup)?.time ?? 0) - 1) < 1e-6)
        #expect(playhead(runtime, setup)?.isPlaying == true)
        #expect(runtime.needsAnotherFrame)
        // Video Time reports the frame before.
        runtime.tick(dt: frame)
        #expect(abs((output(runtime, setup, "time")?.numberValue ?? 0) - 1) < 1e-6)
        #expect(output(runtime, setup, "duration") == .number(4))
        #expect(abs((output(runtime, setup, "progress")?.numberValue ?? 0) - 0.25) < 1e-6)
        #expect(output(runtime, setup, "playing") == .bool(true))
    }

    @Test func aPausedVideoCostsNoFrames() {
        let setup = make([.playing: .bool(false), .time: .number(1.5)])
        let runtime = Runtime(document: setup.document)
        runtime.setVideoDuration(4, for: "clip.mov")
        runtime.advance(seconds: 0.1)
        #expect(playhead(runtime, setup) == Playhead(time: 1.5, isPlaying: false))
        #expect(!runtime.needsAnotherFrame)
        // A video with nothing to play does not run either.
        var empty = Layer.new(.video)
        empty.set(.playing, .bool(true))
        let idle = Runtime(document: Document(screen: Layer(kind: .screen, children: [empty])))
        idle.advance(seconds: 0.1)
        #expect(!idle.needsAnotherFrame)
    }

    @Test func aLoopingVideoStartsOverAndPulsesAtTheEnd() {
        let setup = make()
        let runtime = Runtime(document: setup.document)
        runtime.setVideoDuration(1, for: "clip.mov")
        var ended = 0
        for _ in 0..<90 {
            runtime.tick(dt: frame)
            if output(runtime, setup, "ended") == .pulse(true) { ended += 1 }
        }
        #expect(ended == 1)
        #expect(abs((playhead(runtime, setup)?.time ?? 0) - 0.5) < 1e-6)
        #expect(playhead(runtime, setup)?.isPlaying == true)
    }

    @Test func aVideoThatDoesNotLoopStopsAtTheEnd() {
        let setup = make([.loops: .bool(false)])
        let runtime = Runtime(document: setup.document)
        runtime.setVideoDuration(1, for: "clip.mov")
        var ended = 0
        for _ in 0..<90 {
            runtime.tick(dt: frame)
            if output(runtime, setup, "ended") == .pulse(true) { ended += 1 }
        }
        #expect(ended == 1)
        #expect(playhead(runtime, setup) == Playhead(time: 1, isPlaying: false))
        #expect(output(runtime, setup, "progress") == .number(1))
        #expect(output(runtime, setup, "playing") == .bool(false))
        #expect(!runtime.needsAnotherFrame)

        // Played again once it has stopped, it starts from the beginning.
        var paused = setup.document
        paused.screen.update(setup.video) { $0.set(.playing, .bool(false)) }
        runtime.update(document: paused)
        runtime.advance(seconds: 0.1)
        #expect(playhead(runtime, setup) == Playhead(time: 1, isPlaying: false))
        runtime.update(document: setup.document)
        runtime.advance(seconds: 0.25)
        #expect(abs((playhead(runtime, setup)?.time ?? 0) - 0.25) < 1e-6)
    }

    @Test func turningOnLoopsPlaysOnFromTheEnd() {
        let setup = make([.loops: .bool(false)])
        let runtime = Runtime(document: setup.document)
        runtime.setVideoDuration(1, for: "clip.mov")
        runtime.advance(seconds: 1.5)
        #expect(playhead(runtime, setup)?.isPlaying == false)
        var looping = setup.document
        looping.screen.update(setup.video) { $0.set(.loops, .bool(true)) }
        runtime.update(document: looping)
        runtime.advance(seconds: 0.25)
        #expect(playhead(runtime, setup)?.isPlaying == true)
    }

    @Test func aLengthReportedAgainAFrameApartIsTheSame() {
        let runtime = Runtime(document: make().document)
        runtime.setVideoDuration(4, for: "clip.mov")
        runtime.setVideoDuration(4.0167, for: "clip.mov")
        #expect(runtime.videoDuration(of: "clip.mov") == 4)
        runtime.setVideoDuration(6, for: "clip.mov")
        #expect(runtime.videoDuration(of: "clip.mov") == 6)
    }

    @Test func aVideoThatCannotBePlayedStandsStill() {
        let setup = make()
        let runtime = Runtime(document: setup.document)
        runtime.tick(dt: frame)
        #expect(runtime.needsAnotherFrame)
        runtime.setVideoUnplayable("clip.mov")
        runtime.tick(dt: frame)
        runtime.tick(dt: frame)
        #expect(playhead(runtime, setup)?.isPlaying == false)
        #expect(!runtime.needsAnotherFrame)
        // Its length arriving after all means it can.
        runtime.setVideoDuration(2, for: "clip.mov")
        runtime.tick(dt: frame)
        #expect(playhead(runtime, setup)?.isPlaying == true)
    }

    @Test func aChangeToTimeJumpsThere() {
        // A Value patch drives Time, as a drag would.
        var setup = make([.playing: .bool(false)])
        var document = setup.document
        let value = document.graph.add(PatchNode(kind: "value", position: .zero, inputs: ["value": .number(0)], valueType: .number))
        let view = document.graph.viewNode(layer: setup.video)!.id
        document.graph.connect(from: PortRef(node: value, port: "value"), to: PortRef(node: view, port: "time"))
        setup = Setup(document: document, video: setup.video, time: setup.time)
        let runtime = Runtime(document: document)
        runtime.setVideoDuration(4, for: "clip.mov")
        runtime.advance(seconds: 0.1)
        #expect(playhead(runtime, setup)?.time == 0)

        for seconds in [2.5, 0.75, 9.0, -3.0] {
            document.graph.update(value) { $0.inputs["value"] = .number(seconds) }
            runtime.update(document: document)
            runtime.tick(dt: frame)
            // Past either end it shows that end.
            #expect(playhead(runtime, setup)?.time == min(max(seconds, 0), 4))
        }

        // Playing again goes on from where it was put.
        document.graph.update(value) { $0.inputs["value"] = .number(2) }
        runtime.update(document: document)
        runtime.tick(dt: frame)
        document.screen.update(setup.video) { $0.set(.playing, .bool(true)) }
        runtime.update(document: document)
        runtime.advance(seconds: 0.5)
        #expect(abs((playhead(runtime, setup)?.time ?? 0) - 2.5) < 1e-6)
    }

    @Test func theRateSetsTheSpeedAndDirection() {
        let fast = make([.playbackRate: .number(2)])
        let runtime = Runtime(document: fast.document)
        runtime.setVideoDuration(10, for: "clip.mov")
        runtime.advance(seconds: 1)
        #expect(abs((playhead(runtime, fast)?.time ?? 0) - 2) < 1e-6)

        // Backwards from 1 second, round the start to the end.
        let back = make([.playbackRate: .number(-1), .time: .number(1)])
        let reverse = Runtime(document: back.document)
        reverse.setVideoDuration(4, for: "clip.mov")
        reverse.advance(seconds: 1.5)
        #expect(abs((playhead(reverse, back)?.time ?? 0) - 3.5) < 1e-6)

        // A rate of 0 holds it, and costs nothing.
        let held = make([.playbackRate: .number(0), .time: .number(1)])
        let still = Runtime(document: held.document)
        still.advance(seconds: 0.2)
        #expect(playhead(still, held) == Playhead(time: 1, isPlaying: false))
        #expect(!still.needsAnotherFrame)
    }

    @Test func untilItsLengthIsKnownAVideoPlaysOn() {
        let setup = make()
        let runtime = Runtime(document: setup.document)
        runtime.advance(seconds: 3)
        #expect(abs((playhead(runtime, setup)?.time ?? 0) - 3) < 1e-6)
        runtime.tick(dt: frame)
        #expect(output(runtime, setup, "duration") == .number(0))
        #expect(output(runtime, setup, "progress") == .number(0))
        // Told the length, it wraps into it.
        runtime.setVideoDuration(2, for: "clip.mov")
        runtime.tick(dt: frame)
        #expect((playhead(runtime, setup)?.time ?? 9) < 2)
        // Starting over starts the video over and keeps its length.
        runtime.restart()
        runtime.tick(dt: frame)
        #expect(abs((playhead(runtime, setup)?.time ?? 9) - frame) < 1e-6)
        #expect(runtime.videoDuration(of: "clip.mov") == 2)
    }

    @Test func aRepeatedVideoHasAPlayheadForEachCopy() {
        var setup = make([.playing: .bool(false)])
        var document = setup.document
        // A loop of three times into Time repeats the video three times, each at its own time.
        let loop = document.graph.add(PatchNode(kind: "loopBuilder", position: .zero, inputs: [
            "value0": .number(0.5), "value1": .number(1), "value2": .number(1.5),
        ], valueType: .number))
        let view = document.graph.viewNode(layer: setup.video)!.id
        document.graph.connect(from: PortRef(node: loop, port: "loop"), to: PortRef(node: view, port: "time"))
        setup = Setup(document: document, video: setup.video, time: setup.time)
        let runtime = Runtime(document: document)
        runtime.advance(seconds: 0.1)
        let copies = runtime.resolved.children.filter { $0.id == setup.video }
        #expect(copies.map { $0.playhead?.time } == [0.5, 1, 1.5])
        #expect(output(runtime, setup, "time").map { _ in true } == true)
    }

    @Test func theScrubbingPatternFollowsTheFinger() {
        let example = SampleDocuments.videoScrubbing()
        let runtime = Runtime(document: example.document)
        runtime.setVideoDuration(4, for: SampleDocuments.VideoScrubbing.clipName)
        runtime.advance(seconds: 1)
        func at() -> Double { runtime.resolved.find(example.clip)?.playhead?.time ?? -1 }
        func knobX() -> Double { runtime.resolved.find(example.knob)?.position.x ?? -1 }
        #expect(abs(at() - 1) < 0.05)
        let track = SampleDocuments.VideoScrubbing.track
        #expect(abs(knobX() - (track.x - 12 + track.width / 4)) < 2)

        // A finger three quarters along the bar pauses the clip at three quarters of it.
        let y = track.y + 24
        runtime.send(.touchDown(Point2(x: track.x + track.width * 0.25, y: y)))
        runtime.tick(dt: frame)
        for step in 1...10 {
            runtime.send(.touchMoved(Point2(x: track.x + track.width * (0.25 + 0.05 * Double(step)), y: y)))
            runtime.tick(dt: frame)
        }
        runtime.advance(seconds: 0.5)
        #expect(abs(at() - 3) < 0.01)
        #expect(runtime.resolved.find(example.clip)?.playhead?.isPlaying == false)
        #expect(abs(knobX() - (track.x - 12 + track.width * 0.75)) < 1)

        // Let go and it plays on from there, round to the start.
        runtime.send(.touchUp(Point2(x: track.x + track.width * 0.75, y: y)))
        runtime.advance(seconds: 1.5)
        #expect(abs(at() - 0.5) < 0.05)
    }
}
