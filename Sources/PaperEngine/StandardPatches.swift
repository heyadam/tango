import Foundation
import PaperModel

/// The patches that ship with the Foundational tier.
enum StandardPatches {
    static let anyValue: [PortType] = [.number, .bool, .text, .color, .point, .size]
    /// What a loop can hold: everything Loop Over Array makes, JSON included.
    static let loopValue: [PortType] = anyValue + [.json]
    static let blendable: [PortType] = [.number, .point, .size, .color]

    static var all: [PatchDefinition] {
        input + state + [dragValue] + logic + math + animation + [impulse] + loops + data + ai + device + utility + [Script.definition] + components
    }

    // MARK: Input

    static let input: [PatchDefinition] = [
        // Interaction and Keyboard are fed by the runtime; their definitions describe ports only.
        PatchDefinition(
            kind: PatchKind.interaction,
            name: "Interaction",
            category: .input,
            summary: "Reports touches on a view: whether a finger is down, taps, double taps, long presses, and how far it has dragged.",
            outputs: [
                PortSpec("down", "Down", .bool),
                PortSpec("tap", "Tap", .pulse),
                PortSpec("drag", "Drag", .point),
                PortSpec("position", "Position", .point),
                PortSpec("velocity", "Velocity", .point),
                PortSpec("doubleTap", "Double Tap", .pulse),
                PortSpec("longPress", "Long Press", .pulse),
            ]
        ),
        // Layer Size is fed by the runtime too: it reads where layout put the layer.
        PatchDefinition(
            kind: "layerSize",
            name: "View Size",
            category: .input,
            summary: "Reports the size a view ends up with after layout, so patches can follow a view that resizes.",
            outputs: [
                PortSpec("size", "Size", .size),
                PortSpec("width", "Width", .number),
                PortSpec("height", "Height", .number),
            ]
        ),
        // Video Time reads the playhead the runtime keeps for a video.
        PatchDefinition(
            kind: PatchKind.videoTime,
            name: "Video Time",
            category: .input,
            summary: "Reports where a Video view is: its time and length in seconds, how far through it is from 0 to 1, whether it is playing, and a pulse when it reaches its end.",
            outputs: [
                PortSpec("time", "Time", .number),
                PortSpec("duration", "Duration", .number),
                PortSpec("progress", "Progress", .number),
                PortSpec("playing", "Playing", .bool),
                PortSpec("ended", "Ended", .pulse),
            ]
        ),
        // Scroll is also fed by the runtime.
        PatchDefinition(
            kind: "scroll",
            name: "Scroll",
            category: .input,
            summary: "Scrolls with a finger on a view: follows the drag, coasts on release, and bounces back at the ends. Set a Page Size to make it stop on pages.",
            inputs: [
                PortSpec("axis", "Axis", .text, .text("Vertical"), options: ["Vertical", "Horizontal"]),
                PortSpec("min", "Min", .number, .number(-400)),
                PortSpec("max", "Max", .number, .number(0)),
                PortSpec("page", "Page Size", .number, .number(0)),
            ],
            outputs: [
                PortSpec("offset", "Offset", .number),
                PortSpec("velocity", "Velocity", .number),
                PortSpec("dragging", "Dragging", .bool),
            ]
        ),
        // Text Input, the gestures (Tap, Long Press, Pan, Swipe, Pinch, Rotation) and Hover
        // are fed by the runtime as well.
        PatchDefinition(
            kind: "textInput",
            name: "Text Input",
            category: .input,
            summary: "Reports what is typed in a Text Field: its text, whether it is being edited, and pulses when the text changes or Return is pressed. Focus, Dismiss and Clear control it from the graph.",
            inputs: [
                PortSpec("focus", "Focus", .pulse),
                PortSpec("dismiss", "Dismiss", .pulse),
                PortSpec("clear", "Clear", .pulse),
            ],
            outputs: [
                PortSpec("text", "Text", .text),
                PortSpec("editing", "Editing", .bool),
                PortSpec("changed", "Changed", .pulse),
                PortSpec("submitted", "Submitted", .pulse),
            ]
        ),
        PatchDefinition(
            kind: PatchKind.tap,
            name: "Tap",
            category: .input,
            summary: "Pulses when a view is tapped: the fingers came down and lifted where they were. Taps sets how many in a row it takes, Fingers how many at once.",
            inputs: [
                PortSpec("taps", "Taps", .number, .number(1)),
                PortSpec("fingers", "Fingers", .number, .number(1)),
            ],
            outputs: [
                PortSpec("tapped", "Tapped", .pulse),
                PortSpec("position", "Position", .point),
            ]
        ),
        PatchDefinition(
            kind: PatchKind.longPress,
            name: "Long Press",
            category: .input,
            summary: "A finger held still on a view: on from the moment it has been down for Duration seconds until it lifts.",
            inputs: [
                PortSpec("duration", "Duration", .number, .number(GestureMetrics.longPressDelay)),
                PortSpec("fingers", "Fingers", .number, .number(1)),
            ],
            outputs: [
                PortSpec("pressing", "Pressing", .bool),
                PortSpec("began", "Began", .pulse),
                PortSpec("ended", "Ended", .pulse),
                PortSpec("position", "Position", .point),
            ]
        ),
        PatchDefinition(
            kind: PatchKind.pan,
            name: "Pan",
            category: .input,
            summary: "Fingers dragging across a view: how far they have travelled since the drag began, how fast, and where they are. It begins once they have moved a little, so a tap is not a pan.",
            inputs: [
                PortSpec("direction", "Direction", .text, .text("Any"), options: ["Any", "Horizontal", "Vertical"]),
                PortSpec("minFingers", "Min Fingers", .number, .number(1)),
                PortSpec("maxFingers", "Max Fingers", .number, .number(0)),
            ],
            outputs: [
                PortSpec("translation", "Translation", .point),
                PortSpec("velocity", "Velocity", .point),
                PortSpec("position", "Position", .point),
                PortSpec("panning", "Panning", .bool),
                PortSpec("began", "Began", .pulse),
                PortSpec("ended", "Ended", .pulse),
            ]
        ),
        PatchDefinition(
            kind: PatchKind.swipe,
            name: "Swipe",
            category: .input,
            summary: "Pulses when a finger flicks across a view, by direction.",
            inputs: [PortSpec("fingers", "Fingers", .number, .number(1))],
            outputs: [
                PortSpec("left", "Left", .pulse),
                PortSpec("right", "Right", .pulse),
                PortSpec("up", "Up", .pulse),
                PortSpec("down", "Down", .pulse),
            ]
        ),
        PatchDefinition(
            kind: PatchKind.pinch,
            name: "Pinch",
            category: .input,
            summary: "Two fingers on a view moving apart or together: how far they have spread since the pinch began (1 is where it began), how fast, and the point between them. What it measured stays once the fingers lift.",
            outputs: [
                PortSpec("scale", "Scale", .number, .number(1)),
                PortSpec("rotation", "Rotation", .number),
                PortSpec("pinching", "Pinching", .bool),
                PortSpec("velocity", "Velocity", .number),
                PortSpec("center", "Center", .point),
                PortSpec("began", "Began", .pulse),
                PortSpec("ended", "Ended", .pulse),
            ]
        ),
        PatchDefinition(
            kind: PatchKind.rotation,
            name: "Rotation",
            category: .input,
            summary: "Two fingers on a view turning around each other: how far they have turned since the turn began, in degrees clockwise, how fast, and the point between them.",
            outputs: [
                PortSpec("rotation", "Rotation", .number),
                PortSpec("velocity", "Velocity", .number),
                PortSpec("rotating", "Rotating", .bool),
                PortSpec("center", "Center", .point),
                PortSpec("began", "Began", .pulse),
                PortSpec("ended", "Ended", .pulse),
            ]
        ),
        PatchDefinition(
            kind: "hover",
            name: "Hover",
            category: .input,
            summary: "Reports a pointer resting over a view without touching it, as on iPad or the web.",
            outputs: [
                PortSpec("hovering", "Hovering", .bool),
                PortSpec("position", "Position", .point),
            ]
        ),
        PatchDefinition(
            kind: "keyboard",
            name: "Keyboard",
            category: .input,
            summary: "Reports whether a key is held and pulses when it is pressed.",
            inputs: [PortSpec("key", "Key", .text, .text("space"))],
            outputs: [
                PortSpec("down", "Down", .bool),
                PortSpec("pressed", "Pressed", .pulse),
            ]
        ),
        PatchDefinition(
            kind: "time",
            name: "Time",
            category: .input,
            summary: "Seconds since the prototype started.",
            inputs: [PortSpec("running", "Running", .bool, .bool(true))],
            outputs: [PortSpec("time", "Time", .number)]
        ) { ctx in
            // Stopped, it holds the time it had and asks for no more frames.
            guard ctx.bool(0) else { return }
            ctx.outputs[0] = .number(ctx.time)
            ctx.wantsNextFrame = true
        },
    ]

