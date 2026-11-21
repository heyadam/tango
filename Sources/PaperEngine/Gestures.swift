import Foundation
import PaperModel

/// The distances and times gestures are told apart by.
public enum GestureMetrics {
    /// How far a touch may move and still count as a tap; a pan or a scroll begins beyond it.
    public static let tapSlop: Double = 10
    /// Two taps within this many seconds are a double tap.
    public static let doubleTapInterval: Double = 0.3
    /// Holding still this long is a long press, and no longer a tap.
    public static let longPressDelay: Double = 0.5
    /// A swipe is a touch that moved at least this far and was still moving this fast when lifted.
    public static let swipeDistance: Double = 40
    public static let swipeSpeed: Double = 200
    /// Points the distance between two fingers must change before a pinch begins.
    public static let pinchSlop: Double = 8
    /// Degrees two fingers must turn before a rotation begins.
    public static let rotationSlop: Double = 5
}

/// Recognizes gestures from touches, as UIKit's gesture recognizers do: every recognizer a
/// touch could mean is tried at once, and the first to begin takes the touch from the rest.
///
/// The arena knows nothing of views or patches. Its host says, for each touch that comes
/// down, which recognizers it is offered to (`Candidate`, innermost view first), and reads
/// back what each one reports (`reading`). It has no clock: `advance` is told the time.
///
/// The rules, in order:
/// 1. The first recognizer to begin wins: the others on its touches fail. One listed
///    earlier (a deeper view) is asked first.
/// 2. Pan, Pinch and Rotation on the same view recognize together.
/// 3. A tap waits for a tap with more taps on the same view to fail.
/// 4. A long press that begins fails the taps on its touches.
/// 5. A scroll view begins once the finger has left `tapSlop` along its axis, and then
///    cancels the touch of what is inside it. A drag across its axis that something in
///    the content could mean is left to the content.
/// 6. A value never jumps when a gesture begins: it is measured from where it began.
/// 7. A scroll view takes one finger: two on a view that listens for two take it away.
/// 8. A raw touch (`Kind.touch`) is no recognizer. It never stops another, and only a
///    scroll view or the host cancels it.
public struct GestureArena: Sendable {
    public typealias Hit = ResolvedLayer.Hit

    public enum PanDirection: Sendable, Equatable { case any, horizontal, vertical }
    public enum SwipeDirection: Int, Sendable, Equatable { case left, right, up, down }

    public enum Kind: Sendable, Equatable {
        /// The first finger on a view, followed from down to up: what an Interaction reports.
        case touch
        case tap(taps: Int, fingers: Int)
        case longPress(duration: Double, fingers: Int)
        /// `maxFingers` 0 is any number.
        case pan(direction: PanDirection, minFingers: Int, maxFingers: Int)
        case pinch
        case rotation
        case swipe(fingers: Int)
        /// A scroll view. One that is `moving` when the finger lands is caught at once.
        case scroll(horizontal: Bool, moving: Bool)
    }

    /// A recognizer a touch is offered to. `owner` is whatever the host tells them apart by.
    public struct Candidate: Sendable, Equatable {
        public var owner: Int
        public var hit: Hit
        public var kind: Kind

        public init(owner: Int, hit: Hit, kind: Kind) {
            self.owner = owner
            self.hit = hit
            self.kind = kind
        }
    }

    public struct Key: Sendable, Hashable {
        public var owner: Int
        public var hit: Hit

        public init(owner: Int, hit: Hit) {
            self.owner = owner
            self.hit = hit
        }
    }

    /// What a recognizer reports. `began`, `ended`, `recognized`, `tapped`, `doubleTapped`
    /// and `longPressed` are true for the one frame it happened in.
    public struct Reading: Sendable, Equatable {
        /// A continuous gesture is under way; for a raw touch, the finger is down.
        public var isActive = false
        public var began = false
        public var ended = false
        /// A tap or a swipe happened.
        public var recognized = false
        public var swipe: SwipeDirection?
        /// How far the fingers have travelled since the gesture began (a raw touch: since
        /// the finger came down).
        public var translation = Point2.zero
        /// Points a second.
        public var velocity = Point2.zero
        /// The middle of the fingers.
        public var position = Point2.zero
        public var scale = 1.0
        /// Scale a second.
        public var scaleVelocity = 0.0
        /// Degrees, clockwise, counted past half and full turns.
        public var rotation = 0.0
        /// Degrees a second.
        public var rotationVelocity = 0.0
        public var tapped = false
        public var doubleTapped = false
        public var longPressed = false
    }

