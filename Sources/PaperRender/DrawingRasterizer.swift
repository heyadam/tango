import CoreGraphics
import CoreText
import Foundation
import PaperEngine
import PaperModel

/// Turns what an extension's view drew into a picture. The steps are in the view's
/// points with y down, as a script writes them; the picture has its first row at the top.
enum DrawingRasterizer {
    /// The most pixels a picture may have on a side.
    static let largestSide = 8192
    /// How long one picture may take to make. A script is stopped when it runs too long;
    /// what it asked to have drawn is held to the same, and is cut short where time ran out.
    static let timeLimit = 0.25

    static func image(_ drawing: Drawing, size: CGSize, scale: CGFloat, images: @escaping (String) -> CGImage?) -> CGImage? {
        // A view's size can be anything a cable or a document gives it. It is checked as
        // the number it is: making a whole number of one that is too large stops the app.
        let wide = (size.width * scale).rounded(.up), high = (size.height * scale).rounded(.up)
        guard wide.isFinite, high.isFinite, wide >= 1, high >= 1,
              wide <= Double(largestSide), high <= Double(largestSide) else { return nil }
        let width = Int(wide), height = Int(high)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        // From here on y grows downward, and one unit is a point.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        var painter = Painter(context: context, scale: scale, images: images)
        let started = Date()
        for command in drawing.commands {
            painter.run(command)
            if Date().timeIntervalSince(started) >= timeLimit { break }
        }
        return context.makeImage()
    }

    /// Replays the steps. The current path is kept here, in the picture's own points: a
    /// point is placed by the transform in force when it was added, as on a canvas.
    private struct Painter {
        let context: CGContext
        let scale: CGFloat
        let images: (String) -> CGImage?
        var path = CGMutablePath()
        /// What the script's translate, scale and rotate have added up to.
        var transform = CGAffineTransform.identity
        var saved: [CGAffineTransform] = []

