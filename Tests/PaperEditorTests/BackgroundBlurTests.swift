import AppKit
import Foundation
import Testing
import PaperEngine
import PaperModel
import PaperRender
@testable import PaperEditor

/// A view's Background Blur: what is behind the view shows through it, blurred, the same
/// in a picture with no window as in the Viewer.
@MainActor
@Suite struct BackgroundBlurTests {
    static let red = ColorValue(hex: "#FF0000")!, green = ColorValue(hex: "#00FF00")!
    static let blue = ColorValue(hex: "#0000FF")!, yellow = ColorValue(hex: "#FFFF00")!

    /// Four colored quarters on a 200 × 200 screen, with a view over the middle of them.
    func document(blur: Double, fill: ColorValue = ColorValue(white: 1, alpha: 0), inset: Double = 20, extra: [Layer] = []) -> Document {
        func quarter(_ name: String, _ x: Double, _ y: Double, _ color: ColorValue) -> Layer {
            Layer(name: name, kind: .view, properties: [
                .position: .point(Point2(x: x, y: y)), .size: .size(Size2(width: 100, height: 100)), .fill: .color(color),
            ])
        }
        let glass = Layer(name: "Glass", kind: .view, properties: [
            .position: .point(Point2(x: inset, y: inset)), .size: .size(Size2(width: 200 - inset * 2, height: 200 - inset * 2)),
            .fill: .color(fill), .backgroundBlur: .number(blur),
        ])
        return Document(screen: Layer(name: "Screen", kind: .screen, properties: [.size: .size(Size2(width: 200, height: 200))], children: [
            quarter("Top Left", 0, 0, Self.red), quarter("Top Right", 100, 0, Self.green),
            quarter("Bottom Left", 0, 100, Self.blue), quarter("Bottom Right", 100, 100, Self.yellow), glass,
        ] + extra))
    }

    /// The color at a point of the screen, y down, each part from 0 to 1.
    func color(_ document: Document, at point: Point2) -> (red: Double, green: Double, blue: Double) {
        let bitmap = ViewerSnapshot.bitmaps(of: document, steps: [.look]).first!
        let found = bitmap.colorAt(x: Int(point.x), y: Int(point.y))!.usingColorSpace(.sRGB)!
        return (found.redComponent, found.greenComponent, found.blueComponent)
    }

    @Test func whatIsBehindShowsThroughTheRightWayUp() {
        let blurred = document(blur: 6)
        // Well inside a quarter the blur finds only that quarter's color: nothing is mirrored.
        let topLeft = color(blurred, at: Point2(x: 50, y: 50)), topRight = color(blurred, at: Point2(x: 150, y: 50))
        let bottomLeft = color(blurred, at: Point2(x: 50, y: 150)), bottomRight = color(blurred, at: Point2(x: 150, y: 150))
        #expect(topLeft.red > 0.9 && topLeft.green < 0.1 && topLeft.blue < 0.1)
        #expect(topRight.green > 0.9 && topRight.red < 0.1)
        #expect(bottomLeft.blue > 0.9 && bottomLeft.red < 0.1)
        #expect(bottomRight.red > 0.9 && bottomRight.green > 0.9 && bottomRight.blue < 0.1)
        // Where two quarters meet the colors run into each other.
        let seam = color(blurred, at: Point2(x: 100, y: 50))
        #expect(seam.red > 0.1 && seam.red < 0.95 && seam.green > 0.1 && seam.green < 0.95)
        // Outside the view the edge is as sharp as it was.
        let outside = color(blurred, at: Point2(x: 96, y: 8))
        #expect(outside.red > 0.9 && outside.green < 0.1)
        // And with no blur the view changes nothing.
        let plain = color(document(blur: 0), at: Point2(x: 96, y: 50))
        #expect(plain.red > 0.9 && plain.green < 0.1)
    }

    @Test func theFillIsOverTheBlur() {
        // Half-white over red is pink, not red and not white.
        let frosted = color(document(blur: 10, fill: ColorValue(white: 1, alpha: 0.5)), at: Point2(x: 50, y: 50))
        #expect(frosted.red > 0.95)
        #expect(frosted.green > 0.4 && frosted.green < 0.6)
        #expect(frosted.blue > 0.4 && frosted.blue < 0.6)
    }

