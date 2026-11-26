import AppKit
import PaperEngine
import PaperHost
import PaperModel
import PaperRender
import QuartzCore
import SwiftUI

/// The second finger the Viewer adds while Option is held: the mirror image of the mouse
/// through a pivot, as in the iOS Simulator. Points are view points.
nonisolated enum TwoFingerGesture {
    /// Where the other finger is: the mirror image of `finger` through the pivot.
    static func mirror(of finger: CGPoint, through pivot: CGPoint) -> CGPoint {
        CGPoint(x: 2 * pivot.x - finger.x, y: 2 * pivot.y - finger.y)
    }
}

/// Runs the prototype. The mouse is one finger; holding Option adds a second, mirrored
/// through the middle of the screen, as in the iOS Simulator.
public final class ViewerView: NSView {
    private let store: DocumentStore
    private let renderer = LayerRenderer()
    /// The pictures the prototype shows: the document's, and those it fetched or made.
    private let pictures = PictureStore()
    public let runtime: Runtime
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var scale: CGFloat = 1
    private var origin: CGPoint = .zero
    private var restartToken: Int
    /// Makes the calls of AI patches with the person's keys.
    let ai = AIService()

    /// `sendsRequests` off makes a Viewer whose Network Request patches never get an answer
    /// and send nothing, for pictures. It has to be decided here: the prototype's first
    /// frame, which may already ask for something, runs before this returns.
    public init(store: DocumentStore, sendsRequests: Bool = true) {
        self.store = store
        runtime = Runtime(document: store.runtimeDocument, registry: store.runtimeRegistry)
        runtime.startPage = store.previewScreen
        if store.previewScreen != nil { runtime.restart() }
        restartToken = store.restartToken
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        layer?.addSublayer(renderer.rootLayer)
        secondFinger.isHidden = true
        secondFinger.borderWidth = 1
        secondFinger.zPosition = 10
        layer?.addSublayer(secondFinger)
        firstFinger.isHidden = true
        firstFinger.borderWidth = 1
        firstFinger.zPosition = 10
        layer?.addSublayer(firstFinger)
        services = DeviceServices(runtime: runtime)
        renderer.cameraLayerProvider = { [weak self] in self?.services?.previewLayer }
        // Photos taken by the Camera patch live with the Viewer, not in the document; so
        // do pictures a Network Request fetched. `PictureStore` tells them apart by name.
        pictures.captured = { [weak self] name in self?.services?.photo(named: name) }
        renderer.imageProvider = { [weak store, pictures] name in
            pictures.picture(named: name, assets: store?.assets ?? [:], registry: store?.runtimeRegistry)
        }
        // A video plays from the document's assets or the web. How long it is reaches the
        // runtime from whoever loaded it: the player here, or at once from the file when
        // nothing plays it (a picture, a test).
        renderer.videoURL = { [weak store] source in VideoFiles.url(for: source, assets: store?.assets ?? [:]) }
        renderer.modelURL = { [weak store] name in VideoFiles.assetURL(for: name, assets: store?.assets ?? [:]) }
        // Material glyphs and Google fonts: the document's, else fetched (never for a picture).
        WebAssetClient(
            assets: { [weak store] in store?.assets ?? [:] }, fetches: sendsRequests,
            drawn: { [weak store] in store?.setDrawnWebAssets($1, by: $0) }
        ).attach(to: renderer)
        if sendsRequests {
            arrivalObserver = NotificationCenter.default.addObserver(forName: WebAssets.didArrive, object: nil, queue: .main) { [weak self] note in
                let name = note.object as? String ?? ""
                MainActor.assumeIsolated {
                    guard let self, self.store.usesWebAsset(name) else { return }
                    self.runtime.setNeedsFrame()
                    self.wake()
                }
            }
        }
        renderer.onVideoDuration = { [weak self] source, seconds in
            guard let self, self.runtime.videoDuration(of: source) != seconds else { return }
            self.runtime.setVideoDuration(seconds, for: source)
            self.wake()
        }
        renderer.onVideoFailure = { [weak self] source in
            guard let self, self.runtime.videoDuration(of: source) == nil else { return }
            self.runtime.setVideoUnplayable(source)
            self.wake()
        }
        store.runtime = runtime
        // What the assistant does to its own copy of the prototype is shown here.
        store.onReplay = { [weak self] steps, start in self?.replay(steps, from: start) }
        // An extension that was installed, updated or switched off changes what patches do.
        store.onRegistryChange = { [weak self, weak store] in
            guard let self, let store else { return }
            self.runtime.update(registry: store.runtimeRegistry)
            self.syncDevice()
            self.wake()
        }
        for finger in agentFingers + [agentRest] {
            finger.isHidden = true
            finger.borderWidth = 1.5
            finger.zPosition = 10
            layer?.addSublayer(finger)
        }
        // AI patches: the service makes the call and reports back here. A Viewer for
        // pictures sends nothing, so they stay loading, as Network Request does.
        ai.deliver = { [weak self] id, update in
            self?.runtime.update(ai: id, update)
            self?.wake()
        }
        ai.picture = { [weak self] name in self?.renderer.imageProvider?(name) }
        ai.keep = { [pictures] name, picture in pictures.keep(picture, named: name) }
        ai.ask = { [weak self] provider, answer in self?.askToUseKey(provider, answer) ?? answer(false) }
        runtime.aiHandler = { [weak self] request in
            guard sendsRequests, let self else { return }
            // The assistant showing what it did is not the person using the prototype: it
            // must not spend their credit, speak, or open the microphone.
            if self.isReplaying, request.phase == .send || request.phase == .startRecording {
                self.runtime.update(ai: request.id, .failed(Self.notSentDuringReplay))
                return
            }
            self.ai.handle(request)
        }
        // The prototype's network requests go out through the system's URL loading.
        runtime.requestHandler = { [weak self] request in
            guard sendsRequests else { return }
            if let origin = request.origin {
                // A request from an extension's script: what it may reach and carry is
                // decided by the extension's manifest, not by the script.
                self?.sendForExtension(request, origin)
                return
            }
            if request.service == Unsplash.service {
                self?.sendToUnsplash(request)
                return
            }
            let id = request.id
            PrototypeNetwork.send(request) { [weak self] answer in self?.finish(id, answer) }
        }
        services?.onChange = { [weak self] in self?.wake() }
        runtime.tick(dt: 0)
        renderer.render(runtime.resolved)
    }