    // MARK: State

    static let state: [PatchDefinition] = [
        // Navigate and Navigate Back are run by the runtime, which keeps the stack of screens.
        PatchDefinition(
            kind: PatchKind.navigate,
            name: "Navigate",
            category: .state,
            summary: "Shows a screen. A pulse brings its screen in over the one showing: pushed in from the side, up from the bottom, faded in, or switched at once.",
            inputs: [
                PortSpec("go", "Go", .pulse),
                PortSpec("style", "Style", .text, .text(Navigation.Style.push.rawValue), options: Navigation.Style.allCases.map(\.rawValue)),
                PortSpec("response", "Response", .number, .number(Navigation.defaultResponse)),
            ],
            outputs: [
                PortSpec("progress", "Progress", .number),
                PortSpec("arrived", "Arrived", .pulse),
                PortSpec("showing", "Showing", .bool),
            ]
        ),
        PatchDefinition(
            kind: PatchKind.navigateBack,
            name: "Navigate Back",
            category: .state,
            summary: "Goes back to the screen that was showing before, the way the one on top arrived, in reverse.",
            inputs: [
                PortSpec("go", "Go", .pulse),
                PortSpec("response", "Response", .number, .number(Navigation.defaultResponse)),
            ],
            outputs: [
                PortSpec("canGoBack", "Can Go Back", .bool),
                PortSpec("arrived", "Arrived", .pulse),
            ]
        ),
        PatchDefinition(
            kind: "switch",
            name: "Switch",
            category: .state,
            summary: "Stores an on/off choice. A pulse flips it or sets it, and it stays that way.",
            inputs: [
                PortSpec("flip", "Flip", .pulse),
                PortSpec("turnOn", "Turn On", .pulse),
                PortSpec("turnOff", "Turn Off", .pulse),
                PortSpec("start", "Starts On", .bool),
            ],
            outputs: [PortSpec("on", "On / Off", .bool)]
        ) { ctx in
            var on = ctx.outputs[0].boolValue
            // It begins as Starts On says, and takes that again whenever it changes.
            let start = ctx.bool(3)
            if let last = ctx.state(as: Bool.self) {
                if last != start { on = start }
            } else if start {
                on = true
            }
            ctx.state = start
            if ctx.pulse(0) { on.toggle() }
            if ctx.pulse(1) { on = true }
            if ctx.pulse(2) { on = false }
            ctx.outputs[0] = .bool(on)
        },
        PatchDefinition(
            kind: "eitherPulse",
            name: "Either",
            category: .state,
            summary: "Pulses when either of two pulses arrives: two buttons that do the same thing.",
            inputs: [PortSpec("a", "A", .pulse), PortSpec("b", "B", .pulse)],
            outputs: [PortSpec("pulse", "Pulse", .pulse)]
        ) { ctx in ctx.outputs[0] = .pulse(ctx.pulse(0) || ctx.pulse(1)) },
        PatchDefinition(
            kind: "pulseGate",
            name: "Gate",
            category: .state,
            summary: "Lets a pulse through only while a condition is on.",
            inputs: [PortSpec("pulse", "Pulse", .pulse), PortSpec("open", "Open", .bool, .bool(true))],
            outputs: [PortSpec("pulse", "Pulse", .pulse)]
        ) { ctx in ctx.outputs[0] = .pulse(ctx.pulse(0) && ctx.bool(1)) },
        PatchDefinition(
            kind: "optionSwitch",
            name: "Option Switch",
            category: .state,
            summary: "Selects one of several mutually exclusive states and remembers it.",
            inputs: [
                PortSpec("set0", "Set to 0", .pulse),
                PortSpec("set1", "Set to 1", .pulse),
                PortSpec("set2", "Set to 2", .pulse),
            ],
            outputs: [PortSpec("option", "Option", .number)]
        ) { ctx in
            for index in 0..<3 where ctx.pulse(index) {
                ctx.outputs[0] = .number(Double(index))
            }
        },
        PatchDefinition(
            kind: "counter",
            name: "Counter",
            category: .state,
            summary: "Counts up and down through ordered states.",
            inputs: [
                PortSpec("increase", "Increase", .pulse),
                PortSpec("decrease", "Decrease", .pulse),
                PortSpec("reset", "Reset", .pulse),
                PortSpec("step", "Step", .number, .number(1)),
                PortSpec("min", "Minimum", .number),
                PortSpec("max", "Maximum", .number),
                PortSpec("start", "Start", .number),
            ],
            outputs: [PortSpec("value", "Value", .number)]
        ) { ctx in
            let start = ctx.number(6)
            // A document made before Start keeps the count it had.
            var state = ctx.state(as: CounterState.self) ?? CounterState(value: start + ctx.outputs[0].numberValue, start: start)
            if state.start != start {
                state.start = start
                state.value = start
            }
            if ctx.pulse(0) { state.value += ctx.number(3) }
            if ctx.pulse(1) { state.value -= ctx.number(3) }
            if ctx.pulse(2) { state.value = start }
            // Limits count only when they leave room between them.
            let (low, high) = (ctx.number(4), ctx.number(5))
            if low < high { state.value = min(max(state.value, low), high) }
            state.value = state.value.clampedFinite
            ctx.state = state
            ctx.outputs[0] = .number(state.value)
        },
        PatchDefinition(
            kind: "optionPicker",
            name: "Option Picker",
            category: .state,
            summary: "Outputs the value that matches the active option.",
            inputs: [
                PortSpec("option", "Option", .number),
                .generic("value0", "Value 0"),
                .generic("value1", "Value 1", .number(1)),
                .generic("value2", "Value 2", .number(2)),
            ],
            outputs: [.generic("value", "Value")],
            genericTypes: anyValue
        ) { ctx in
            let option = min(max(ctx.number(0).whole, 0), 2)
            ctx.outputs[0] = ctx.inputs[1 + option]
        },
        PatchDefinition(
            kind: "pulse",
            name: "Pulse",
            category: .state,
            summary: "Turns a change in state into an event: pulses when its input turns on or turns off.",
            inputs: [PortSpec("value", "On / Off", .bool)],
            outputs: [
                PortSpec("turnedOn", "Turned On", .pulse),
                PortSpec("turnedOff", "Turned Off", .pulse),
            ]
        ) { ctx in
            let now = ctx.bool(0)
            if let before = ctx.state(as: Bool.self), before != now {
                ctx.outputs[now ? 0 : 1] = .pulse(true)
            }
            ctx.state = now
        },
        PatchDefinition(
            kind: "sampleHold",
            name: "Sample & Hold",
            category: .state,
            summary: "Captures its input when pulsed and keeps outputting that value until the next pulse. Starts at zero / off.",
            inputs: [
                .generic("value", "Value"),
                PortSpec("sample", "Sample", .pulse),
            ],
            outputs: [.generic("value", "Value")],
            genericTypes: anyValue
        ) { ctx in
            if ctx.pulse(1) {
                ctx.outputs[0] = ctx.inputs[0]
            }
        },
        PatchDefinition(
            kind: "delay",
            name: "Delay",
            category: .state,
            summary: "Passes its input through after a number of seconds.",
            inputs: [
                .generic("value", "Value"),
                PortSpec("duration", "Duration", .number, .number(0.3)),
            ],
            outputs: [.generic("value", "Value")],
            genericTypes: anyValue
        ) { ctx in
            guard var state = ctx.state(as: DelayState.self) else {
                ctx.outputs[0] = ctx.inputs[0]
                ctx.state = DelayState(last: ctx.inputs[0], queue: [])
                return
            }
            if state.last != ctx.inputs[0] {
                state.last = ctx.inputs[0]
                state.queue.append(DelayState.Entry(due: ctx.time + max(ctx.number(1), 0), value: ctx.inputs[0]))
            }
            while let first = state.queue.first, first.due <= ctx.time {
                ctx.outputs[0] = first.value
                state.queue.removeFirst()
            }
            ctx.wantsNextFrame = !state.queue.isEmpty
            ctx.state = state
        },
    ]

