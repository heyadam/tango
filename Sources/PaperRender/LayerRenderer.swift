import CoreImage
import CoreText
import Foundation
import PaperEngine
import PaperModel
import QuartzCore

#if canImport(AppKit)
import AppKit
typealias PlatformFont = NSFont
#else
import UIKit
typealias PlatformFont = UIFont
#endif

/// Draws a resolved layer tree with Core Animation.
///
/// The renderer keeps one `CALayer` per document layer and updates it in place each frame.
/// It is used both by the Canvas (static document values) and the Viewer (live values).
public final class LayerRenderer {
    /// Add this to a host layer and give it the host's bounds. Its coordinate space is
    /// y-down, matching the document.
    public let rootLayer = CALayer()
    /// Holds the screen. Moved and scaled by `setViewport`.
    private let contentLayer = CALayer()
    /// A loop can show one document layer several times; each repetition has its own CALayer.
    private struct Key: Hashable {
        let id: LayerID
        let instance: Int
    }

    private var layers: [Key: CALayer] = [:]
    private var kinds: [Key: LayerKind] = [:]
    /// For a view that clips its content and also casts a shadow: the layer inside it that
    /// does the clipping. Clipping the view's own layer would cut the shadow off too.
    private var clippers: [Key: CALayer] = [:]
    /// For a shader view: the pictures it is drawn through. The views inside it are not on
    /// screen themselves; they are drawn into a picture the shader reads.
    private var surfaces: [Key: ShaderSurface] = [:]
    /// For views that extensions draw: the layer showing the drawing, and which drawing
    /// at what size it shows, so a picture is made again only when one of them changed.
    private var drawings: [Key: (layer: CALayer, stamp: Int, size: CGSize, scale: CGFloat)] = [:]
    /// For video views: the layer showing the picture, a glyph for when there is none,
    /// what the view plays and, in a Viewer that plays video, its player.
    private final class VideoEntry {
        let picture = CALayer()
        let glyph = CALayer()
        var source = ""
        var player: VideoPlayer?

        init() {
            picture.masksToBounds = true
            glyph.contentsGravity = .center
            picture.addSublayer(glyph)
        }
    }

    private var videos: [Key: VideoEntry] = [:]
    /// For views that blur what is behind them: the layer under the view's children that
    /// shows the blurred picture with the view's fill over it.
    private var backdrops: [Key: CALayer] = [:]
    /// The blurring views of the tree being rendered, back to front, so that one in front
    /// of another sees the other's material behind it.
    private var pendingBackdrops: [(view: CALayer, backdrop: CALayer, radius: CGFloat)] = []
    private static let blurContext = CIContext(options: [.cacheIntermediates: false])
    /// The shader views of the tree being rendered, innermost first, so that one inside
    /// another is drawn before the outer one reads it.
    private var pendingShaders: [(surface: ShaderSurface, shader: ResolvedShader, size: CGSize, view: CALayer)] = []
    /// How far past a shader view the picture of what is behind it reaches, so glass can
    /// bend what is beside it into view.
    static let behindMargin: CGFloat = 32

    /// Pixels per point for text and shapes; set to backing scale × zoom.
    public var contentsScale: CGFloat = 2
    /// Looks up image data for image layers by asset name.
    public var imageProvider: ((String) -> CGImage?)?
    /// Supplies the live picture for Camera views. Without one they show a placeholder.
    public var cameraLayerProvider: (() -> CALayer?)?
    /// Finds the file or web address a Video view's `video` names. Without one, or for a
    /// name it does not know, the view shows a placeholder.
    public var videoURL: ((String) -> URL?)?
    /// Whether videos are played, with sound, as in the Viewer. Otherwise each frame shows
    /// the picture at the playhead, made at once from the file, and a video from the web
    /// shows a placeholder: pictures made this way are the same every time and never
    /// reach the network.
    public var playsVideo = false {
        didSet {
            guard playsVideo != oldValue else { return }
            for entry in videos.values {
                entry.player?.stop()
                entry.player = nil
            }
        }
    }
    /// Told how long a video is once that is known, by its `video` value: the runtime
    /// needs it to loop or stop at the end.
    public var onVideoDuration: ((String, Double) -> Void)?
    /// Called when the video a `video` value names cannot be played.
    public var onVideoFailure: ((String) -> Void)?

    /// Whether the root is flipped to make its coordinates y-down. A view's layer is y-up
    /// on the Mac and already y-down on iOS.
    #if canImport(AppKit)
    static let flipsRoot = true
    #else
    static let flipsRoot = false
    #endif

