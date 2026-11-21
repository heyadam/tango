import AppKit
import PaperEngine
import PaperModel

/// Holds a picture of the real thing against a picture of ours: where each one's content
/// is, how much of the region differs, where each has edges along the lines through its
/// middle, and a picture with the two side by side and their differences in red.
///
/// Pure functions on pixels, so they are tested without a simulator.
public enum Redline {
    /// A picture as plain sRGB bytes, four to a pixel, top row first.
    public struct Picture {
        public let width: Int
        public let height: Int
        public var bytes: [UInt8]
        /// Pixels to a point.
        public let scale: Double

        public init(width: Int, height: Int, bytes: [UInt8], scale: Double) {
            self.width = width
            self.height = height
            self.bytes = bytes
            self.scale = scale
        }

        /// This picture with `area` (in points) taken from `other`, pixel for pixel at this
        /// one's scale.
        public func with(_ area: CGRect, from other: Picture) -> Picture {
            var copy = self
            let ratio = other.scale / scale
            for y in max(Int(area.minY * scale), 0)..<min(Int(area.maxY * scale), height) {
                for x in max(Int(area.minX * scale), 0)..<min(Int(area.maxX * scale), width) {
                    let c = other.color(Int(Double(x) * ratio), Int(Double(y) * ratio)), at = (y * width + x) * 4
                    copy.bytes[at] = UInt8(c.r); copy.bytes[at + 1] = UInt8(c.g); copy.bytes[at + 2] = UInt8(c.b)
                }
            }
            return copy
        }

        public func color(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
            let at = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
            return (Int(bytes[at]), Int(bytes[at + 1]), Int(bytes[at + 2]))
        }
    }

    public struct Result {
        public let reference: CGRect?
        public let ours: CGRect?
        /// The share of the region's pixels that differ, from 0 to 1.
        public let differing: Double
        public let referenceEdges: (across: [Double], down: [Double])
        public let oursEdges: (across: [Double], down: [Double])
        public let picture: CGImage?
    }

    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A picture from an image. `managed` converts its colors to sRGB, as for a screenshot;
    /// without it the numbers are taken as they are, as for a picture of ours, whose
    /// bitmap says "device" for what are sRGB values.
    public static func picture(_ image: CGImage, pointsWide: Double, managed: Bool) -> Picture? {
        let source = managed ? image : image.copy(colorSpace: space) ?? image
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(source, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? Picture(width: image.width, height: image.height, bytes: bytes, scale: Double(image.width) / pointsWide) : nil
    }

    public static func picture(at url: URL, pointsWide: Double) -> Picture? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return picture(image, pointsWide: pointsWide, managed: true)
    }

