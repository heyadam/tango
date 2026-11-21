import AVFoundation
import AppKit
import CoreVideo

/// Captures the Viewer into a movie file, one picture per drawn frame. Stretches where
/// nothing moves cost nothing: the last picture simply stays on screen until the next.
final class PrototypeRecorder {
    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let pixelWidth: Int
    private let pixelHeight: Int
    private let scale: CGFloat
    /// The last picture's time in 600ths of a second, the movie's own unit.
    private var lastTick: Int64 = -1

    /// `size` is the Viewer's size in points; the movie has twice as many pixels each way.
    init(size: CGSize, url: URL) throws {
        self.url = url
        scale = 2
        // H.264 wants even dimensions.
        pixelWidth = max(Double(size.width * scale).whole / 2 * 2, 2)
        pixelHeight = max(Double(size.height * scale).whole / 2 * 2, 2)
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight,
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: pixelWidth,
            kCVPixelBufferHeightKey as String: pixelHeight,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
    }

    /// Adds what `layer` shows now as the picture at `seconds` into the movie.
    func append(_ layer: CALayer, at seconds: Double) {
        // Presentation times must strictly increase, counted in the movie's unit: two times
        // a hair apart in seconds can land on the same 600th, which fails the whole movie.
        let tick = max(Int64((seconds * 600).rounded()), lastTick + 1)
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        var created: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
        guard let buffer = created else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        if adaptor.append(buffer, withPresentationTime: CMTime(value: tick, timescale: 600)) {
            lastTick = tick
        }
    }

    /// Closes the movie. Returns whether it was written.
    func finish() async -> Bool {
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed
    }
}