    public init() {
        rootLayer.isGeometryFlipped = Self.flipsRoot
        rootLayer.masksToBounds = true
        contentLayer.anchorPoint = .zero
        rootLayer.addSublayer(contentLayer)
    }

    /// Places the screen's top-left at `offset` (in root coordinates, y-down) at `scale`.
    public func setViewport(scale: CGFloat, offset: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.position = offset
        contentLayer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        CATransaction.commit()
    }

    public func render(_ tree: ResolvedLayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var seen: Set<Key> = []
        let screen = sync(tree, seen: &seen)
        if contentLayer.sublayers?.first !== screen || contentLayer.sublayers?.count != 1 {
            contentLayer.sublayers = [screen]
        }
        for key in layers.keys where !seen.contains(key) {
            layers[key] = nil
            kinds[key] = nil
            clippers[key] = nil
            surfaces[key] = nil
            drawings[key] = nil
            backdrops[key] = nil
            videos.removeValue(forKey: key)?.player?.stop()
        }
        CATransaction.commit()
        let shaders = pendingShaders
        pendingShaders = []
        // What only reads the views inside it is drawn first, innermost first. Then, back to
        // front, whatever reads what is behind it: blurring views, and shaders that ask.
        var glass: [(surface: ShaderSurface, shader: ResolvedShader, size: CGSize, view: CALayer)] = []
        for item in shaders {
            if ShaderSource.interface(of: item.shader.source).readsBehind { glass.append(item) } else {
                item.surface.draw(item.shader, size: item.size, scale: contentsScale)
            }
        }
        let blurred = pendingBackdrops
        pendingBackdrops = []
        for item in blurred { drawBackdrop(item.backdrop, behind: item.view, radius: item.radius) }
        // Sync visits a view before the views in it, so the reverse of innermost first is back to front.
        for item in glass.reversed() {
            let scale = min(max(contentsScale.isFinite ? contentsScale : 1, 0.25), 2)
            let texture = picture(behind: item.view, margin: LayerRenderer.behindMargin, scale: scale).flatMap { taken in
                ShaderCompiler.shared?.texture(from: taken.context)
            }
            item.surface.draw(item.shader, size: item.size, scale: contentsScale, behind: texture, margin: LayerRenderer.behindMargin)
        }
    }

    // MARK: What is behind a view