    /// A finger, from when it came down.
    public struct TouchPoint: Sendable, Equatable {
        public let id: Int
        public let start: Point2
        public internal(set) var current: Point2
        var previous: Point2
        public internal(set) var velocity = Point2.zero
        public let downTime: Double
        /// The furthest it has been from where it came down.
        public internal(set) var travelled = 0.0
        public internal(set) var isDown = true
        /// Whether anything was listening for it.
        public internal(set) var isTracked = false
        /// Held still long enough to be a long press, so no longer a tap.
        public internal(set) var heldLong = false
        /// A scroll view took it, or the host cancelled it.
        public internal(set) var wasTaken = false

        /// Whether it came down and went up as a tap does.
        public var isTap: Bool {
            !isDown && travelled <= GestureMetrics.tapSlop && !heldLong && !wasTaken
        }
    }

    private enum State: Sendable { case possible, active, ended, failed }

    private struct Recognizer: Sendable {
        /// Changes only when the host renumbers its owners.
        var key: Key
        var kind: Kind
        /// Its place among the candidates of the touch that made it: lower is deeper.
        var depth: Int
        var state = State.possible
        /// The touches it follows that are still down, in the order they came.
        var touches: [Int] = []
        var reading = Reading()
        /// Driven by the host's own recognition (a trackpad), not by touches.
        var indirect = false

        // Tap.
        var tapsDone = 0
        var fingersThisTap = 0
        var lastTapTime = 0.0
        /// Has its taps and waits for a tap with more of them to fail.
        var deferred = false

        // Pan: where the middle of the fingers was when the set of fingers last changed,
        // and what the gesture had reported by then.
        var origin = Point2.zero
        var base = Point2.zero
        var carried = Point2.zero

        // Pinch and rotation.
        var originSpread = 1.0
        var baseSpread = 1.0
        var lastAngle = 0.0
        /// Degrees the fingers have turned since both were down.
        var turned = 0.0
        var baseTurn = 0.0
        var lastScale = 1.0
        var lastRotation = 0.0

        // Swipe.
        var mostFingers = 0

        var isContinuous: Bool {
            switch kind {
            case .pan, .pinch, .rotation: true
            default: false
            }
        }
    }

    private var touches: [Int: TouchPoint] = [:]
    private var recognizers: [Key: Recognizer] = [:]
    /// Keys in the order recognizers are asked: deeper views first, then as they were made.
    private var order: [Key] = []
    /// When each raw touch last saw a tap, for telling a double tap. Kept by recognizer:
    /// two Interactions on one view each count their own.
    private var lastTaps: [Key: Double] = [:]
    /// The fingers that have moved since the recognizers last looked.
    private var moved: Set<Int> = []

    public init() {}

    // MARK: Reading

    /// What a recognizer reports this frame, or nil when no touch concerns it.
    public func reading(owner: Int, hit: Hit) -> Reading? {
        recognizers[Key(owner: owner, hit: hit)]?.reading
    }

    public func touch(_ id: Int) -> TouchPoint? { touches[id] }

    /// The fingers that are down, by id.
    public var fingersDown: [TouchPoint] {
        touches.values.filter(\.isDown).sorted { $0.id < $1.id }
    }

    /// Whether something here changes with time alone: a finger down (a long press may
    /// come), a tap waiting for another, a gesture under way.
    public var needsFrames: Bool {
        touches.values.contains { $0.isDown && $0.isTracked } || recognizers.values.contains { recognizer in
            recognizer.state == .active || (recognizer.state == .possible && (recognizer.tapsDone > 0 || recognizer.deferred))
        }
    }

    // MARK: Frames

    /// Starts a frame: what happened in the last one is no longer new, and recognizers
    /// that have finished and have no finger left are forgotten.
    public mutating func beginFrame() {
        for key in order {
            guard var recognizer = recognizers[key] else { continue }
            recognizer.reading.began = false
            recognizer.reading.ended = false
            recognizer.reading.recognized = false
            recognizer.reading.swipe = nil
            recognizer.reading.tapped = false
            recognizer.reading.doubleTapped = false
            recognizer.reading.longPressed = false
            let waiting = recognizer.state == .possible && (recognizer.tapsDone > 0 || recognizer.deferred)
            let done = recognizer.touches.isEmpty && !waiting && !(recognizer.indirect && recognizer.state == .active)
            recognizers[key] = done ? nil : recognizer
        }
        order.removeAll { recognizers[$0] == nil }
        touches = touches.filter(\.value.isDown)
    }