    static func differs(_ a: (r: Int, g: Int, b: Int), _ b: (r: Int, g: Int, b: Int), by tolerance: Int) -> Bool {
        max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b)) > tolerance
    }

    /// The box round everything in a region that is not its background, in points. The
    /// background is the color of the region's top left corner.
    public static func content(of picture: Picture, in region: CGRect, tolerance: Int = 5) -> CGRect? {
        let s = picture.scale
        let x0 = Int(region.minX * s), y0 = Int(region.minY * s), x1 = min(Int(region.maxX * s), picture.width), y1 = min(Int(region.maxY * s), picture.height)
        guard x1 > x0, y1 > y0 else { return nil }
        // A picture the simulator takes has a few black pixels in its very corner, which
        // would stretch the box of a region that starts there to the corner.
        let speck = Int(s)
        func inCorner(_ x: Int, _ y: Int) -> Bool { x <= speck && y <= speck }
        let background = picture.color(x0 + speck + 1, y0 + speck + 1)
        var left = x1, right = x0 - 1, top = y1, bottom = y0 - 1
        for y in y0..<y1 {
            for x in x0..<x1 where !inCorner(x, y) && differs(picture.color(x, y), background, by: tolerance) {
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
            }
        }
        guard right >= left, bottom >= top else { return nil }
        return CGRect(x: Double(left) / s, y: Double(top) / s, width: Double(right + 1 - left) / s, height: Double(bottom + 1 - top) / s)
    }

    /// Where the color changes along a line, in points from the line's start: the edges a
    /// redline is drawn from. A change counts once it has lasted half a point.
    public static func edges(of picture: Picture, from start: CGPoint, to end: CGPoint, tolerance: Int = 22) -> [Double] {
        let s = picture.scale
        let length = Int((hypot(end.x - start.x, end.y - start.y) * s).rounded())
        guard length > 1 else { return [] }
        func at(_ step: Int) -> (r: Int, g: Int, b: Int) {
            let t = Double(step) / Double(length)
            return picture.color(Int((start.x + (end.x - start.x) * t) * s), Int((start.y + (end.y - start.y) * t) * s))
        }
        var found: [Double] = []
        var settled = at(0), candidate = 0, run = 0
        let needed = max(Int(s / 2), 1)
        for step in 1..<length {
            if differs(at(step), settled, by: tolerance) {
                if run == 0 { candidate = step }
                run += 1
                if run >= needed {
                    found.append((Double(candidate) / s * 10).rounded() / 10)
                    settled = at(step)
                    run = 0
                }
            } else {
                run = 0
            }
        }
        return found
    }

    /// Compares a region of two pictures of the same screen.
    public static func compare(reference: Picture, ours: Picture, region: CGRect, tolerance: Int = 40) -> Result {
        let referenceBox = content(of: reference, in: region), oursBox = content(of: ours, in: region)
        func lines(_ picture: Picture, _ box: CGRect?) -> (across: [Double], down: [Double]) {
            guard let box else { return ([], []) }
            return (
                edges(of: picture, from: CGPoint(x: region.minX, y: box.midY), to: CGPoint(x: region.maxX, y: box.midY)).map { $0 + region.minX },
                edges(of: picture, from: CGPoint(x: box.midX, y: region.minY), to: CGPoint(x: box.midX, y: region.maxY)).map { $0 + region.minY }
            )
        }
        // Pixel for pixel, at the reference's scale.
        let s = reference.scale, ratio = ours.scale / s
        let x0 = Int(region.minX * s), y0 = Int(region.minY * s)
        let wide = min(Int(region.width * s), reference.width - x0), tall = min(Int(region.height * s), reference.height - y0)
        guard wide > 0, tall > 0 else {
            return Result(reference: referenceBox, ours: oursBox, differing: 0, referenceEdges: lines(reference, referenceBox), oursEdges: lines(ours, oursBox), picture: nil)
        }
        var panel = [UInt8](repeating: 255, count: (wide * 3 + 24) * tall * 4)
        let panelWide = wide * 3 + 24
        var different = 0
        for y in 0..<tall {
            for x in 0..<wide {
                let real = reference.color(x0 + x, y0 + y)
                let mine = ours.color(Int(Double(x0 + x) * ratio), Int(Double(y0 + y) * ratio))
                let unlike = differs(real, mine, by: tolerance)
                if unlike { different += 1 }
                func put(_ column: Int, _ color: (r: Int, g: Int, b: Int)) {
                    let at = (y * panelWide + column) * 4
                    panel[at] = UInt8(color.r); panel[at + 1] = UInt8(color.g); panel[at + 2] = UInt8(color.b); panel[at + 3] = 255
                }
                put(x, real)
                put(wide + 12 + x, mine)
                // The redline: the real thing washed out, with red where ours is not like it.
                let grey = (real.r * 30 + real.g * 59 + real.b * 11) / 100
                let faint = 255 - (255 - grey) / 4
                put(wide * 2 + 24 + x, unlike ? (230, 30, 40) : (faint, faint, faint))
            }
        }
        let image = panel.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(
                data: buffer.baseAddress, width: panelWide, height: tall, bitsPerComponent: 8, bytesPerRow: panelWide * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
        return Result(
            reference: referenceBox, ours: oursBox, differing: Double(different) / Double(wide * tall),
            referenceEdges: lines(reference, referenceBox), oursEdges: lines(ours, oursBox), picture: image
        )
    }

    /// One case's lines of the report.
    public static func report(_ title: String, id: String, _ result: Result) -> String {
        func box(_ rect: CGRect?) -> String {
            guard let rect else { return "nothing" }
            return String(format: "x %.1f, y %.1f, %.1f × %.1f", rect.minX, rect.minY, rect.width, rect.height)
        }
        func list(_ numbers: [Double]) -> String { numbers.map { String(format: "%.1f", $0) }.joined(separator: "  ") }
        var lines = ["## \(title) (`\(id)`)", "", "![\(id)](\(id).png)", "", "| | Real | Ours |", "|---|---|---|"]
        lines.append("| Content | \(box(result.reference)) | \(box(result.ours)) |")
        if let real = result.reference, let mine = result.ours {
            lines.append(String(
                format: "| Ours is off by | | x %+.1f, y %+.1f, width %+.1f, height %+.1f |",
                mine.minX - real.minX, mine.minY - real.minY, mine.width - real.width, mine.height - real.height
            ))
        }
        lines.append("| Edges across the middle | \(list(result.referenceEdges.across)) | \(list(result.oursEdges.across)) |")
        lines.append("| Edges down the middle | \(list(result.referenceEdges.down)) | \(list(result.oursEdges.down)) |")
        lines.append(String(format: "| Pixels that differ | | %.1f%% |", result.differing * 100))
        return lines.joined(separator: "\n") + "\n"
    }

    /// Where the Dynamic Island is on the 402-point phone, a point round it included.
    public static let dynamicIsland = CGRect(x: 137, y: 13, width: 128, height: 39)

    /// Runs the cases whose reference picture is in `shots`, writes each one's picture and
    /// `report.md` into `out`, and returns the report.
    @MainActor
    public static func run(shots: URL, out: URL, only: Set<String> = [], dark: Bool = false) throws -> String {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var report = "# The iOS shelf against real SwiftUI\(dark ? ", in dark appearance" : "")\n\nEach picture is the real thing, ours, and the real thing with what differs in red. Measures are in points.\n\n"
        var summary = ["| Case | Size off by | Differs |", "|---|---|---|"]
        var sections: [String] = []
        for item in ReferenceCase.all where only.isEmpty || only.contains(item.id) {
            let width = ReferenceCase.device.width
            guard let shot = picture(at: shots.appendingPathComponent("\(item.id).png"), pointsWide: width) else {
                summary.append("| \(item.title) | no picture of the real thing | |")
                continue
            }
            guard let bitmap = ViewerSnapshot.bitmaps(of: dark ? item.makeDark() : item.make(), steps: [.wait(1.2), .look], scale: 3).first?.cgImage,
                  let ours = picture(bitmap, pointsWide: width, managed: false) else { continue }
            // The simulator draws the Dynamic Island into some pictures and not others, and
            // the shelf has none: it is left out of the comparison.
            let reference = shot.with(dynamicIsland, from: ours)
            // Ours whole, beside the pictures of the real thing, to measure with other tools.
            let whole = out.appendingPathComponent("ours")
            try FileManager.default.createDirectory(at: whole, withIntermediateDirectories: true)
            try NSBitmapImageRep(cgImage: bitmap).representation(using: .png, properties: [:])?.write(to: whole.appendingPathComponent("\(item.id).png"))
            let region = CGRect(x: item.region.x, y: item.region.y, width: item.region.width, height: item.region.height)
            let result = compare(reference: reference, ours: ours, region: region)
            if let image = result.picture {
                let rep = NSBitmapImageRep(cgImage: image)
                try rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(item.id).png"))
            }
            var size = "nothing to measure"
            if let real = result.reference, let mine = result.ours {
                size = String(format: "%+.1f × %+.1f", mine.width - real.width, mine.height - real.height)
            }
            summary.append(String(format: "| \(item.title) | \(size) | %.1f%% |", result.differing * 100))
            sections.append(Redline.report(item.title, id: item.id, result))
        }
        report += summary.joined(separator: "\n") + "\n\n" + sections.joined(separator: "\n")
        try report.write(to: out.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        return summary.joined(separator: "\n")
    }
}

// MARK: Fitting the glass

extension Redline {
    /// The cases that hold the shelf's glass against iOS 26's: a pane named "Glass" over a
    /// backdrop.
    public static var glassCases: [ReferenceCase] { ReferenceCase.all.filter { $0.id.hasPrefix("glass-") } }

    /// How far the glass, given these shader inputs, is from the real pictures in `shots`:
    /// the mean difference of a channel, 0 to 255, over each pane, averaged over the cases.
    @MainActor
    public static func glassError(shots: URL, inputs: [String: Value], dark: Bool = false) -> Double? {
        var total = 0.0, counted = 0
        for item in glassCases {
            guard let reference = picture(at: shots.appendingPathComponent("\(item.id).png"), pointsWide: ReferenceCase.device.width) else { continue }
            var document = dark ? item.makeDark() : item.make()
            guard let pane = document.screen.children.first(where: { $0.name == "Glass" }) else { continue }
            _ = document.screen.update(pane.id) { layer in
                for (name, value) in inputs { layer.shader?.inputs[name] = value }
            }
            guard let bitmap = ViewerSnapshot.bitmaps(of: document, steps: [.look], scale: 3).first?.cgImage,
                  let ours = picture(bitmap, pointsWide: ReferenceCase.device.width, managed: false) else { continue }
            let at = pane.value(.position).pointValue, size = pane.value(.size).sizeValue
            let frame = (x: at.x, y: at.y, width: size.width, height: size.height)
            let s = reference.scale, ratio = ours.scale / s
            var sum = 0, pixels = 0
            for y in Int(frame.y * s)..<Int((frame.y + frame.height) * s) {
                for x in Int(frame.x * s)..<Int((frame.x + frame.width) * s) {
                    let real = reference.color(x, y), mine = ours.color(Int(Double(x) * ratio), Int(Double(y) * ratio))
                    sum += abs(real.r - mine.r) + abs(real.g - mine.g) + abs(real.b - mine.b)
                    pixels += 3
                }
            }
            if pixels > 0 { total += Double(sum) / Double(pixels); counted += 1 }
        }
        return counted > 0 ? total / Double(counted) : nil
    }
}
