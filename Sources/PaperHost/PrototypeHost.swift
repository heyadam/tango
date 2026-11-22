import CoreGraphics
import CryptoKit
import Foundation
import PaperEngine
import PaperModel
import PaperRender
import QuartzCore

/// A running prototype and everything around it that is not a view: the runtime, the
/// renderer, the pictures it shows and the requests it sends. A view (the player's on a
/// phone) adds `layer` to its own, tells it its bounds, forwards touches and calls `step`
/// from its display link.
public final class PrototypeHost {
    public let runtime: Runtime
    public let renderer = LayerRenderer()
    public let pictures = PictureStore()
    /// Apple's models on this device: the only AI patches that run here.
    public let apple = AppleIntelligence()
    /// Add this to the view's layer. It holds the renderer's root.
    public let layer = CALayer()
    public private(set) var assets: [String: Data]
    public private(set) var registry: PatchRegistry

    /// Called when something happened that needs a frame (an answer arrived, a video's
    /// length became known): a display link that rests should run again.
    public var onWake: (() -> Void)?
    /// What the prototype asked the device to do this frame (a haptic, a sound).
    public var onEffect: ((DeviceEffect) -> Void)?

    private var restartToken: Int
    /// What the screen was last fitted into, and its size then.
    private var fitted: (bounds: CGRect, fills: Bool, backingScale: CGFloat, screen: CGSize)?
    /// The scale and corner the screen is shown at, in the layer's coordinates (y-down).
    public private(set) var scale: CGFloat = 1
    public private(set) var origin = CGPoint.zero