    /// Moves time on: speeds are measured, long presses begin, taps stop waiting.
    public mutating func advance(time now: Double, dt: Double) {
        settle()
        if !lastTaps.isEmpty {
            lastTaps = lastTaps.filter { now - $0.value <= GestureMetrics.doubleTapInterval }
        }
        for (id, var touch) in touches where touch.isDown {
            if dt > 0 {
                let raw = (touch.current - touch.previous) * (1 / dt)
                touch.velocity = touch.velocity * 0.5 + raw * 0.5
            }
            touch.previous = touch.current
            let held = touch.isTracked && !touch.wasTaken && touch.travelled <= GestureMetrics.tapSlop
                && now - touch.downTime >= GestureMetrics.longPressDelay
            if held, !touch.heldLong {
                touch.heldLong = true
                for key in order where recognizers[key]?.kind == .touch && recognizers[key]?.touches.first == id {
                    recognizers[key]?.reading.longPressed = true
                }
            }
            touches[id] = touch
        }

        for key in order {
            guard var recognizer = recognizers[key] else { continue }
            switch recognizer.kind {
            case let .longPress(duration, fingers):
                guard recognizer.state == .possible, recognizer.touches.count == max(fingers, 1) else { break }
                let latest = recognizer.touches.compactMap { touches[$0]?.downTime }.max() ?? now
                if now - latest >= max(duration, 0) {
                    recognizer.reading.position = middle(of: recognizer)
                    recognizers[key] = recognizer
                    begin(key)
                    continue
                }
            case .tap:
                guard recognizer.state == .possible else { break }
                if let first = recognizer.touches.compactMap({ touches[$0]?.downTime }).min() {
                    // Held too long to be a tap.
                    if now - first >= GestureMetrics.longPressDelay { recognizer.state = .failed }
                } else if recognizer.deferred {
                    if !isWaitedFor(by: recognizer) {
                        recognizers[key] = recognizer
                        recognizeTap(key)
                        continue
                    }
                } else if recognizer.tapsDone > 0, now - recognizer.lastTapTime > GestureMetrics.doubleTapInterval {
                    recognizer.state = .failed
                }
            case .pan where recognizer.state == .active:
                let speeds = recognizer.touches.compactMap { touches[$0]?.velocity }
                if !speeds.isEmpty {
                    recognizer.reading.velocity = speeds.reduce(.zero, +) * (1 / Double(speeds.count))
                }
            case .pinch where recognizer.state == .active, .rotation where recognizer.state == .active:
                if dt > 0 {
                    let scaling = (recognizer.reading.scale - recognizer.lastScale) / dt
                    let turning = (recognizer.reading.rotation - recognizer.lastRotation) / dt
                    recognizer.reading.scaleVelocity = (recognizer.reading.scaleVelocity * 0.5 + scaling * 0.5).clampedFinite
                    recognizer.reading.rotationVelocity = (recognizer.reading.rotationVelocity * 0.5 + turning * 0.5).clampedFinite
                }
                recognizer.lastScale = recognizer.reading.scale
                recognizer.lastRotation = recognizer.reading.rotation
            case .touch where recognizer.state == .active:
                if let id = recognizer.touches.first, let touch = touches[id] {
                    recognizer.reading.velocity = touch.velocity
                }
            default:
                break
            }
            recognizers[key] = recognizer
        }
    }

    /// The host has renumbered its owners (a document was edited while fingers were down):
    /// each recognizer goes on under its new number, and one whose owner is gone is
    /// dropped, its gesture with it.
    public mutating func renumberOwners(_ new: (Int) -> Int?) {
        var renamed: [Key: Recognizer] = [:]
        var kept: [Key] = []
        var taps: [Key: Double] = [:]
        for key in order {
            guard let recognizer = recognizers[key], let owner = new(key.owner) else { continue }
            let moved = Key(owner: owner, hit: key.hit)
            guard renamed[moved] == nil else { continue }
            var copy = recognizer
            copy.key = moved
            renamed[moved] = copy
            kept.append(moved)
        }
        for (key, time) in lastTaps {
            if let owner = new(key.owner) { taps[Key(owner: owner, hit: key.hit)] = time }
        }
        recognizers = renamed
        order = kept
        lastTaps = taps
    }

    /// Forgets everything, as when the prototype restarts.
    public mutating func reset() {
        self = GestureArena()
    }

    // MARK: Touches

