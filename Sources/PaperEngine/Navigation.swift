import Foundation
import PaperModel

/// Which of a prototype's screens is showing, and how one gives way to another. Plain
/// values with no views or patches, like `GestureArena`: the runtime tells it where to go
/// (Navigate and Navigate Back patches), steps it once a frame, and asks where each screen
/// is. With no screens it does nothing.
public struct Navigation: Sendable, Equatable {
    /// How a screen arrives. Going back replays in reverse the way the screen on top came.
    public enum Style: String, Sendable, CaseIterable {
        /// In from the right while the one before drifts a little to the left.
        case push = "Push"
        /// Up from the bottom, over the one before.
        case modal = "Modal"
        /// Fades in over the one before.
        case fade = "Fade"
        /// At once, starting over on that screen: there is nothing to go back to, as when a
        /// tab is chosen. "Instant", as design tools call it; "Switch" was the Switch patch's.
        case replace = "Instant"
        /// Views with the same name on both screens move from one place to the other, and
        /// the rest crossfades (`ResolvedLayer.morph`).
        case morph = "Morph"

        /// The style a name stands for, ignoring case; "Switch", its first name, too.
        public static func named(_ name: String) -> Style? {
            let lower = name.lowercased()
            if lower == "switch" { return .replace }
            return allCases.first { $0.rawValue.lowercased() == lower }
        }
    }

    /// How close to the left edge a finger must come down to swipe back, in points.
    public static let edgeWidth = 20.0

    /// How far the screen underneath drifts during a push, as a share of the width.
    public static let parallax = 0.3
    public static let defaultResponse = 0.33

    /// One screen on the stack, and how it got there.
    public struct Entry: Sendable, Equatable {
        public var page: LayerID
        public var style: Style
    }

    /// One screen giving way to another. `over` is the one that travels (arriving, or
    /// leaving when going back) and `shown` runs from 0, out of sight, to 1, in place.
    public struct Move: Sendable, Equatable {
        public var over: LayerID
        public var under: LayerID
        public var style: Style
        public var back: Bool
        public var shown: Double
        public var velocity: Double
        public var response: Double
        /// Held by a finger (a swipe back from the edge): it stays where the finger puts it.
        public var dragging = false
        /// Ends without saying so: a swipe back let go too early, sliding home again.
        public var quiet = false
    }

    /// What ended in the last step, for the patches to report on the next frame.
    public enum Event: Sendable, Equatable {
        case arrived(LayerID)
        case wentBack(to: LayerID)
    }

    /// Where a screen is this frame.
    public struct Placement: Sendable, Equatable {
        public var visible = false
        /// From the device's top-left corner.
        public var offset = Point2.zero
        public var opacity = 1.0
    }

    public private(set) var pages: [LayerID] = []
    public private(set) var stack: [Entry] = []
    public private(set) var move: Move?
    public private(set) var event: Event?

    public init() {}

    public var hasPages: Bool { !pages.isEmpty }
    /// The screen on top: the one showing, or arriving.
    public var current: LayerID? { stack.last?.page }
    public var canGoBack: Bool { stack.count > 1 }
    /// The screen that is drawn over the others while one gives way to another.
    public var front: LayerID? { move?.over }

    /// Tells it which screens there are, in order. The first is where it starts; screens
    /// that are gone leave the stack.
    public mutating func settle(pages: [LayerID]) {
        guard pages != self.pages || stack.isEmpty != pages.isEmpty else { return }
        self.pages = pages
        let known = Set(pages)
        stack.removeAll { !known.contains($0.page) }
        if let move, !known.contains(move.over) || !known.contains(move.under) { self.move = nil }
        if stack.isEmpty, let first = pages.first { stack = [Entry(page: first, style: .replace)] }
    }

    /// Starts over on a screen, with nothing to go back to: what a person previewing a
    /// screen in the middle of a flow sees. A screen that is not there leaves it as it is.
    public mutating func start(at page: LayerID) {
        guard pages.contains(page) else { return }
        move = nil
        event = nil
        stack = [Entry(page: page, style: .replace)]
    }

    /// Whether a finger at the left edge can drag the screen on top away: one that was
    /// pushed, as on iPhone, with nothing else moving.
    public var canSwipeBack: Bool {
        stack.count > 1 && stack.last?.style == .push && (move == nil || move?.dragging == true)
    }

    /// A finger dragging the screen on top back: `fraction` of the width it has travelled
    /// from the edge. The stack is not changed until the finger lets go.
    public mutating func dragBack(_ fraction: Double) {
        guard stack.count > 1, let top = current else { return }
        let under = stack[stack.count - 2].page
        let shown = 1 - min(max(fraction.clampedFinite, 0), 1)
        if var held = move, held.dragging {
            held.shown = shown
            move = held
        } else {
            guard canSwipeBack else { return }
            move = Move(over: top, under: under, style: .push, back: false, shown: shown, velocity: 0,
                        response: Navigation.defaultResponse, dragging: true)
        }
    }

