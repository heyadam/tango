import AppKit
import Foundation
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

/// Comparing motion with recordings of real SwiftUI, on clips made here: the simulator is
/// only needed to record the real ones (`REFERENCE_MOTION=1 Reference/run.sh`).
@MainActor
@Suite struct RedlineMotionTests {
    /// A frame 100 × 40 points at 1x: gray, with a dark box 20 wide whose left edge is at `x`.
    func frame(boxAt x: Double) -> Redline.Picture {
        let wide = 100, tall = 40
        var bytes = [UInt8](repeating: 255, count: wide * tall * 4)
        for row in 0..<tall {
            for column in 0..<wide {
                let inside = Double(column) + 0.5 >= x && Double(column) + 0.5 < x + 20 && row >= 10 && row < 30
                let at = (row * wide + column) * 4
                let value: UInt8 = inside ? 40 : 242
                bytes[at] = value; bytes[at + 1] = value; bytes[at + 2] = value
            }
        }
        return Redline.Picture(width: wide, height: tall, bytes: bytes, scale: 1)
    }

    /// Five frames at rest at x 10, then a move to 50 that takes `frames` frames along
    /// `curve`, then rest.
    func clip(frames: Int, curve: (Double) -> Double = { $0 }) -> Redline.Clip {
        var pictures = Array(repeating: frame(boxAt: 10), count: 5)
        for step in 1...frames { pictures.append(frame(boxAt: (10 + 40 * curve(Double(step) / Double(frames))).rounded())) }
        pictures += Array(repeating: frame(boxAt: 50), count: 30)
        return Redline.Clip(frames: pictures)
    }

    let track = ReferenceMotion.Track("Box", from: Point2(x: 1, y: 20), to: Point2(x: 99, y: 20))

    @Test func aMoveIsFoundAndMeasuredFromWhereItBegins() throws {
        let made = clip(frames: 10)
        #expect(Redline.firstChange(in: made) == 5)
        let motion = try #require(Redline.measure(made, tracks: [track], seconds: 0.6))
        #expect(motion.progress.first == 0)
        #expect(abs((motion.progress.last ?? 0) - 1) < 1e-9)
        // Progress climbs as the box goes: never back.
        #expect(zip(motion.progress, motion.progress.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 })
        // The edge along the line is the box's left edge.
        let edge = Redline.timing(of: motion, track: 0)
        #expect(edge.from == 9 && edge.to == 49)
        #expect(edge.overshoot == 0)
        // A move of ten frames at an even pace is half way about five frames after it began.
        let timing = Redline.timing(of: motion)
        let half = try #require(timing.half)
        #expect(abs(half - 4.5 / 60) < 1.5 / 60)
        #expect(timing.settled > 0.1 && timing.settled < 0.2)
        #expect(timing.overshoot == 0)
        // The same against itself differs nowhere.
        #expect(Redline.curveDifference(motion, motion, seconds: 0.5) < 1e-9)
    }

    @Test func aSlowerOneAndOneThatOvershootsAreSaid() throws {
        let real = try #require(Redline.measure(clip(frames: 10), tracks: [track], seconds: 0.8))
        let slow = try #require(Redline.measure(clip(frames: 24), tracks: [track], seconds: 0.8))
        let springy = try #require(Redline.measure(clip(frames: 16) { t in t < 0.6 ? t / 0.6 * 1.25 : 1.25 - (t - 0.6) / 0.4 * 0.25 }, tracks: [track], seconds: 0.8))
        #expect(try #require(Redline.timing(of: slow).half) > Redline.timing(of: real).half! + 0.08)
        #expect(Redline.timing(of: slow).settled > Redline.timing(of: real).settled + 0.15)
        #expect(Redline.curveDifference(real, slow, seconds: 0.6) > 0.1)
        // Past the end and back: the edge's overshoot is in points.
        #expect(Redline.timing(of: springy, track: 0).overshoot >= 9)
        // Progress does not: a box past its end is no further toward its last frame, only
        // unlike it. A move's overshoot is the tracks' to tell.
        #expect(Redline.timing(of: springy).overshoot < 0.05)
        let report = Redline.motionReport(ReferenceMotion.all[0], real, slow)
        #expect(report.contains("| Half way |"))
        #expect(report.contains("Curves differ by"))
        #expect(Redline.filmstrip(real, slow, seconds: 0.8)?.width == 9 * (100 + 8) - 8)
        #expect(Redline.curves(ReferenceMotion.all[0], real, slow) != nil)
    }

    @Test func aStillClipHasNoMotion() {
        #expect(Redline.measure(Redline.Clip(frames: Array(repeating: frame(boxAt: 10), count: 20)), seconds: 0.2) == nil)
    }

    @Test func everyMovingCaseMovesWhenTappedAndComesToRest() throws {
        #expect(Set(ReferenceMotion.all.map(\.id)).count == ReferenceMotion.all.count)
        for item in ReferenceMotion.all {
            #expect(item.region.x >= 0 && item.region.y >= 0 && item.region.x + item.region.width <= 402 && item.region.y + item.region.height <= 874, "\(item.id)")
            let made = try #require(Redline.clip(of: item), "\(item.id)")
            let motion = try #require(Redline.measure(made, tracks: item.tracks, origin: CGPoint(x: item.region.x, y: item.region.y), seconds: item.seconds), "\(item.id) does not move")
            #expect(Redline.timing(of: motion).settled < item.seconds, "\(item.id) is still moving")
            for index in item.tracks.indices {
                #expect(Redline.timing(of: motion, track: index).to != nil, "\(item.id): \(item.tracks[index].name) is not found")
            }
        }
        // The reference app has a case for each, under the same id.
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Reference/ReferenceApp.swift")
        let source = (try? String(contentsOf: app, encoding: .utf8)) ?? ""
        for item in ReferenceMotion.all { #expect(source.contains("case \"\(item.id)\""), "\(item.id) is not in the reference app") }
    }
}
