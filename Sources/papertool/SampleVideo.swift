import AVFoundation
import AppKit
import CoreText

/// Writes the short clip the Video Scrubbing pattern plays (`Gallery.sampleVideo`): four
/// seconds of a ball crossing a sky that darkens, with the time written large, so where the
/// playhead is can be read off any frame. Frequent keyframes keep scrubbing quick.
enum SampleVideo {
    static let width = 480
    static let height = 270
    static let seconds = 4
    static let fps = 30

    static func write(to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 600_000,
                AVVideoMaxKeyFrameIntervalKey: 6,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let frames = seconds * fps
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
            var created: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
            guard let buffer = created else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) {
                draw(Double(frame) / Double(frames - 1), seconds: Double(frame) / Double(fps), in: context)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// One frame, `progress` of the way through. Core Graphics draws y up.
    private static func draw(_ progress: Double, seconds: Double, in context: CGContext) {
        let w = Double(width), h = Double(height)
        // A sky from dusk blue at the start to deep violet at the end.
        let top = CGColor(srgbRed: 0.24 - 0.14 * progress, green: 0.48 - 0.36 * progress, blue: 0.96 - 0.4 * progress, alpha: 1)
        let bottom = CGColor(srgbRed: 0.98 - 0.5 * progress, green: 0.72 - 0.5 * progress, blue: 0.5 - 0.1 * progress, alpha: 1)
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [bottom, top] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: h), options: [])

        // The ball crosses in an arc.
        let x = 40 + (w - 80) * progress
        let y = 40 + sin(progress * .pi) * 100
        context.setFillColor(CGColor(srgbRed: 1, green: 0.86, blue: 0.3, alpha: 1))
        context.fillEllipse(in: CGRect(x: x - 22, y: y - 22, width: 44, height: 44))

        // The time, large.
        let text = String(format: "%.1f s", seconds)
        let font = CTFontCreateUIFontForLanguage(.system, 64, nil)!
        let bold = CTFontCreateCopyWithSymbolicTraits(font, 64, nil, .traitBold, .traitBold) ?? font
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): bold,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 0.95),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.textPosition = CGPoint(x: (w - bounds.width) / 2 - bounds.minX, y: h - 96)
        CTLineDraw(line, context)

        // How far through, along the bottom.
        context.setFillColor(CGColor(gray: 1, alpha: 0.3))
        context.fill(CGRect(x: 0, y: 0, width: w, height: 8))
        context.setFillColor(CGColor(gray: 1, alpha: 0.95))
        context.fill(CGRect(x: 0, y: 0, width: w * progress, height: 8))
    }
}
