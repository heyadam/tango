import AppKit
import AVFoundation
import PaperEngine
import PaperModel

/// Holds motion of the shelf against real SwiftUI: a clip of each (the simulator's screen
/// recording, and ours a picture every sixtieth of a second), lined up where each starts to
/// move, and how each gets from rest to rest: a progress curve from 0 to 1, where the moving
/// edges are along the case's lines, when each is half way, nearly there and settled, and how
/// far it overshoots.
///
/// Both sides are measured against themselves, so a color that differs a little everywhere
/// (the recording is not color-managed) does not count. Pure functions on pixels but for the
/// two that make the clips, so they are tested without a simulator.
extension Redline {
    /// Pictures of the region a case follows, `frameLength` apart, the first at rest.
    public struct Clip {
        public var frames: [Picture]
        public let frameLength: Double
        public init(frames: [Picture], frameLength: Double = 1.0 / 60) {
            self.frames = frames
            self.frameLength = frameLength
        }
    }

    /// One side's motion, measured.
    public struct Motion {
        /// From 0 at rest to 1 where it came to rest, one value a frame.
        public let progress: [Double]
        /// Seconds into the clip at which progress first passed `onsetLevel`: time 0 of every measure.
        public let onset: Double
        /// For each track, where its edge is in each frame, in points along its line.
        public let tracks: [[Double?]]
        public let frameLength: Double
        public let clip: Clip

        /// Progress `t` seconds after the onset, read between frames.
        public func progress(at t: Double) -> Double { Self.read(progress, at: (onset + t) / frameLength) }

        public func track(_ index: Int, at t: Double) -> Double? {
            let values = tracks[index], at = (onset + t) / frameLength
            let low = min(max(Int(at.rounded(.down)), 0), values.count - 1), high = min(low + 1, values.count - 1)
            guard let a = values[low] else { return values[high] }
            guard let b = values[high] else { return a }
            return a + (b - a) * min(max(at - Double(low), 0), 1)
        }

        /// The frame showing `t` seconds after the onset.
        public func frame(at t: Double) -> Picture {
            clip.frames[min(max(Int(((onset + t) / frameLength).rounded()), 0), clip.frames.count - 1)]
        }

        static func read(_ values: [Double], at index: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let low = min(max(Int(index.rounded(.down)), 0), values.count - 1), high = min(low + 1, values.count - 1)
            return values[low] + (values[high] - values[low]) * min(max(index - Double(low), 0), 1)
        }
    }

    /// How far progress must have come for motion to have begun; the frames before it are
    /// not compared, so a side that takes a frame longer to answer is not counted as slower.
    public static let onsetLevel = 0.05
    /// How close to its end progress must stay to have settled.
    public static let settleBand = 0.02
    /// How close to its end an edge must stay to have settled, in points.
    public static let trackBand = 0.5

    /// The first frame that differs from the first anywhere in the clip, or nil when nothing moves.
    public static func firstChange(in clip: Clip, tolerance: Int = 16) -> Int? {
        guard let rest = clip.frames.first else { return nil }
        let least = max(rest.width * rest.height / 2000, 3)
        for (index, frame) in clip.frames.enumerated().dropFirst() {
            var count = 0
            for y in 0..<min(frame.height, rest.height) {
                for x in 0..<min(frame.width, rest.width) where differs(frame.color(x, y), rest.color(x, y), by: tolerance) {
                    count += 1
                }
                if count >= least { return index }
            }
        }
        return nil
    }