    /// Looks up the key an extension's request names. Set by the app; a Viewer made for
    /// a test or a picture has none, so such a request is refused.
    public var keyLookup: (@Sendable (_ extensionID: String, _ secret: ExtensionManifest.Secret) -> String?)?
    /// Sends what `ExtensionNetwork` has prepared; replaced in tests.
    var extensionTransport: ExtensionNetwork.Transport = ExtensionNetwork.send

    private func sendForExtension(_ request: NetworkRequest, _ origin: String) {
        guard let member = store.runtimeRegistry.extensions.member(origin), member.isAvailable else {
            finish(request.id, NetworkResponse(status: 0, error: "The extension that asked is not installed."))
            return
        }
        let manifest = member.package.manifest
        let lookup = keyLookup
        let transport = extensionTransport
        let id = request.id
        Task { [weak self] in
            let answer = await ExtensionNetwork.perform(
                request, for: manifest, key: { lookup?(origin, $0) }, transport: transport
            )
            // A script gets no Image output, so a picture it fetched is not kept.
            self?.finish(id, answer, keepsPicture: false)
        }
    }

    /// The Unsplash access key, from Settings; replaced in tests.
    var unsplashKey: () -> String? = { AIKeys.shared.key(account: AIKeys.unsplash) }

    /// A request of the Unsplash Photo patch: to Unsplash's API only, with the person's key.
    private func sendToUnsplash(_ request: NetworkRequest) {
        guard let key = unsplashKey() else {
            return finish(request.id, NetworkResponse(status: 0, error: "Add an Unsplash access key in Settings > AI to find photos."))
        }
        guard var signed = Unsplash.signed(request, key: key) else {
            return finish(request.id, NetworkResponse(status: 0, error: "Only Unsplash's own API can be asked."))
        }
        signed.service = nil
        let id = request.id
        PrototypeNetwork.send(signed) { [weak self] answer in self?.finish(id, answer) }
    }

    private var services: DeviceServices?
    private var arrivalObserver: NSObjectProtocol?

    isolated deinit {
        if let arrivalObserver { NotificationCenter.default.removeObserver(arrivalObserver) }
    }
    /// Whether this Viewer may use the Mac's camera, microphone and so on. Off for
    /// snapshots and tests, which must not prompt for access.
    public var usesDevice = false {
        didSet { syncDevice() }
    }