    /// A hash of the kinds of patch and view this build knows. A Mac and a phone whose
    /// hashes differ were built from different versions, and the phone may show a
    /// prototype wrongly.
    public static let kinds: String = {
        let names = PatchRegistry.standard.library.map(\.kind).sorted() + LayerKind.allCases.map(\.rawValue)
            + ["document \(Document.currentVersion)"]
        return SHA256.hash(data: Data(names.joined(separator: "\n").utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }()

    /// What AI patches are told when they ask a cloud model, which needs a key this
    /// device does not have.
    public static let noAI = "Only Apple's on-device models run on this device: choose \(AIRequest.onDevice)."
    /// What Transcribe is told: nothing records here yet.
    public static let noRecording = "Transcribe does not record on this device yet."

    /// The patches a package runs with where no extension is installed: its extensions'
    /// patches keep their ports and cables and run nothing.
    public static func registry(for package: DocumentPackage) -> PatchRegistry {
        PatchRegistry.standard.adding(ExtensionSet([], unavailable: package.carried))
    }

    /// `sendsRequests` off makes a host whose Network Request patches send nothing and
    /// stay loading, for pictures and tests.
    public init(
        package: DocumentPackage, registry: PatchRegistry? = nil, sendsRequests: Bool = true,
        startScreen: LayerID? = nil, restartToken: Int = 0
    ) {
        self.restartToken = restartToken
        let registry = registry ?? Self.registry(for: package)
        self.registry = registry
        assets = package.assets
        runtime = Runtime(document: package.document, registry: registry)
        if let startScreen {
            runtime.startPage = startScreen
            runtime.restart()
        }
        layer.masksToBounds = true
        layer.addSublayer(renderer.rootLayer)
        renderer.imageProvider = { [weak self, pictures] name in
            pictures.picture(named: name, assets: self?.assets ?? [:], registry: self?.registry)
        }
        renderer.videoURL = { [weak self] source in VideoFiles.url(for: source, assets: self?.assets ?? [:]) }
        renderer.onVideoDuration = { [weak self] source, seconds in
            guard let self, self.runtime.videoDuration(of: source) != seconds else { return }
            self.runtime.setVideoDuration(seconds, for: source)
            self.onWake?()
        }
        renderer.onVideoFailure = { [weak self] source in
            guard let self, self.runtime.videoDuration(of: source) == nil else { return }
            self.runtime.setVideoUnplayable(source)
            self.onWake?()
        }
        apple.picture = { [weak self, pictures] name in
            pictures.picture(named: name, assets: self?.assets ?? [:], registry: self?.registry)
        }
        apple.deliver = { [weak self] id, update in
            self?.runtime.update(ai: id, update)
            self?.onWake?()
        }
        runtime.aiHandler = { [weak self] request in
            guard sendsRequests, let self else { return }
            if request.phase == .cancel { return self.apple.cancel(request.id) }
            if request.task == .transcription {
                guard request.phase == .startRecording else { return }
                self.runtime.update(ai: request.id, .failed(Self.noRecording))
            } else if request.provider == .apple {
                return self.apple.handle(request)
            } else if request.phase == .send {
                self.runtime.update(ai: request.id, .failed(Self.noAI))
            }
            self.onWake?()
        }
        runtime.requestHandler = { [weak self] request in
            guard sendsRequests else { return }
            let id = request.id
            // A script's request needs its extension, and none runs here.
            guard request.origin == nil else {
                self?.finish(id, NetworkResponse(status: 0, error: "The extension that asked is not installed."))
                return
            }
            PrototypeNetwork.send(request) { [weak self] answer in self?.finish(id, answer) }
        }
        runtime.tick(dt: 0)
        renderer.render(runtime.resolved)
    }

    private func finish(_ id: UUID, _ response: NetworkResponse) {
        runtime.complete(id, with: pictures.settle(response, for: id))
        onWake?()
    }

    // MARK: The document

    /// The document changed, as the Mac's Viewer is told: patches that are still there keep
    /// their state. A new `restartToken` starts the prototype over, on `startScreen`.
    public func update(
        document: Document, assets: [String: Data]? = nil, registry: PatchRegistry? = nil,
        restartToken: Int? = nil, startScreen: LayerID? = nil
    ) {
        if let assets { self.assets = assets }
        // The extensions it carries changed: their patches' ports did too.
        if let registry, registry.extensions != self.registry.extensions {
            self.registry = registry
            runtime.update(registry: registry)
        }
        runtime.update(document: document)
        if let restartToken, restartToken != self.restartToken {
            self.restartToken = restartToken
            runtime.startPage = startScreen
            runtime.restart()
        }
        onWake?()
    }

    public func restart() {
        apple.stopAll()
        runtime.restart()
        onWake?()
    }

    // MARK: Frames and touches

    public var needsAnotherFrame: Bool { runtime.needsAnotherFrame }

    /// Runs one frame and draws it. Returns whether another is wanted.
    @discardableResult
    public func step(dt: Double) -> Bool {
        runtime.tick(dt: dt)
        for effect in runtime.takeEffects() { onEffect?(effect) }
        // An edit gave the device another size: the screen is fitted again, or it would
        // stay at the old scale, cut off or small, in a view whose bounds did not change.
        if let fitted, fitted.screen != screenSize {
            layout(in: fitted.bounds, fills: fitted.fills, backingScale: fitted.backingScale)
        } else {
            renderer.render(runtime.resolved)
        }
        return runtime.needsAnotherFrame
    }

    public func send(_ event: InputEvent) {
        runtime.send(event)
        onWake?()
    }

    /// Whether videos play, with sound. Off, each frame shows the picture at the playhead.
    public var playsVideo: Bool {
        get { renderer.playsVideo }
        set { renderer.playsVideo = newValue }
    }

    // MARK: Layout

    /// The size of the prototype's screen in points.
    public var screenSize: CGSize {
        let size = runtime.resolved.size
        return CGSize(width: size.width, height: size.height)
    }

    /// Fits the screen into `bounds`, the bounds of the layer this host's `layer` is in.
    /// `backingScale` is the display's pixels per point.
    public func layout(in bounds: CGRect, fills: Bool, backingScale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = bounds
        renderer.rootLayer.frame = layer.bounds
        CATransaction.commit()
        fitted = (bounds, fills, backingScale, screenSize)
        guard let fit = Viewport.fit(screen: screenSize, in: layer.bounds, fills: fills) else { return }
        scale = fit.scale
        origin = fit.origin
        renderer.contentsScale = backingScale * max(scale, 0.5)
        renderer.setViewport(scale: scale, offset: origin)
        renderer.render(runtime.resolved)
    }

    /// Where a point of `layer` (y-down, as a `UIView` has it) is on the prototype's screen.
    public func screenPoint(_ point: CGPoint) -> Point2 {
        Point2(x: (point.x - origin.x) / max(scale, 0.0001), y: (point.y - origin.y) / max(scale, 0.0001))
    }

    // MARK: Pictures

    /// The prototype as it is drawn now, `scale` pixels per point of `layer`, the right way
    /// up. Made with `CALayer.render(in:)`, so it needs no window.
    public func picture(scale: CGFloat = 1) -> CGImage? {
        let width = (layer.bounds.width * scale).rounded(.down), height = (layer.bounds.height * scale).rounded(.down)
        guard width >= 1, height >= 1, width <= 8192, height <= 8192,
              let context = CGContext(
                  data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        #if !canImport(AppKit)
        // A layer on iOS is y-down and a bitmap is y-up.
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        #endif
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        return context.makeImage()
    }
}