    @Test func aViewInFrontIsNotInThePictureAndOneBehindIs() {
        // A black view after the glass is over it, and is not what the glass blurs.
        let cover = Layer(name: "Cover", kind: .view, properties: [
            .position: .point(Point2(x: 120, y: 120)), .size: .size(Size2(width: 60, height: 60)), .fill: .color(.black),
        ])
        let covered = document(blur: 6, extra: [cover])
        let beside = color(covered, at: Point2(x: 60, y: 60))
        #expect(beside.red > 0.9 && beside.green < 0.1)
        let nearCover = color(covered, at: Point2(x: 112, y: 150))
        #expect(nearCover.blue > 0.3 || nearCover.red > 0.3, "the cover's black ran into the blur")
        let onCover = color(covered, at: Point2(x: 150, y: 150))
        #expect(onCover.red < 0.05 && onCover.green < 0.05 && onCover.blue < 0.05)
    }

    @Test func aViewPartlyOffTheScreenBlursWhatIsOnIt() {
        // The glass hangs off every side of the screen; what it shows is still in place.
        let wide = document(blur: 6, inset: -40)
        let topLeft = color(wide, at: Point2(x: 30, y: 30)), bottomRight = color(wide, at: Point2(x: 170, y: 170))
        #expect(topLeft.red > 0.9 && topLeft.green < 0.1)
        #expect(bottomRight.red > 0.9 && bottomRight.green > 0.9 && bottomRight.blue < 0.1)
    }

    @Test func aViewOffToOneSideBlursWhatIsUnderItThere() {
        // Only over the top right quarter, and part of the bottom right: green above, yellow below.
        var off = document(blur: 4)
        off.screen.update(off.screen.children[4].id) { glass in
            glass.set(.position, .point(Point2(x: 120, y: 30)))
            glass.set(.size, .size(Size2(width: 60, height: 140)))
        }
        let upper = color(off, at: Point2(x: 150, y: 50)), lower = color(off, at: Point2(x: 150, y: 150))
        #expect(upper.green > 0.9 && upper.red < 0.1)
        #expect(lower.red > 0.9 && lower.green > 0.9 && lower.blue < 0.1)
        let seam = color(off, at: Point2(x: 150, y: 100))
        #expect(seam.red > 0.1 && seam.red < 0.95 && seam.green > 0.9)
    }

    /// The earlier checks stand a view the same distance from the top as from the bottom,
    /// where a picture taken of the mirrored place would look right. This one does not.
    @Test func aViewNearTheTopBlursTheTopAndOneNearTheBottomTheBottom() {
        func strip(y: Double) -> Document {
            var made = document(blur: 4)
            made.screen.update(made.screen.children[4].id) { glass in
                glass.set(.position, .point(Point2(x: 10, y: y)))
                glass.set(.size, .size(Size2(width: 180, height: 40)))
            }
            return made
        }
        let top = strip(y: 20), bottom = strip(y: 140)
        let topLeft = color(top, at: Point2(x: 50, y: 40)), topRight = color(top, at: Point2(x: 150, y: 40))
        #expect(topLeft.red > 0.9 && topLeft.green < 0.1 && topLeft.blue < 0.1)
        #expect(topRight.green > 0.9 && topRight.red < 0.1)
        let bottomLeft = color(bottom, at: Point2(x: 50, y: 160)), bottomRight = color(bottom, at: Point2(x: 150, y: 160))
        #expect(bottomLeft.blue > 0.9 && bottomLeft.red < 0.1)
        #expect(bottomRight.red > 0.9 && bottomRight.green > 0.9 && bottomRight.blue < 0.1)
        // The same with room around the screen, as a picture with a margin has.
        let framed = ViewerSnapshot.bitmaps(of: top, steps: [.look], margin: 16).first!
        let found = framed.colorAt(x: 16 + 50, y: 16 + 40)!.usingColorSpace(.sRGB)!
        #expect(found.redComponent > 0.9 && found.greenComponent < 0.1 && found.blueComponent < 0.1)
    }

    // MARK: A shader that reads what is behind it

    /// The quarters with a shader view over part of them.
    func shaded(_ source: String, x: Double = 10, y: Double, width: Double = 180, height: Double = 40) -> Document {
        var made = document(blur: 0)
        made.screen.update(made.screen.children[4].id) { glass in
            glass.set(.position, .point(Point2(x: x, y: y)))
            glass.set(.size, .size(Size2(width: width, height: height)))
            glass.shader = ShaderUse(source: source)
        }
        return made
    }

