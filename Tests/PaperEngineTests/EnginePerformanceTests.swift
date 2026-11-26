import Foundation
import Testing
import PaperModel
@testable import PaperEngine

/// What a frame of the runtime costs while a prototype is busy: every gallery example
/// under a finger that keeps dragging. `ENGINE_PERF=1` prints microseconds a tick for each;
/// the test only holds a generous ceiling.
@Suite struct EnginePerformanceTests {
    static func microseconds(_ document: Document, frames: Int = 600) -> Double {
        let runtime = Runtime(document: document)
        let size = document.screen.value(.size).sizeValue
        runtime.advance(seconds: 0.2)
        let clock = ContinuousClock()
        var down = false
        let elapsed = clock.measure {
            for frame in 0..<frames {
                // A finger that wanders over the middle of the screen, lifting now and then.
                let t = Double(frame) / 60
                let point = Point2(x: size.width * (0.5 + 0.3 * sin(t * 2.1)), y: size.height * (0.5 + 0.3 * sin(t * 1.3)))
                if frame % 90 == 0 {
                    if down { runtime.send(.touchUp(point)) }
                    runtime.send(.touchDown(point))
                    down = true
                } else {
                    runtime.send(.touchMoved(point))
                }
                runtime.tick(dt: 1.0 / 60)
            }
        }
        return Double(elapsed.components.attoseconds) / 1e12 / Double(frames) + Double(elapsed.components.seconds) * 1e6 / Double(frames)
    }

    @Test func aBusyFrameOfEveryExampleIsCheap() {
        var total = 0.0
        var lines: [String] = []
        let environment = ProcessInfo.processInfo.environment
        // `ENGINE_PERF_ONLY=list,kit` times only those, `ENGINE_PERF_FRAMES` for longer: for a profiler.
        let only = environment["ENGINE_PERF_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        // A short run unless the numbers are wanted: a debug build is slow, and every test waits on it.
        let frames = environment["ENGINE_PERF_FRAMES"].flatMap { Int($0) } ?? (environment["ENGINE_PERF"] != nil ? 600 : 60)
        for item in Gallery.items where only?.contains(item.id) ?? true {
            let cost = Self.microseconds(item.make(), frames: frames)
            total += cost
            lines.append("\(item.id) \(Int(cost))")
        }
        if ProcessInfo.processInfo.environment["ENGINE_PERF"] != nil {
            print("ENGINE_PERF total \(Int(total)) us: " + lines.joined(separator: ", "))
        }
        // A frame at 120 a second is 8333 microseconds, and drawing wants most of it.
        #expect(total / Double(max(lines.count, 1)) < 20_000)
    }

    @Test func aMeasuredTextIsRememberedAndTheMemoryIsBounded() {
        let first = TextMeasurer.measure("Remembered words", fontSize: 17, weight: 400, maxWidth: nil)
        #expect(TextMeasurer.measure("Remembered words", fontSize: 17, weight: 400, maxWidth: nil) == first)
        // Everything the size depends on is part of what is remembered.
        #expect(TextMeasurer.measure("Remembered words", fontSize: 34, weight: 400, maxWidth: nil).width > first.width)
        #expect(TextMeasurer.measure("Remembered words", fontSize: 17, weight: 700, maxWidth: nil).width > first.width)
        #expect(TextMeasurer.measure("Remembered words", fontSize: 17, weight: 400, maxWidth: 40).height > first.height)
        #expect(TextMeasurer.measure("Remembered words!", fontSize: 17, weight: 400, maxWidth: nil).width > first.width)
        // Text that changes every frame, like a counter, never fills it for ever.
        for count in 0..<(TextMeasurer.mostKept + 200) {
            _ = TextMeasurer.measure("Count \(count)", fontSize: 12, weight: 400, maxWidth: nil)
        }
        #expect(TextMeasurer.kept <= TextMeasurer.mostKept)
        #expect(TextMeasurer.measure("Remembered words", fontSize: 17, weight: 400, maxWidth: nil) == first)
    }

    @Test func aPropertyIsTheKeyItWasWhenHashedByItsNumber() throws {
        // One byte, a different number for every case: what hashing by the case relies on.
        #expect(MemoryLayout<LayerProperty>.size == 1)
        var values: [LayerProperty: Value] = [:]
        for (index, property) in LayerProperty.allCases.enumerated() { values[property] = .number(Double(index)) }
        #expect(values.count == LayerProperty.allCases.count)
        for (index, property) in LayerProperty.allCases.enumerated() {
            #expect(values[property] == .number(Double(index)))
            #expect(LayerProperty(rawValue: property.rawValue) == property)
        }
        #expect(Set(LayerProperty.allCases).count == LayerProperty.allCases.count)
        #expect(LayerProperty.position != LayerProperty.size)
        // It is still written to a file by its name.
        let written = try JSONEncoder().encode([LayerProperty.cornerRadius: Value.number(4)])
        #expect(String(decoding: written, as: UTF8.self).contains("cornerRadius"))
        #expect(try JSONDecoder().decode([LayerProperty: Value].self, from: written) == [.cornerRadius: .number(4)])
    }
}