    private func syncDevice() {
        services?.sync(usesDevice && window != nil ? runtime.capabilities : [])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// In its own window the prototype fills the view edge to edge and scales with it,
    /// up as well as down. Otherwise it keeps a margin and never grows past actual size.
    public var fillsWindow = false {
        didSet { needsLayout = true }
    }

    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Document updates

    public func update(document: PaperModel.Document, restartToken: Int) {
        if restartToken != self.restartToken {
            self.restartToken = restartToken
            // Starting over is the person's call: what the assistant was showing ends.
            cancelReplay()
            runtime.update(document: document)
            // On the screen the person asked to preview from, or the first.
            runtime.startPage = store.previewScreen
            runtime.restart()
        } else {
            runtime.update(document: document)
        }
        syncDevice()
        needsLayout = true
        wake()
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        let screen = runtime.resolved.size
        guard let fit = Viewport.fit(
            screen: CGSize(width: screen.width, height: screen.height), in: bounds, fills: fillsWindow
        ) else { return }
        scale = fit.scale
        origin = fit.origin
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer.rootLayer.frame = bounds
        CATransaction.commit()
        // Changing the pixel density redraws every text and symbol layer. While the window
        // is being dragged to a new size that would happen on each step, so the density
        // stays put until the drag ends and the picture is only scaled.
        if !inLiveResize {
            renderer.contentsScale = (window?.backingScaleFactor ?? 2) * max(scale, 0.5)
        }
        renderer.setViewport(scale: scale, offset: origin)
        renderer.render(runtime.resolved)
        placeAgentBadge()
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        needsLayout = true
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncDevice()
        if let modifierMonitor {
            NSEvent.removeMonitor(modifierMonitor)
            self.modifierMonitor = nil
        }
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncVideo() }
            }
        }
        syncVideo()
        if window == nil {
            link?.invalidate()
            link = nil
            ai.stopAll()
        } else {
            wake()
            // Option can go down or up while the pointer rests over the Viewer.
            modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.modifiersChanged(event.modifierFlags)
                return event
            }
        }
    }

    private var occlusionObserver: NSObjectProtocol?

    /// Only a Viewer on screen plays video, with its sound: a hidden one falls silent. One
    /// without a window, as for a picture, draws each video's frame at its playhead from
    /// the file, the same every time.
    private func syncVideo() {
        let shown = window.map { $0.occlusionState.contains(.visible) } ?? false
        guard renderer.playsVideo != shown else { return }
        // Out of sight, nothing speaks or listens.
        if shown { ai.hidden = false } else { ai.quiet() }
        renderer.playsVideo = shown
        renderer.render(runtime.resolved)
        if shown { wake() }
    }

    private func finish(_ id: UUID, _ response: NetworkResponse, keepsPicture: Bool = true) {
        // An answer that is a picture is kept for the patch's Image output to name.
        runtime.complete(id, with: pictures.settle(response, for: id, keepsPicture: keepsPicture))
        wake()
    }

    /// Asks, once per provider while this Viewer is open, whether the prototype may use the
    /// person's key: a prototype from someone else should not spend their credit unasked.
    private func askToUseKey(_ provider: AIProvider, _ answer: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Let this prototype use your \(provider.name) API key?"
        alert.informativeText = "Its AI patches send what you type, and any pictures it shows them, to \(provider.name). Requests are charged to your account. You can stop asking in Settings."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")
        guard let window else { return answer(alert.runModal() == .alertFirstButtonReturn) }
        alert.beginSheetModal(for: window) { response in answer(response == .alertFirstButtonReturn) }
    }

    // MARK: Frame clock

    private func wake() {
        guard window != nil else { return }
        if link == nil {
            let created = displayLink(target: self, selector: #selector(step(_:)))
            created.add(to: .main, forMode: .common)
            link = created
        }
        if link?.isPaused == true { lastTimestamp = nil }
        link?.isPaused = false
    }

    @objc private func step(_ link: CADisplayLink) {
        let dt: Double
        if let last = lastTimestamp {
            dt = min(max(link.targetTimestamp - last, 0), 1.0 / 20.0)
        } else {
            dt = min(max(link.duration, 1.0 / 240.0), 1.0 / 30.0)
        }
        lastTimestamp = link.targetTimestamp
        advance(by: dt, recordingAt: CACurrentMediaTime() - recordingStart)
        // A touch that just lifted is still fading out of the recording.
        if !runtime.needsAnotherFrame, lifted == nil, !isReplaying, agentFade == nil {
            link.isPaused = true
        }
    }

    /// Advances the prototype and draws the result. Also used for snapshots and tests.
    /// A recording normally runs on the wall clock, so pauses in the prototype are pauses
    /// in the movie. Without `recordingAt` it runs on the prototype's own time instead.
    public func advance(by dt: Double, recordingAt: Double? = nil) {
        // A replay runs the prototype on its own clock, a sixtieth at a time, exactly as the
        // run it shows did. Otherwise time is what has passed on the display.
        if let ticks = playReplay(dt) {
            for _ in 0..<ticks { runtime.tick(dt: ViewerSnapshot.frameLength) }
        } else {
            runtime.tick(dt: dt)
        }
        for effect in runtime.takeEffects() where usesDevice { services?.perform(effect) }
        renderer.render(runtime.resolved)
        store.frameDidTick()
        if let recorder, let layer {
            recordedTime += dt
            // On screen the pointer's finger is a cursor, which no movie contains, and its
            // twin shows whenever Option is held. A movie shows fingers only while they
            // touch, drawn as layers for this one picture.
            let twinShown = !secondFinger.isHidden
            let touches = recordedTouches(advancing: dt)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            secondFinger.isHidden = true
            for (finger, touch) in zip([firstFinger, recordedTwin], touches) {
                style(finger, pressed: true)
                finger.position = touch.position
                finger.opacity = Float(touch.opacity)
                finger.isHidden = false
            }
            CATransaction.commit()
            recorder.append(layer, at: recordingAt ?? recordedTime)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            firstFinger.isHidden = true
            recordedTwin.isHidden = true
            secondFinger.isHidden = !twinShown
            CATransaction.commit()
        }
    }

    // MARK: Recording

    private var recorder: PrototypeRecorder?
    private var recordingStart: CFTimeInterval = 0
    private var recordedTime = 0.0
    private var usesWallClock = true

    public var isRecording: Bool { recorder != nil }

    /// The setting for whether movies show where fingers touch. On unless switched off.
    public static let recordsTouchesKey = "recordsTouches"
    public static var recordsTouchesByDefault: Bool {
        UserDefaults.standard.object(forKey: recordsTouchesKey) as? Bool ?? true
    }

    /// Whether the movie being recorded shows touches.
    public private(set) var recordsTouches = true
    /// How long a lifted finger takes to fade from a movie, so a quick tap can be seen.
    public static let touchLinger = 0.3

    /// A finger to draw into one picture of a movie, in view coordinates.
    struct RecordedTouch: Equatable {
        var position: CGPoint
        var opacity: Double
    }

    private let firstFinger = CALayer()
    private lazy var recordedTwin: CALayer = {
        let twin = CALayer()
        twin.isHidden = true
        twin.borderWidth = 1
        twin.zPosition = 10
        layer?.addSublayer(twin)
        return twin
    }()
    /// Where a finger just lifted, and how much of its fade is left.
    private var lifted: (positions: [CGPoint], left: Double)?

    /// The fingers the next picture of the movie shows: those touching now, or those that
    /// just lifted, fading. Moves the fade on by `dt`.
    func recordedTouches(advancing dt: Double) -> [RecordedTouch] {
        guard recordsTouches else {
            lifted = nil
            return []
        }
        if isTouching, let pointer {
            lifted = nil
            var touches = [RecordedTouch(position: pointer, opacity: 1)]
            if secondFingerDown {
                touches.append(RecordedTouch(position: TwoFingerGesture.mirror(of: pointer, through: currentPivot), opacity: 1))
            }
            return touches
        }
        guard let fading = lifted else { return [] }
        let touches = fading.positions.map { RecordedTouch(position: $0, opacity: max(fading.left / Self.touchLinger, 0)) }
        let left = fading.left - dt
        lifted = left > 0 ? (fading.positions, left) : nil
        return touches
    }

    /// A finger lifted at these places: let it fade from the movie instead of vanishing.
    private func fingersLifted(_ positions: [CGPoint]) {
        guard recorder != nil, recordsTouches else { return }
        lifted = (positions, Self.touchLinger)
    }

    /// A tap that did not come from the mouse (a script or `papertool`), shown in a movie
    /// like any other.
    public func tap(at point: Point2) {
        runtime.send(.touchDown(point))
        runtime.send(.touchUp(point))
        fingersLifted([viewPoint(point)])
        wake()
    }

    /// Where a point of the screen is in this view.
    private func viewPoint(_ point: Point2) -> CGPoint {
        CGPoint(x: origin.x + point.x * scale, y: bounds.height - (origin.y + point.y * scale))
    }

    // MARK: The assistant's touches

    /// The setting for whether the Viewer shows what the assistant does when it tries the
    /// prototype. On unless switched off.
    public static let showsAssistantTouchesKey = "showsAssistantTouches"
    public static var showsAssistantTouches: Bool {
        UserDefaults.standard.object(forKey: showsAssistantTouchesKey) as? Bool ?? true
    }

    /// The frames still to play of what the assistant did, and how far along they are.
    private var replayFrames: [ViewerSnapshot.Frame] = []
    private var replayIndex = 0
    private var replayClock = 0.0
    /// What to play once this replay is over. Only the newest is kept.
    private var waitingReplay: [ViewerSnapshot.Step]?
    private var waitingReplayStart: LayerID?
    /// The assistant's fingers on the screen now, in screen points.
    private var agentTouches: [Point2] = []
    /// Its finger near the screen without touching.
    private var agentResting: Point2?
    /// What the prototype has been told and not yet told the end of: the fingers that are
    /// down and where (by the id each was sent with), a pointer hovering. Kept
    /// from what was really sent, so letting go is right even when the steps stop short
    /// of a lift.
    private var agentDown: [Int: Point2] = [:]
    private var agentHovers = false

    /// Where its fingers just lifted, and how much of their fade is left.
    private var agentFade: (positions: [CGPoint], left: Double)?
    private let agentFingers = [CALayer(), CALayer()]
    private let agentRest = CALayer()

    /// Whether the assistant's steps are being played.
    public var isReplaying: Bool { replayIndex < replayFrames.count }

    /// What an AI patch says when the assistant's replay presses its Send.
    static let notSentDuringReplay = "Not sent while the assistant shows the prototype. Try it yourself to send."


    /// Where the assistant's fingers are drawn now, in view coordinates, for tests.
    var agentFingerPositions: [CGPoint] {
        agentFingers.filter { !$0.isHidden }.map(\.position)
    }

    var showsAgentBadge: Bool { !agentBadge.isHidden }

    /// Plays `steps` on the prototype from its start, at a speed a person can follow, with
    /// the assistant's fingers drawn. This is a showing of what the assistant did to its own
    /// hidden copy (`ViewerSnapshot`), not that run itself. A replay asked for while one is
    /// playing waits for it.
    public func replay(_ steps: [ViewerSnapshot.Step], from start: LayerID? = nil) {
        // The prototype is the person's first: not while they are touching it, and not in
        // a Viewer that is out of sight, where it would sit waiting to play later.
        guard !isTouching, !secondFingerDown, !isMagnifying, !isRotating else { return }
        if let window, !window.isVisible { return }
        guard !isReplaying else {
            waitingReplay = steps
            waitingReplayStart = start
            return
        }
        let frames = ViewerSnapshot.beats(for: steps, paced: true).compactMap { beat -> ViewerSnapshot.Frame? in
            if case let .frame(frame) = beat { return frame }
            return nil
        }
        guard !frames.isEmpty else { return }
        // The document as it is now: an edit made a moment ago may not have reached here yet.
        runtime.update(document: store.runtimeDocument)
        // On the screen the hidden run the assistant looked at started on.
        runtime.startPage = start
        runtime.restart()
        // The same two first frames the hidden run has had before its steps begin.
        runtime.tick(dt: 0)
        runtime.tick(dt: ViewerSnapshot.frameLength)
        needsLayout = true
        replayFrames = frames
        replayIndex = 0
        replayClock = 0
        agentFade = nil
        drawAgent()
        wake()
    }

    /// Ends the replay, lifting any finger of the assistant's that is down. The person
    /// touching the prototype does this: it is theirs first.
    public func cancelReplay() {
        guard isReplaying || waitingReplay != nil || agentFade != nil else { return }
        replayFrames = []
        replayIndex = 0
        waitingReplay = nil
        letGo()
        agentFade = nil
        drawAgent()
    }

    /// Takes the assistant's fingers and pointer off the prototype, whatever the steps left
    /// there: a finger that stayed down would hold the prototype for good.
    private func letGo() {
        for (id, point) in agentDown.sorted(by: { $0.key < $1.key }) { runtime.send(.touchEnded(id: id, point)) }
        if !agentTouches.isEmpty { agentFade = (agentTouches.map(viewPoint), Self.touchLinger) }
        if agentHovers { runtime.send(.hover(nil)) }
        agentTouches = []
        agentResting = nil
        agentDown = [:]
        agentHovers = false
    }

    /// Moves the replay on by `dt`: one of its frames for each sixtieth of a second, so it
    /// plays at the same speed whatever the display's rate. Returns how many sixtieths of
    /// its own time the prototype runs now, or nil when nothing is being replayed.
    private func playReplay(_ dt: Double) -> Int? {
        if var fade = agentFade {
            fade.left -= dt
            agentFade = fade.left > 0 ? fade : nil
        }
        guard isReplaying else {
            if !agentFingers[0].isHidden || !agentBadge.isHidden { drawAgent() }
            return nil
        }
        replayClock += dt
        guard replayClock >= ViewerSnapshot.frameLength - 1e-9 else {
            drawAgent()
            return 0
        }
        // A slow frame does not earn a burst of them afterwards.
        replayClock = min(replayClock - ViewerSnapshot.frameLength, ViewerSnapshot.frameLength)
        let frame = replayFrames[replayIndex]
        replayIndex += 1
        for event in frame.events {
            runtime.send(event)
            switch event {
            case let .touchDown(point), let .touchMoved(point): agentDown[0] = point
            case .touchUp: agentDown[0] = nil
            case let .touchBegan(id, point), let .touchChanged(id, point): agentDown[id] = point
            case let .touchEnded(id, _), let .touchCancelled(id): agentDown[id] = nil
            case let .hover(point): agentHovers = point != nil
            default: break
            }
        }
        if frame.fingers.isEmpty, !agentTouches.isEmpty {
            agentFade = (agentTouches.map(viewPoint), Self.touchLinger)
        } else if !frame.fingers.isEmpty {
            agentFade = nil
        }
        agentTouches = frame.fingers
        agentResting = frame.resting
        if !isReplaying {
            replayFrames = []
            replayIndex = 0
            letGo()
            if let next = waitingReplay {
                waitingReplay = nil
                replay(next, from: waitingReplayStart)
            }
        }
        drawAgent()
        return frame.ticks
    }

    /// Draws the assistant's fingers and its badge as they are now.
    private func drawAgent() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var touches: [(CGPoint, Double)] = agentTouches.map { (viewPoint($0), 1) }
        if touches.isEmpty, let fade = agentFade {
            touches = fade.positions.map { ($0, max(fade.left / Self.touchLinger, 0)) }
        }
        for (index, finger) in agentFingers.enumerated() {
            guard index < touches.count else {
                finger.isHidden = true
                continue
            }
            styleAgent(finger, pressed: true)
            finger.position = touches[index].0
            finger.opacity = Float(touches[index].1)
            finger.isHidden = false
        }
        if let resting = agentResting, agentTouches.isEmpty {
            styleAgent(agentRest, pressed: false)
            agentRest.position = viewPoint(resting)
            agentRest.isHidden = false
        } else {
            agentRest.isHidden = true
        }
        agentBadge.isHidden = !(isReplaying || agentFade != nil)
        CATransaction.commit()
    }

    /// The touch cursor's look in the accent color: the assistant's finger, not the person's.
    private func styleAgent(_ finger: CALayer, pressed: Bool) {
        style(finger, pressed: pressed)
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        finger.backgroundColor = accent.withAlphaComponent(pressed ? 0.7 : 0.35).cgColor
        finger.borderColor = NSColor(white: 1, alpha: 0.95).cgColor
        // A white ring and a shadow keep it in sight on any color, the accent color included.
        finger.borderWidth = 2
        finger.shadowColor = NSColor.black.cgColor
        finger.shadowOpacity = 0.35
        finger.shadowRadius = 3
        finger.shadowOffset = .zero
    }

    /// Says whose fingers these are, at the top of the Viewer, while they are at work.
    private lazy var agentBadge: CALayer = {
        let title = NSAttributedString(string: "Assistant", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        let size = title.size()
        let text = CATextLayer()
        text.string = title
        text.contentsScale = window?.backingScaleFactor ?? 2
        text.frame = CGRect(x: 9, y: 3, width: ceil(size.width), height: ceil(size.height))
        let badge = CALayer()
        badge.bounds = CGRect(x: 0, y: 0, width: ceil(size.width) + 18, height: ceil(size.height) + 6)
        badge.cornerRadius = badge.bounds.height / 2
        badge.backgroundColor = (NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue).cgColor
        badge.zPosition = 11
        badge.isHidden = true
        badge.addSublayer(text)
        layer?.addSublayer(badge)
        return badge
    }()

    private func placeAgentBadge() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        agentBadge.position = CGPoint(x: bounds.midX, y: bounds.height - 12 - agentBadge.bounds.height / 2)
        CATransaction.commit()
    }

    /// Starts capturing the Viewer into a movie at `url`. `touches` says whether it shows
    /// where fingers touch; left out, the app's setting decides.
    public func startRecording(to url: URL, wallClock: Bool = true, touches: Bool? = nil) throws {
        guard recorder == nil, let layer else { return }
        recordsTouches = touches ?? Self.recordsTouchesByDefault
        lifted = nil
        let created = try PrototypeRecorder(size: bounds.size, url: url)
        recorder = created
        recordingStart = CACurrentMediaTime()
        recordedTime = 0
        usesWallClock = wallClock
        created.append(layer, at: 0)
    }

    /// Stops capturing and closes the movie. Returns its location, or nil if it failed.
    public func stopRecording() async -> URL? {
        guard let finished = recorder, let layer else { return nil }
        lifted = nil
        // One last picture so the movie lasts until now, even if nothing was moving.
        finished.append(layer, at: usesWallClock ? CACurrentMediaTime() - recordingStart : recordedTime)
        recorder = nil
        return await finished.finish() ? finished.url : nil
    }

    // MARK: Touch cursor

    /// The Viewer stands for a phone, so the pointer over it is a fingertip, not an arrow.
    public static let touchCursor = makeTouchCursor(pressed: false)
    /// The fingertip while it is touching the screen: smaller and more solid.
    public static let pressedTouchCursor = makeTouchCursor(pressed: true)

    private static func makeTouchCursor(pressed: Bool) -> NSCursor {
        let side: CGFloat = 40
        let diameter: CGFloat = pressed ? 26 : 32
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let inset = (side - diameter) / 2
            let circle = NSBezierPath(ovalIn: NSRect(x: inset, y: inset, width: diameter, height: diameter))
            // Grey with a light and a dark ring, so it reads on any prototype.
            NSColor(white: 0.5, alpha: pressed ? 0.6 : 0.35).setFill()
            circle.fill()
            NSColor(white: 0, alpha: 0.3).setStroke()
            circle.lineWidth = 1
            circle.stroke()
            let inner = NSBezierPath(ovalIn: NSRect(x: inset, y: inset, width: diameter, height: diameter).insetBy(dx: 1, dy: 1))
            NSColor(white: 1, alpha: 0.7).setStroke()
            inner.lineWidth = 1
            inner.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }

    private var isTouching = false
    private var cursorArea: NSTrackingArea?

    private func showTouchCursor() {
        (isTouching ? Self.pressedTouchCursor : Self.touchCursor).set()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorArea { removeTrackingArea(cursorArea) }
        // The Viewer is a floating panel that is often not the key window, so the cursor
        // has to follow the pointer whichever window is active.
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        cursorArea = area
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: isTouching ? Self.pressedTouchCursor : Self.touchCursor)
    }

    public override func cursorUpdate(with event: NSEvent) { showTouchCursor() }
    public override func mouseEntered(with event: NSEvent) { showTouchCursor() }
    public override func mouseMoved(with event: NSEvent) {
        showTouchCursor()
        hover(artboardPoint(event))
        trackFingers(to: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags)
    }

    public override func mouseExited(with event: NSEvent) {
        if !isTouching { NSCursor.arrow.set() }
        hover(nil)
        pointer = nil
        if !secondFingerDown { setSecondFinger(hidden: true) }
    }

    /// Only prototypes with a Hover patch hear about a pointer that is not touching, so
    /// moving the pointer over any other prototype costs no frames.
    private func hover(_ point: Point2?) {
        // The person's pointer drifting over the Viewer is not part of what is being shown.
        guard !isReplaying else { return }
        guard runtime.usesHover else { return }
        runtime.send(.hover(point))
        wake()
    }

    // MARK: Two fingers

    // Holding Option puts a second finger on the screen, mirrored from the pointer through
    // a pivot that starts in the middle. Pressing then puts both fingers down, as two
    // touches of their own, and dragging spreads and turns them around the pivot. Holding
    // Shift as well moves the pivot with the pointer, so both fingers travel together:
    // before pressing, to put them somewhere else, and while pressing, to pan with two.
    private let secondFinger = CALayer()
    /// The point the fingers mirror through, in view coordinates. nil is the middle.
    private var pivot: CGPoint?
    /// Where the pointer was last seen over the Viewer, in view coordinates.
    private var pointer: CGPoint?
    /// Whether the mirrored finger is down with the mouse's: finger 1 beside finger 0.
    private var secondFingerDown = false
    private var modifierMonitor: Any?

    private var currentPivot: CGPoint { pivot ?? CGPoint(x: bounds.midX, y: bounds.midY) }

    /// Where the second finger is, in view coordinates, while it is showing.
    var secondFingerPosition: CGPoint? { secondFinger.isHidden ? nil : secondFinger.position }

    private func artboardPoint(view point: CGPoint) -> Point2 {
        Point2(x: (point.x - origin.x) / scale, y: (bounds.height - point.y - origin.y) / scale)
    }

    private func setSecondFinger(hidden: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        secondFinger.isHidden = hidden
        CATransaction.commit()
    }

    /// The look of the touch cursor, for a finger that is drawn as a layer.
    private func style(_ finger: CALayer, pressed: Bool) {
        let diameter: CGFloat = pressed ? 26 : 32
        finger.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        finger.cornerRadius = diameter / 2
        finger.backgroundColor = NSColor(white: 0.5, alpha: pressed ? 0.6 : 0.35).cgColor
        finger.borderColor = NSColor(white: 1, alpha: 0.7).cgColor
    }

    private func placeSecondFinger() {
        guard let pointer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        style(secondFinger, pressed: secondFingerDown)
        secondFinger.position = TwoFingerGesture.mirror(of: pointer, through: currentPivot)
        secondFinger.isHidden = false
        CATransaction.commit()
    }

    private func trackFingers(to location: CGPoint, modifiers: NSEvent.ModifierFlags) {
        let before = pointer
        pointer = location
        guard modifiers.contains(.option) || secondFingerDown else {
            setSecondFinger(hidden: true)
            return
        }
        // With Shift the pivot travels with the pointer, so both fingers move as one.
        if modifiers.contains(.shift), let before {
            let middle = currentPivot
            pivot = CGPoint(x: middle.x + location.x - before.x, y: middle.y + location.y - before.y)
        }
        placeSecondFinger()
    }

    private func modifiersChanged(_ modifiers: NSEvent.ModifierFlags) {
        guard pointer != nil else { return }
        if modifiers.contains(.option) {
            placeSecondFinger()
        } else if !secondFingerDown {
            setSecondFinger(hidden: true)
            // Letting go of Option puts the pivot back in the middle, as the Simulator does.
            pivot = nil
        }
    }

    // A trackpad pinch or twist over the Viewer is a pinch the Mac has already recognized:
    // the prototype is told of it as such, with no fingers (`InputEvent.pinchBegan`).
    private var pinchScale = 1.0
    private var pinchRotation = 0.0
    // Spreading and turning are two gestures to AppKit, each with its own start and end.
    // They are one pinch here, which lasts until both are over.
    private var isMagnifying = false
    private var isRotating = false

    private func pinch(_ event: NSEvent, active: inout Bool, change: () -> Void) {
        let wasPinching = isMagnifying || isRotating
        if event.phase.contains(.began) {
            cancelReplay()
            active = true
        }
        guard active else { return }
        if !wasPinching {
            pinchScale = 1
            pinchRotation = 0
            runtime.send(.pinchBegan(artboardPoint(event)))
        }
        change()
        runtime.send(.pinchChanged(scale: pinchScale, rotation: pinchRotation))
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            active = false
            if !isMagnifying, !isRotating { runtime.send(.pinchEnded) }
        }
        wake()
    }

    public override func magnify(with event: NSEvent) {
        pinch(event, active: &isMagnifying) { pinchScale = max(pinchScale * (1 + event.magnification), 0.05) }
    }

    public override func rotate(with event: NSEvent) {
        // AppKit turns counter-clockwise for positive values; layers turn clockwise.
        pinch(event, active: &isRotating) { pinchRotation -= Double(event.rotation) }
    }

    // MARK: Input

    private func artboardPoint(_ event: NSEvent) -> Point2 {
        let point = convert(event.locationInWindow, from: nil)
        let yDown = bounds.height - point.y
        return Point2(x: (point.x - origin.x) / scale, y: (yDown - origin.y) / scale)
    }

    public override func mouseDown(with event: NSEvent) {
        cancelReplay()
        window?.makeFirstResponder(self)
        isTouching = true
        showTouchCursor()
        let location = convert(event.locationInWindow, from: nil)
        pointer = location
        runtime.send(.touchBegan(id: 0, artboardPoint(event)))
        if event.modifierFlags.contains(.option) {
            // Two fingers come down: the pointer's and its mirror image.
            secondFingerDown = true
            placeSecondFinger()
            runtime.send(.touchBegan(id: 1, artboardPoint(view: TwoFingerGesture.mirror(of: location, through: currentPivot))))
        }
        wake()
    }

    public override func mouseDragged(with event: NSEvent) {
        showTouchCursor()
        let location = convert(event.locationInWindow, from: nil)
        runtime.send(.touchChanged(id: 0, artboardPoint(event)))
        if secondFingerDown {
            // The twin mirrors the pointer; with Shift the pivot comes along instead, and
            // the two fingers pan side by side.
            trackFingers(to: location, modifiers: event.modifierFlags)
            runtime.send(.touchChanged(id: 1, artboardPoint(view: TwoFingerGesture.mirror(of: location, through: currentPivot))))
        } else {
            pointer = location
        }
        wake()
    }

    public override func mouseUp(with event: NSEvent) {
        isTouching = false
        let location = convert(event.locationInWindow, from: nil)
        if secondFingerDown {
            let twin = TwoFingerGesture.mirror(of: location, through: currentPivot)
            fingersLifted([location, twin])
            secondFingerDown = false
            runtime.send(.touchEnded(id: 0, artboardPoint(event)))
            runtime.send(.touchEnded(id: 1, artboardPoint(view: twin)))
            window?.invalidateCursorRects(for: self)
            trackFingers(to: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags)
            wake()
            return
        }
        // A drag can end outside the Viewer, where the arrow belongs again.
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            showTouchCursor()
        } else {
            NSCursor.arrow.set()
        }
        window?.invalidateCursorRects(for: self)
        pointer = location
        fingersLifted([location])
        runtime.send(.touchEnded(id: 0, artboardPoint(event)))
        wake()
    }

    private func keyName(_ event: NSEvent) -> String? {
        guard let characters = event.charactersIgnoringModifiers, let first = characters.unicodeScalars.first else {
            return nil
        }
        switch Int(first.value) {
        case 0x20: return "space"
        case 0x0D, 0x03: return "return"
        case 0x1B: return "escape"
        case NSUpArrowFunctionKey: return "up"
        case NSDownArrowFunctionKey: return "down"
        case NSLeftArrowFunctionKey: return "left"
        case NSRightArrowFunctionKey: return "right"
        default: return characters.lowercased()
        }
    }

    /// While a text field has focus, every key belongs to it: none reaches a Keyboard patch.
    private func type(_ event: NSEvent) -> Bool {
        guard runtime.isEditingText, !event.modifierFlags.contains(.command) else { return false }
        // Control combinations and dead keys (Option-E, waiting for its letter) type nothing.
        guard !event.modifierFlags.contains(.control), let characters = event.characters,
              let first = characters.unicodeScalars.first else { return true }
        switch Int(first.value) {
        case 0x0D, 0x03: if !event.isARepeat { runtime.send(.submit) }
        case 0x7F, 0x08: runtime.send(.deleteBackward)
        // Arrows, function keys and Forward Delete: the caret is always at the end.
        case 0xF700...0xF8FF: break
        default:
            let printable = String(String.UnicodeScalarView(characters.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
            if !printable.isEmpty { runtime.send(.text(printable)) }
        }
        wake()
        return true
    }

    /// Edit > Paste while a text field has focus types what is on the pasteboard.
    @objc func paste(_ sender: Any?) {
        cancelReplay()
        guard runtime.isEditingText, let text = NSPasteboard.general.string(forType: .string) else { return }
        // A field is one line of printable text, and not a whole book.
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let printable = String(String.UnicodeScalarView(line.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }).prefix(5000))
        guard !printable.isEmpty else { return }
        runtime.send(.text(printable))
        wake()
    }

    public override func keyDown(with event: NSEvent) {
        cancelReplay()
        if type(event) { return }
        guard !event.modifierFlags.contains(.command), let key = keyName(event) else {
            super.keyDown(with: event)
            return
        }
        if !event.isARepeat { runtime.send(.keyDown(key)) }
        wake()
    }

    public override func keyUp(with event: NSEvent) {
        guard let key = keyName(event) else { return }
        runtime.send(.keyUp(key))
        wake()
    }
}

struct ViewerRepresentable: NSViewRepresentable {
    let store: DocumentStore
    let document: PaperModel.Document
    let restartToken: Int

    func makeNSView(context: Context) -> ViewerView {
        ViewerView(store: store)
    }

    func updateNSView(_ view: ViewerView, context: Context) {
        view.update(document: document, restartToken: restartToken)
    }
}

extension ViewerView: NSMenuItemValidation {
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(paste(_:)) {
            // Asks only whether there is text, without reading it: reading is what macOS
            // may show a privacy alert for.
            return runtime.isEditingText && NSPasteboard.general.availableType(from: [.string]) != nil
        }
        return true
    }
}
