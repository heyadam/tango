import Foundation
import Testing
import PaperModel
@testable import PaperEngine

@Suite struct DeviceTests {
    func press(_ runtime: Runtime, _ point: Point2) {
        runtime.send(.touchDown(point))
        runtime.tick(dt: 1 / 60)
        runtime.send(.touchUp(point))
        runtime.tick(dt: 1 / 60)
    }

    @Test func theShutterAsksForAPhotoAndGivesFeedback() {
        let example = SampleDocuments.camera()
        let runtime = Runtime(document: example.document)
        runtime.advance(seconds: 0.1)
        func layer(_ id: LayerID) -> ResolvedLayer { runtime.resolved.find(id)! }

        // The prototype says what it needs; with no camera yet, it says so on screen.
        #expect(runtime.capabilities == [.camera])
        #expect(layer(example.notice).opacity == 1)
        #expect(runtime.takeEffects().isEmpty)

        // A player with a camera reports it.
        runtime.setDevice("camera.available", .bool(true))
        runtime.advance(seconds: 0.1)
        #expect(layer(example.notice).opacity == 0)

        press(runtime, Point2(x: 195, y: 732))
        let effects = runtime.takeEffects()
        #expect(effects.contains(.capturePhoto))
        #expect(effects.contains(.sound(name: "Shutter", volume: 1)))
        #expect(effects.contains(.haptic(style: "Tap")))
        #expect(effects.count == 3)
        // The flash is at full strength and fades out on its own.
        #expect(layer(example.flash).opacity > 0.8)
        runtime.advance(seconds: 0.2)
        #expect(layer(example.flash).opacity > 0 && layer(example.flash).opacity < 0.5)
        runtime.advance(seconds: 1)
        #expect(layer(example.flash).opacity == 0)
        #expect(runtime.takeEffects().isEmpty)
        #expect(!runtime.needsAnotherFrame)

        // The photo arrives from the player and becomes the thumbnail.
        runtime.setDevice("camera.photo", .text("capture:1"))
        runtime.deviceEvent("camera.captured")
        #expect(runtime.needsAnotherFrame)
        runtime.tick(dt: 1 / 60)
        #expect(layer(example.thumbnail).value(.image) == .text("capture:1"))
        #expect(runtime.outputValue(PortRef(node: example.camera, port: "captured")) == .pulse(true))
        runtime.tick(dt: 1 / 60)
        #expect(runtime.outputValue(PortRef(node: example.camera, port: "captured")) == .pulse(false))
        runtime.advance(seconds: 0.1)
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func deviceValuesFlowIntoTheGraph() {
        let bar = Layer(name: "Meter", kind: .view)
        var b = SampleDocuments.Builder(screen: Layer(kind: .screen, children: [bar]))
        let microphone = b.add("microphone", at: .zero)
        let clock = b.add("dateTime", at: .zero)
        let info = b.add("deviceInfo", at: .zero)
        b.connect(microphone, "level", to: b.property(.opacity, of: bar.id, at: .zero), "value")
        let runtime = Runtime(document: b.document)
        runtime.tick(dt: 1 / 60)
        #expect(runtime.capabilities == [.microphone, .clock, .appearance])
        #expect(runtime.resolved.find(bar.id)!.opacity == 0)
        #expect(!runtime.needsAnotherFrame)

        runtime.setDevice("microphone.level", .number(0.6))
        runtime.setDevice("clock.time", .text("9:41"))
        runtime.setDevice("device.dark", .bool(true))
        #expect(runtime.needsAnotherFrame)
        runtime.tick(dt: 1 / 60)
        #expect(runtime.resolved.find(bar.id)!.opacity == 0.6)
        #expect(runtime.outputValue(PortRef(node: clock, port: "time")) == .text("9:41"))
        #expect(runtime.outputValue(PortRef(node: info, port: "dark")) == .bool(true))
        // The same value again changes nothing.
        runtime.tick(dt: 1 / 60)
        runtime.setDevice("microphone.level", .number(0.6))
        #expect(!runtime.needsAnotherFrame)
    }

    @Test func anImpulseJumpsAndEasesBack() {
        var graph = Graph()
        let key = graph.add(PatchNode(kind: "keyboard", inputs: ["key": .text("a")]))
        let impulse = graph.add(PatchNode(kind: "impulse", inputs: ["duration": .number(0.5)]))
        graph.connect(from: PortRef(node: key, port: "pressed"), to: PortRef(node: impulse, port: "trigger"))
        let runtime = Runtime(document: Document(graph: graph))
        runtime.tick(dt: 1 / 60)
        func value() -> Double { runtime.outputValue(PortRef(node: impulse, port: "value"))!.numberValue }
        #expect(value() == 0)
        runtime.send(.keyDown("a"))
        runtime.tick(dt: 1 / 60)
        #expect(value() == 1)
        runtime.advance(seconds: 0.25)
        #expect(value() > 0.1 && value() < 0.4)
        runtime.advance(seconds: 0.4)
        #expect(value() == 0)
        #expect(!runtime.needsAnotherFrame)
    }
}