    struct DelayState: Sendable {
        struct Entry: Sendable {
            var due: Double
            var value: Value
        }

        var last: Value
        var queue: [Entry]
    }

    // MARK: Logic

    struct DragState: Sendable {
        var value: Double
        var base: Double
        var wasDown: Bool
        var start: Double
    }

    static let dragValue = PatchDefinition(
        kind: "dragValue",
        name: "Drag Value",
        category: .state,
        summary: "A value from 0 to 1 that a drag pushes up and down and that stays put on release, like a slider's.",
        inputs: [
            PortSpec("down", "Down", .bool),
            PortSpec("drag", "Drag", .number),
            PortSpec("range", "Distance", .number, .number(100)),
            PortSpec("start", "Start", .number),
        ],
        outputs: [PortSpec("value", "Value", .number)]
    ) { ctx in
        let start = min(max(ctx.number(3), 0), 1)
        var state = ctx.state(as: DragState.self) ?? DragState(value: start, base: start, wasDown: false, start: start)
        if state.start != start {
            state.start = start
            state.value = start
        }
        let down = ctx.bool(0)
        if down {
            if !state.wasDown { state.base = state.value }
            let range = ctx.number(2)
            if range > 0 { state.value = min(max(state.base + ctx.number(1) / range, 0), 1) }
        }
        state.wasDown = down
        ctx.state = state
        ctx.outputs[0] = .number(state.value)
    }