        mutating func run(_ command: DrawCommand) {
            switch command {
            case .save:
                context.saveGState()
                saved.append(transform)
            case .restore:
                guard let before = saved.popLast() else { return }
                context.restoreGState()
                transform = before
            case let .translate(x, y): concatenate(CGAffineTransform(translationX: x, y: y))
            case let .scale(x, y): concatenate(CGAffineTransform(scaleX: x, y: y))
            case let .rotate(angle): concatenate(CGAffineTransform(rotationAngle: angle))
            case .beginPath: path = CGMutablePath()
            case let .move(x, y): path.move(to: CGPoint(x: x, y: y), transform: transform)
            case let .line(x, y):
                if path.isEmpty { path.move(to: CGPoint(x: x, y: y), transform: transform) }
                else { path.addLine(to: CGPoint(x: x, y: y), transform: transform) }
            case let .quad(cx, cy, x, y):
                if path.isEmpty { path.move(to: CGPoint(x: cx, y: cy), transform: transform) }
                path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: cx, y: cy), transform: transform)
            case let .curve(ax, ay, bx, by, x, y):
                if path.isEmpty { path.move(to: CGPoint(x: ax, y: ay), transform: transform) }
                path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: ax, y: ay), control2: CGPoint(x: bx, y: by), transform: transform)
            case let .arc(x, y, radius, start, end, counterclockwise):
                // With y down, an angle that grows turns clockwise on screen, which is what
                // Core Graphics calls counterclockwise.
                path.addArc(
                    center: CGPoint(x: x, y: y), radius: radius, startAngle: start, endAngle: end,
                    clockwise: counterclockwise, transform: transform
                )
            case let .rect(x, y, w, h): path.addRect(CGRect(x: x, y: y, width: w, height: h).standardized, transform: transform)
            case let .roundRect(x, y, w, h, radius): path.addPath(rounded(x, y, w, h, radius), transform: transform)
            case let .ellipse(x, y, rx, ry):
                path.addEllipse(in: CGRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2), transform: transform)
            case .close: if !path.isEmpty { path.closeSubpath() }
            case let .fill(style): fill(path, style, placed: true)
            case let .stroke(style, line): stroke(path, style, line, placed: true)
            case .clip:
                guard !path.isEmpty else { return }
                inBaseSpace {
                    context.addPath(path)
                    context.clip()
                }
            case let .fillRect(x, y, w, h, style):
                fill(CGPath(rect: CGRect(x: x, y: y, width: w, height: h).standardized, transform: nil), style, placed: false)
            case let .strokeRect(x, y, w, h, style, line):
                stroke(CGPath(rect: CGRect(x: x, y: y, width: w, height: h).standardized, transform: nil), style, line, placed: false)
            case let .clearRect(x, y, w, h):
                context.clear(CGRect(x: x, y: y, width: w, height: h).standardized)
            case let .text(text, x, y, style, font): draw(text, x, y, style, font)
            case let .image(name, x, y, w, h, alpha):
                guard let image = images(name), w != 0, h != 0 else { return }
                context.saveGState()
                context.setAlpha(alpha)
                // A picture is drawn the right way up in a space where y is down.
                context.translateBy(x: x, y: y + h)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                context.restoreGState()
            }
        }

        private mutating func concatenate(_ change: CGAffineTransform) {
            guard change.a.isFinite, change.d.isFinite else { return }
            context.concatenate(change)
            transform = change.concatenating(transform)
        }

        private func rounded(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ radius: Double) -> CGPath {
            let rect = CGRect(x: x, y: y, width: w, height: h).standardized
            let corner = min(radius, rect.width / 2, rect.height / 2)
            guard corner > 0 else { return CGPath(rect: rect, transform: nil) }
            return CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
        }

        /// Runs `body` with the picture's own points in force, where the kept path is.
        private func inBaseSpace(_ body: () -> Void) {
            guard abs(transform.a * transform.d - transform.b * transform.c) > 1e-12 else { return }
            context.concatenate(transform.inverted())
            body()
            context.concatenate(transform)
        }

        private func apply(_ style: DrawCommand.Style) {
            context.setAlpha(style.alpha)
            if let shadow = style.shadow {
                // A shadow's offset is in the picture's pixels, where y still grows upward.
                context.setShadow(
                    offset: CGSize(width: shadow.offset.x * scale, height: -shadow.offset.y * scale),
                    blur: shadow.blur * scale, color: shadow.color.cgColor
                )
            } else {
                context.setShadow(offset: .zero, blur: 0, color: nil)
            }
        }

        /// `placed` says the path is already in the picture's points (the kept path);
        /// otherwise it is in the script's, as a rectangle given in one call is.
        private func fill(_ shape: CGPath, _ style: DrawCommand.Style, placed: Bool) {
            guard !shape.isEmpty else { return }
            context.saveGState()
            apply(style)
            let paint = { paint(shape, style.paint, placed: placed) }
            if placed { inBaseSpace(paint) } else { paint() }
            context.restoreGState()
        }

        private func stroke(_ shape: CGPath, _ style: DrawCommand.Style, _ line: DrawCommand.Line, placed: Bool) {
            guard !shape.isEmpty, line.width > 0 else { return }
            // The width is in the script's points; the kept path is in the picture's.
            let grown = placed ? sqrt(abs(transform.a * transform.d - transform.b * transform.c)) : 1
            let cap: CGLineCap = line.cap == "round" ? .round : line.cap == "square" ? .square : .butt
            let join: CGLineJoin = line.join == "round" ? .round : line.join == "bevel" ? .bevel : .miter
            var outline = shape
            if !line.dash.isEmpty, line.dash.contains(where: { $0 > 0 }) {
                outline = outline.copy(dashingWithPhase: 0, lengths: line.dash.map { CGFloat($0) * grown })
            }
            outline = outline.copy(strokingWithWidth: line.width * grown, lineCap: cap, lineJoin: join, miterLimit: 10)
            fill(outline, style, placed: placed)
        }

        private func paint(_ shape: CGPath, _ paint: DrawCommand.Paint, placed: Bool) {
            switch paint {
            case let .color(color):
                context.setFillColor(color.cgColor)
                context.addPath(shape)
                context.fillPath()
            case let .linear(from, to, stops):
                gradient(stops, in: shape, placed: placed) { gradient in
                    context.drawLinearGradient(
                        gradient, start: CGPoint(x: from.x, y: from.y), end: CGPoint(x: to.x, y: to.y),
                        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                    )
                }
            case let .radial(from, radius, to, toRadius, stops):
                gradient(stops, in: shape, placed: placed) { gradient in
                    context.drawRadialGradient(
                        gradient, startCenter: CGPoint(x: from.x, y: from.y), startRadius: radius,
                        endCenter: CGPoint(x: to.x, y: to.y), endRadius: toRadius,
                        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                    )
                }
            }
        }

        /// A gradient fills a shape by being drawn through it. It is given in the
        /// script's points, so for a shape that is in the picture's (`placed`) the
        /// script's transform is put back while it is drawn.
        private func gradient(_ stops: [DrawCommand.Stop], in shape: CGPath, placed: Bool, draw: (CGGradient) -> Void) {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let gradient = CGGradient(
                    colorsSpace: space, colors: stops.map(\.color.cgColor) as CFArray, locations: stops.map { CGFloat($0.at) }
                  ) else { return }
            // One layer, so a shadow is cast by the whole shape and not by each band.
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.addPath(shape)
            context.clip()
            if placed { context.concatenate(transform) }
            draw(gradient)
            context.endTransparencyLayer()
        }

        private func draw(_ text: String, _ x: Double, _ y: Double, _ style: DrawCommand.Style, _ font: DrawCommand.Font) {
            guard !text.isEmpty else { return }
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): TextMeasurer.font(size: font.size, weight: font.weight),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): style.paint.flat.cgColor,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            var origin = CGPoint(x: x, y: y)
            switch font.align {
            case "center": origin.x -= width / 2
            case "right", "end": origin.x -= width
            default: break
            }
            switch font.baseline {
            case "top", "hanging": origin.y += ascent
            case "middle": origin.y += (ascent - descent) / 2
            case "bottom", "ideographic": origin.y -= descent
            default: break
            }
            context.saveGState()
            apply(style)
            // Glyphs are drawn for a space where y is up, so they are turned over here.
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = origin
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }
}
