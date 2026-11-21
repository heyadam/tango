import AppKit
import PaperEngine
import PaperModel

/// Pictures of a prototype as the Viewer would show it, made without a window. Used by
/// `papertool` and by the assistant to look at what it built.
public enum ViewerSnapshot {
    /// One thing done to a running prototype, in order.
    public enum Step: Equatable {
        case tap(Point2)
        /// A finger down at `from`, moved to `to` over `seconds`, then lifted.
        case drag(from: Point2, to: Point2, seconds: Double)
        /// A finger down that stays down, so a picture can be taken while it is held.
        /// `finger` 2 is a second one beside the first, so two can be down at once.
        case down(Point2, finger: Int = 1)
        /// That finger moved to a point over `seconds`.
        case move(to: Point2, seconds: Double, finger: Int = 1)
        /// That finger lifted.
        case up(finger: Int = 1)
        case wait(Double)
        /// Types into the text field that has focus.
        case type(String)
        /// Return in the text field that has focus.
        case submit
        case deleteBackward
        /// Two fingers either side of `at`, spread to `scale` times as far apart, turned by
        /// `rotation` degrees and carried `pan` points over `seconds`, then lifted. They
        /// are two touches, so what a patch reports counts from where its gesture began.
        case pinch(at: Point2, scale: Double, rotation: Double, seconds: Double, pan: Point2 = .zero)
        /// A pointer resting at a point without touching, or nil for gone.
        case hover(Point2?)
        /// Take a picture here.
        case look
    }

    /// Runs `document` from the start, optionally taps it, lets `seconds` pass, and draws it.
    /// With no margin the picture is exactly the screen, so a point in it is an screen point.
    public static func bitmap(
        of document: PaperModel.Document,
        assets: [String: Data] = [:],
        registry: PatchRegistry = .standard,
        tap: Point2? = nil,
        seconds: Double = 0,
        margin: CGFloat = 0,
        scale: Int = 1,
        startScreen: LayerID? = nil
    ) -> NSBitmapImageRep? {
        var steps: [Step] = []
        if let tap { steps.append(.tap(tap)) }
        steps += [.wait(seconds), .look]
        return bitmaps(of: document, assets: assets, registry: registry, steps: steps, margin: margin, scale: scale, startScreen: startScreen).first
    }

    /// What one frame of a run does: what the prototype is sent before it, and where
    /// fingers are during it.
    public struct Frame: Equatable {
        public var events: [InputEvent] = []
        /// Fingers touching the screen, in screen points, in the order of their numbers.
        public var fingers: [Point2] = []
        /// A finger near the screen that is not touching: hovering, or on its way to a touch.
        public var resting: Point2?
        /// How many sixtieths of a second of the prototype's time this frame is. One, except
        /// in a paced run: none while only the finger moves, several while a long wait is
        /// hurried through.
        public var ticks = 1
    }

    /// A run of steps, a frame at a time.
    public enum Beat: Equatable {
        case frame(Frame)
        /// A picture is taken here.
        case look
    }

    /// The length of a frame of a run.
    public static let frameLength = 1.0 / 60.0
    /// The most frames a paced run has, a minute's worth: a run of a thousand taps is not
    /// sat through, and a list of a million steps is not laid out in memory.
    public static let longestPacedRun = 60 * 60

