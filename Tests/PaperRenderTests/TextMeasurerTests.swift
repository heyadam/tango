import AppKit
import CoreText
import QuartzCore
import Testing
import PaperEngine
import PaperModel

/// Text that sizes its own height shows every line when drawn as the renderer draws it.
@MainActor
@Suite struct TextMeasurerTests {
    /// The rows of ink a text layer of this size draws, counted as separate lines.
    func drawnLines(_ text: String, size: Double, width: Double, height: Double) -> Int {
        let layer = CATextLayer()
        layer.isWrapped = true
        layer.truncationMode = .none
        layer.string = text
        layer.font = NSFont.systemFont(ofSize: size)
        layer.fontSize = size
        layer.foregroundColor = .black
        layer.contentsScale = 1
        layer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let rows = Int(height) + 40
        let context = CGContext(
            data: nil, width: Int(width), height: rows, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: Double(rows)))
        context.translateBy(x: 0, y: Double(rows) - height)
        layer.render(in: context)
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        var lines = 0, last = -10
        for y in 0..<rows where (0..<Int(width)).contains(where: { pixels[y * context.bytesPerRow + $0] < 128 }) {
            if y - last > 3 { lines += 1 }
            last = y
        }
        return lines
    }

    @Test(arguments: [(16.0, 362.0), (16.0, 268.0), (14.0, 200.0), (17.0, 300.0), (28.0, 314.0)])
    func everyLineOfAutoHeightTextIsDrawn(size: Double, width: Double) {
        let text = "Imagine a place where gravity pulls so hard that nothing can escape, not even light. They form when a big star gets squished into a tiny spot. They're like invisible traps in space."
        let measured = TextMeasurer.measure(text, fontSize: size, weight: 400, maxWidth: width)
        // As many lines as there are with room to spare.
        let all = drawnLines(text, size: size, width: width, height: measured.height + 200)
        #expect(all > 1)
        #expect(drawnLines(text, size: size, width: width, height: measured.height) == all)
    }

    @Test func oneLineIsMeasuredAsBefore() {
        let measured = TextMeasurer.measure("Settings", fontSize: 17, weight: 400, maxWidth: 300)
        #expect(measured.height == 20)
    }
}