    /// Measures a clip: progress by how far each frame has gone from the first toward the
    /// last (each pixel's change projected on the whole change), and where each track's edge
    /// is. The clip is cut to `seconds` after it begins to move. Nil when nothing moves.
    public static func measure(_ clip: Clip, tracks: [ReferenceMotion.Track] = [], origin: CGPoint = .zero, seconds: Double) -> Motion? {
        guard let first = firstChange(in: clip) else { return nil }
        let start = max(first - 3, 0), last = min(first + Int((seconds / clip.frameLength).rounded()) + 3, clip.frames.count - 1)
        var kept = clip
        kept.frames = Array(clip.frames[start...last])
        // Before motion is the first frame of the clip itself: a recording made from a still
        // screen may hold no frame for the moment just before.
        kept.frames[0] = clip.frames[0]
        guard let rest = kept.frames.first, let end = kept.frames.last else { return nil }
        let count = rest.width * rest.height
        var change = [Double](repeating: 0, count: count * 3)
        var whole = 0.0
        for y in 0..<rest.height {
            for x in 0..<rest.width {
                let a = rest.color(x, y), b = end.color(x, y), at = (y * rest.width + x) * 3
                change[at] = Double(b.r - a.r); change[at + 1] = Double(b.g - a.g); change[at + 2] = Double(b.b - a.b)
                whole += change[at] * change[at] + change[at + 1] * change[at + 1] + change[at + 2] * change[at + 2]
            }
        }
        guard whole > 0 else { return nil }
        let progress = kept.frames.map { frame -> Double in
            var along = 0.0
            for y in 0..<rest.height {
                for x in 0..<rest.width {
                    let a = rest.color(x, y), c = frame.color(x, y), at = (y * rest.width + x) * 3
                    along += Double(c.r - a.r) * change[at] + Double(c.g - a.g) * change[at + 1] + Double(c.b - a.b) * change[at + 2]
                }
            }
            return along / whole
        }
        // Where it passed the onset level, read between the frames either side.
        var onset = 0.0
        if let after = progress.firstIndex(where: { $0 >= onsetLevel }), after > 0 {
            let a = progress[after - 1], b = progress[after]
            onset = (Double(after - 1) + (b > a ? (onsetLevel - a) / (b - a) : 1)) * kept.frameLength
        }
        let found = tracks.map { track in
            kept.frames.map { frame -> Double? in
                let from = CGPoint(x: track.from.x - origin.x, y: track.from.y - origin.y), to = CGPoint(x: track.to.x - origin.x, y: track.to.y - origin.y)
                return edges(of: frame, from: from, to: to).first
            }
        }
        return Motion(progress: progress, onset: onset, tracks: found, frameLength: kept.frameLength, clip: kept)
    }

    /// What one side's motion comes to, in seconds after its onset.
    public struct Timing: Equatable {
        public var half: Double?
        public var mostly: Double?
        /// When it came within `settleBand` of the end for good.
        public var settled: Double
        /// How far past the end it went, as a share of the way (0 for none).
        public var overshoot: Double
    }

    public static func timing(of motion: Motion) -> Timing {
        let values = motion.progress, dt = motion.frameLength
        func crossing(_ level: Double) -> Double? {
            guard let after = values.firstIndex(where: { $0 >= level }) else { return nil }
            guard after > 0 else { return 0 }
            let a = values[after - 1], b = values[after]
            return (Double(after - 1) + (b > a ? (level - a) / (b - a) : 1)) * dt - motion.onset
        }
        let outside = values.lastIndex(where: { abs($0 - 1) > settleBand }) ?? -1
        return Timing(
            half: crossing(0.5), mostly: crossing(0.9),
            settled: max(Double(outside + 1) * dt - motion.onset, 0),
            overshoot: max((values.max() ?? 1) - 1, 0)
        )
    }

    /// Where a track's edge started and ended, how far past the end it went (in points, in
    /// the way it moved) and when it settled, in seconds after the onset.
    public struct TrackTiming: Equatable {
        public var from: Double?
        public var to: Double?
        public var overshoot: Double
        public var settled: Double?
    }

    public static func timing(of motion: Motion, track index: Int) -> TrackTiming {
        let values = motion.tracks[index]
        guard let end = values.last(where: { $0 != nil }) ?? nil else { return TrackTiming(from: nil, to: nil, overshoot: 0, settled: nil) }
        let start = values.first(where: { $0 != nil }) ?? nil
        let way: Double = (start ?? end) <= end ? 1 : -1
        let overshoot = values.compactMap { $0 }.map { ($0 - end) * way }.max() ?? 0
        let outside = values.lastIndex(where: { value in value.map { abs($0 - end) > trackBand } ?? true }) ?? -1
        return TrackTiming(from: start, to: end, overshoot: max(overshoot, 0), settled: max(Double(outside + 1) * motion.frameLength - motion.onset, 0))
    }

    /// How far apart the two progress curves are over the first `seconds` after their
    /// onsets: the root mean square of the difference, as a share of the way.
    public static func curveDifference(_ real: Motion, _ ours: Motion, seconds: Double) -> Double {
        let steps = max(Int(seconds * 120), 1)
        var sum = 0.0
        for step in 0...steps {
            let t = Double(step) / 120
            let d = real.progress(at: t) - ours.progress(at: t)
            sum += d * d
        }
        return (sum / Double(steps + 1)).squareRoot()
    }