    static let logic: [PatchDefinition] = [
        PatchDefinition(
            kind: "and", name: "And", category: .logic,
            summary: "On when both inputs are on.",
            inputs: [PortSpec("a", "A", .bool), PortSpec("b", "B", .bool)],
            outputs: [PortSpec("result", "Result", .bool)]
        ) { ctx in ctx.outputs[0] = .bool(ctx.bool(0) && ctx.bool(1)) },
        PatchDefinition(
            kind: "or", name: "Or", category: .logic,
            summary: "On when either input is on.",
            inputs: [PortSpec("a", "A", .bool), PortSpec("b", "B", .bool)],
            outputs: [PortSpec("result", "Result", .bool)]
        ) { ctx in ctx.outputs[0] = .bool(ctx.bool(0) || ctx.bool(1)) },
        PatchDefinition(
            kind: "not", name: "Not", category: .logic,
            summary: "On when its input is off.",
            inputs: [PortSpec("value", "Value", .bool)],
            outputs: [PortSpec("result", "Result", .bool)]
        ) { ctx in ctx.outputs[0] = .bool(!ctx.bool(0)) },
        comparison("equal", "=", "On when A equals B.") { abs($0 - $1) < 1e-9 },
        comparison("notEqual", "≠", "On when A differs from B.") { abs($0 - $1) >= 1e-9 },
        comparison("greater", ">", "On when A is greater than B.") { $0 > $1 },
        comparison("greaterEqual", "≥", "On when A is greater than or equal to B.") { $0 >= $1 },
        comparison("less", "<", "On when A is less than B.") { $0 < $1 },
        comparison("lessEqual", "≤", "On when A is less than or equal to B.") { $0 <= $1 },
        PatchDefinition(
            kind: "if",
            name: "If",
            category: .logic,
            summary: "Chooses between two values with a condition.",
            inputs: [
                PortSpec("condition", "Condition", .bool),
                .generic("then", "Then", .number(1)),
                .generic("else", "Else"),
            ],
            outputs: [.generic("value", "Value")],
            genericTypes: anyValue
        ) { ctx in ctx.outputs[0] = ctx.bool(0) ? ctx.inputs[1] : ctx.inputs[2] },
    ]

    static func comparison(
        _ kind: String,
        _ name: String,
        _ summary: String,
        _ test: @escaping @Sendable (Double, Double) -> Bool
    ) -> PatchDefinition {
        PatchDefinition(
            kind: kind, name: name, category: .logic, summary: summary,
            inputs: [PortSpec("a", "A", .number), PortSpec("b", "B", .number)],
            outputs: [PortSpec("result", "Result", .bool)]
        ) { ctx in ctx.outputs[0] = .bool(test(ctx.number(0), ctx.number(1))) }
    }

    // MARK: Math

    static let math: [PatchDefinition] = [
        binary("add", "+", "Adds two numbers.") { $0 + $1 },
        binary("subtract", "−", "Subtracts B from A.") { $0 - $1 },
        binary("multiply", "×", "Multiplies two numbers.", defaultB: 1) { $0 * $1 },
        binary("divide", "÷", "Divides A by B. Dividing by zero gives 0.", defaultB: 1) { $1 == 0 ? 0 : $0 / $1 },
        binary("mod", "Mod", "The remainder of A divided by B.", defaultB: 1) {
            $1 == 0 ? 0 : $0 - $1 * ($0 / $1).rounded(.down)
        },
        binary("min", "Min", "The smaller of two numbers.") { min($0, $1) },
        binary("max", "Max", "The larger of two numbers.") { max($0, $1) },
        PatchDefinition(
            kind: "clamp", name: "Clamp", category: .math,
            summary: "Keeps a number between a minimum and a maximum.",
            inputs: [
                PortSpec("value", "Value", .number),
                PortSpec("min", "Min", .number),
                PortSpec("max", "Max", .number, .number(1)),
            ],
            outputs: [PortSpec("result", "Result", .number)]
        ) { ctx in
            let low = min(ctx.number(1), ctx.number(2))
            let high = max(ctx.number(1), ctx.number(2))
            ctx.outputs[0] = .number(min(max(ctx.number(0), low), high))
        },
        PatchDefinition(
            kind: "abs", name: "Absolute Value", category: .math,
            summary: "The distance of a number from zero.",
            inputs: [PortSpec("value", "Value", .number)],
            outputs: [PortSpec("result", "Result", .number)]
        ) { ctx in ctx.outputs[0] = .number(abs(ctx.number(0))) },
        PatchDefinition(
            kind: "round", name: "Round", category: .math,
            summary: "Rounds to the nearest whole number.",
            inputs: [PortSpec("value", "Value", .number)],
            outputs: [PortSpec("result", "Result", .number)]
        ) { ctx in ctx.outputs[0] = .number(ctx.number(0).rounded()) },
        PatchDefinition(
            kind: "progress", name: "Progress", category: .math,
            summary: "Converts a value within a range into progress from 0 to 1.",
            inputs: [
                PortSpec("value", "Value", .number),
                PortSpec("start", "Start", .number),
                PortSpec("end", "End", .number, .number(1)),
            ],
            outputs: [PortSpec("progress", "Progress", .number)]
        ) { ctx in
            let span = ctx.number(2) - ctx.number(1)
            ctx.outputs[0] = .number(span == 0 ? 0 : (ctx.number(0) - ctx.number(1)) / span)
        },
        PatchDefinition(
            kind: "makePoint", name: "Make Point", category: .math,
            summary: "Combines X and Y into a point.",
            inputs: [PortSpec("x", "X", .number), PortSpec("y", "Y", .number)],
            outputs: [PortSpec("point", "Point", .point)]
        ) { ctx in ctx.outputs[0] = .point(Point2(x: ctx.number(0), y: ctx.number(1))) },
        PatchDefinition(
            kind: "splitPoint", name: "Split Point", category: .math,
            summary: "Separates a point into X and Y.",
            inputs: [PortSpec("point", "Point", .point)],
            outputs: [PortSpec("x", "X", .number), PortSpec("y", "Y", .number)]
        ) { ctx in
            let point = ctx.point(0)
            ctx.outputs[0] = .number(point.x)
            ctx.outputs[1] = .number(point.y)
        },
    ]