    /// A finger came down. `candidates` are the recognizers it could mean, the deepest
    /// view's first.
    public mutating func begin(id: Int, at point: Point2, time now: Double, candidates: [Candidate]) {
        settle()
        if touches[id]?.isDown == true { cancel(id: id) }
        var touch = TouchPoint(id: id, start: point, current: point, previous: point, downTime: now)
        touch.isTracked = !candidates.isEmpty
        touches[id] = touch

        for (depth, candidate) in candidates.enumerated() {
            let key = Key(owner: candidate.owner, hit: candidate.hit)
            var recognizer = recognizers[key] ?? Recognizer(key: key, kind: candidate.kind, depth: depth)
            let finished = recognizer.state == .ended || recognizer.state == .failed
            if finished, recognizer.touches.isEmpty || recognizer.indirect {
                // Everything it followed has lifted: it starts over. What it reported in
                // this frame (a tap, an end) is still to be read.
                var reading = recognizer.reading
                reading.isActive = false
                recognizer = Recognizer(key: key, kind: candidate.kind, depth: depth)
                recognizer.reading = reading
            }
            if recognizers[key] == nil || !order.contains(key) { insert(key, depth: depth) }
            // Its settings are read afresh while it has not made up its mind.
            if recognizer.state == .possible { recognizer.kind = candidate.kind }
            add(id, to: &recognizer, at: now)
            recognizers[key] = recognizer
        }

        // A scroll view that was still moving is caught by the finger at once.
        for key in order {
            if let recognizer = recognizers[key], recognizer.state == .possible, recognizer.touches == [id],
               case .scroll(_, moving: true) = recognizer.kind {
                recognizers[key]?.base = point
                begin(key)
                break
            }
        }
        // Two fingers on something that listens for two are not a scroll.
        for key in order {
            guard let recognizer = recognizers[key], recognizer.state == .possible, case .scroll = recognizer.kind,
                  let first = recognizer.touches.first, first != id else { continue }
            let takesTwo = recognizers.values.contains { other in
                other.state == .possible && other.touches.contains(first) && other.touches.contains(id) && {
                    switch other.kind {
                    case .pinch, .rotation: true
                    case let .pan(_, _, most): most != 1
                    default: false
                    }
                }()
            }
            if takesTwo { recognizers[key]?.state = .failed }
        }
    }

    /// A finger moved. Fingers that move in the same moment are looked at together, at
    /// the next `settle`, so two fingers spreading are a pinch and never, for an instant,
    /// one finger dragging.
    public mutating func move(id: Int, to point: Point2) {
        guard var touch = touches[id], touch.isDown else { return }
        touch.current = point
        touch.travelled = max(touch.travelled, (point - touch.start).length)
        touches[id] = touch
        moved.insert(id)
    }

    /// Lets the recognizers see where the fingers have moved to. `canScroll` says whether
    /// the scroll view an owner stands for can still move its content the way a finger
    /// travelling `along` (points along its axis) would take it. Whatever else happens to
    /// a touch settles the moves before it first.
    public mutating func settle(canScroll: (_ owner: Int, _ along: Double) -> Bool = { _, _ in true }) {
        guard !moved.isEmpty else { return }
        let ids = moved
        moved = []
        func left(_ recognizer: Recognizer) -> Bool {
            recognizer.touches.contains { ids.contains($0) && (touches[$0]?.travelled ?? 0) > GestureMetrics.tapSlop }
        }

        for key in order {
            guard var recognizer = recognizers[key], recognizer.touches.contains(where: ids.contains) else { continue }
            let leftSlop = left(recognizer)
            switch recognizer.kind {
            case .touch:
                guard recognizer.state == .active, let id = recognizer.touches.first, ids.contains(id),
                      let touch = touches[id] else { continue }
                recognizer.reading.translation = touch.current - touch.start
                recognizer.reading.position = touch.current
            case .tap:
                if recognizer.state == .possible, leftSlop { recognizer.state = .failed }
            case .longPress:
                if recognizer.state == .possible, leftSlop { recognizer.state = .failed }
                if recognizer.state == .active { recognizer.reading.position = middle(of: recognizer) }
            case .swipe:
                break
            case let .pan(direction, least, most):
                let center = middle(of: recognizer)
                if recognizer.state == .active {
                    recognizer.reading.translation = recognizer.carried + (center - recognizer.base)
                    recognizer.reading.position = center
                } else if recognizer.state == .possible {
                    let count = recognizer.touches.count
                    guard count >= max(least, 1), most <= 0 || count <= most else { break }
                    let travel = center - recognizer.origin
                    guard travel.length > GestureMetrics.tapSlop else { break }
                    let sideways = abs(travel.x) >= abs(travel.y)
                    if (direction == .horizontal && !sideways) || (direction == .vertical && sideways) {
                        recognizer.state = .failed
                        break
                    }
                    // Measured from where it left the slop, so nothing jumps.
                    recognizer.base = recognizer.origin + travel * (GestureMetrics.tapSlop / travel.length)
                    recognizer.carried = .zero
                    recognizer.reading.translation = center - recognizer.base
                    recognizer.reading.position = center
                    recognizer.reading.velocity = .zero
                    recognizers[key] = recognizer
                    begin(key)
                    continue
                }
            case .pinch, .rotation:
                guard recognizer.touches.count == 2, !recognizer.indirect else { break }
                let (spread, angle) = arms(of: recognizer)
                turn(&recognizer, to: angle, spread: spread)
                let center = middle(of: recognizer)
                if recognizer.state == .possible {
                    if recognizer.kind == .pinch {
                        let change = spread - recognizer.originSpread
                        guard abs(change) > GestureMetrics.pinchSlop else { break }
                        recognizer.baseSpread = max(recognizer.originSpread + (change > 0 ? 1 : -1) * GestureMetrics.pinchSlop, 1)
                        recognizer.baseTurn = recognizer.turned
                    } else {
                        guard abs(recognizer.turned) > GestureMetrics.rotationSlop else { break }
                        recognizer.baseTurn = (recognizer.turned > 0 ? 1 : -1) * GestureMetrics.rotationSlop
                    }
                    measure(&recognizer, spread: spread, center: center)
                    recognizer.lastScale = 1
                    recognizer.lastRotation = 0
                    recognizer.reading.scaleVelocity = 0
                    recognizer.reading.rotationVelocity = 0
                    recognizers[key] = recognizer
                    begin(key)
                    continue
                } else if recognizer.state == .active {
                    measure(&recognizer, spread: spread, center: center)
                }
            case .scroll:
                guard let id = recognizer.touches.first, ids.contains(id), let touch = touches[id] else { continue }
                if recognizer.state == .active {
                    recognizer.reading.translation = touch.current - recognizer.base
                    recognizer.reading.position = touch.current
                } else if recognizer.state == .possible, leftSlop {
                    // Settled here, at the innermost scroll view's turn: what is inside it
                    // has had its chance, and what is around it has not.
                    decideScroll(for: touch, canScroll: canScroll)
                    continue
                }
            }
            recognizers[key] = recognizer
        }
    }