    @Test func aShaderSeesWhatIsBehindItsViewWhereItIs() throws {
        try #require(ShaderCompiler.shared != nil, "no GPU to compile with")
        let through = "float4 shader(Frame frame, Inputs in) { return behind(frame, frame.position); }"
        #expect(ShaderSource.interface(of: through).readsBehind)
        #expect(!ShaderSource.interface(of: "float4 shader(Frame frame, Inputs in) { return content(frame, frame.position); }").readsBehind)
        #expect(ShaderCompiler.error(in: through) == nil)
        // A view that shows what is behind it, untouched, cannot be told from no view: near
        // the top it is red and green, near the bottom blue and yellow, and the seams stay sharp.
        let top = shaded(through, y: 20), bottom = shaded(through, y: 140)
        let topLeft = color(top, at: Point2(x: 50, y: 40)), topRight = color(top, at: Point2(x: 150, y: 40))
        #expect(topLeft.red > 0.95 && topLeft.green < 0.05 && topLeft.blue < 0.05)
        #expect(topRight.green > 0.95 && topRight.red < 0.05)
        let bottomLeft = color(bottom, at: Point2(x: 50, y: 160)), bottomRight = color(bottom, at: Point2(x: 150, y: 160))
        #expect(bottomLeft.blue > 0.95 && bottomLeft.red < 0.05)
        #expect(bottomRight.red > 0.95 && bottomRight.green > 0.95 && bottomRight.blue < 0.05)
        let seamLeft = color(top, at: Point2(x: 96, y: 40)), seamRight = color(top, at: Point2(x: 104, y: 40))
        #expect(seamLeft.red > 0.95 && seamLeft.green < 0.05)
        #expect(seamRight.green > 0.95 && seamRight.red < 0.05)
        // Across the seam between top and bottom, each side keeps its own.
        let across = shaded(through, y: 80)
        let above = color(across, at: Point2(x: 50, y: 92)), below = color(across, at: Point2(x: 50, y: 108))
        #expect(above.red > 0.95 && above.blue < 0.05)
        #expect(below.blue > 0.95 && below.red < 0.05)
    }

    @Test func aShaderCanReachALittlePastItsView() throws {
        try #require(ShaderCompiler.shared != nil, "no GPU to compile with")
        // Reading twenty-five points further down: a view that ends at 90 shows what is at 115.
        let lower = "float4 shader(Frame frame, Inputs in) { return behind(frame, frame.position + float2(0, 25)); }"
        let made = shaded(lower, y: 50)
        let left = color(made, at: Point2(x: 50, y: 85)), right = color(made, at: Point2(x: 150, y: 85))
        #expect(left.blue > 0.95 && left.red < 0.05)
        #expect(right.red > 0.95 && right.green > 0.95 && right.blue < 0.05)
        // And twenty-five to the right: the left of the view shows what is right of it.
        let over = "float4 shader(Frame frame, Inputs in) { return behind(frame, frame.position + float2(25, 0)); }"
        let shifted = shaded(over, x: 40, y: 20, width: 60)
        let edge = color(shifted, at: Point2(x: 90, y: 40))
        #expect(edge.green > 0.95 && edge.red < 0.05)
    }

    /// Layers wholly outside the picture are left out of it, which must go by what they
    /// draw: a stroke lies half outside its shape's frame.
    @Test func aStrokeThatReachesIntoThePictureIsInIt() throws {
        try #require(ShaderCompiler.shared != nil, "no GPU to compile with")
        // The view ends at 60 and reads 25 further down, to 85 at most; the picture reaches
        // 32 past the view, to 92. The ellipse's frame starts below that, at 96, but its
        // stroke, 40 wide, reaches up to 76.
        let lower = "float4 shader(Frame frame, Inputs in) { return behind(frame, frame.position + float2(0, 25)); }"
        var made = shaded(lower, y: 20)
        let ring = Layer(name: "Ring", kind: .ellipse, properties: [
            .position: .point(Point2(x: 60, y: 96)), .size: .size(Size2(width: 80, height: 60)),
            .fill: .color(ColorValue(white: 1, alpha: 0)),
            .strokeColor: .color(.black), .strokeWidth: .number(40),
        ])
        made.screen.children.insert(ring, at: 4)
        let seen = color(made, at: Point2(x: 100, y: 55))
        #expect(seen.red < 0.05 && seen.green < 0.05 && seen.blue < 0.05, "the stroke was left out of the picture")
    }