    static func binary(
        _ kind: String,
        _ name: String,
        _ summary: String,
        defaultB: Double = 0,
        _ operation: @escaping @Sendable (Double, Double) -> Double
    ) -> PatchDefinition {
        PatchDefinition(
            kind: kind, name: name, category: .math, summary: summary,
            inputs: [PortSpec("a", "A", .number), PortSpec("b", "B", .number, .number(defaultB))],
            outputs: [PortSpec("result", "Result", .number)]
        ) { ctx in
            let result = operation(ctx.number(0), ctx.number(1))
            ctx.outputs[0] = .number(result.isFinite ? result : 0)
        }
    }

    // MARK: Animation

    struct SpringState: Sendable {
        var position: Double
        var velocity: Double
        /// While held: the distance between the value and the Follow input at the moment
        /// Hold turned on. nil when not held.
        var grabOffset: Double?
    }

    struct EasingState: Sendable {
        var from: Double
        var to: Double
        var elapsed: Double
        var value: Double
    }

    static let animation: [PatchDefinition] = [
        PatchDefinition(
            kind: "spring",
            name: "Spring Animation",
            category: .animation,
            summary: "Follows its target with spring motion. While Hold is on, the value moves along with Follow from wherever it was grabbed, then settles from there on release.",
            inputs: [
                PortSpec("target", "Target", .number),
                PortSpec("response", "Response", .number, .number(0.4)),
                PortSpec("damping", "Damping", .number, .number(0.8)),
                PortSpec("hold", "Hold", .bool),
                PortSpec("held", "Follow", .number),
            ],
            outputs: [
                PortSpec("value", "Value", .number),
                PortSpec("velocity", "Velocity", .number),
                PortSpec("animating", "Animating", .bool),
            ]
        ) { ctx in
            let target = ctx.number(0)
            // The first evaluation starts at the target: nothing animates on launch.
            var state = ctx.state(as: SpringState.self) ?? SpringState(position: target, velocity: 0, grabOffset: nil)
            var animating = false

            if ctx.bool(3) {
                // Direct manipulation. The value is grabbed where it is, so catching it
                // mid-flight does not jump; from then on it moves by exactly as much as
                // Follow does. Velocity is estimated so the release continues the movement.
                let offset = state.grabOffset ?? (state.position - ctx.number(4))
                state.grabOffset = offset
                let held = ctx.number(4) + offset
                if ctx.dt > 0 {
                    let raw = (held - state.position) / ctx.dt
                    state.velocity = state.velocity * 0.5 + raw * 0.5
                }
                state.position = held
                animating = true
                ctx.wantsNextFrame = true
            } else if !Spring.isAtRest(position: state.position, velocity: state.velocity, target: target) {
                state.grabOffset = nil
                let next = Spring.step(
                    position: state.position,
                    velocity: state.velocity,
                    target: target,
                    response: ctx.number(1),
                    dampingRatio: ctx.number(2),
                    dt: ctx.dt
                )
                state.position = next.position
                state.velocity = next.velocity
                if Spring.isAtRest(position: state.position, velocity: state.velocity, target: target) {
                    state = SpringState(position: target, velocity: 0, grabOffset: nil)
                } else {
                    animating = true
                    ctx.wantsNextFrame = true
                }
            } else {
                state = SpringState(position: target, velocity: 0, grabOffset: nil)
            }

            ctx.state = state
            ctx.outputs[0] = .number(state.position)
            ctx.outputs[1] = .number(state.velocity)
            ctx.outputs[2] = .bool(animating)
        },
        PatchDefinition(
            kind: "easing",
            name: "Easing Animation",
            category: .animation,
            summary: "Moves to its target over a fixed duration along an easing curve.",
            inputs: [
                PortSpec("target", "Target", .number),
                PortSpec("duration", "Duration", .number, .number(0.3)),
                PortSpec(
                    "curve", "Curve", .text, .text(EasingCurve.easeInOut.rawValue),
                    options: EasingCurve.allCases.map(\.rawValue)
                ),
            ],
            outputs: [
                PortSpec("value", "Value", .number),
                PortSpec("animating", "Animating", .bool),
            ]
        ) { ctx in
            let target = ctx.number(0)
            var state = ctx.state(as: EasingState.self)
                ?? EasingState(from: target, to: target, elapsed: 0, value: target)
            if state.to != target {
                // Retarget from wherever the value is now.
                state = EasingState(from: state.value, to: target, elapsed: 0, value: state.value)
            } else if state.value != state.to {
                state.elapsed += ctx.dt
            }

            let duration = max(ctx.number(1), 0)
            let curve = EasingCurve(rawValue: ctx.text(2)) ?? .easeInOut
            let t = duration == 0 ? 1 : min(state.elapsed / duration, 1)
            state.value = t >= 1 ? state.to : state.from + (state.to - state.from) * curve.apply(t)

            let animating = state.value != state.to
            ctx.wantsNextFrame = animating
            ctx.state = state
            ctx.outputs[0] = .number(state.value)
            ctx.outputs[1] = .bool(animating)
        },
        PatchDefinition(
            kind: "transition",
            name: "Transition",
            category: .animation,
            summary: "Maps progress from 0 to 1 onto a range between a start and an end value.",
            inputs: [
                PortSpec("progress", "Progress", .number),
                .generic("start", "Start"),
                .generic("end", "End", .number(1)),
            ],
            outputs: [.generic("value", "Value")],
            genericTypes: blendable
        ) { ctx in
            ctx.outputs[0] = Value.lerp(ctx.inputs[1], ctx.inputs[2], ctx.number(0))
        },
    ]

    // MARK: Utility