    /// A picture cut to `area` (in points), at its own scale.
    public static func crop(_ picture: Picture, to area: CGRect) -> Picture {
        let s = picture.scale
        let x0 = max(Int(area.minX * s), 0), y0 = max(Int(area.minY * s), 0)
        let wide = max(min(Int(area.width * s), picture.width - x0), 0), tall = max(min(Int(area.height * s), picture.height - y0), 0)
        var bytes = [UInt8](repeating: 0, count: wide * tall * 4)
        for y in 0..<tall {
            let from = ((y0 + y) * picture.width + x0) * 4
            bytes.replaceSubrange((y * wide * 4)..<((y + 1) * wide * 4), with: picture.bytes[from..<(from + wide * 4)])
        }
        return Picture(width: wide, height: tall, bytes: bytes, scale: s)
    }
}

// MARK: Pictures for the report

extension Redline {
    /// When the filmstrip shows each side, in seconds after its onset.
    public static let filmstripTimes = [0, 1.0 / 30, 1.0 / 15, 0.1, 0.15, 0.2, 0.3, 0.45, 0.7, 1.0]

    static func image(width: Int, height: Int, _ draw: (CGContext) -> Void) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Top left first, as the pictures are.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(context)
        return context.makeImage()
    }

    static func put(_ picture: Picture, at origin: CGPoint, in context: CGContext, unlike other: Picture? = nil) {
        var bytes = picture.bytes
        if let other {
            for y in 0..<picture.height {
                for x in 0..<picture.width {
                    let real = picture.color(x, y), at = (y * picture.width + x) * 4
                    let ratio = other.scale / picture.scale
                    let unlike = differs(real, other.color(Int(Double(x) * ratio), Int(Double(y) * ratio)), by: 40)
                    let grey = (real.r * 30 + real.g * 59 + real.b * 11) / 100, faint = UInt8(255 - (255 - grey) / 4)
                    (bytes[at], bytes[at + 1], bytes[at + 2]) = unlike ? (230, 30, 40) : (faint, faint, faint)
                }
            }
        }
        for at in stride(from: 3, to: bytes.count, by: 4) { bytes[at] = 255 }
        let made = bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: picture.width, height: picture.height, bitsPerComponent: 8, bytesPerRow: picture.width * 4,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        guard let made else { return }
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y + CGFloat(picture.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(made, in: CGRect(x: 0, y: 0, width: picture.width, height: picture.height))
        context.restoreGState()
    }

    static func write(_ text: String, at point: CGPoint, size: CGFloat = 11, color: NSColor = NSColor(white: 0.35, alpha: 1), in context: CGContext, alignment: NSTextAlignment = .left) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color]
        let string = NSAttributedString(string: text, attributes: attributes)
        let width = string.size().width
        let x = alignment == .right ? point.x - width : alignment == .center ? point.x - width / 2 : point.x
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        string.draw(at: CGPoint(x: x, y: point.y))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Rows of the real thing, ours, and the real thing washed out with what differs in red,
    /// at each of `filmstripTimes` within `seconds`.
    public static func filmstrip(_ real: Motion, _ ours: Motion, seconds: Double) -> CGImage? {
        let times = filmstripTimes.filter { $0 <= seconds + 0.001 }
        let sample = real.frame(at: 0), gap = 8, label = 18
        let width = times.count * (sample.width + gap) - gap, height = label + 3 * (sample.height + gap)
        return image(width: width, height: height) { context in
            for (column, t) in times.enumerated() {
                let x = CGFloat(column * (sample.width + gap))
                write(String(format: "%.0f ms", t * 1000), at: CGPoint(x: x + 2, y: 2), in: context)
                let mine = ours.frame(at: t), theirs = real.frame(at: t)
                put(theirs, at: CGPoint(x: x, y: CGFloat(label)), in: context)
                put(mine, at: CGPoint(x: x, y: CGFloat(label + sample.height + gap)), in: context)
                put(theirs, at: CGPoint(x: x, y: CGFloat(label + 2 * (sample.height + gap))), in: context, unlike: mine)
            }
        }
    }

    /// The two sides' series in the default palette's first two categorical slots.
    static let realColor = CGColor(red: 0x2a / 255.0, green: 0x78 / 255.0, blue: 0xd6 / 255.0, alpha: 1)
    static let oursColor = CGColor(red: 0xeb / 255.0, green: 0x68 / 255.0, blue: 0x34 / 255.0, alpha: 1)

    /// One chart: a value against time for both sides, from the onset to `seconds` after it.
    static func chart(
        _ title: String, unit: String, seconds: Double, in context: CGContext, frame: CGRect,
        real: (Double) -> Double?, ours: (Double) -> Double?, guides: [Double]
    ) {
        let samples = stride(from: 0.0, through: seconds, by: 1.0 / 120).map { ($0, real($0), ours($0)) }
        let values = samples.flatMap { [$0.1, $0.2].compactMap { $0 } } + guides
        guard var low = values.min(), var high = values.max() else { return }
        if high - low < 1e-6 { low -= 1; high += 1 }
        let pad = (high - low) * 0.08
        low -= pad; high += pad
        let plot = CGRect(x: frame.minX + 48, y: frame.minY + 26, width: frame.width - 60, height: frame.height - 50)
        func point(_ t: Double, _ v: Double) -> CGPoint {
            CGPoint(x: plot.minX + CGFloat(t / seconds) * plot.width, y: plot.maxY - CGFloat((v - low) / (high - low)) * plot.height)
        }
        write(title, at: CGPoint(x: frame.minX + 8, y: frame.minY + 4), size: 12, color: NSColor(white: 0.1, alpha: 1), in: context)
        // A legend, since the two meet where they come to rest.
        for (index, (name, color)) in [("Real", realColor), ("Ours", oursColor)].enumerated() {
            let x = frame.maxX - 120 + CGFloat(index) * 60
            context.setFillColor(color)
            context.fill(CGRect(x: x, y: frame.minY + 9, width: 12, height: 3))
            write(name, at: CGPoint(x: x + 16, y: frame.minY + 3), in: context)
        }
        // Recessive guides: the values that matter and every tenth of a second.
        context.setLineWidth(1)
        context.setStrokeColor(CGColor(gray: 0.88, alpha: 1))
        for guide in guides {
            let y = point(0, guide).y
            context.strokeLineSegments(between: [CGPoint(x: plot.minX, y: y), CGPoint(x: plot.maxX, y: y)])
            write(String(format: unit.isEmpty ? "%.1f" : "%.0f", guide), at: CGPoint(x: plot.minX - 6, y: y - 7), size: 10, in: context, alignment: .right)
        }
        for tenth in 0...Int((seconds * 10).rounded(.down)) {
            let x = point(Double(tenth) / 10, low).x
            context.setStrokeColor(CGColor(gray: tenth % 2 == 0 ? 0.88 : 0.94, alpha: 1))
            context.strokeLineSegments(between: [CGPoint(x: x, y: plot.minY), CGPoint(x: x, y: plot.maxY)])
            if tenth % 2 == 0 { write("\(tenth * 100) ms", at: CGPoint(x: x, y: plot.maxY + 4), size: 10, in: context, alignment: .center) }
        }
        context.setLineWidth(2)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        for (series, color) in [(1, realColor), (2, oursColor)] {
            context.setStrokeColor(color)
            var drawing = false
            for sample in samples {
                guard let v = series == 1 ? sample.1 : sample.2 else { drawing = false; continue }
                if drawing { context.addLine(to: point(sample.0, v)) } else { context.move(to: point(sample.0, v)) }
                drawing = true
            }
            context.strokePath()
        }
    }

    /// The progress curves and one chart per track, one under another.
    public static func curves(_ item: ReferenceMotion, _ real: Motion, _ ours: Motion) -> CGImage? {
        let width = 720, each = 220, scale = 2
        let charts = 1 + item.tracks.count
        return image(width: width * scale, height: each * charts * scale) { context in
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            chart("Progress, from rest to rest", unit: "", seconds: item.seconds, in: context,
                  frame: CGRect(x: 0, y: 0, width: width, height: each),
                  real: { real.progress(at: $0) }, ours: { ours.progress(at: $0) }, guides: [0, 0.5, 1])
            for (index, track) in item.tracks.enumerated() {
                let ends = [timing(of: real, track: index), timing(of: ours, track: index)].flatMap { [$0.from, $0.to].compactMap { $0 } }
                chart("\(track.name), points", unit: "pt", seconds: item.seconds, in: context,
                      frame: CGRect(x: 0, y: each * (index + 1), width: width, height: each),
                      real: { real.track(index, at: $0) }, ours: { ours.track(index, at: $0) },
                      guides: Array(Set(ends.map { $0.rounded() })).sorted())
            }
        }
    }
}