    /// A finger lifted. Returns it as it was, so the host can tell a tap from a drag.
    @discardableResult
    public mutating func end(id: Int, at point: Point2, time now: Double) -> TouchPoint? {
        settle()
        guard var touch = touches[id], touch.isDown else { return nil }
        touch.current = point
        touch.travelled = max(touch.travelled, (point - touch.start).length)
        touch.isDown = false
        touches[id] = touch

        for key in order {
            guard var recognizer = recognizers[key], recognizer.touches.contains(id) else { continue }
            let left = recognizer.touches.filter { $0 != id }
            switch recognizer.kind {
            case .touch:
                guard recognizer.touches.first == id, recognizer.state == .active else { break }
                recognizer.state = .ended
                recognizer.reading.isActive = false
                recognizer.reading.translation = point - touch.start
                recognizer.reading.position = point
                if touch.isTap {
                    recognizer.reading.tapped = true
                    if let last = lastTaps[key], now - last <= GestureMetrics.doubleTapInterval {
                        recognizer.reading.doubleTapped = true
                        lastTaps[key] = nil
                    } else {
                        lastTaps[key] = now
                    }
                }
            case let .tap(taps, fingers):
                guard recognizer.state == .possible else { break }
                if touch.travelled > GestureMetrics.tapSlop || touch.heldLong {
                    recognizer.state = .failed
                } else if left.isEmpty {
                    if recognizer.fingersThisTap != max(fingers, 1) {
                        recognizer.state = .failed
                    } else {
                        recognizer.tapsDone += 1
                        recognizer.fingersThisTap = 0
                        recognizer.lastTapTime = now
                        recognizer.reading.position = point
                        if recognizer.tapsDone >= max(taps, 1) {
                            recognizer.touches = left
                            if isWaitedFor(by: recognizer) {
                                recognizer.deferred = true
                                recognizers[key] = recognizer
                            } else {
                                recognizers[key] = recognizer
                                recognizeTap(key, touch: id)
                            }
                            continue
                        }
                    }
                }
            case .longPress:
                if recognizer.state == .active {
                    finish(&recognizer)
                } else if recognizer.state == .possible {
                    recognizer.state = .failed
                }
            case let .pan(_, least, _):
                if recognizer.state == .active {
                    // Where it lifted is the last place it went.
                    let center = middle(of: recognizer)
                    recognizer.reading.translation = recognizer.carried + (center - recognizer.base)
                    recognizer.reading.position = center
                    if left.count < max(least, 1) {
                        finish(&recognizer)
                    } else {
                        // The fingers that stay carry on from here.
                        recognizer.carried = recognizer.reading.translation
                        recognizer.base = middle(of: left)
                        recognizer.reading.position = recognizer.base
                    }
                } else if recognizer.state == .possible {
                    if left.isEmpty { recognizer.state = .failed } else { recognizer.origin = middle(of: left) }
                }
            case .pinch, .rotation:
                if recognizer.state == .active {
                    if recognizer.touches.count == 2, !recognizer.indirect {
                        let (spread, angle) = arms(of: recognizer)
                        turn(&recognizer, to: angle, spread: spread)
                        measure(&recognizer, spread: spread, center: middle(of: recognizer))
                    }
                    finish(&recognizer)
                } else if recognizer.state == .possible, left.isEmpty {
                    recognizer.state = .failed
                }
            case let .swipe(fingers):
                guard recognizer.state == .possible else { break }
                let travel = point - touch.start
                if recognizer.mostFingers == max(fingers, 1), travel.length >= GestureMetrics.swipeDistance,
                   touch.velocity.length >= GestureMetrics.swipeSpeed, !isBlocked(recognizer) {
                    recognizer.reading.swipe = abs(travel.x) >= abs(travel.y)
                        ? (travel.x < 0 ? .left : .right) : (travel.y < 0 ? .up : .down)
                    recognizer.reading.recognized = true
                    recognizer.reading.position = point
                    recognizer.state = .ended
                    recognizers[key] = recognizer
                    failOthers(than: key)
                    recognizer = recognizers[key] ?? recognizer
                } else {
                    recognizer.state = .failed
                }
            case .scroll:
                guard recognizer.touches.first == id else { break }
                if recognizer.state == .active {
                    recognizer.reading.translation = point - recognizer.base
                    finish(&recognizer)
                } else if recognizer.state == .possible {
                    recognizer.state = .failed
                }
            }
            recognizer.touches = left
            recognizers[key] = recognizer
        }
        return touch
    }