    /// A picture of what is drawn before `view` in a place of the root, with the view and
    /// everything painted after it left out: the views after it, and the views after each
    /// of the views it is in. Made the way snapshots are, so it is the same with no window.
    /// The picture is the other way up from the tree, row for row.
    private func picture(of place: CGRect, without view: CALayer, scale: CGFloat) -> (context: CGContext, place: CGRect)? {
        let width = (place.width * scale).rounded(.up), height = (place.height * scale).rounded(.up)
        guard width.isFinite, height.isFinite, width >= 1, height >= 1, width <= 4096, height <= 4096,
              let context = CGContext(
                  data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: Int(width) * 4,
                  space: ShaderSurface.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        var hidden: [CALayer] = []
        var current = view
        var includesItself = true
        while current !== rootLayer, let parent = current.superlayer {
            let siblings = parent.sublayers ?? []
            if let index = siblings.firstIndex(where: { $0 === current }) {
                for sibling in siblings[(includesItself ? index : index + 1)...] where !sibling.isHidden {
                    sibling.isHidden = true
                    hidden.append(sibling)
                }
            }
            includesItself = false
            current = parent
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The root is drawn top down into the bitmap, so its own coordinates place the picture.
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -place.minX, y: -place.minY)
        rootLayer.render(in: context)
        for layer in hidden { layer.isHidden = false }
        CATransaction.commit()
        return (context, place)
    }

    /// What is behind a view where it stands and `margin` of its own points around it, off
    /// the screen included.
    private func picture(behind view: CALayer, margin: CGFloat, scale: CGFloat) -> (context: CGContext, place: CGRect)? {
        guard isOnScreen(view) else { return nil }
        let reach = margin * zoom(of: view)
        return picture(of: view.convert(view.bounds, to: rootLayer).insetBy(dx: -reach, dy: -reach), without: view, scale: scale)
    }

    /// How large one of a view's points is in the root: the Viewer's or the Canvas's zoom.
    private func zoom(of view: CALayer) -> CGFloat {
        let width = view.bounds.width
        guard width > 0 else { return 1 }
        let shown = view.convert(view.bounds, to: rootLayer).width / width
        return shown.isFinite && shown > 0 ? shown : 1
    }

    /// Whether a layer is in the tree that is on screen. The views in a shader view are
    /// not: they are drawn into a picture of their own, with nothing behind them to read.
    private func isOnScreen(_ view: CALayer) -> Bool {
        var current: CALayer? = view
        while let layer = current {
            if layer === rootLayer { return true }
            current = layer.superlayer
        }
        return false
    }

    // MARK: Background blur

    /// The layer that shows what is behind a view, blurred. It is filled in `drawBackdrop`,
    /// once the whole tree is where it belongs.
    private func backdrop(for key: Key, in layer: CALayer, node: ResolvedLayer, radius: CGFloat) -> CALayer {
        let back = backdrops[key] ?? CALayer()
        if backdrops[key] == nil {
            back.masksToBounds = true
            // The blurred picture, and over it the view's fill.
            let picture = CALayer(), tint = CALayer()
            picture.contentsGravity = .resize
            // The tree is drawn top down, and a picture taken of it is the other way up.
            picture.setAffineTransform(CGAffineTransform(scaleX: 1, y: -1))
            back.sublayers = [picture, tint]
            backdrops[key] = back
        }
        back.frame = layer.bounds
        back.cornerRadius = layer.cornerRadius
        back.cornerCurve = layer.cornerCurve
        // The fill goes over the picture, so the view's own layer has none.
        let fill = node.value(.fill).colorValue.cgColor
        back.sublayers?.last?.frame = back.bounds
        back.sublayers?.last?.backgroundColor = fill
        layer.backgroundColor = nil
        pendingBackdrops.append((layer, back, radius))
        return back
    }

    /// Takes a picture of what is drawn before `view` where it stands, blurs it, lays the
    /// view's fill over it and gives it to `back`. The picture is made the way snapshots
    /// are, so it is the same in a window, in a recording and with no window at all.
    private func drawBackdrop(_ back: CALayer, behind view: CALayer, radius: CGFloat) {
        // The radius is in the prototype's points; on screen it is as much larger as the view is.
        let radius = radius * zoom(of: view)
        let area = isOnScreen(view) ? view.convert(view.bounds, to: rootLayer).intersection(rootLayer.bounds) : .zero
        // Half the pixels are plenty for something blurred, and a quarter of the work.
        let scale = min(max(contentsScale.isFinite ? contentsScale : 1, 0.25), 1) * (radius >= 4 ? 0.5 : 1)
        let margin = (radius * 2).rounded(.up)
        guard radius.isFinite, area.width >= 1, area.height >= 1,
              let taken = picture(of: area.insetBy(dx: -margin, dy: -margin), without: view, scale: scale) else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            back.sublayers?.first?.contents = nil
            CATransaction.commit()
            return
        }
        let context = taken.context
        let width = CGFloat(context.width), height = CGFloat(context.height)

        guard let picture = context.makeImage() else { return }
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let inner = CGRect(x: margin * scale, y: margin * scale, width: area.width * scale, height: area.height * scale)
        let soft = CIImage(cgImage: picture).clampedToExtent()
            .applyingGaussianBlur(sigma: Double(radius * scale) / 2)
            .cropped(to: extent)
        let image = LayerRenderer.blurContext.createCGImage(soft, from: inner, format: .RGBA8, colorSpace: ShaderSurface.colorSpace)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The view may reach past the screen: the picture covers the part that is on it.
        back.sublayers?.first?.frame = rootLayer.convert(area, to: view)
        back.sublayers?.first?.contents = image
        CATransaction.commit()
    }

    /// The Core Animation layer currently showing a document layer.
    public func layer(for id: LayerID, instance: Int = 0) -> CALayer? { layers[Key(id: id, instance: instance)] }

    // MARK: Reconciliation

    private func makeLayer(for kind: LayerKind) -> CALayer {
        switch kind {
        case .ellipse:
            return CAShapeLayer()
        case .text:
            let text = CATextLayer()
            text.isWrapped = true
            text.alignmentMode = .left
            text.truncationMode = .none
            return text
        default:
            return CALayer()
        }
    }