    /// The finger lets go. Past half way, or flicked towards the right (`velocity` in widths
    /// a second), the screen goes back; otherwise it slides home and nothing has happened.
    public mutating func endDragBack(velocity: Double) {
        guard var held = move, held.dragging else { return }
        let flick = velocity.clampedFinite
        held.dragging = false
        held.velocity = -flick
        if held.shown < 0.5 && flick > -0.5 || flick > 0.8 {
            stack.removeLast()
            held.back = true
        } else {
            held.quiet = true
        }
        move = held
    }

    /// Shows a screen. Nothing happens if it is the one showing.
    public mutating func go(to page: LayerID, style: Style, response: Double = Navigation.defaultResponse) {
        guard pages.contains(page), let from = current, from != page else { return }
        finish()
        guard style != .replace else {
            stack = [Entry(page: page, style: .replace)]
            event = .arrived(page)
            fresh = true
            return
        }
        stack.append(Entry(page: page, style: style))
        move = Move(over: page, under: from, style: style, back: false, shown: 0, velocity: 0, response: response)
    }

    /// Goes back to the screen before. One that is still arriving turns round where it is.
    public mutating func back(response: Double = Navigation.defaultResponse) {
        guard stack.count > 1 else { return }
        if var turning = move, !turning.back {
            turning.back = true
            turning.dragging = false
            turning.quiet = false
            turning.response = response
            move = turning
            stack.removeLast()
            return
        }
        finish()
        let leaving = stack.removeLast()
        guard let to = current else { return }
        move = Move(over: leaving.page, under: to, style: leaving.style, back: true, shown: 1, velocity: 0, response: response)
    }

    /// Ends a move where it was going.
    private mutating func finish() {
        guard let move else { return }
        self.move = nil
        guard !move.quiet, !move.dragging else { return }
        event = move.back ? .wentBack(to: move.under) : .arrived(move.over)
        fresh = true
    }

    /// Moves on by `dt` seconds. Returns whether another frame is wanted: while a screen
    /// is moving, and for the one frame in which the patches report that it stopped.
    public mutating func step(dt: Double) -> Bool {
        // What ended before this frame's patches ran has been reported by them; what they
        // themselves ended a moment ago is reported on the next frame.
        let kept = fresh
        fresh = false
        if !kept { event = nil }
        guard var moving = move else { return kept }
        // A finger holds it: it is where the finger is.
        if moving.dragging { return true }
        let target = moving.back ? 0.0 : 1.0
        let next = Spring.step(
            position: moving.shown, velocity: moving.velocity, target: target,
            response: moving.response, dampingRatio: 1, dt: dt
        )
        moving.shown = next.position.clampedFinite
        moving.velocity = next.velocity.clampedFinite
        move = moving
        if abs(moving.shown - target) < 0.001, abs(moving.velocity) < 0.01 {
            finish()
            fresh = false
        }
        return true
    }

    /// Set when a patch ended something during this frame (a Switch, or a move cut short
    /// by the next one), so the step that follows in the same frame keeps the event.
    private var fresh = false

    /// Where a screen is, on a device of a size.
    public func placement(of page: LayerID, in size: Size2) -> Placement {
        guard let move, move.over == page || move.under == page else {
            return Placement(visible: page == current)
        }
        var placement = Placement(visible: true)
        let shown = min(max(move.shown, -0.25), 1.25)
        if move.over == page {
            switch move.style {
            case .push: placement.offset.x = (1 - shown) * size.width
            case .modal: placement.offset.y = (1 - shown) * size.height
            case .fade: placement.opacity = min(max(shown, 0), 1)
            // Both stay where they rest: the runtime blends what is on them.
            case .replace, .morph: break
            }
        } else if move.style == .push {
            placement.offset.x = -Navigation.parallax * shown * size.width
        }
        return placement
    }

    /// Whether a screen is drawn over what floats over every screen (a tab bar): one
    /// presented with Modal covers everything, as a sheet does on iPhone, and so does one
    /// leaving that way.
    public func coversEverything(_ page: LayerID) -> Bool {
        if let move, move.over == page { return move.style == .modal }
        return stack.contains { $0.page == page && $0.style == .modal }
    }

    /// How much of a screen is in place, from 0 to 1: what a Navigate patch reports.
    public func presence(of page: LayerID) -> Double {
        if let move {
            if move.over == page { return min(max(move.shown, 0), 1) }
            if move.under == page { return 1 - min(max(move.shown, 0), 1) }
        }
        return page == current ? 1 : 0
    }
}