    /// A finger was taken away without lifting: the host lost it. Nothing it was doing
    /// counts as done.
    public mutating func cancel(id: Int) {
        settle()
        guard var touch = touches[id], touch.isDown else { return }
        touch.isDown = false
        touch.wasTaken = true
        touches[id] = touch
        for key in order {
            guard var recognizer = recognizers[key], recognizer.touches.contains(id) else { continue }
            if recognizer.state == .active {
                finish(&recognizer)
            } else if recognizer.state == .possible {
                recognizer.state = .failed
            }
            recognizer.touches.removeAll { $0 == id }
            recognizers[key] = recognizer
        }
    }

    // MARK: A pinch the host recognized

    /// A pinch the host has already recognized, as a trackpad's: `candidates` are the
    /// Pinch and Rotation recognizers of the view under it.
    public mutating func indirectBegan(at point: Point2, candidates: [Candidate]) {
        indirectEnded()
        for (depth, candidate) in candidates.enumerated() {
            let key = Key(owner: candidate.owner, hit: candidate.hit)
            // Touches that could have meant something else on this view no longer do.
            for other in order where other != key {
                guard let rival = recognizers[other], rival.key.hit == key.hit, rival.kind != .touch,
                      rival.state == .possible, !candidates.contains(where: { $0.owner == other.owner && $0.hit == other.hit })
                else { continue }
                recognizers[other]?.state = .failed
            }
            var recognizer = Recognizer(key: key, kind: candidate.kind, depth: depth)
            recognizer.indirect = true
            recognizer.state = .active
            recognizer.reading.isActive = true
            recognizer.reading.began = true
            recognizer.reading.position = point
            if recognizers[key] == nil || !order.contains(key) { insert(key, depth: depth) }
            recognizers[key] = recognizer
        }
    }

    /// How far the host's pinch has spread (1 is where it started) and turned, in degrees.
    public mutating func indirectChanged(scale: Double, rotation: Double) {
        for key in order {
            guard var recognizer = recognizers[key], recognizer.indirect, recognizer.state == .active else { continue }
            recognizer.reading.scale = scale.clampedFinite
            recognizer.reading.rotation = rotation.clampedFinite
            recognizers[key] = recognizer
        }
    }

    public mutating func indirectEnded() {
        for key in order {
            guard var recognizer = recognizers[key], recognizer.indirect, recognizer.state == .active else { continue }
            finish(&recognizer)
            recognizers[key] = recognizer
        }
    }

    // MARK: Rules

    private mutating func insert(_ key: Key, depth: Int) {
        order.removeAll { $0 == key }
        let index = order.firstIndex { (recognizers[$0]?.depth ?? 0) > depth } ?? order.count
        order.insert(key, at: index)
    }