    private func sync(_ node: ResolvedLayer, seen: inout Set<Key>) -> CALayer {
        let key = Key(id: node.id, instance: node.instance)
        seen.insert(key)
        let layer: CALayer
        let surface = node.kind == .view && node.shader != nil ? surfaces[key] ?? ShaderCompiler.shared.map(ShaderSurface.init) : nil
        if let existing = layers[key], kinds[key] == node.kind, (surfaces[key] == nil) == (surface == nil) {
            layer = existing
        } else {
            layer = makeLayer(for: node.kind)
            layers[key] = layer
            kinds[key] = node.kind
        }

        surfaces[key] = surface
        apply(node, to: layer)

        if let surface, let shader = node.shader {
            // The view's fill and the views in it go into a picture; the layer on screen
            // shows what the shader makes of it, and keeps the corners, border and shadow.
            clippers[key] = nil
            let children = node.children.map { sync($0, seen: &seen) }
            let current = surface.content.sublayers ?? []
            if current.count != children.count || !zip(current, children).allSatisfy({ $0 === $1 }) {
                surface.content.sublayers = children
            }
            surface.content.backgroundColor = node.value(.fill).colorValue.cgColor
            surface.display.bounds = layer.bounds
            surface.display.position = .zero
            surface.display.cornerRadius = layer.cornerRadius
            if layer.sublayers?.first !== surface.display || layer.sublayers?.count != 1 { layer.sublayers = [surface.display] }
            layer.backgroundColor = nil
            layer.masksToBounds = false
            pendingShaders.append((surface, shader, layer.bounds.size, layer))
            return layer
        }

        // A Camera view's only sublayer is the live camera picture, managed in `apply`.
        // A text field's sublayers are its text and caret, managed there too.
        if node.kind == .camera || node.kind == .textField { return layer }
        if node.kind == .video {
            showVideo(node, key: key, in: layer)
            return layer
        }
        var children = node.children.map { sync($0, seen: &seen) }
        // What an extension drew goes under the views inside the view.
        if let drawing = node.drawing {
            children.insert(drawn(drawing, for: key, in: layer), at: 0)
        } else {
            drawings[key] = nil
        }
        // And under that, what is behind the view, blurred, when it asks for it.
        let blur = node.kind == .view ? CGFloat(node.value(.backgroundBlur).numberValue) : 0
        if blur.isFinite, blur > 0 {
            children.insert(backdrop(for: key, in: layer, node: node, radius: min(blur, 100)), at: 0)
        } else {
            backdrops[key] = nil
        }
        let host = contentHost(of: node, key: key, in: layer)
        let current = host.sublayers ?? []
        if current.count != children.count || !zip(current, children).allSatisfy({ $0 === $1 }) {
            host.sublayers = children
        }
        return layer
    }

    /// The layer that shows a drawing, with its picture made again if the drawing, the
    /// view's size or the scale changed.
    private func drawn(_ drawing: Drawing, for key: Key, in layer: CALayer) -> CALayer {
        let size = layer.bounds.size
        var entry = drawings[key] ?? (CALayer(), -1, .zero, 0)
        if entry.stamp != drawing.stamp || entry.size != size || entry.scale != contentsScale {
            let provider = imageProvider
            entry.layer.contents = DrawingRasterizer.image(drawing, size: size, scale: contentsScale) { provider?($0) }
            entry.layer.contentsScale = contentsScale
            entry.layer.contentsGravity = .resize
            entry.layer.masksToBounds = true
            entry.stamp = drawing.stamp
            entry.size = size
            entry.scale = contentsScale
        }
        entry.layer.frame = CGRect(origin: .zero, size: size)
        entry.layer.cornerRadius = layer.cornerRadius
        entry.layer.cornerCurve = layer.cornerCurve
        drawings[key] = entry
        return entry.layer
    }

    /// The layer a view's children go in: the view's own, or the clipping layer inside it
    /// when the view both clips and casts a shadow.
    private func contentHost(of node: ResolvedLayer, key: Key, in layer: CALayer) -> CALayer {
        guard node.kind == .view, node.clips, node.value(.shadowRadius).numberValue > 0 else {
            if let clipper = clippers.removeValue(forKey: key) {
                clipper.sublayers = nil
                clipper.removeFromSuperlayer()
            }
            return layer
        }
        let clipper = clippers[key] ?? CALayer()
        if clippers[key] == nil {
            clipper.masksToBounds = true
            clipper.cornerCurve = .continuous
            clippers[key] = clipper
            layer.sublayers = [clipper]
        }
        clipper.frame = layer.bounds
        clipper.cornerRadius = layer.cornerRadius
        return clipper
    }

    private func apply(_ node: ResolvedLayer, to layer: CALayer) {
        // Core Animation stops the app when handed a number that is not one. A patch can
        // produce such a number (a division by zero in a script), so they end here.
        func finite(_ value: Double, or fallback: Double = 0) -> Double { value.isFinite ? value : fallback }
        let size = node.size
        let origin = node.origin
        let width = max(finite(size.width), 0)
        let height = max(finite(size.height), 0)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)