    // MARK: At another size on screen

    /// The color at a point of the screen when the Viewer shows it `zoom` times as large,
    /// as a Viewer window that was made bigger does, and the Canvas zoomed in.
    func color(_ document: Document, at point: Point2, zoom: Double) -> (red: Double, green: Double, blue: Double) {
        let store = DocumentStore(package: DocumentPackage(document: document))
        let view = ViewerView(store: store, sendsRequests: false)
        view.fillsWindow = true
        view.frame = CGRect(x: 0, y: 0, width: 200 * zoom, height: 200 * zoom)
        view.layoutSubtreeIfNeeded()
        view.advance(by: 1.0 / 60)
        view.advance(by: 1.0 / 60)
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(200 * zoom), pixelsHigh: Int(200 * zoom), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        view.layer?.render(in: NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext)
        let found = bitmap.colorAt(x: Int(point.x * zoom), y: Int(point.y * zoom))!.usingColorSpace(.sRGB)!
        return (found.redComponent, found.greenComponent, found.blueComponent)
    }

    @Test func aShaderReadsTheSamePlaceWhenTheViewerIsLargerOrSmaller() throws {
        try #require(ShaderCompiler.shared != nil, "no GPU to compile with")
        // Twenty-five points further down, in the prototype's points whatever the zoom.
        let lower = "float4 shader(Frame frame, Inputs in) { return behind(frame, frame.position + float2(0, 25)); }"
        let through = "float4 shader(Frame frame, Inputs in) { return behind(frame, frame.position); }"
        for zoom in [0.5, 2.0, 3.0] {
            let made = shaded(lower, y: 50)
            let left = color(made, at: Point2(x: 50, y: 85), zoom: zoom), high = color(made, at: Point2(x: 50, y: 60), zoom: zoom)
            #expect(left.blue > 0.9 && left.red < 0.1, "zoom \(zoom)")
            #expect(high.red > 0.9 && high.blue < 0.1, "zoom \(zoom)")
            // Unbent, the seams are where they are without the view.
            let plain = shaded(through, y: 80)
            let above = color(plain, at: Point2(x: 50, y: 94), zoom: zoom), below = color(plain, at: Point2(x: 50, y: 106), zoom: zoom)
            #expect(above.red > 0.9 && above.blue < 0.1, "zoom \(zoom)")
            #expect(below.blue > 0.9 && below.red < 0.1, "zoom \(zoom)")
        }
    }

    @Test func aBlurIsAsWideInThePrototypeWhateverTheZoom() {
        // Ten points from the seam, a blur of six has not reached; at two it has.
        for zoom in [0.5, 2.0, 3.0] {
            let made = document(blur: 6)
            let near = color(made, at: Point2(x: 98, y: 50), zoom: zoom), far = color(made, at: Point2(x: 82, y: 50), zoom: zoom)
            #expect(near.green > 0.1, "zoom \(zoom): the blur is narrower than it should be")
            #expect(far.red > 0.9 && far.green < 0.1, "zoom \(zoom): the blur is wider than it should be")
        }
    }

    @Test func aBlurInsideAShaderViewDrawsNothingWrong() throws {
        try #require(ShaderCompiler.shared != nil, "no GPU to compile with")
        // The views in a shader view are drawn into a picture of their own, not on the
        // screen: one that asks for what is behind it there gets its fill and no more.
        var made = document(blur: 0)
        var inner = Layer(name: "Inner", kind: .view, properties: [
            .position: .point(Point2(x: 10, y: 10)), .size: .size(Size2(width: 60, height: 20)),
            .fill: .color(ColorValue(hex: "#FFFFFF")!), .backgroundBlur: .number(8),
        ])
        inner.id = LayerID()
        made.screen.update(made.screen.children[4].id) { glass in
            glass.set(.fill, .color(.black))
            glass.shader = ShaderUse(source: "float4 shader(Frame frame, Inputs in) { return content(frame, frame.position); }")
            glass.children = [inner]
        }
        made.normalize()
        let on = color(made, at: Point2(x: 60, y: 40)), off = color(made, at: Point2(x: 150, y: 150))
        #expect(on.red > 0.9 && on.green > 0.9 && on.blue > 0.9)
        #expect(off.red < 0.1 && off.green < 0.1 && off.blue < 0.1)
    }
}