    private mutating func add(_ id: Int, to recognizer: inout Recognizer, at now: Double) {
        guard let touch = touches[id] else { return }
        switch recognizer.kind {
        case .touch:
            // The first finger only.
            guard recognizer.touches.isEmpty else { return }
            recognizer.state = .active
            recognizer.reading.isActive = true
            recognizer.reading.translation = .zero
            recognizer.reading.position = touch.start
            recognizer.reading.velocity = .zero
            recognizer.touches = [id]
        case let .tap(_, fingers):
            guard recognizer.state == .possible else { recognizer.touches.append(id); return }
            // It has its taps and waits to hear whether they were the start of more.
            if recognizer.deferred { return }
            if recognizer.tapsDone > 0, recognizer.touches.isEmpty,
               now - recognizer.lastTapTime > GestureMetrics.doubleTapInterval {
                recognizer.tapsDone = 0
            }
            recognizer.touches.append(id)
            recognizer.fingersThisTap = max(recognizer.fingersThisTap, recognizer.touches.count)
            if recognizer.fingersThisTap > max(fingers, 1) { recognizer.state = .failed }
        case let .longPress(_, fingers):
            recognizer.touches.append(id)
            if recognizer.state == .possible, recognizer.touches.count > max(fingers, 1) { recognizer.state = .failed }
        case let .pan(_, _, most):
            if recognizer.state == .active {
                // One more finger joins a pan that has room for it; the middle moves, the pan does not.
                guard most <= 0 || recognizer.touches.count < most else { return }
                recognizer.carried = recognizer.reading.translation
                recognizer.touches.append(id)
                recognizer.base = middle(of: recognizer)
            } else {
                recognizer.touches.append(id)
                recognizer.origin = middle(of: recognizer)
                if recognizer.state == .possible, most > 0, recognizer.touches.count > most { recognizer.state = .failed }
            }
        case .pinch, .rotation:
            guard recognizer.touches.count < 2, !recognizer.indirect else { return }
            recognizer.touches.append(id)
            if recognizer.touches.count == 2 {
                let (spread, angle) = arms(of: recognizer)
                recognizer.originSpread = spread
                recognizer.lastAngle = angle
                recognizer.turned = 0
            }
        case .swipe:
            recognizer.touches.append(id)
            recognizer.mostFingers = max(recognizer.mostFingers, recognizer.touches.count)
        case .scroll:
            // One finger.
            guard recognizer.touches.isEmpty else { return }
            recognizer.touches = [id]
        }
    }

    private func middle(of recognizer: Recognizer) -> Point2 { middle(of: recognizer.touches) }

    private func middle(of ids: [Int]) -> Point2 {
        let points = ids.compactMap { touches[$0]?.current }
        guard !points.isEmpty else { return .zero }
        return points.reduce(.zero, +) * (1 / Double(points.count))
    }

    /// How far apart a recognizer's two fingers are, and the angle from the first to the second.
    private func arms(of recognizer: Recognizer) -> (spread: Double, angle: Double) {
        guard recognizer.touches.count == 2, let first = touches[recognizer.touches[0]],
              let second = touches[recognizer.touches[1]] else { return (1, 0) }
        let arm = second.current - first.current
        return (max(arm.length, 1), atan2(arm.y, arm.x))
    }

    /// Counts how far two fingers have turned, past half and full turns.
    private func turn(_ recognizer: inout Recognizer, to angle: Double, spread: Double) {
        // Too close together to say which way they point.
        guard spread > 1 else { return }
        var turn = angle - recognizer.lastAngle
        if turn > .pi { turn -= 2 * .pi }
        if turn < -.pi { turn += 2 * .pi }
        recognizer.turned += turn * 180 / .pi
        recognizer.lastAngle = angle
    }

    private func measure(_ recognizer: inout Recognizer, spread: Double, center: Point2) {
        if recognizer.kind == .pinch {
            recognizer.reading.scale = (spread / max(recognizer.baseSpread, 1)).clampedFinite
        }
        recognizer.reading.rotation = recognizer.turned - recognizer.baseTurn
        recognizer.reading.position = center
    }

    private func finish(_ recognizer: inout Recognizer) {
        recognizer.state = .ended
        recognizer.reading.isActive = false
        recognizer.reading.ended = true
    }

    /// Pan, Pinch and Rotation on one view go together.
    private func goTogether(_ a: Recognizer, _ b: Recognizer) -> Bool {
        a.key.hit == b.key.hit && a.isContinuous && b.isContinuous
    }

    private func shares(_ a: Recognizer, _ b: Recognizer) -> Bool {
        a.touches.contains { b.touches.contains($0) }
    }

    /// Whether a gesture already under way on its touches keeps this one from beginning.
    private func isBlocked(_ recognizer: Recognizer) -> Bool {
        recognizers.values.contains { other in
            other.key != recognizer.key && other.kind != .touch && other.state == .active && !other.indirect
                && shares(other, recognizer) && !goTogether(other, recognizer)
        }
    }