        layer.bounds = bounds
        layer.position = CGPoint(x: finite(origin.x) + width / 2, y: finite(origin.y) + height / 2)
        let scale = finite(node.scale, or: 1)
        layer.setAffineTransform(
            CGAffineTransform(rotationAngle: finite(node.rotation) * .pi / 180).scaledBy(x: scale, y: scale)
        )
        layer.opacity = Float(min(max(finite(node.opacity, or: 1), 0), 1))
        if layer.contentsScale != contentsScale {
            layer.contentsScale = contentsScale
            // Text keeps the picture it made at the old density, and inside a shader view,
            // which is drawn off screen, nothing makes it draw another: on iOS it then
            // shows twice, at two sizes. So it is drawn again here, at once.
            if layer is CATextLayer {
                layer.contents = nil
                layer.setNeedsDisplay()
                layer.displayIfNeeded()
            }
        }

        let cornerRadius = max(min(node.value(.cornerRadius).numberValue, min(width, height) / 2), 0)

        switch node.kind {
        case .screen:
            layer.backgroundColor = node.value(.fill).colorValue.cgColor
            layer.cornerRadius = cornerRadius
            layer.cornerCurve = .continuous
            layer.masksToBounds = true

        case .camera:
            layer.backgroundColor = ColorValue(white: 0.12).cgColor
            layer.cornerRadius = cornerRadius
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
            if let live = cameraLayerProvider?() {
                if live.superlayer !== layer {
                    live.removeFromSuperlayer()
                    layer.sublayers = [live]
                }
                live.frame = bounds
            } else {
                // No camera here (the Canvas, or a player without one): a camera glyph.
                layer.sublayers = nil
                layer.contentsGravity = .center
                layer.contents = symbolImage("camera.fill", weight: 400, color: ColorValue(white: 0.45), height: min(height * 0.25, 44))
                layer.contentsScale = contentsScale
            }

        case .video:
            // The picture is a sublayer, managed in `showVideo`; around it, the fill.
            layer.backgroundColor = node.value(.fill).colorValue.cgColor
            layer.cornerRadius = cornerRadius
            layer.cornerCurve = .continuous
            layer.masksToBounds = true

        case .component:
            // Only seen when the component's definition is missing.
            layer.backgroundColor = ColorValue(white: 0.5, alpha: 0.2).cgColor

        case .symbol:
            layer.contentsGravity = .resizeAspect
            layer.contents = iconImage(
                node.value(.symbol).textValue,
                weight: node.value(.fontWeight).numberValue,
                color: node.value(.fill).colorValue,
                width: width,
                height: height
            )

        case .view:
            layer.backgroundColor = node.value(.fill).colorValue.cgColor
            layer.cornerRadius = cornerRadius
            layer.cornerCurve = .continuous
            layer.borderWidth = max(node.value(.strokeWidth).numberValue, 0)
            layer.borderColor = node.value(.strokeColor).colorValue.cgColor
            applyShadow(node, to: layer, path: CGPath(
                roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil
            ))
            // A shadow lies outside the bounds, so a view with one clips in `contentHost`.
            layer.masksToBounds = node.clips && layer.shadowOpacity == 0

        case .ellipse:
            guard let shape = layer as? CAShapeLayer else { break }
            let path = CGPath(ellipseIn: bounds, transform: nil)
            shape.path = path
            shape.fillColor = node.value(.fill).colorValue.cgColor
            let stroke = max(node.value(.strokeWidth).numberValue, 0)
            shape.lineWidth = stroke
            shape.strokeColor = stroke > 0 ? node.value(.strokeColor).colorValue.cgColor : nil
            applyShadow(node, to: layer, path: path)

        case .text:
            guard let text = layer as? CATextLayer else { break }
            let fontSize = max(node.value(.fontSize).numberValue, 1)
            text.string = node.value(.text).textValue
            text.font = font(of: node, size: fontSize)
            text.fontSize = fontSize
            text.foregroundColor = node.value(.textColor).colorValue.cgColor
            let singleLine = node.value(.singleLine).boolValue
            text.isWrapped = !singleLine
            // Text that sizes itself to its content always fits, so it is never cut short.
            text.truncationMode = singleLine && node.value(.widthMode).textValue != "Auto" ? .end : .none
            switch node.value(.textAlignment).textValue {
            case "Center": text.alignmentMode = .center
            case "Right": text.alignmentMode = .right
            default: text.alignmentMode = .left
            }

        case .textField:
            layer.backgroundColor = node.value(.fill).colorValue.cgColor
            layer.cornerRadius = cornerRadius
            layer.cornerCurve = .continuous
            layer.borderWidth = max(node.value(.strokeWidth).numberValue, 0)
            layer.borderColor = node.value(.strokeColor).colorValue.cgColor
            applyField(node, to: layer, width: width, height: height)

        case .image:
            let name = node.value(.image).textValue
            layer.contents = name.isEmpty ? nil : imageProvider?(name)
            // Gray says there is no picture. One that is on its way (a fetched photo, a
            // picture an AI patch makes) leaves what is behind it showing, such as the
            // photo's color; a missing asset is still gray.
            let pending = name.hasPrefix("fetched:") || name.hasPrefix("ai:") || name.hasPrefix("capture:")
            layer.backgroundColor = layer.contents == nil && !pending ? ColorValue(white: 0.9).cgColor : nil
            layer.contentsGravity = .resizeAspectFill
            layer.cornerRadius = cornerRadius
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
        }
    }

    /// A Video view shows the frame at its playhead: from its player while one plays it,
    /// and otherwise a picture made from the file at that very time.
    private func showVideo(_ node: ResolvedLayer, key: Key, in layer: CALayer) {
        let entry = videos[key] ?? VideoEntry()
        videos[key] = entry
        if layer.sublayers?.first !== entry.picture || layer.sublayers?.count != 1 { layer.sublayers = [entry.picture] }
        let bounds = layer.bounds
        entry.picture.frame = bounds
        entry.picture.cornerRadius = layer.cornerRadius
        entry.picture.cornerCurve = .continuous
        entry.picture.contentsGravity = node.value(.contentMode).textValue == "Fit" ? .resizeAspect : .resizeAspectFill
        if entry.glyph.contents == nil || entry.glyph.bounds.size != bounds.size || entry.glyph.contentsScale != contentsScale {
            entry.glyph.contentsScale = contentsScale
            entry.glyph.contents = symbolImage("play.rectangle.fill", weight: 400, color: ColorValue(white: 0.5), height: min(bounds.height * 0.25, 44))
        }
        entry.glyph.frame = bounds

        let source = node.value(.video).textValue
        let stored = node.value(.time).numberValue
        let time = node.playhead?.time ?? (stored.isFinite ? max(stored, 0) : 0)
        let moving = node.playhead?.isPlaying ?? false
        if source != entry.source {
            entry.player?.stop()
            entry.player = nil
            entry.source = source
            entry.picture.contents = nil
        }
        guard !source.isEmpty, let url = videoURL?(source) else {
            if !source.isEmpty { onVideoFailure?(source) }
            entry.picture.contents = nil
            entry.glyph.isHidden = false
            return
        }
        // The same name can come to mean another file (a movie chosen again in the Inspector).
        if let player = entry.player, player.url != url {
            player.stop()
            entry.player = nil
        }

        if playsVideo {
            let player = entry.player ?? {
                let made = VideoPlayer(url: url)
                made.picture = entry.picture
                made.glyph = entry.glyph
                made.onDuration = { [weak self] in self?.onVideoDuration?(source, $0) }
                made.onFailure = { [weak self] in self?.onVideoFailure?(source) }
                entry.player = made
                return made
            }()
            player.follow(
                time: time, playing: moving, rate: node.value(.playbackRate).numberValue,
                muted: node.value(.muted).boolValue, volume: node.value(.volume).numberValue
            )
            // A file at rest shows its exact frame at once; the player catches up behind it.
            if !moving, url.isFileURL, let still = VideoStills.shared.picture(of: url, at: time) {
                entry.picture.contents = still
                entry.glyph.isHidden = true
            }
            return
        }

        if url.isFileURL, VideoStills.shared.duration(of: url) == nil {
            onVideoFailure?(source)
        }
        if url.isFileURL, let still = VideoStills.shared.picture(of: url, at: time) {
            if let seconds = VideoStills.shared.duration(of: url) { onVideoDuration?(source, seconds) }
            entry.picture.contents = still
            entry.glyph.isHidden = true
        } else {
            entry.picture.contents = nil
            entry.glyph.isHidden = false
        }
    }

    /// The tint of the caret in a text field being typed in.
    public static let caretColor = ColorValue(red: 0, green: 0.478, blue: 1)

    /// A text field is a clipped line of text (or its placeholder) and, while it is being
    /// typed in, a blinking caret after the text. The blink is a Core Animation animation,
    /// so it costs the prototype no frames.
    private func applyField(_ node: ResolvedLayer, to layer: CALayer, width: Double, height: Double) {
        let clip: CALayer
        let text: CATextLayer
        let caret: CALayer
        if let parts = layer.sublayers, parts.count == 2, let existing = parts[0].sublayers?.first as? CATextLayer {
            clip = parts[0]
            text = existing
            caret = parts[1]
        } else {
            clip = CALayer()
            clip.masksToBounds = true
            clip.anchorPoint = .zero
            text = CATextLayer()
            text.anchorPoint = .zero
            text.isWrapped = false
            text.truncationMode = .none
            text.alignmentMode = .left
            clip.addSublayer(text)
            caret = CALayer()
            caret.anchorPoint = .zero
            caret.cornerRadius = 1
            layer.sublayers = [clip, caret]
        }

        let fontSize = max(node.value(.fontSize).numberValue, 1)
        let font = font(of: node, size: fontSize) as PlatformFont
        let typed = node.value(.text).textValue
        let shown = typed.isEmpty ? node.value(.placeholder).textValue : typed
        let color = node.value(.textColor).colorValue
        let lineHeight = (font.ascender - font.descender + font.leading).rounded(.up)
        let textWidth = (shown as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        let typedWidth = typed.isEmpty ? 0 : textWidth

        let padding = max(min(node.value(.padding).numberValue, width / 2), 0)
        let available = max(width - padding * 2, 0)
        // Where the text starts inside the padding. Text longer than the field keeps its end,
        // where the typing happens, in view.
        var start = 0.0
        switch node.value(.textAlignment).textValue {
        case "Center": start = (available - textWidth) / 2
        case "Right": start = available - textWidth
        default: break
        }
        if node.isEditing, typedWidth > available - 2 { start = available - typedWidth - 2 }
        if !node.isEditing { start = max(start, 0) }

        clip.bounds = CGRect(x: 0, y: 0, width: available, height: height)
        clip.position = CGPoint(x: padding, y: 0)
        text.contentsScale = contentsScale
        text.string = shown
        text.font = font
        text.fontSize = fontSize
        text.foregroundColor = (typed.isEmpty
            ? ColorValue(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha * 0.3)
            : color).cgColor
        text.truncationMode = node.isEditing ? .none : .end
        text.bounds = CGRect(x: 0, y: 0, width: node.isEditing ? textWidth + 2 : max(min(textWidth + 2, available - start), 0), height: lineHeight)
        text.position = CGPoint(x: start, y: ((height - lineHeight) / 2).rounded())

        caret.isHidden = !node.isEditing
        caret.backgroundColor = Self.caretColor.cgColor
        caret.bounds = CGRect(x: 0, y: 0, width: 2, height: lineHeight)
        let caretStart = typed.isEmpty ? max(start, 0) + (node.value(.textAlignment).textValue == "Center" ? textWidth / 2 : 0) : start + typedWidth
        caret.position = CGPoint(x: padding + min(max(caretStart, 0), available), y: ((height - lineHeight) / 2).rounded())
        if node.isEditing {
            if caret.animation(forKey: "blink") == nil {
                let blink = CAKeyframeAnimation(keyPath: "opacity")
                blink.values = [1, 1, 0, 0]
                blink.keyTimes = [0, 0.55, 0.55, 1]
                blink.calculationMode = .discrete
                blink.duration = 1.1
                blink.repeatCount = .infinity
                caret.add(blink, forKey: "blink")
            }
        } else {
            caret.removeAnimation(forKey: "blink")
        }
    }

    /// The font a text or a text field is set in: the same `FontBook` face layout measured.
    private func font(of node: ResolvedLayer, size: Double) -> CTFont {
        let family = node.value(.fontFamily).textValue
        let weight = node.value(.fontWeight).numberValue, italic = node.value(.italic).boolValue
        if !FontBook.isSystemDesign(family), onFont != nil {
            // Once per face, and again after fonts are registered (one may have failed).
            if reportedGeneration != FontBook.generation {
                reportedFonts.removeAll()
                reportedGeneration = FontBook.generation
            }
            if reportedFonts.insert("\(family)|\(GoogleFonts.weight(weight))|\(italic)").inserted { onFont?(family, weight, italic) }
        }
        return FontBook.font(family: family, size: size, weight: weight, italic: italic)
    }

    /// Hears every family other than the system's that text is set in, with its weight and
    /// slant, before it is set: the host makes sure a Google family is registered (or on its
    /// way) and the editor keeps its file in the document.
    public var onFont: ((String, Double, Bool) -> Void)? {
        didSet { reportedFonts.removeAll() }
    }
    private var reportedFonts: Set<String> = []
    private var reportedGeneration = -1

    /// Hears every face again on the next render: after a fetch failed, say, or when the
    /// document's assets changed.
    public func reportFontsAgain() { reportedFonts.removeAll() }

    /// Finds the glyphs of icon sets that are not shipped (Material Symbols): from the
    /// document's assets, or fetched. Nil, or nil for an icon, draws nothing until it is
    /// there; the host draws again when it arrives.
    public var iconProvider: ((IconName, Double) -> VectorGlyph?)?

    /// What a Symbol view shows: an SF Symbol sized to its height, or an icon of another set
    /// fitted into its frame.
    private func iconImage(_ value: String, weight: Double, color: ColorValue, width: Double, height: Double) -> CGImage? {
        guard let icon = IconName(value) else { return nil }
        if icon.set == .sf { return symbolImage(icon.name, weight: weight, color: color, height: height) }
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { return nil }
        let pixelWidth = Int((width * contentsScale).rounded(.up)), pixelHeight = Int((height * contentsScale).rounded(.up))
        let key = "\(icon.value)|\(weight.whole)|\(color.hex)|\(pixelWidth)x\(pixelHeight)"
        if let cached = symbolCache[key] { return cached }
        let glyph = icon.set == .lucide ? LucideIcons.glyph(icon.name, weight: weight) : iconProvider?(icon, weight)
        guard let glyph, let rendered = glyph.image(width: pixelWidth, height: pixelHeight, color: color.cgColor) else { return nil }
        if symbolCache.count > 400 { symbolCache.removeAll() }
        symbolCache[key] = rendered
        return rendered
    }

    private var symbolCache: [String: CGImage] = [:]

    /// A system symbol drawn in one color, sized to the layer's height.
    private func symbolImage(_ name: String, weight: Double, color: ColorValue, height: Double) -> CGImage? {
        guard height > 0, height <= 4096, !name.isEmpty else { return nil }
        let pixels = Int((height * contentsScale).rounded(.up))
        let key = "\(name)|\(weight.whole)|\(color.hex)|\(pixels)"
        if let cached = symbolCache[key] { return cached }
        #if canImport(AppKit)
        let configuration = NSImage.SymbolConfiguration(pointSize: height * 0.8, weight: fontWeight(weight))
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(cgColor: color.cgColor) ?? .black]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration), image.size.width > 0, image.size.height > 0
        else { return nil }
        let scale = Double(pixels) / max(image.size.height, 1)
        let width = max(Int((image.size.width * scale).rounded(.up)), 1)
        guard let context = CGContext(
            data: nil, width: width, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let rendered = context.makeImage()
        #else
        let configuration = UIImage.SymbolConfiguration(font: .systemFont(ofSize: height * 0.8, weight: fontWeight(weight)))
            .applying(UIImage.SymbolConfiguration(paletteColors: [UIColor(cgColor: color.cgColor)]))
        guard let image = UIImage(systemName: name, withConfiguration: configuration),
              image.size.width > 0, image.size.height > 0
        else { return nil }
        let scale = Double(pixels) / max(image.size.height, 1)
        let width = max(Int((image.size.width * scale).rounded(.up)), 1)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let size = CGSize(width: width, height: pixels)
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
        #endif
        if symbolCache.count > 400 { symbolCache.removeAll() }
        symbolCache[key] = rendered
        return rendered
    }

    private func applyShadow(_ node: ResolvedLayer, to layer: CALayer, path: CGPath) {
        let radius = max(node.value(.shadowRadius).numberValue, 0)
        guard radius > 0 else {
            layer.shadowOpacity = 0
            layer.shadowPath = nil
            return
        }
        let color = node.value(.shadowColor).colorValue
        let offset = node.value(.shadowOffset).pointValue
        layer.shadowColor = ColorValue(red: color.red, green: color.green, blue: color.blue).cgColor
        layer.shadowOpacity = Float(color.alpha)
        layer.shadowRadius = radius
        layer.shadowOffset = CGSize(width: offset.x, height: offset.y)
        layer.shadowPath = path
    }

    private func fontWeight(_ value: Double) -> PlatformFont.Weight {
        switch value {
        case ..<150: .ultraLight
        case ..<250: .thin
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        case ..<750: .bold
        case ..<850: .heavy
        default: .black
        }
    }
}

extension ColorValue {
    public nonisolated var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