// MARK: Making the clips and the report

extension Redline {
    /// Ours: the case at rest, the tap, then a picture every frame for as long as it is followed.
    public static func clip(of item: ReferenceMotion, dark: Bool = false) -> Clip? {
        let frames = Int(((item.seconds + 0.3) * 60).rounded())
        var steps: [ViewerSnapshot.Step] = [.wait(0.5), .look, .tap(item.tap)]
        for _ in 0..<frames { steps += [.look, .wait(1.0 / 60)] }
        let region = CGRect(x: item.region.x, y: item.region.y, width: item.region.width, height: item.region.height)
        let pictures = ViewerSnapshot.bitmaps(of: dark ? item.makeDark() : item.make(), steps: steps, scale: 1).compactMap { bitmap -> Picture? in
            guard let image = bitmap.cgImage, let whole = picture(image, pointsWide: ReferenceCase.device.width, managed: false) else { return nil }
            return crop(whole, to: region)
        }
        return pictures.count > 2 ? Clip(frames: pictures) : nil
    }

    /// The real thing: a screen recording of the simulator, the region at one pixel a point,
    /// a frame every sixtieth of a second. A recording holds a frame only when the screen
    /// changed, so each sixtieth shows the last frame that came before it, and the clip ends
    /// at the last change: the recording must go on until the case has come to rest.
    public static func clip(ofVideo url: URL, region: CGRect, pointsWide: Double = ReferenceCase.device.width) -> Clip? {
        let asset = AVURLAsset(url: url)
        nonisolated final class Found: @unchecked Sendable { var track: AVAssetTrack? }
        let found = Found(), done = DispatchSemaphore(value: 0)
        Task.detached {
            found.track = try? await asset.loadTracks(withMediaType: .video).first
            done.signal()
        }
        guard done.wait(timeout: .now() + 10) == .success, let track = found.track, let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { return nil }
        let wide = Int(region.width), tall = Int(region.height)
        var samples: [(time: Double, picture: Picture)] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { continue }
            let row = CVPixelBufferGetBytesPerRow(pixels), width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
            let s = Double(width) / pointsWide
            var bytes = [UInt8](repeating: 255, count: wide * tall * 4)
            for y in 0..<tall {
                let sy = min(Int((region.minY + Double(y) + 0.5) * s), height - 1)
                for x in 0..<wide {
                    let sx = min(Int((region.minX + Double(x) + 0.5) * s), width - 1)
                    let from = sy * row + sx * 4, at = (y * wide + x) * 4
                    bytes[at] = base[from + 2]; bytes[at + 1] = base[from + 1]; bytes[at + 2] = base[from]
                }
            }
            let picture = Picture(width: wide, height: tall, bytes: bytes, scale: 1)
            // A frame like the last one held adds nothing.
            if let last = samples.last, last.picture.bytes == picture.bytes { continue }
            samples.append((time, picture))
        }
        // The recording starts while the app may still be opening, which pauses too: the clip
        // starts at the frame the screen held longest, the case at rest before its change.
        if let still = samples.indices.dropLast().max(by: { samples[$0 + 1].time - samples[$0].time < samples[$1 + 1].time - samples[$1].time }) {
            samples.removeFirst(still)
        }
        guard let first = samples.first, let last = samples.last else { return nil }
        var frames: [Picture] = [], index = 0
        for step in 0...Int(((last.time - first.time) * 60).rounded(.up)) {
            let t = first.time + Double(step) / 60
            while index + 1 < samples.count, samples[index + 1].time <= t + 1e-6 { index += 1 }
            frames.append(samples[index].picture)
        }
        return Clip(frames: frames)
    }

    static func milliseconds(_ seconds: Double?) -> String {
        seconds.map { String(format: "%.0f ms", $0 * 1000) } ?? "never"
    }

    /// One case's lines of the report.
    public static func motionReport(_ item: ReferenceMotion, _ real: Motion, _ ours: Motion) -> String {
        let a = timing(of: real), b = timing(of: ours)
        var lines = [
            "## \(item.title) (`\(item.id)`)", "",
            "![\(item.id)](\(item.id).png)", "", "![\(item.id) curves](\(item.id)-curves.png)", "",
            "| | Real | Ours |", "|---|---|---|",
            "| Half way | \(milliseconds(a.half)) | \(milliseconds(b.half)) |",
            "| 90% of the way | \(milliseconds(a.mostly)) | \(milliseconds(b.mostly)) |",
            "| Settled (within \(Int(settleBand * 100))%) | \(milliseconds(a.settled)) | \(milliseconds(b.settled)) |",
            String(format: "| Overshoot | %.1f%% | %.1f%% |", a.overshoot * 100, b.overshoot * 100),
        ]
        for (index, track) in item.tracks.enumerated() {
            let r = timing(of: real, track: index), o = timing(of: ours, track: index)
            func describe(_ t: TrackTiming) -> String {
                guard let to = t.to else { return "not found" }
                return String(format: "%@ → %.1f pt, overshoot %.1f pt, settled %@", t.from.map { String(format: "%.1f", $0) } ?? "–", to, t.overshoot, milliseconds(t.settled))
            }
            lines.append("| \(track.name) | \(describe(r)) | \(describe(o)) |")
        }
        lines.append(String(format: "| Curves differ by | | %.1f%% of the way (RMS over %.1f s) |", curveDifference(real, ours, seconds: item.seconds) * 100, item.seconds))
        return lines.joined(separator: "\n") + "\n"
    }

    /// Runs the moving cases whose recording is in `videos` (`<id>.mov`), writes each one's
    /// filmstrip, curves and numbers (`<id>.csv`) and `report.md` into `out`, and returns
    /// the summary.
    public static func runMotion(videos: URL, out: URL, only: Set<String> = [], dark: Bool = false) throws -> String {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var report = "# The iOS shelf's motion against real SwiftUI\(dark ? ", in dark appearance" : "")\n\n"
            + "Each filmstrip is the real thing, ours, and the real thing with what differs in red, at times after each began to move. "
            + "Times are from where each had come \(Int(onsetLevel * 100))% of the way.\n\n"
        var summary = ["| Case | Half way, real / ours | Settled, real / ours | Curves differ |", "|---|---|---|---|"]
        var sections: [String] = []
        for item in ReferenceMotion.all where only.isEmpty || only.contains(item.id) {
            let region = CGRect(x: item.region.x, y: item.region.y, width: item.region.width, height: item.region.height)
            guard let recorded = clip(ofVideo: videos.appendingPathComponent("\(item.id).mov"), region: region) else {
                summary.append("| \(item.title) | no recording of the real thing | | |")
                continue
            }
            guard let real = measure(recorded, tracks: item.tracks, origin: region.origin, seconds: item.seconds) else {
                summary.append("| \(item.title) | the real thing does not move in the recording | | |")
                continue
            }
            guard let made = clip(of: item, dark: dark), let ours = measure(made, tracks: item.tracks, origin: region.origin, seconds: item.seconds) else {
                summary.append("| \(item.title) | ours does not move | | |")
                continue
            }
            for (name, image) in [("\(item.id).png", filmstrip(real, ours, seconds: item.seconds)), ("\(item.id)-curves.png", curves(item, real, ours))] {
                if let image { try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name)) }
            }
            var csv = ["t," + (["real", "ours"] + item.tracks.flatMap { ["real \($0.name)", "ours \($0.name)"] }).joined(separator: ",")]
            for step in 0...Int(item.seconds * 120) {
                let t = Double(step) / 120
                var row = [String(format: "%.4f", t), String(format: "%.4f", real.progress(at: t)), String(format: "%.4f", ours.progress(at: t))]
                for index in item.tracks.indices {
                    row += [real.track(index, at: t), ours.track(index, at: t)].map { $0.map { String(format: "%.2f", $0) } ?? "" }
                }
                csv.append(row.joined(separator: ","))
            }
            try (csv.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("\(item.id).csv"), atomically: true, encoding: .utf8)
            let a = timing(of: real), b = timing(of: ours)
            summary.append(String(
                format: "| \(item.title) | %@ / %@ | %@ / %@ | %.1f%% |",
                milliseconds(a.half), milliseconds(b.half), milliseconds(a.settled), milliseconds(b.settled),
                curveDifference(real, ours, seconds: item.seconds) * 100
            ))
            sections.append(motionReport(item, real, ours))
        }
        report += summary.joined(separator: "\n") + "\n\n" + sections.joined(separator: "\n")
        try report.write(to: out.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        return summary.joined(separator: "\n")
    }
}