    // MARK: Loops

    /// Longest loop a patch will make, so a mistyped count cannot stall the prototype.
    static let loopLimit = 2000

    static let loops: [PatchDefinition] = [
        PatchDefinition(
            kind: "loop",
            name: "Loop",
            category: .loop,
            summary: "Outputs the indexes 0, 1, 2… up to a count. Anything connected after it runs once per index, and a view it reaches is repeated.",
            inputs: [PortSpec("count", "Count", .number, .number(3))],
            outputs: [PortSpec("index", "Index", .number)]
        ).wholeLoop { ctx in
            let wanted = ctx.first(0)?.numberValue ?? 0
            let count = min(max(wanted.whole, 0), loopLimit)
            ctx.outputs = (0..<count).map { [.number(Double($0))] }
        },
        PatchDefinition(
            kind: "loopBuilder",
            name: "Loop Builder",
            category: .loop,
            summary: "Makes a loop from the values you give it, one per input. Right-click to add or remove inputs.",
            inputs: [.generic("value", "Value")],
            outputs: [.generic("loop", "Loop"), PortSpec("index", "Index", .number)],
            genericTypes: loopValue,
            variableInputs: VariableInputs(standard: 3, range: 1...24)
        ).wholeLoop { ctx in
            ctx.outputs = ctx.inputs.enumerated().map { index, values in
                [values.first ?? Value.defaultValue(for: ctx.valueType), .number(Double(index))]
            }
        },
        PatchDefinition(
            kind: "loopOverArray",
            name: "Loop Over Array",
            category: .loop,
            summary: "Makes a loop with one value per item of an array.",
            inputs: [PortSpec("array", "Array", .array)],
            outputs: [.generic("value", "Value"), PortSpec("index", "Index", .number)],
            // Text first: a patch whose type was never chosen works on the first, and saved
            // documents rely on Loop Over Array giving text.
            genericTypes: [.text] + loopValue.filter { $0 != .text }
        ).wholeLoop { ctx in
            let items = (ctx.first(0)?.arrayValue ?? []).prefix(loopLimit)
            ctx.outputs = items.enumerated().map { index, item in
                [item.converted(to: ctx.valueType), .number(Double(index))]
            }
        },
        PatchDefinition(
            kind: "filterArray",
            name: "Filter Array",
            category: .loop,
            summary: "Keeps the items of an array that contain the search text, ignoring capitals: what a search field does to a list. For items that are objects, Key names the field to look in. An empty search keeps everything.",
            inputs: [PortSpec("array", "Array", .array), PortSpec("search", "Search", .text), PortSpec("key", "Key", .text)],
            outputs: [PortSpec("array", "Array", .array), PortSpec("count", "Count", .number)]
        ) { ctx in
            let search = ctx.text(1).trimmingCharacters(in: .whitespaces)
            let key = ctx.text(2)
            func text(of item: Value) -> String {
                guard case let .object(fields) = item else { return item.textValue }
                if !key.isEmpty { return fields[key]?.textValue ?? "" }
                // No field named: any of them may match.
                return fields.keys.sorted().compactMap { fields[$0]?.textValue }.joined(separator: "\n")
            }
            let kept = search.isEmpty ? ctx.inputs[0].arrayValue : ctx.inputs[0].arrayValue.filter {
                text(of: $0).localizedCaseInsensitiveContains(search)
            }
            ctx.outputs[0] = .array(kept)
            ctx.outputs[1] = .number(Double(kept.count))
        },
        PatchDefinition(
            kind: "splitText",
            name: "Split Text",
            category: .loop,
            summary: "Cuts text into an array at every separator, for example a comma-separated list of names.",
            inputs: [PortSpec("text", "Text", .text, .text("One, Two, Three")), PortSpec("separator", "Separator", .text, .text(","))],
            outputs: [PortSpec("array", "Array", .array), PortSpec("count", "Count", .number)]
        ) { ctx in
            let separator = ctx.text(1)
            let text = ctx.text(0)
            let parts: [String] = text.isEmpty ? [] : separator.isEmpty
                ? text.map(String.init)
                : text.components(separatedBy: separator)
            let items = parts.map { Value.text($0.trimmingCharacters(in: .whitespaces)) }
            ctx.outputs[0] = .array(items)
            ctx.outputs[1] = .number(Double(items.count))
        },
        PatchDefinition(
            kind: "loopSelect",
            name: "Loop Select",
            category: .loop,
            summary: "Picks the value at one index of a loop, turning the loop back into a single value.",
            inputs: [.generic("loop", "Loop"), PortSpec("index", "Index", .number)],
            outputs: [.generic("value", "Value")],
            genericTypes: loopValue
        ).wholeLoop { ctx in
            let loop = ctx.inputs[0]
            let index = (ctx.first(1)?.numberValue ?? 0).whole
            let picked = loop.indices.contains(index) ? loop[index] : Value.defaultValue(for: ctx.valueType)
            ctx.outputs = [[picked]]
        },
        PatchDefinition(
            kind: "loopCount",
            name: "Loop Count",
            category: .loop,
            summary: "Outputs how many values a loop has.",
            inputs: [.generic("loop", "Loop")],
            outputs: [PortSpec("count", "Count", .number)],
            genericTypes: loopValue
        ).wholeLoop { ctx in
            ctx.outputs = [[.number(Double(ctx.inputs[0].count))]]
        },
        PatchDefinition(
            kind: "loopOptionSwitch",
            name: "Loop Option Switch",
            category: .loop,
            summary: "Remembers which index of a loop last pulsed. Connect the Tap of an Interaction on a repeated view to know which one was chosen.",
            inputs: [PortSpec("set", "Set", .pulse), PortSpec("start", "Start", .number, .number(0))],
            outputs: [
                PortSpec("option", "Option", .number), PortSpec("changed", "Changed", .pulse), PortSpec("picked", "Picked", .pulse),
            ]
        ).wholeLoop { ctx in
            let start = ctx.first(1)?.numberValue ?? 0
            var option = ctx.state(as: Double.self) ?? start
            var changed = false
            var picked = false
            if let index = ctx.inputs[0].firstIndex(where: \.pulseValue) {
                changed = option != Double(index)
                picked = true
                option = Double(index)
            }
            ctx.state = option
            ctx.outputs = [[.number(option), .pulse(changed), .pulse(picked)]]
        },
    ]