    /// What `steps` mean, frame by frame: this is the one place that says so, for the
    /// pictures the assistant gets and for the replay a person watches.
    ///
    /// `paced` adds what a person needs to follow it: the finger travels to where it will
    /// touch, and a wait is shown in two seconds at most. None of it moves the prototype's
    /// own time. The finger travels during frames in which nothing else happens, and where
    /// there are none the prototype stands still for it (frames of no `ticks`); a long wait
    /// is hurried through (frames of several). So the prototype is sent the same things at
    /// the same moments of its time either way, and a double tap or a delay comes out the
    /// same for the person watching as it did for the assistant. At most `limit` seconds
    /// of steps are run.
    public static func beats(for steps: [Step], limit: Double = 30, paced: Bool = false) -> [Beat] {
        var run = Run(left: limit, paced: paced)
        /// Where the fingers of `down` steps are while they are held, by the id the
        /// prototype knows each by: 0 for finger 1.
        var held: [Int: Point2] = [:]
        func fingers(_ held: [Int: Point2]) -> [Point2] { held.sorted { $0.key < $1.key }.map(\.value) }
        // The first finger is sent as the one-finger events, the way a mouse sends it.
        func began(_ id: Int, _ point: Point2) -> InputEvent { id == 0 ? .touchDown(point) : .touchBegan(id: id, point) }
        func moved(_ id: Int, _ point: Point2) -> InputEvent { id == 0 ? .touchMoved(point) : .touchChanged(id: id, point) }
        func ended(_ id: Int, _ point: Point2) -> InputEvent { id == 0 ? .touchUp(point) : .touchEnded(id: id, point) }
        // A touch is seen by the prototype on the next frame, and a lift on the one after
        // (a down and its up are kept in separate frames). A picture waits for both.
        var unseen = false
        for step in steps {
            if step == .look {
                if unseen { run.run(2 * frameLength) }
                unseen = false
            } else if case .wait = step {
            } else {
                unseen = true
            }
            switch step {
            case let .tap(point):
                run.approach(point)
                // A frame with the finger down, so two taps in a row are two taps.
                run.send(.touchDown(point))
                run.fingers = [point]
                run.run(frameLength)
                run.send(.touchUp(point))
                run.fingers = []
            case let .drag(from, to, seconds):
                run.approach(from)
                run.send(.touchDown(from))
                run.fingers = [from]
                run.tick()
                run.run(max(seconds, 2 * frameLength)) { run, progress in
                    let point = Point2(x: from.x + (to.x - from.x) * progress, y: from.y + (to.y - from.y) * progress)
                    run.send(.touchMoved(point))
                    run.fingers = [point]
                }
                run.send(.touchUp(to))
                run.fingers = []
                run.last = to
            case let .down(point, finger):
                let id = max(finger, 1) - 1
                if let before = held[id] {
                    run.send(ended(id, before))
                    held[id] = nil
                    run.fingers = fingers(held)
                    run.run(2 * frameLength)
                }
                // Only the first finger is seen travelling there; another just lands.
                if held.isEmpty { run.approach(point) }
                run.send(began(id, point))
                held[id] = point
                run.fingers = fingers(held)
                run.run(frameLength)
            case let .move(to, seconds, finger):
                let id = max(finger, 1) - 1
                guard let from = held[id] else { continue }
                let others = held
                run.run(max(seconds, 2 * frameLength)) { run, progress in
                    let point = Point2(x: from.x + (to.x - from.x) * progress, y: from.y + (to.y - from.y) * progress)
                    run.send(moved(id, point))
                    var now = others
                    now[id] = point
                    run.fingers = fingers(now)
                }
                held[id] = to
                run.last = to
            case let .up(finger):
                let id = max(finger, 1) - 1
                guard let point = held[id] else { continue }
                run.send(ended(id, point))
                held[id] = nil
                run.fingers = fingers(held)
            case let .wait(seconds):
                run.run(seconds, shownIn: 2)
            case let .type(text):
                // A tap that gave a field focus needs its frames first.
                run.run(3 * frameLength)
                run.send(.text(text))
                run.run(frameLength)
            case .submit:
                run.run(3 * frameLength)
                run.send(.submit)
                run.run(frameLength)
            case .deleteBackward:
                run.run(3 * frameLength)
                run.send(.deleteBackward)
                run.run(frameLength)
            case let .pinch(at, scale, rotation, seconds, pan):
                // Fingers already down would make it four: they lift first.
                if !held.isEmpty {
                    for (id, point) in held.sorted(by: { $0.key < $1.key }) { run.send(ended(id, point)) }
                    held = [:]
                    run.fingers = []
                    run.run(2 * frameLength)
                }
                run.approach(at)
                var places = pinchFingers(at: at, scale: 1, rotation: 0)
                run.send(.touchBegan(id: 0, places[0]))
                run.send(.touchBegan(id: 1, places[1]))
                run.fingers = places
                run.tick()
                run.run(max(seconds, 2 * frameLength)) { run, progress in
                    let (spread, turn) = (1 + (scale - 1) * progress, rotation * progress)
                    let middle = Point2(x: at.x + pan.x * progress, y: at.y + pan.y * progress)
                    places = pinchFingers(at: middle, scale: spread, rotation: turn)
                    run.send(.touchChanged(id: 0, places[0]))
                    run.send(.touchChanged(id: 1, places[1]))
                    run.fingers = places
                }
                run.send(.touchEnded(id: 0, places[0]))
                run.send(.touchEnded(id: 1, places[1]))
                run.fingers = []
                run.last = Point2(x: at.x + pan.x, y: at.y + pan.y)
            case let .hover(point):
                run.send(.hover(point))
                run.resting = point
                if let point { run.last = point }
                run.run(2 * frameLength)
            case .look:
                run.beats.append(.look)
            }
        }
        // A moment to see the last finger leave. What was sent after the last frame is
        // left unsent, as it is in a run that is not paced: there the pictures are done.
        if paced { run.rest(0.3) }
        return run.beats
    }