    /// Fails every recognizer that was still deciding on the touches of the one that won.
    private mutating func failOthers(than key: Key) {
        guard let winner = recognizers[key] else { return }
        for other in order where other != key {
            guard let rival = recognizers[other], rival.kind != .touch, rival.state == .possible,
                  shares(rival, winner), !goTogether(rival, winner) else { continue }
            recognizers[other]?.state = .failed
        }
    }

    /// A continuous gesture begins, unless one already has its touches.
    @discardableResult
    private mutating func begin(_ key: Key) -> Bool {
        guard var recognizer = recognizers[key] else { return false }
        if isBlocked(recognizer) {
            recognizers[key]?.state = .failed
            return false
        }
        recognizer.state = .active
        recognizer.reading.isActive = true
        recognizer.reading.began = true
        recognizers[key] = recognizer
        failOthers(than: key)
        if case .scroll = recognizer.kind {
            // What is inside a scroll view loses its touch once the view scrolls.
            for id in recognizer.touches { touches[id]?.wasTaken = true }
            for other in order where other != key {
                guard var inside = recognizers[other], inside.kind == .touch, inside.state == .active,
                      shares(inside, recognizer) else { continue }
                inside.state = .ended
                inside.reading.isActive = false
                recognizers[other] = inside
            }
        }
        return true
    }

    /// Whether a tap with more taps on the same view could still happen.
    private func isWaitedFor(by recognizer: Recognizer) -> Bool {
        guard case let .tap(taps, fingers) = recognizer.kind else { return false }
        return recognizers.values.contains { other in
            guard other.key != recognizer.key, other.key.hit == recognizer.key.hit, other.state == .possible,
                  case let .tap(more, same) = other.kind else { return false }
            return more > taps && same == fingers && (other.tapsDone > 0 || !other.touches.isEmpty)
        }
    }

    private mutating func recognizeTap(_ key: Key, touch id: Int? = nil) {
        guard var recognizer = recognizers[key] else { return }
        // For the rule that the first wins, the finger that just lifted still counts.
        if let id { recognizer.touches.append(id) }
        recognizers[key] = recognizer
        failOthers(than: key)
        recognizer.touches.removeAll { $0 == id }
        recognizer.state = .ended
        recognizer.deferred = false
        recognizer.reading.recognized = true
        recognizers[key] = recognizer
        // A tap that was waiting on this one has its answer.
        for other in order where other != key {
            guard let waiting = recognizers[other], waiting.key.hit == key.hit, waiting.deferred else { continue }
            recognizers[other]?.state = .failed
            recognizers[other]?.deferred = false
        }
    }

    /// Once a finger has left the slop, the scroll views waiting on it are settled: the
    /// innermost along the way it went that can still move takes it. A drag across them
    /// all is left to the content when the content has a use for it.
    private mutating func decideScroll(for touch: TouchPoint, canScroll: (Int, Double) -> Bool) {
        let waiting = order.filter { key in
            guard let recognizer = recognizers[key], recognizer.state == .possible, recognizer.touches.first == touch.id,
                  case .scroll = recognizer.kind else { return false }
            return true
        }
        guard !waiting.isEmpty else { return }
        func isHorizontal(_ key: Key) -> Bool {
            if case .scroll(horizontal: true, _)? = recognizers[key]?.kind { true } else { false }
        }
        let travel = touch.current - touch.start
        let sideways = abs(travel.x) > abs(travel.y)
        let along = waiting.filter { isHorizontal($0) == sideways }
        let distance = sideways ? travel.x : travel.y
        let chosen: Key
        if let able = along.first(where: { canScroll($0.owner, distance) }) ?? along.first {
            chosen = able
        } else {
            // Only what follows a drag: a tap or a long press still waiting is about to
            // fail on this very move, wherever it is in the order.
            let contentWantsIt = recognizers.values.contains { other in
                guard other.touches.contains(touch.id) else { return false }
                switch other.kind {
                case .touch, .pan, .swipe, .pinch, .rotation: return other.state == .active || other.state == .possible
                case .longPress: return other.state == .active
                case .tap, .scroll: return false
                }
            }
            if contentWantsIt {
                for key in waiting { recognizers[key]?.state = .failed }
                return
            }
            chosen = waiting[0]
        }
        for key in waiting where key != chosen { recognizers[key]?.state = .failed }
        recognizers[chosen]?.base = touch.start + travel * (GestureMetrics.tapSlop / max(travel.length, GestureMetrics.tapSlop))
        if begin(chosen), var scroll = recognizers[chosen] {
            scroll.reading.translation = touch.current - scroll.base
            scroll.reading.position = touch.current
            recognizers[chosen] = scroll
        }
    }
}
