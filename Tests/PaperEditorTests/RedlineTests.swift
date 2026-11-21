import AppKit
import Foundation
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

/// The comparison of the shelf with pictures of real SwiftUI, on pictures made here: the
/// simulator is only needed to take the real ones (`Reference/run.sh`).
@MainActor
@Suite struct RedlineTests {
    /// A picture 100 points wide at 2x, gray, with boxes of a color on it.
    func picture(_ boxes: [(CGRect, (UInt8, UInt8, UInt8))]) -> Redline.Picture {
        let wide = 200, tall = 120
        var bytes = [UInt8](repeating: 0, count: wide * tall * 4)
        for y in 0..<tall {
            for x in 0..<wide {
                var color: (UInt8, UInt8, UInt8) = (242, 242, 247)
                for (box, fill) in boxes where box.contains(CGPoint(x: Double(x) / 2 + 0.25, y: Double(y) / 2 + 0.25)) { color = fill }
                let at = (y * wide + x) * 4
                bytes[at] = color.0; bytes[at + 1] = color.1; bytes[at + 2] = color.2; bytes[at + 3] = 255
            }
        }
        return Redline.Picture(width: wide, height: tall, bytes: bytes, scale: 2)
    }

    let whole = CGRect(x: 0, y: 0, width: 100, height: 60)

    @Test func theSameThingDiffersNowhereAndASmallerOneIsMeasured() {
        let real = picture([(CGRect(x: 20, y: 10, width: 51, height: 31), (52, 199, 89))])
        let same = Redline.compare(reference: real, ours: real, region: whole)
        #expect(same.differing == 0)
        #expect(same.reference == CGRect(x: 20, y: 10, width: 51, height: 31))
        #expect(same.ours == same.reference)

        // Ours three points narrower and two lower: both are said, and the strip that differs counted.
        let ours = picture([(CGRect(x: 20, y: 12, width: 48, height: 31), (52, 199, 89))])
        let off = Redline.compare(reference: real, ours: ours, region: whole)
        #expect(off.ours == CGRect(x: 20, y: 12, width: 48, height: 31))
        #expect(off.differing > 0.03 && off.differing < 0.08)
        let report = Redline.report("Toggle", id: "toggle", off)
        #expect(report.contains("x +0.0, y +2.0, width -3.0, height +0.0"))
        // The picture has the real thing, ours, and the redline, side by side.
        #expect(off.picture?.width == 200 * 3 + 24)
        #expect(off.picture?.height == 120)
    }

    @Test func edgesAreFoundAlongTheLinesThroughTheMiddle() {
        // A track with a knob in it: its edges across are the track's and the knob's.
        let made = picture([
            (CGRect(x: 20, y: 10, width: 60, height: 28), (52, 199, 89)), (CGRect(x: 42, y: 12, width: 36, height: 24), (255, 255, 255)),
        ])
        let result = Redline.compare(reference: made, ours: made, region: whole)
        #expect(result.referenceEdges.across == [20, 42, 78, 80])
        #expect(result.referenceEdges.down == [10, 12, 36, 38])
    }

    @Test func aFaintThingIsStillContentAndOnlyTheRegionIsRead() {
        // A track two shades off the background, and something loud outside the region.
        let made = picture([(CGRect(x: 10, y: 20, width: 80, height: 4), (233, 233, 235)), (CGRect(x: 0, y: 50, width: 100, height: 10), (0, 0, 0))])
        let region = CGRect(x: 0, y: 0, width: 100, height: 45)
        #expect(Redline.content(of: made, in: region) == CGRect(x: 10, y: 20, width: 80, height: 4))
        #expect(Redline.content(of: picture([]), in: region) == nil)
    }

    @Test func everyCaseHasADocumentThatPlaysAndARegionOnTheScreen() {
        #expect(Set(ReferenceCase.all.map(\.id)).count == ReferenceCase.all.count)
        for item in ReferenceCase.all {
            let document = item.make()
            #expect(document.screen.value(.size) == .size(ReferenceCase.device), "\(item.id)")
            #expect(item.region.x >= 0 && item.region.y >= 0 && item.region.x + item.region.width <= 402 && item.region.y + item.region.height <= 874, "\(item.id)")
            let runtime = Runtime(document: document)
            runtime.advance(seconds: 1.5)
            // A spinner turns for as long as it is shown; everything else comes to rest.
            #expect(item.id == "activity" || !runtime.needsAnotherFrame, "\(item.id)")
        }
        // The reference app has a case for each, under the same id.
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Reference/ReferenceApp.swift")
        let source = (try? String(contentsOf: app, encoding: .utf8)) ?? ""
        for item in ReferenceCase.all { #expect(source.contains("case \"\(item.id)\""), "\(item.id) is not in the reference app") }
    }
}