    /// Where two fingers are in a pinch: either side of the middle, as far apart as it has
    /// spread and turned as far as it has turned.
    static func pinchFingers(at middle: Point2, scale: Double, rotation: Double) -> [Point2] {
        let reach = 44 * max(scale, 0.1), angle = rotation * .pi / 180
        let offset = Point2(x: cos(angle) * reach, y: sin(angle) * reach)
        return [Point2(x: middle.x - offset.x, y: middle.y - offset.y), Point2(x: middle.x + offset.x, y: middle.y + offset.y)]
    }

    /// The frames of a run as they are put together.
    private struct Run {
        var beats: [Beat] = []
        var pending: [InputEvent] = []
        var fingers: [Point2] = []
        var resting: Point2?
        /// Where a finger last was, which is where it sets off from for the next touch.
        var last: Point2?
        var left: Double
        let paced: Bool

        mutating func send(_ event: InputEvent) { pending.append(event) }

        private var isFull: Bool { paced && beats.count >= ViewerSnapshot.longestPacedRun }

        /// A frame of the prototype's time, `ticks` sixtieths long, carrying what was sent
        /// since the last.
        mutating func tick(_ ticks: Int = 1) {
            guard !isFull else {
                pending = []
                return
            }
            beats.append(.frame(Frame(events: pending, fingers: fingers, resting: resting, ticks: ticks)))
            pending = []
        }

        /// A frame in which the prototype stands still, for someone watching only. What
        /// was sent since the last frame waits for the next one of the prototype's own.
        mutating func still() {
            guard paced, !isFull else { return }
            beats.append(.frame(Frame(fingers: fingers, resting: resting, ticks: 0)))
        }

        /// Frames for `seconds` of the steps' own time, out of what is left of the limit.
        /// A paced run shows them in `shownIn` seconds at most, by putting several of the
        /// prototype's frames into each one shown.
        mutating func run(_ seconds: Double, shownIn: Double? = nil, each: ((inout Run, Double) -> Void)? = nil) {
            let total = min(seconds, left)
            guard total > 0 else { return }
            left -= total
            let frames = max(Int((total / frameLength).rounded()), 1)
            if paced, let shownIn, total > shownIn {
                let shown = max(Int((shownIn / frameLength).rounded()), 1)
                for index in 0..<shown {
                    tick((index + 1) * frames / shown - index * frames / shown)
                }
                return
            }
            for index in 1...frames {
                each?(&self, Double(index) / Double(frames))
                tick()
            }
        }

        /// Frames in which nothing happens but the prototype stands still, for someone
        /// watching only: time to see the last finger leave.
        mutating func rest(_ seconds: Double) {
            for _ in 0..<max(Int((seconds / frameLength).rounded()), 1) { still() }
        }