    struct CounterState: Sendable {
        var value: Double
        var start: Double
    }

    struct ImpulseState: Sendable {
        var remaining = 0.0
    }

    static let impulse = PatchDefinition(
        kind: "impulse",
        name: "Impulse",
        category: .animation,
        summary: "Jumps to 1 on a pulse and eases back to 0: a flash, a bump, a moment of feedback.",
        inputs: [PortSpec("trigger", "Trigger", .pulse), PortSpec("duration", "Duration", .number, .number(0.35))],
        outputs: [PortSpec("value", "Value", .number), PortSpec("active", "Active", .bool)]
    ) { ctx in
        var state = ctx.state(as: ImpulseState.self) ?? ImpulseState()
        let duration = max(ctx.number(1), 0.001)
        if ctx.pulse(0) {
            state.remaining = duration
        } else {
            state.remaining = max(state.remaining - ctx.dt, 0)
        }
        let progress = state.remaining / duration
        ctx.state = state
        ctx.outputs[0] = .number(progress * progress)
        ctx.outputs[1] = .bool(state.remaining > 0)
        ctx.wantsNextFrame = state.remaining > 0
    }

    // MARK: Device

    static let hapticStyles = ["Tap", "Alignment", "Level Change"]
    static let soundNames = ["Tink", "Pop", "Glass", "Ping", "Hero", "Funk", "Bottle", "Purr", "Submarine", "Shutter"]

    static let device: [PatchDefinition] = [
        PatchDefinition(
            kind: "camera",
            name: "Camera",
            category: .device,
            summary: "Takes a photo with the camera a Camera view shows. Connect Photo to an Image view to display it.",
            inputs: [PortSpec("capture", "Capture", .pulse)],
            outputs: [
                PortSpec("photo", "Photo", .text),
                PortSpec("captured", "Captured", .pulse),
                PortSpec("available", "Available", .bool),
            ]
        ) { ctx in
            if ctx.pulse(0) { ctx.effects.append(.capturePhoto) }
        }.device(.camera, outputs: ["camera.photo", "camera.captured", "camera.available"]),
        PatchDefinition(
            kind: "hapticFeedback",
            name: "Haptic Feedback",
            category: .device,
            summary: "Makes the device tap back, on hardware that can.",
            inputs: [
                PortSpec("trigger", "Trigger", .pulse),
                PortSpec("style", "Style", .text, .text("Tap"), options: hapticStyles),
            ]
        ) { ctx in
            if ctx.pulse(0) { ctx.effects.append(.haptic(style: ctx.text(1))) }
        },
        PatchDefinition(
            kind: "playSound",
            name: "Play Sound",
            category: .device,
            summary: "Plays a short sound on a pulse.",
            inputs: [
                PortSpec("trigger", "Trigger", .pulse),
                PortSpec("sound", "Sound", .text, .text("Tink"), options: soundNames),
                PortSpec("volume", "Volume", .number, .number(1)),
            ]
        ) { ctx in
            if ctx.pulse(0) { ctx.effects.append(.sound(name: ctx.text(1), volume: min(max(ctx.number(2), 0), 1))) }
        },
        PatchDefinition(
            kind: "microphone",
            name: "Microphone",
            category: .device,
            summary: "Reports how loud it is around the device, from 0 (silence) to 1.",
            outputs: [PortSpec("level", "Level", .number), PortSpec("available", "Available", .bool)]
        ).device(.microphone, outputs: ["microphone.level", "microphone.available"]),
        PatchDefinition(
            kind: "location",
            name: "Location",
            category: .device,
            summary: "Reports where the device is.",
            outputs: [
                PortSpec("latitude", "Latitude", .number),
                PortSpec("longitude", "Longitude", .number),
                PortSpec("available", "Available", .bool),
            ]
        ).device(.location, outputs: ["location.latitude", "location.longitude", "location.available"]),
        PatchDefinition(
            kind: "dateTime",
            name: "Date and Time",
            category: .device,
            summary: "The current time on the device, as numbers and as text.",
            outputs: [
                PortSpec("hours", "Hours", .number),
                PortSpec("minutes", "Minutes", .number),
                PortSpec("seconds", "Seconds", .number),
                PortSpec("time", "Time", .text),
                PortSpec("date", "Date", .text),
            ]
        ).device(.clock, outputs: ["clock.hours", "clock.minutes", "clock.seconds", "clock.time", "clock.date"]),
        PatchDefinition(
            kind: "deviceInfo",
            name: "Device Info",
            category: .device,
            summary: "Facts about the device the prototype is running on.",
            outputs: [
                PortSpec("name", "Name", .text),
                PortSpec("dark", "Dark Mode", .bool),
                PortSpec("scale", "Screen Scale", .number, .number(2)),
            ]
        ).device(.appearance, outputs: ["device.name", "device.dark", "device.scale"]),
    ]

    // MARK: Data