        /// The finger travels to where it will touch next, for someone watching only. It
        /// travels during the frames just before in which nothing was touching, such as a
        /// wait. Where there are too few of those the prototype stands still for the rest.
        mutating func approach(_ point: Point2) {
            defer { last = point }
            guard paced else { return }
            let from = last ?? point
            // A finger that is already there only needs a moment to be seen arriving.
            let wanted = from == point ? (last == nil ? 8 : 0) : 18
            guard wanted > 0 else { return }
            // The frames just before in which no finger of ours was anywhere.
            var free: [Int] = []
            var index = beats.count - 1
            while index >= 0, free.count < wanted {
                guard case let .frame(frame) = beats[index] else {
                    index -= 1
                    continue
                }
                guard frame.fingers.isEmpty, frame.resting == nil else { break }
                free.append(index)
                index -= 1
            }
            free.reverse()
            // Too few to read as movement: the prototype waits for the finger instead.
            let added = free.count >= wanted / 2 ? 0 : wanted - free.count
            let total = free.count + added
            func place(_ step: Int) -> Point2 {
                let progress = Double(step) / Double(total)
                // Eases out: quick to set off, gentle to arrive.
                let eased = 1 - (1 - progress) * (1 - progress)
                return Point2(x: from.x + (point.x - from.x) * eased, y: from.y + (point.y - from.y) * eased)
            }
            for (step, index) in free.enumerated() {
                guard case var .frame(frame) = beats[index] else { continue }
                frame.resting = place(step + 1)
                beats[index] = .frame(frame)
            }
            let hovering = resting
            for step in 0..<added {
                resting = place(free.count + step + 1)
                still()
            }
            resting = hovering
        }
    }

    /// Runs `document` from the start through `steps` and returns one picture per `.look`.
    /// At most `limit` seconds of prototype time are run in all.
    public static func bitmaps(
        of document: PaperModel.Document,
        assets: [String: Data] = [:],
        registry: PatchRegistry = .standard,
        steps: [Step],
        margin: CGFloat = 0,
        scale: Int = 1,
        limit: Double = 30,
        startScreen: LayerID? = nil
    ) -> [NSBitmapImageRep] {
        // A store of its own, so the running Viewer keeps its place as the document's runtime.
        let store = DocumentStore(package: DocumentPackage(document: document, assets: assets), registry: registry)
        let screen = store.document.screen.value(.size).sizeValue
        // A picture is over before any answer could arrive, so nothing is sent: a Network
        // Request patch stays in its loading state.
        let view = ViewerView(store: store, sendsRequests: false)
        view.fillsWindow = margin == 0
        view.frame = CGRect(x: 0, y: 0, width: screen.width + margin * 2, height: screen.height + margin * 2)
        view.layoutSubtreeIfNeeded()
        // On a screen in the middle of a flow, as Preview from Here does.
        if let startScreen {
            view.runtime.startPage = startScreen
            view.runtime.restart()
        }
        view.advance(by: frameLength)

        var pictures: [NSBitmapImageRep] = []
        for beat in beats(for: steps, limit: limit) {
            switch beat {
            case let .frame(frame):
                for event in frame.events { view.runtime.send(event) }
                view.advance(by: frameLength)
            case .look:
                // No bigger than a large display: an screen a million points wide is a mistake.
                guard view.bounds.width * CGFloat(scale) <= 8192, view.bounds.height * CGFloat(scale) <= 8192,
                      view.bounds.width >= 1, view.bounds.height >= 1 else { continue }
                guard let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: Int(view.bounds.width) * scale, pixelsHigh: Int(view.bounds.height) * scale,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
                context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                view.layer?.render(in: context.cgContext)
                pictures.append(bitmap)
            }
        }
        return pictures
    }

    public static func png(
        of document: PaperModel.Document, assets: [String: Data] = [:], registry: PatchRegistry = .standard,
        tap: Point2? = nil, seconds: Double = 0, startScreen: LayerID? = nil
    ) -> Data? {
        bitmap(of: document, assets: assets, registry: registry, tap: tap, seconds: seconds, startScreen: startScreen)?
            .representation(using: .png, properties: [:])
    }
}