    static let data: [PatchDefinition] = [
        PatchDefinition(
            kind: "joinText",
            name: "Join Text",
            category: .data,
            summary: "Puts two pieces of text together, for example \"Hello, \" and a name.",
            inputs: [PortSpec("a", "A", .text), PortSpec("b", "B", .text)],
            outputs: [PortSpec("text", "Text", .text)]
        ) { ctx in ctx.outputs[0] = .text(ctx.text(0) + ctx.text(1)) },
        PatchDefinition(
            kind: "textLength",
            name: "Text Length",
            category: .data,
            summary: "Counts the characters in a text, and says whether there are none.",
            inputs: [PortSpec("text", "Text", .text)],
            outputs: [PortSpec("length", "Length", .number), PortSpec("empty", "Is Empty", .bool, .bool(true))]
        ) { ctx in
            ctx.outputs[0] = .number(Double(ctx.text(0).count))
            ctx.outputs[1] = .bool(ctx.text(0).isEmpty)
        },
        PatchDefinition(
            kind: "textContains",
            name: "Text Contains",
            category: .data,
            summary: "Whether a text contains another, ignoring capitals. An empty search matches everything, which suits a search field.",
            inputs: [PortSpec("text", "Text", .text), PortSpec("search", "Search", .text)],
            outputs: [PortSpec("result", "Result", .bool, .bool(true))]
        ) { ctx in
            let search = ctx.text(1).trimmingCharacters(in: .whitespaces)
            ctx.outputs[0] = .bool(search.isEmpty || ctx.text(0).localizedCaseInsensitiveContains(search))
        },
        // Network Request is run by the runtime, which hands the request to its host.
        PatchDefinition(
            kind: "networkRequest",
            name: "Network Request",
            category: .data,
            summary: "Fetches a URL and outputs what came back, as JSON when it is JSON and as a picture when it is one. Loading, Done and Failed let the interface show each state.",
            inputs: [
                PortSpec("url", "URL", .text),
                PortSpec("method", "Method", .text, .text("GET"), options: NetworkRequest.patchMethods),
                PortSpec("body", "Body", .text),
                PortSpec("send", "Send", .pulse),
                PortSpec("auto", "Send on Start", .bool, .bool(true)),
                PortSpec("headers", "Headers", .text),
                PortSpec("query", "Query", .text),
            ],
            outputs: [
                PortSpec("loading", "Loading", .bool),
                PortSpec("response", "Response", .json),
                PortSpec("text", "Text", .text),
                PortSpec("done", "Done", .pulse),
                PortSpec("failed", "Failed", .pulse),
                PortSpec("hasError", "Has Error", .bool),
                PortSpec("error", "Error", .text),
                PortSpec("status", "Status", .number),
                PortSpec("image", "Image", .text),
            ]
        ),
        PatchDefinition(
            kind: "jsonValue",
            name: "JSON Value",
            category: .data,
            summary: "Picks one value out of JSON by its path, such as items.0.name. Fed by a loop of objects, it picks from each.",
            inputs: [PortSpec("json", "JSON", .json), PortSpec("path", "Path", .text)],
            outputs: [.generic("value", "Value"), PortSpec("found", "Found", .bool)],
            genericTypes: [.text, .number, .bool, .color, .array, .json]
        ) { ctx in
            let found = ctx.inputs[0].value(atPath: ctx.text(1))
            ctx.outputs[0] = found?.converted(to: ctx.valueType) ?? Value.defaultValue(for: ctx.valueType)
            ctx.outputs[1] = .bool(found != nil)
        },
        PatchDefinition(
            kind: "parseJSON",
            name: "Parse JSON",
            category: .data,
            summary: "Turns JSON text into data, for trying a design with content typed or pasted in.",
            inputs: [PortSpec("text", "Text", .text, .text("[]"))],
            outputs: [PortSpec("json", "JSON", .json), PortSpec("valid", "Valid", .bool)]
        ) { ctx in
            let parsed = Value.parseJSON(ctx.text(0))
            ctx.outputs[0] = parsed ?? .object([:])
            ctx.outputs[1] = .bool(parsed != nil)
        },
    ]

    // MARK: Components

    static let components: [PatchDefinition] = [
        PatchDefinition(
            kind: PatchKind.componentInput,
            name: "Component Input",
            category: .component,
            summary: "Inside a component: publishes an input. Its name, type and default are what people see on every use of the component.",
            inputs: [
                .generic("value", "Default"),
                PortSpec("loops", "Loops", .text, .text(PatchKind.repeatComponent),
                         options: [PatchKind.repeatComponent, PatchKind.passLoopInside]),
                PortSpec("options", "Choices", .text),
            ],
            outputs: [.generic("value", "Value")],
            genericTypes: PatchRegistry.publishedTypes
        ) { ctx in ctx.outputs[0] = ctx.inputs[0] },
        PatchDefinition(
            kind: PatchKind.componentOutput,
            name: "Component Output",
            category: .component,
            summary: "Inside a component: publishes an output, such as a button's Tap.",
            inputs: [.generic("value", "Value")],
            outputs: [.generic("value", "Published")],
            genericTypes: PatchRegistry.publishedTypes
        ) { ctx in ctx.outputs[0] = ctx.inputs[0] },
    ]

    static let utility: [PatchDefinition] = [
        PatchDefinition(
            kind: "value",
            name: "Value",
            category: .utility,
            summary: "Holds a value to share with several inputs.",
            inputs: [.generic("value", "Value")],
            outputs: [.generic("value", "Value")],
            genericTypes: anyValue
        ) { ctx in ctx.outputs[0] = ctx.inputs[0] },
        // Broadcast and Receive are joined by the runtime: same name, same type.
        PatchDefinition(
            kind: "broadcast",
            name: "Broadcast",
            category: .utility,
            summary: "Shares a named value with every Receive patch of the same name, without a cable.",
            inputs: [PortSpec("name", "Name", .text, .text("Variable")), .generic("value", "Value")],
            genericTypes: anyValue
        ),
        PatchDefinition(
            kind: "receive",
            name: "Receive",
            category: .utility,
            summary: "Outputs the value sent by the Broadcast patch with the same name.",
            inputs: [PortSpec("name", "Name", .text, .text("Variable"))],
            outputs: [.generic("value", "Value")],
            genericTypes: anyValue
        ),
        PatchDefinition(
            kind: "makeColor",
            name: "Make Color",
            category: .utility,
            summary: "Builds a color from red, green, blue, and alpha between 0 and 1.",
            inputs: [
                PortSpec("red", "Red", .number),
                PortSpec("green", "Green", .number),
                PortSpec("blue", "Blue", .number),
                PortSpec("alpha", "Alpha", .number, .number(1)),
            ],
            outputs: [PortSpec("color", "Color", .color)]
        ) { ctx in
            ctx.outputs[0] = .color(ColorValue(
                red: ctx.number(0), green: ctx.number(1), blue: ctx.number(2), alpha: ctx.number(3)
            ))
        },
    ]
}
