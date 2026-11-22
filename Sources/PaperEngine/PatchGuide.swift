import PaperModel

/// What the Patch Library says about a patch or a view beyond its one-line summary: a fuller
/// explanation, a way to use it, a note on each port, and words people might search for that
/// are not in its name. Written by hand, one entry per built-in kind; an extension's patches
/// have none and the library falls back to their summary.
public struct PatchGuide: Sendable {
    /// A paragraph or two on what it does and how it behaves at the edges.
    public let details: String
    /// One way to use it, in a sentence or two, naming the patches it is usually cabled to.
    public let tip: String?
    /// By input port id. A patch with variable inputs is described by its template port.
    public let inputs: [String: String]
    /// By output port id.
    public let outputs: [String: String]
    /// Other words for it: what other tools call it, what it is used for, the code it
    /// stands for. Lower case.
    public let tags: [String]

    public init(
        _ details: String,
        tip: String? = nil,
        inputs: [String: String] = [:],
        outputs: [String: String] = [:],
        tags: [String] = []
    ) {
        self.details = details
        self.tip = tip
        self.inputs = inputs
        self.outputs = outputs
        self.tags = tags
    }

    /// The guide for a patch kind, if it is built in.
    public static func patch(_ kind: String) -> PatchGuide? { patches[kind] }

    /// The guide for a view type.
    public static func view(_ type: ViewType) -> PatchGuide? { views[type] }

    /// What each input a view's patch shows by default means, shared by every view type.
    public static let viewInputs: [String: String] = [
        "backgroundBlur": "How much what is behind the view is blurred where the view covers it, in points. With a fill that is partly clear, the view is a material: a bar or a sheet that what scrolls under shows through.",
        "x": "Distance of the view's anchor from the left edge of the view it is in, in points. Dimmed when a stack or grid places it.",
        "y": "Distance of the view's anchor from the top edge of the view it is in, in points. Dimmed when a stack or grid places it.",
        "width": "How wide the view is, in points.",
        "height": "How tall the view is, in points.",
        "fill": "The color it is filled with. Clear lets what is behind it show through.",
        "spacing": "The gap between neighbouring views inside it, in points.",
        "text": "The words it shows.",
        "image": "The picture it shows: an image added to the document, or one a patch hands it, such as the Photo of a Camera patch.",
        "symbol": "The name of an SF Symbol, such as heart.fill or chevron.right.",
        "video": "What it plays: the name of a movie added to the document, or a web address. A video from the web shows a placeholder in pictures of the prototype.",
        "contentMode": "Fill covers the whole view and crops what does not fit; Fit shows all of the picture, with the fill around it.",
        "playing": "On while it plays. Off holds it where it is, which costs nothing.",
        "loops": "Whether it starts over when it reaches its end. Off, it stops on its last frame; turning Playing off and on again plays it from the start.",
        "time": "Where it is, in seconds. Whenever this changes the video jumps there and goes on from there: cable a drag into it to scrub.",
        "playbackRate": "How fast it plays: 1 as recorded, 0.5 half speed, 2 twice as fast, negative backwards.",
        "muted": "Silences its sound.",
        "volume": "How loud its sound is, from 0 to 1.",
    ]

    /// What a scroll view's patch reports.
    public static let scrollOutputs: [String: String] = [
        "offset": "How far the content has scrolled, in points. Grows as the content moves up (or left).",
        "velocity": "How fast the content is moving, in points per second.",
        "dragging": "On while a finger is on the content.",
    ]

    /// What every view's patch reports about where layout put it.
    public static let frameOutputs: [String: String] = [
        "frameX": "Where the view's anchor ended up from the left edge of the view it is in, after layout: a stack's child reports where the stack placed it. Read on the next frame.",
        "frameY": "Where the view's anchor ended up from the top edge of the view it is in, after layout. Read on the next frame.",
        "frameWidth": "How wide the view was laid out, which for a Grow or Auto view is what the stack gave it.",
        "frameHeight": "How tall the view was laid out, which for a Grow or Auto view is what the stack gave it.",
    ]

    // MARK: Views

    static let views: [ViewType: PatchGuide] = [
        .screen: PatchGuide(
            "The device's screen. Every other view is inside it, and its size is the device chosen in the toolbar.",
            tags: ["artboard", "root", "device", "canvas", "page"]
        ),
        .view: PatchGuide(
            "The basic building block: a rectangle with a fill, corner radius, border and shadow that can hold other views. The views inside are placed by their own x and y, measured from its top-left corner, and can be clipped to its bounds. Turn it into a Stack or Grid with Change To and its children and cables come along.",
            tip: "Make a card: a View with a corner radius and a shadow, a Text and an Image inside, and an Interaction patch whose Down drives a Spring Animation into its Scale.",
            tags: ["rectangle", "box", "container", "group", "frame", "card", "div", "rect", "layer", "shape", "background", "zstack", "uiview"]
        ),
        .stack: PatchGuide(
            "Lines up the views inside it in a row or a column, so you never place them by hand. Spacing sets the gap, padding the margin around them, alignment where they sit across the stack, and distribution what happens to space left over. Each child can be fixed, grow to fill, or size to its content, and one marked absolute is placed by its own x and y instead.",
            tip: "Make a list row: a horizontal Stack holding a Symbol, a Text set to grow, and a chevron Symbol.",
            tags: ["hstack", "vstack", "row", "column", "auto layout", "flexbox", "flex", "linear layout", "list", "uistackview", "arrange"]
        ),
        .grid: PatchGuide(
            "Arranges the views inside it in equal columns, filling row by row. Set the number of columns and the spacing; every child gets the same width.",
            tip: "Put an Image view in a Grid and drive it with a Loop: one image is repeated into a photo grid.",
            tags: ["lazyvgrid", "collection view", "gallery", "tiles", "columns", "photo grid", "uicollectionview", "css grid"]
        ),
        .scrollView: PatchGuide(
            "A stack that scrolls when what it holds is longer than it is. It follows a finger, coasts on release and bounces at the ends, like iOS. Set a page size and it stops on whole pages, for carousels and onboarding. Its patch reports how far it has scrolled, so a header can shrink or fade as the content moves.",
            tip: "Cable Offset into a Progress patch (0 to 100) and on into a Transition to fade a large title out as the list scrolls.",
            tags: ["scroll", "list", "feed", "carousel", "paging", "pager", "uiscrollview", "scrollview", "overflow", "table view", "swipe pages"]
        ),
        .ellipse: PatchGuide(
            "An oval, or a circle when its width and height are equal, with a fill, border and shadow. It can hold other views like any view.",
            tags: ["oval", "circle", "dot", "round", "avatar", "badge", "shape"]
        ),
        .text: PatchGuide(
            "A piece of text with a font, size, weight, color and alignment. Its text can be typed in the Inspector or come from a patch, such as Join Text or a JSON Value.",
            tip: "Cable the Value of a Counter into Text to show a number that changes.",
            tags: ["label", "string", "type", "typography", "title", "heading", "copy", "uilabel", "paragraph", "words"]
        ),
        .image: PatchGuide(
            "Shows a picture, scaled to fill or fit its frame. Drop an image file into the document to use it, or cable in a picture from a patch, such as the Photo a Camera patch takes.",
            tags: ["picture", "photo", "bitmap", "png", "jpeg", "img", "uiimageview", "asset", "avatar", "thumbnail"]
        ),
        .symbol: PatchGuide(
            "Draws a glyph from Apple's SF Symbols by name, such as heart.fill or chevron.right, in a color and at a weight. Symbols scale cleanly and match the system's icons.",
            tip: "Swap between heart and heart.fill with an If patch driven by a Switch to make a like button.",
            tags: ["icon", "glyph", "sf symbols", "sfsymbol", "chevron", "pictogram", "emoji"]
        ),
        .textField: PatchGuide(
            "A box the person can type into. A tap gives it focus and shows a caret; typing comes from the Mac's keyboard while the Viewer is in front. Attach a Text Input patch to read what was typed and to focus or clear it from the graph.",
            tip: "For a search screen, cable the Text Input's Text into the Search of a Filter Array.",
            tags: ["input", "textbox", "text box", "form", "search bar", "uitextfield", "entry", "edit", "keyboard", "type"]
        ),
        .camera: PatchGuide(
            "Shows the live feed of the Mac's camera, standing in for the phone's. macOS asks for access the first time a prototype uses it. Add a Camera patch to take a photo from it.",
            tags: ["video", "live feed", "viewfinder", "webcam", "capture", "avfoundation", "preview"]
        ),
        .video: PatchGuide(
            "Plays a movie, from a file in the document or a web address. Playing starts and stops it, Loop starts it over at the end, Playback Rate sets its speed (negative plays it backwards), and Time makes it jump: cable a drag into Time to scrub. Where it is comes from the prototype's own clock, so a paused video costs nothing and a picture of it is the same every time. Attach a Video Time patch to know where it is and when it ends.",
            tip: "Cable an Interaction's Down through Not into Playing and a drag into Time: the video pauses under the finger and scrubs with it.",
            tags: ["movie", "film", "clip", "player", "mp4", "mov", "avplayer", "videoplayer", "playback", "media", "footage", "scrub"]
        ),
        .component: PatchGuide(
            "A use of a component: a copy of views and patches made once and used in many places. Its inputs and outputs are the ones the component publishes.",
            tags: ["symbol", "instance", "reusable", "master", "template"]
        ),
        .shader: PatchGuide(
            "A view drawn by Metal shader code you write, run on the GPU for every pixel. The inputs declared in the code become ports on its patch, so springs and touches can drive them. A shader can draw something from scratch, such as a gradient or noise, or read what is inside the view as content and change it: blur, ripple, tint, distort. A shader that uses time animates by itself.",
            tip: "Ask the assistant for a look (\"a liquid glass ripple where I touch\") and it writes the code and cables the touch in.",
            tags: ["metal", "glsl", "gpu", "effect", "filter", "gradient", "noise", "blur", "distortion", "fragment", "msl", "visual effect"]
        ),
        .custom: PatchGuide("A view an extension draws with a script."),
    ]

    // MARK: Patches

    static let patches: [String: PatchGuide] = {
        var all: [String: PatchGuide] = [:]
        for group in [input, state, logic, math, animation, loops, data, device, utility] {
            all.merge(group) { first, _ in first }
        }
        return all
    }()

    static let input: [String: PatchGuide] = [
        "interaction": PatchGuide(
            "Attach it to a view to make that view respond to touch. It reports whether a finger is down on the view, pulses on a tap, a double tap and a long press, and follows a drag: how far the finger has moved since it came down, where it is, and how fast it is going. A tap only counts when the finger lifts near where it came down.",
            tip: "Down into a Spring Animation's Target, and its Value through a Transition (1 to 0.95) into the view's Scale, makes a button that presses in.",
            outputs: [
                "down": "On while a finger is touching the view.",
                "tap": "Pulses when a finger comes down and lifts on the view without moving far.",
                "drag": "How far the finger has travelled since it came down, in points. Back to zero on the next touch.",
                "position": "Where the finger is, in the view's own coordinates.",
                "velocity": "How fast the finger is moving, in points per second. Useful for flicks and for throwing things with a spring.",
                "doubleTap": "Pulses on the second of two quick taps.",
                "longPress": "Pulses once a finger has stayed down, without moving, for about half a second.",
            ],
            tags: ["touch", "tap", "click", "press", "gesture", "button", "drag", "pan", "hit area", "on click", "ontap", "touch down", "long press", "double tap", "hold", "pointer"]
        ),
        "layerSize": PatchGuide(
            "Reports how big a view turned out after layout. That is not always the size you set: a stack sizes to what it holds, and a child set to grow takes up what is left. Use it when something should follow a view whose size changes.",
            tip: "Cable Width into another view's Width so an underline always matches the label above it.",
            outputs: [
                "size": "The width and height together.",
                "width": "The laid-out width, in points.",
                "height": "The laid-out height, in points.",
            ],
            tags: ["bounds", "frame", "dimensions", "measure", "geometry reader", "layout", "resize", "intrinsic size"]
        ),
        "videoTime": PatchGuide(
            "Attach it to a Video view to follow its playhead: where it is, how long it is, and how far through. Its values are those at the end of the frame before, as with View Size. Duration is 0 until the video has been loaded.",
            tip: "Progress through a Transition into the X of a knob makes a scrubber that follows the video; Ended into a Switch's Turn Off shows a Replay button.",
            outputs: [
                "time": "Where the video is, in seconds from its start.",
                "duration": "How long the video is, in seconds; 0 until it is known.",
                "progress": "Time divided by Duration: 0 at the start, 1 at the end.",
                "playing": "On while the video is moving: playing, at a rate other than 0, and not stopped at its end.",
                "ended": "Pulses when the video reaches its end, whether it then loops or stops.",
            ],
            tags: ["video", "playhead", "current time", "duration", "progress", "position", "movie", "ended", "finished", "avplayer", "seek"]
        ),
        "textInput": PatchGuide(
            "Attach it to a Text Field to read what is typed into it and to control it from the graph. Text is everything typed so far; Changed pulses with every keystroke and Submitted when Return is pressed.",
            tip: "Cable Text into the Search of a Filter Array to filter a list as the person types, and into Text Length to show a Clear button only when there is something to clear.",
            inputs: [
                "focus": "A pulse gives the field focus, as if it had been tapped.",
                "dismiss": "A pulse takes focus away, as Return does.",
                "clear": "A pulse empties the field.",
            ],
            outputs: [
                "text": "What is in the field now.",
                "editing": "On while the field has focus and is showing a caret.",
                "changed": "Pulses each time the text changes.",
                "submitted": "Pulses when Return is pressed in the field.",
            ],
            tags: ["keyboard", "typing", "type", "form", "search", "text field", "input", "on change", "onsubmit", "focus", "string"]
        ),
        "tap": PatchGuide(
            "Attach it to a view to hear taps on it: fingers that came down and lifted without moving or staying long. Taps is how many in a row it takes, so 2 is a double tap, and Fingers how many at once. A Tap for one tap beside a Tap for two on the same view waits a moment to see whether a second tap comes, and stays silent when it does, as on iPhone.",
            tip: "Tapped into a Switch's Flip turns something on and off. For a button that presses in as well, use an Interaction: its Down is on from the moment the finger lands.",
            inputs: [
                "taps": "How many taps in a row it takes: 1 for a tap, 2 for a double tap.",
                "fingers": "How many fingers must tap together.",
            ],
            outputs: [
                "tapped": "Pulses when the taps are complete.",
                "position": "Where the last tap landed, in screen points.",
            ],
            tags: ["tap", "click", "double tap", "two finger tap", "gesture", "button", "on click", "ontap", "uitapgesturerecognizer", "tapgesture", "press"]
        ),
        "longPress": PatchGuide(
            "Attach it to a view to hear a finger held still on it. It begins once the finger has been down for Duration seconds without moving away, and stays on until the finger lifts, which may be after dragging. Once it has begun, the touch is no longer a tap, and a scroll view around it does not scroll.",
            tip: "Began into a Switch's Turn On puts a list into an edit mode; Pressing into a Spring makes what is held lift a little.",
            inputs: [
                "duration": "Seconds the finger must stay down before it counts.",
                "fingers": "How many fingers must be held together.",
            ],
            outputs: [
                "pressing": "On from when the press begins until the finger lifts.",
                "began": "Pulses when the finger has been held long enough.",
                "ended": "Pulses when the finger lifts after a long press.",
                "position": "Where the finger is, in screen points. It follows the finger while Pressing is on.",
            ],
            tags: ["long press", "hold", "press and hold", "touch and hold", "context menu", "haptic touch", "gesture", "uilongpressgesturerecognizer", "longpressgesture", "peek"]
        ),
        "pan": PatchGuide(
            "Attach it to a view to follow fingers dragging across it. It begins once they have moved a little, so a tap is never a pan, and Translation counts from there: nothing jumps when it begins. With two fingers it follows the point between them, and goes on with the one that stays when the other lifts. Beside a Pinch and a Rotation on the same view all three go at once. Inside a scroll view, set Direction so that a sideways drag pans and an up-and-down one scrolls.",
            tip: "Translation added to where the view rests moves it with the finger. Panning into a Spring's Hold, with Velocity into its Velocity, throws it on release.",
            inputs: [
                "direction": "Any drag, or only one that starts sideways (Horizontal) or up and down (Vertical). A drag that starts the other way is left to whatever else listens, such as a scroll view.",
                "minFingers": "The fewest fingers that make it a pan. 2 leaves one-finger drags to something else.",
                "maxFingers": "The most fingers it follows; 0 is any number.",
            ],
            outputs: [
                "translation": "How far the fingers have travelled since the pan began, in points. It keeps its last value when they lift.",
                "velocity": "How fast they are moving, in points per second. When they lift it holds the speed they left at.",
                "position": "The point between the fingers, in screen points.",
                "panning": "On while the pan is under way.",
                "began": "Pulses when the pan begins.",
                "ended": "Pulses when the fingers lift, or when the pan is cancelled.",
            ],
            tags: ["drag", "pan", "move", "gesture", "two finger", "translation", "follow finger", "draggable", "uipangesturerecognizer", "draggesture", "sheet", "slide"]
        ),
        "swipe": PatchGuide(
            "Attach it to a view to hear flicks. A swipe is a touch that travelled far enough and was still moving fast when it lifted; a slow drag is not one. Each direction has its own pulse. A Pan that has begun on the same touch takes it from the Swipe: to throw something that is being dragged, read the Pan's Velocity when it ends.",
            tip: "Cable Left and Right into the Increase and Decrease of a Counter to step through pages.",
            inputs: [
                "fingers": "How many fingers must flick together.",
            ],
            outputs: [
                "left": "Pulses on a flick towards the left.",
                "right": "Pulses on a flick towards the right.",
                "up": "Pulses on a flick upwards.",
                "down": "Pulses on a flick downwards.",
            ],
            tags: ["flick", "gesture", "fling", "swipe to dismiss", "swipe left", "swipe right", "tinder", "card stack", "next", "previous", "uiswipegesturerecognizer"]
        ),
        "pinch": PatchGuide(
            "Attach it to a view to follow two fingers on it moving apart or together. Both fingers must be on the view. It begins once the distance between them has changed a little, and Scale counts from there. In the Viewer, hold Option to place a mirrored second finger and drag (Shift moves both), or pinch on a trackpad. Its values keep their last reading when the fingers lift, so a spring can settle from there.",
            tip: "Scale into the view's Scale zooms a photo; with a Pan and a Rotation on the same view it can be moved, zoomed and turned at once. Feed Scale to a Spring with Hold on while Pinching for a zoom that snaps back.",
            outputs: [
                "scale": "How far apart the fingers are compared with when the pinch began: 1 is the same, 2 twice as far.",
                "rotation": "How far the fingers have turned since the pinch began, in degrees. Kept for documents that already use it: a Rotation patch tells a turn from a pinch.",
                "pinching": "On while the pinch is under way.",
                "velocity": "How fast Scale is changing, per second.",
                "center": "The point between the two fingers, in screen points.",
                "began": "Pulses when the pinch begins.",
                "ended": "Pulses when a finger lifts and the pinch ends.",
            ],
            tags: ["zoom", "magnify", "two finger", "multitouch", "gesture", "scale", "spread", "magnification", "uipinchgesturerecognizer", "magnifygesture", "photo"]
        ),
        "rotation": PatchGuide(
            "Attach it to a view to follow two fingers on it turning around each other. It begins once they have turned a few degrees, and counts from there, clockwise, past half and full turns. In the Viewer, hold Option and drag around the middle, or rotate on a trackpad.",
            tip: "Rotation into the view's Rotation turns it with the fingers. Add what it had before with a Variable set when Ended pulses, so each turn starts where the last one stopped.",
            outputs: [
                "rotation": "Degrees the fingers have turned since the turn began, clockwise. It keeps its last value when they lift.",
                "velocity": "How fast they are turning, in degrees per second.",
                "rotating": "On while the turn is under way.",
                "center": "The point between the two fingers, in screen points.",
                "began": "Pulses when the turn begins.",
                "ended": "Pulses when a finger lifts and the turn ends.",
            ],
            tags: ["rotate", "turn", "twist", "two finger", "multitouch", "gesture", "angle", "dial", "knob", "uirotationgesturerecognizer", "rotategesture"]
        ),
        "hover": PatchGuide(
            "Attach it to a view to know when a pointer rests over it without touching, as on an iPad with a trackpad, or the web. The prototype only listens for the pointer when it has a Hover patch.",
            tip: "Hovering into a Spring that lifts a card a little, for a pointer effect.",
            outputs: [
                "hovering": "On while the pointer is over the view.",
                "position": "Where the pointer is, in the view's own coordinates.",
            ],
            tags: ["mouse", "pointer", "mouse over", "mouseover", "mouse enter", "rollover", "cursor", "ipad", "web"]
        ),
        "keyboard": PatchGuide(
            "Listens for one key on the Mac's keyboard while the Viewer is in front. Name the key in Key: a letter, a digit, or space, return, escape, left, right, up or down. Keys go to a text field instead while one is being edited.",
            tip: "Space into the Flip of a Switch to try a state change without reaching for the pointer.",
            inputs: ["key": "Which key to listen for."],
            outputs: [
                "down": "On while the key is held.",
                "pressed": "Pulses when the key goes down.",
            ],
            tags: ["key", "shortcut", "hotkey", "keypress", "key down", "keystroke", "hardware keyboard"]
        ),
        "time": PatchGuide(
            "Counts the seconds since the prototype started, smoothly, every frame. Use it for anything that should keep moving by itself. Because it asks for every frame, a prototype with a Time patch never rests while Running is on.",
            tip: "Time into a JavaScript patch with Math.sin to make something bob up and down forever.",
            inputs: ["running": "Off, it holds the time it had and asks for no frames, so the prototype can rest."],
            outputs: ["time": "Seconds since the prototype started or was restarted."],
            tags: ["clock", "seconds", "elapsed", "timer", "frame", "loop", "forever", "ticker", "continuous", "oscillate"]
        ),
    ]

    static let state: [String: PatchGuide] = [
        "navigate": PatchGuide(
            "Attached to one of the prototype's screens, it shows that screen. A pulse into Go brings it in over the one showing, and the one it covered is remembered so Navigate Back can return to it. Only one screen is there at a time; while one gives way to another both are. Drawing an arrow from a view to a screen on the Canvas makes one of these with a Tap cabled into Go.",
            tip: "Cable a button's Tap into Go to open a detail screen, and the detail's back button into a Navigate Back.",
            inputs: [
                "go": "A pulse shows this patch's screen. Nothing happens if it is already showing.",
                "style": "How the screen arrives: Push from the right, Modal up from the bottom, Fade, Instant, which changes at once and leaves nothing to go back to (tabs), or Morph, in which a view with the same name on both screens moves and changes from one to the other while the rest crossfades.",
                "response": "How long the move takes to settle, in seconds, as a Spring Animation's Response.",
            ],
            outputs: [
                "progress": "How much of the screen is in place: 0 while it is away, 1 while it shows, and in between as it arrives or leaves.",
                "arrived": "Pulses when the screen has finished arriving.",
                "showing": "On while this is the screen showing and nothing is moving.",
            ],
            tags: ["screen", "flow", "push", "present", "modal", "sheet", "segue", "route", "navigation", "navigationstack", "navigate", "go to", "link", "transition", "tab", "page", "router", "fade", "cross dissolve", "smart animate", "magic move", "shared element", "hero", "morph", "matched geometry"]
        ),
        "navigateBack": PatchGuide(
            "Goes back to the screen that was showing before the one on top. The screen leaves the way it arrived, in reverse: a pushed one slides out to the right, a modal one drops away. A screen that is still arriving turns round where it is.",
            tip: "Cable the Navigation Bar's Back output, or a close button's Tap, into Go.",
            inputs: [
                "go": "A pulse goes back one screen. Nothing happens on the first screen.",
                "response": "How long the move takes to settle, in seconds.",
            ],
            outputs: [
                "canGoBack": "On while there is a screen to go back to.",
                "arrived": "Pulses when the screen gone back to is in place.",
            ],
            tags: ["back", "pop", "dismiss", "close", "return", "navigation", "unwind", "screen", "flow", "previous"]
        ),
        "switch": PatchGuide(
            "Remembers one thing that is either on or off: a menu open or closed, a like set or not, a mode. A pulse into Flip changes it, and Turn On and Turn Off set it whatever it was. It starts off unless Starts On says otherwise.",
            tip: "Cable a view's Interaction Tap into Flip, and On / Off into a Spring Animation's Target, to open and close something with a tap.",
            inputs: [
                "flip": "A pulse turns it on if it is off and off if it is on.",
                "turnOn": "A pulse turns it on.",
                "turnOff": "A pulse turns it off.",
                "start": "What it is before any pulse. Changing this sets the switch to it.",
            ],
            outputs: ["on": "Whether it is on."],
            tags: ["toggle", "boolean", "state", "flip flop", "on off", "checkbox", "@state", "usestate", "open closed", "expanded", "selected", "bool"]
        ),
        "eitherPulse": PatchGuide(
            "Joins two pulses into one: it pulses when A does and when B does. Use it when two things should do the same, such as a Cancel button and a tap outside both closing a sheet.",
            tip: "For more than two, chain them: the Pulse of one into A of the next.",
            inputs: ["a": "One pulse.", "b": "Another."],
            outputs: ["pulse": "Pulses when either arrives."],
            tags: ["or", "merge", "join", "any", "both", "combine pulses", "union"]
        ),
        "pulseGate": PatchGuide(
            "An If for pulses: a pulse goes through while Open is on and is dropped while it is off. Use it for a tap that should count only in one state, or a release that matters only past a threshold.",
            tip: "Cable a comparison into Open: a drag's end through a Gate that is open when the drag went far enough dismisses a sheet.",
            inputs: ["pulse": "The pulse to let through.", "open": "Whether it gets through."],
            outputs: ["pulse": "The pulse, when Open was on."],
            tags: ["filter", "condition", "if", "allow", "block", "only when", "guard", "enabled"]
        ),
        "optionSwitch": PatchGuide(
            "Remembers which of three choices was picked last, as 0, 1 or 2. Each input picks one. Use it for tabs, segmented controls and screens of a flow; for more than three choices use a Counter or a Loop Option Switch.",
            tip: "Cable the Taps of three tab buttons into the three inputs, and Option into the Option of an Option Picker to choose each tab's content.",
            inputs: [
                "set0": "A pulse picks option 0.",
                "set1": "A pulse picks option 1.",
                "set2": "A pulse picks option 2.",
            ],
            outputs: ["option": "The option picked last, starting at 0."],
            tags: ["tabs", "segmented control", "radio", "selection", "enum", "mode", "index", "state", "picker", "selected tab"]
        ),
        "counter": PatchGuide(
            "Keeps a number that pulses step up and down. It starts at Start and moves by Step. Give it a Minimum below its Maximum to keep it between them; left equal, it has no limit. A Mod after it wraps round.",
            tip: "Next and Back buttons into Increase and Decrease step through onboarding pages; Value times the page width drives the offset.",
            inputs: [
                "increase": "A pulse adds 1.",
                "decrease": "A pulse takes 1 away.",
                "reset": "A pulse sets it back to Start.",
                "step": "How much one pulse adds or takes away.",
                "min": "The least it can be, when it is below Maximum.",
                "max": "The most it can be, when it is above Minimum.",
                "start": "What it counts from. Changing it sets the count to it.",
            ],
            outputs: ["value": "The current count."],
            tags: ["count", "increment", "decrement", "stepper", "index", "page", "number", "state", "tally", "plus minus"]
        ),
        "optionPicker": PatchGuide(
            "Chooses one of three values by number: Option 0 gives Value 0, 1 gives Value 1, 2 gives Value 2. Numbers in between round down and numbers outside are kept to the nearest end. Right-click to change the type of value it picks.",
            tip: "Cable the Option of an Option Switch in, and three colors into the values, to color a selected tab.",
            inputs: [
                "option": "Which value to output: 0, 1 or 2.",
                "value0": "What to output when Option is 0.",
                "value1": "What to output when Option is 1.",
                "value2": "What to output when Option is 2.",
            ],
            outputs: ["value": "The value Option chose."],
            tags: ["switch case", "select", "choose", "mux", "multiplexer", "lookup", "map", "index", "pick"]
        ),
        "pulse": PatchGuide(
            "Turns a change into a moment: it pulses once when its input turns on and once when it turns off. Use it where something must happen when a state changes, such as a sound when a switch flips.",
            tip: "The Animating output of a Spring into this, and Turned Off into a Haptic Feedback, gives a tap when the motion comes to rest.",
            inputs: ["value": "The on/off value to watch."],
            outputs: [
                "turnedOn": "Pulses in the frame its input turns on.",
                "turnedOff": "Pulses in the frame its input turns off.",
            ],
            tags: ["edge", "trigger", "event", "onchange", "rising edge", "falling edge", "when", "fire"]
        ),
        "sampleHold": PatchGuide(
            "Takes a snapshot of its input when pulsed and keeps it until the next pulse, however much the input changes in between. It starts at zero or off.",
            tip: "Sample a drag's position on release to remember where something was dropped.",
            inputs: [
                "value": "The value to capture.",
                "sample": "A pulse captures Value as it is now.",
            ],
            outputs: ["value": "The value captured at the last pulse."],
            tags: ["snapshot", "latch", "capture", "remember", "store", "freeze", "save", "memory"]
        ),
        "delay": PatchGuide(
            "Passes its input through a set time later. Each change is delivered after the delay, in order, so a quick on and off arrives as a quick on and off. Use it to stagger animations or wait before something happens.",
            tip: "Give each of three cards a Delay of 0, 0.05 and 0.1 before their springs, for a staggered entrance.",
            inputs: [
                "value": "The value to delay.",
                "duration": "How long to wait, in seconds.",
            ],
            outputs: ["value": "The input as it was Duration seconds ago."],
            tags: ["wait", "timeout", "settimeout", "after", "stagger", "lag", "later", "timer", "sleep", "debounce"]
        ),
        "dragValue": PatchGuide(
            "Turns dragging into a value between 0 and 1 that stays where it is let go, as a slider's thumb does. Each new drag continues from the current value rather than jumping. Distance is how far a drag must travel to go from 0 to 1.",
            tip: "Cable an Interaction's Down and the X of its Drag (through Split Point) in, and Value into a Transition to place the thumb and set a volume.",
            inputs: [
                "down": "On while the drag is happening: usually an Interaction's Down.",
                "drag": "How far the finger has moved since it came down, along one axis.",
                "range": "How many points of drag cover the whole range from 0 to 1.",
                "start": "Where the value begins, between 0 and 1. Changing it moves the value there.",
            ],
            outputs: ["value": "The current value, between 0 and 1."],
            tags: ["slider", "scrubber", "knob", "dial", "volume", "progress", "seek", "drag", "fader", "uislider"]
        ),
    ]

    static let logic: [String: PatchGuide] = {
        let compare: [String: String] = ["a": "The first number.", "b": "The number to compare it with."]
        let result = ["result": "On when the comparison holds."]
        let comparisonTags = ["compare", "comparison", "condition", "test", "threshold", "check"]
        return [
            "and": PatchGuide(
                "On only when both inputs are on. Use it when two things must both be true, such as a field that is filled and a box that is checked.",
                inputs: ["a": "The first condition.", "b": "The second condition."],
                outputs: ["result": "On when A and B are both on."],
                tags: ["&&", "both", "all", "boolean", "logic gate", "conjunction"]
            ),
            "or": PatchGuide(
                "On when either input is on, or both. Use it when any of several things should have the same effect.",
                inputs: ["a": "The first condition.", "b": "The second condition."],
                outputs: ["result": "On when A or B is on."],
                tags: ["||", "either", "any", "boolean", "logic gate", "disjunction"]
            ),
            "not": PatchGuide(
                "Turns on into off and off into on.",
                tip: "Cable an Is Empty into Not to know when a field has text.",
                inputs: ["value": "The condition to invert."],
                outputs: ["result": "The opposite of Value."],
                tags: ["!", "invert", "negate", "opposite", "toggle", "boolean", "inverse"]
            ),
            "equal": PatchGuide(
                "On when two numbers are the same.",
                tip: "Compare the Option of an Option Switch with each tab's index to know which tab is selected.",
                inputs: compare, outputs: result,
                tags: comparisonTags + ["==", "equals", "same", "is", "match", "selected"]
            ),
            "notEqual": PatchGuide(
                "On when two numbers differ.",
                inputs: compare, outputs: result,
                tags: comparisonTags + ["!=", "different", "differs", "not equal", "unequal"]
            ),
            "greater": PatchGuide(
                "On when A is more than B.",
                tip: "Scroll Offset greater than 40 tells when to show a compact header.",
                inputs: compare, outputs: result,
                tags: comparisonTags + ["greater than", "more than", "above", "larger", "over"]
            ),
            "greaterEqual": PatchGuide(
                "On when A is more than B or the same.",
                inputs: compare, outputs: result,
                tags: comparisonTags + [">=", "at least", "greater than or equal", "minimum"]
            ),
            "less": PatchGuide(
                "On when A is less than B.",
                inputs: compare, outputs: result,
                tags: comparisonTags + ["less than", "below", "under", "smaller", "fewer"]
            ),
            "lessEqual": PatchGuide(
                "On when A is less than B or the same.",
                inputs: compare, outputs: result,
                tags: comparisonTags + ["<=", "at most", "less than or equal", "maximum"]
            ),
            "if": PatchGuide(
                "Chooses between two values: Then when the condition is on, Else when it is off. Right-click to change what type of value it chooses between: a number, text, a color, a point.",
                tip: "A Switch into Condition with heart and heart.fill as Then and Else gives a like button its icon.",
                inputs: [
                    "condition": "Which value to choose.",
                    "then": "The value to output when Condition is on.",
                    "else": "The value to output when Condition is off.",
                ],
                outputs: ["value": "Then or Else."],
                tags: ["ternary", "?:", "conditional", "choose", "select", "branch", "else", "when", "switch", "mux"]
            ),
        ]
    }()

    static let math: [String: PatchGuide] = {
        let ab = ["a": "The first number.", "b": "The second number."]
        let result = ["result": "The answer."]
        return [
            "add": PatchGuide("Adds two numbers.", inputs: ab, outputs: result,
                              tags: ["+", "plus", "sum", "addition", "offset", "total"]),
            "subtract": PatchGuide("Takes B away from A.", inputs: ["a": "The number to start from.", "b": "The number to take away."], outputs: result,
                                   tags: ["-", "minus", "difference", "subtraction", "less"]),
            "multiply": PatchGuide(
                "Multiplies two numbers. Use it to scale one value into another's range, such as a page index times the page width.",
                inputs: ab, outputs: result,
                tags: ["*", "times", "product", "scale", "multiplication", "factor"]
            ),
            "divide": PatchGuide(
                "Divides A by B. Dividing by zero gives 0 rather than an error, so a prototype never breaks on it.",
                inputs: ["a": "The number to divide.", "b": "The number to divide it by."], outputs: result,
                tags: ["/", "division", "quotient", "ratio", "fraction", "over"]
            ),
            "mod": PatchGuide(
                "The remainder after dividing A by B, always between 0 and B. Use it to wrap a counter round, so after the last item comes the first again.",
                tip: "A Counter through Mod 3 cycles 0, 1, 2, 0, 1, 2.",
                inputs: ["a": "The number to divide.", "b": "The number to divide by: the length of the cycle."], outputs: result,
                tags: ["%", "modulo", "remainder", "wrap", "cycle", "repeat", "circular"]
            ),
            "min": PatchGuide("The smaller of two numbers. Use it to cap a value from above.", inputs: ab, outputs: result,
                              tags: ["minimum", "smallest", "lower", "cap", "limit", "least"]),
            "max": PatchGuide("The larger of two numbers. Use it to keep a value from going below a floor.", inputs: ab, outputs: result,
                              tags: ["maximum", "largest", "higher", "floor", "limit", "greatest"]),
            "clamp": PatchGuide(
                "Keeps a number between a minimum and a maximum: anything below comes out as the minimum, anything above as the maximum.",
                tip: "Clamp a drag between -100 and 0 so a sheet cannot be pulled past its ends.",
                inputs: [
                    "value": "The number to keep in range.",
                    "min": "The lowest it may be.",
                    "max": "The highest it may be.",
                ],
                outputs: ["result": "Value, kept between Min and Max."],
                tags: ["limit", "bound", "constrain", "range", "restrict", "cap", "saturate"]
            ),
            "abs": PatchGuide(
                "How far a number is from zero, whichever side it is on: -5 and 5 both give 5. Use it when only the size of a movement matters, not its direction.",
                inputs: ["value": "Any number."],
                outputs: ["result": "Value without its sign."],
                tags: ["absolute", "magnitude", "positive", "distance", "unsigned", "abs"]
            ),
            "round": PatchGuide(
                "Rounds to the nearest whole number. Halves round away from zero.",
                tip: "Round a scroll offset divided by the page width to know which page is showing.",
                inputs: ["value": "Any number."],
                outputs: ["result": "The nearest whole number."],
                tags: ["integer", "whole", "nearest", "snap", "floor", "ceil", "truncate", "int"]
            ),
            "progress": PatchGuide(
                "Says how far a value has got from Start to End, as a number from 0 to 1: Start gives 0, End gives 1, halfway gives 0.5. Values outside the range go below 0 or above 1. It is the opposite of Transition, and the two together map any range onto any other.",
                tip: "Scroll Offset with Start 0 and End 120, then a Transition from 1 to 0 into Opacity, fades a header out over the first 120 points.",
                inputs: [
                    "value": "The number to measure.",
                    "start": "The value that counts as 0.",
                    "end": "The value that counts as 1.",
                ],
                outputs: ["progress": "How far Value is from Start to End."],
                tags: ["normalize", "map range", "remap", "inverse lerp", "percentage", "ratio", "interpolate", "fraction", "range"]
            ),
            "makePoint": PatchGuide(
                "Puts an X and a Y together into a point, for ports that take a position.",
                inputs: ["x": "The horizontal part.", "y": "The vertical part."],
                outputs: ["point": "The point (X, Y)."],
                tags: ["point", "vector", "position", "coordinate", "cgpoint", "combine", "pack", "xy"]
            ),
            "splitPoint": PatchGuide(
                "Takes a point apart into its X and Y, such as the Drag of an Interaction, so each can drive something different.",
                inputs: ["point": "The point to take apart."],
                outputs: ["x": "The horizontal part.", "y": "The vertical part."],
                tags: ["point", "vector", "position", "coordinate", "separate", "unpack", "xy", "components"]
            ),
        ]
    }()

    static let animation: [String: PatchGuide] = [
        "spring": PatchGuide(
            "Moves towards its target the way a real object on a spring would: quickly at first, settling with or without a bounce, and keeping its speed when the target changes mid-way, so interrupted motion stays smooth. Response is roughly how long it takes; damping below 1 bounces, 1 does not. Hold lets a finger take the value directly and hands it back to the spring on release, with the finger's speed.",
            tip: "Cable a Switch's On / Off into Target and Value through a Transition into a view's Y to slide a sheet up and down. For a sheet you can drag, put the Interaction's Down into Hold and its Drag's Y into Follow.",
            inputs: [
                "target": "Where the value should end up. Usually 0 or 1, mapped to a real range afterwards with a Transition.",
                "response": "Roughly how long the motion takes, in seconds. Smaller is snappier.",
                "damping": "How much bounce: 1 settles without overshooting, lower values bounce more. Between 0.6 and 0.9 is usual.",
                "hold": "While on, the spring lets go and the value follows Follow instead.",
                "held": "What the value moves with while Hold is on, such as a drag. It moves by the same amount from where it was grabbed.",
            ],
            outputs: [
                "value": "The animated value.",
                "velocity": "How fast it is moving, in units per second.",
                "animating": "On while it is moving.",
            ],
            tags: ["animation", "animate", "motion", "physics", "bounce", "spring animation", "withspring", "interpolatingspring", "uispringtimingparameters", "transition", "ease", "tween", "dynamics", "elastic"]
        ),
        "easing": PatchGuide(
            "Moves to its target over a set time along a curve: linear, ease in, ease out or ease in and out. Unlike a spring it always takes the same time and never overshoots. If the target changes mid-way, it starts again from where it is.",
            tip: "Use it for fades and anything timed, such as a progress bar that fills in exactly two seconds.",
            inputs: [
                "target": "Where the value should end up.",
                "duration": "How long the move takes, in seconds.",
                "curve": "How it speeds up and slows down: Linear, Ease In, Ease Out or Ease In Out.",
            ],
            outputs: [
                "value": "The animated value.",
                "animating": "On while it is moving.",
            ],
            tags: ["animation", "animate", "tween", "ease in", "ease out", "ease in out", "timing", "curve", "bezier", "duration", "withtiming", "fade", "linear", "classic animation"]
        ),
        "transition": PatchGuide(
            "Maps progress from 0 to 1 onto any range: at 0 it gives Start, at 1 End, and in between a blend. It works on numbers, points, sizes and colors, so one spring can move, grow and recolor a view at once through several Transitions. Progress outside 0 to 1 goes past the ends, which keeps a spring's overshoot.",
            tip: "Spring Value into three Transitions: Y from 800 to 100, Scale from 0.9 to 1, Fill from gray to blue.",
            inputs: [
                "progress": "How far along: 0 is Start, 1 is End.",
                "start": "The value at progress 0.",
                "end": "The value at progress 1.",
            ],
            outputs: ["value": "The blend of Start and End."],
            tags: ["lerp", "interpolate", "mix", "map", "range", "blend", "remap", "tween", "from to", "keyframe", "color fade"]
        ),
        "impulse": PatchGuide(
            "On a pulse, jumps to 1 and falls back to 0 over a duration, quickly at first. Use it for momentary feedback: a flash, a bump, a shake that dies away.",
            tip: "A Tap into Trigger and Value through a Transition (1 to 1.2) into Scale makes something pop when tapped.",
            inputs: [
                "trigger": "A pulse starts it again from 1.",
                "duration": "How long it takes to fall back to 0, in seconds.",
            ],
            outputs: [
                "value": "1 at the pulse, falling to 0.",
                "active": "On until it has fallen back to 0.",
            ],
            tags: ["flash", "bump", "pop", "feedback", "decay", "pulse", "blink", "highlight", "envelope", "shake"]
        ),
    ]

    static let loops: [String: PatchGuide] = [
        "loop": PatchGuide(
            "Makes a list of indexes, 0, 1, 2 and so on up to a count. Everything cabled after it runs once per index, and a view it reaches is repeated once per index, so one view becomes many. Layout arranges the copies if they are in a stack or grid.",
            tip: "Loop of 5 into the Y of a row (through Multiply by 60) gives five rows; inside a Stack, cable the index into the row's Text instead.",
            inputs: ["count": "How many indexes to make, up to 2,000."],
            outputs: ["index": "The index of each copy, from 0."],
            tags: ["repeat", "for", "for each", "foreach", "iterate", "range", "array", "list", "copies", "duplicate", "repeater", "map"]
        ),
        "loopBuilder": PatchGuide(
            "Makes a loop out of values you type, one per input, such as three titles or five colors. Right-click it to add or remove inputs, and to choose the type of value.",
            tip: "Three tab titles into a Loop Builder, its Loop into a Text inside a horizontal Stack, gives a tab bar.",
            inputs: ["value": "One value of the loop. There is one input for each, numbered from 0."],
            outputs: [
                "loop": "The values, as a loop.",
                "index": "The index of each value.",
            ],
            tags: ["array", "list", "items", "values", "collection", "literal", "enumerate", "build list", "data"]
        ),
        "loopOverArray": PatchGuide(
            "Turns an array, such as the items in a network response, into a loop with one value per item, so a view repeats once for each. Choose the type to read each item as text, a number, or JSON to pick fields from with JSON Value.",
            tip: "A Network Request's Response through JSON Value (path items, type array), then Loop Over Array set to JSON, then JSON Value with path name into a row's Text, lists the names.",
            inputs: ["array": "The array to go through."],
            outputs: [
                "value": "Each item of the array.",
                "index": "The index of each item, from 0.",
            ],
            tags: ["for each", "foreach", "iterate", "map", "list", "array", "items", "data", "render list", "collection"]
        ),
        "filterArray": PatchGuide(
            "Keeps the items of an array that contain a search text, ignoring capitals, and drops the rest: what a search field does to a list. For an array of objects, Key names the field to search in; left empty, any field may match. An empty search keeps everything.",
            tip: "A Text Input's Text into Search and the result into Loop Over Array makes a list that filters as you type.",
            inputs: [
                "array": "The items to filter.",
                "search": "The text to look for.",
                "key": "For objects, which field to look in. Empty looks in all of them.",
            ],
            outputs: [
                "array": "The items that matched.",
                "count": "How many matched, for showing \"No results\".",
            ],
            tags: ["search", "filter", "find", "query", "match", "where", "results", "narrow", "lookup"]
        ),
        "splitText": PatchGuide(
            "Cuts text into an array at every separator, trimming spaces, so a list can be typed as one line. With an empty separator it splits into single characters.",
            tip: "Type \"Home, Search, Profile\" and cable the Array into Loop Over Array to make tab titles.",
            inputs: [
                "text": "The text to cut up.",
                "separator": "Where to cut: a comma by default.",
            ],
            outputs: [
                "array": "The pieces, in order.",
                "count": "How many pieces there are.",
            ],
            tags: ["split", "explode", "tokenize", "csv", "comma", "separate", "string to array", "words", "characters"]
        ),
        "loopSelect": PatchGuide(
            "Picks one value out of a loop by its index, turning the loop back into a single value. An index outside the loop gives an empty value.",
            tip: "With the Option of a Loop Option Switch as Index, it gives the title of the row that was tapped.",
            inputs: [
                "loop": "The loop to pick from.",
                "index": "Which value to pick, from 0.",
            ],
            outputs: ["value": "The value at Index."],
            tags: ["index", "subscript", "at", "pick", "get", "element", "item", "nth", "array access"]
        ),
        "loopCount": PatchGuide(
            "Says how many values a loop has.",
            tip: "Use it to size a container to its rows, or to stop a Counter at the last page.",
            inputs: ["loop": "The loop to count."],
            outputs: ["count": "How many values it has."],
            tags: ["length", "count", "size", "how many", "number of items", "array length"]
        ),
        "loopOptionSwitch": PatchGuide(
            "Remembers which copy of a repeated view was picked last. Cable in a pulse that is itself repeated, such as the Tap of an Interaction on a repeated row: whichever copy pulses becomes the option.",
            tip: "Then compare each row's index with Option using = to highlight the selected row.",
            inputs: [
                "set": "A repeated pulse; the index of the copy that pulses becomes the option.",
                "start": "The option before anything is picked.",
            ],
            outputs: [
                "option": "The index picked last.",
                "changed": "Pulses when a different index is picked.",
                "picked": "Pulses whenever any copy pulses, also the one already picked: what closes a menu.",
            ],
            tags: ["selection", "selected", "list selection", "radio", "which", "tapped row", "current", "index", "tab", "picker"]
        ),
    ]

    static let data: [String: PatchGuide] = [
        "joinText": PatchGuide(
            "Puts two pieces of text together, A then B. Numbers cabled in become text. Chain several to build longer sentences.",
            tip: "Join \"Hello, \" with a Text Input's Text to greet the person by name.",
            inputs: ["a": "The text that comes first.", "b": "The text that comes after it."],
            outputs: ["text": "A followed by B."],
            tags: ["concatenate", "concat", "append", "combine", "string", "interpolate", "format", "template", "+"]
        ),
        "textLength": PatchGuide(
            "Counts the characters in a text and says whether it is empty.",
            tip: "Is Empty through Not into a button's Opacity shows a Send button only once something is typed.",
            inputs: ["text": "The text to measure."],
            outputs: [
                "length": "How many characters it has.",
                "empty": "On when there are none.",
            ],
            tags: ["length", "count", "characters", "empty", "isempty", "string length", "validation", "character limit"]
        ),
        "textContains": PatchGuide(
            "Whether a text contains another, ignoring capitals. An empty search matches everything, which is what a search field should do before anything is typed.",
            tip: "Inside a loop, cable each row's title in and the search field's text as Search, then into each row's Visible.",
            inputs: [
                "text": "The text to look in.",
                "search": "The text to look for.",
            ],
            outputs: ["result": "On when Search is found in Text, or is empty."],
            tags: ["search", "contains", "includes", "match", "find", "substring", "filter", "string"]
        ),
        "networkRequest": PatchGuide(
            "Fetches a URL from the internet and outputs what came back, as JSON when it is JSON, as a picture when it is one, and otherwise as text. It sends when the prototype starts and whenever Send pulses. Loading, Done and Failed let the interface show a spinner, the result or an error. Pictures made by the assistant and the gallery never send requests.",
            tip: "Response into a JSON Value with a path such as results.0.name; Loading into a spinner's Opacity; Image straight into an Image view.",
            inputs: [
                "url": "The address to fetch.",
                "method": "GET to read; POST, PUT and PATCH to send data; DELETE to remove.",
                "body": "For POST, PUT, PATCH and DELETE, the text to send, usually JSON.",
                "send": "A pulse sends the request again.",
                "auto": "Whether to send it as soon as the prototype starts.",
                "headers": "Headers to send, one per line as Name: value, or a JSON object.",
                "query": "Parameters added to the address, one per line as name=value, or a JSON object. They are encoded for you.",
            ],
            outputs: [
                "loading": "On while waiting for the answer.",
                "response": "The answer as JSON.",
                "text": "The answer as plain text.",
                "done": "Pulses when an answer arrives.",
                "failed": "Pulses when the request fails.",
                "hasError": "On after a failed request, until the next one succeeds.",
                "error": "What went wrong, in words.",
                "status": "The HTTP status code, such as 200 or 404.",
                "image": "When the answer is a picture, its name, for an Image view's Image.",
            ],
            tags: ["fetch", "http", "https", "api", "rest", "get", "post", "put", "patch", "delete", "headers", "query", "parameters", "authorization", "image", "picture", "url", "download", "ajax", "request", "server", "endpoint", "load data", "urlsession"]
        ),
        "aiText": PatchGuide(
            "Sends Prompt to Claude, an OpenAI model or Apple's on-device model when Send pulses, and streams the answer into Text as it is written. Instructions set how it behaves, like a system prompt. With Remember on it keeps the conversation, so the next prompt follows on; Conversation lists every turn for a chat built with a loop. Claude and OpenAI need your API key in Settings; apple-on-device needs none, costs nothing and never leaves the Mac or the phone, and runs where Apple Intelligence is on. Pictures made by the assistant and the gallery never send.",
            tip: "A Text Field's Submitted into Send and its text into Prompt; Conversation into Loop Over Array to draw the chat bubbles.",
            inputs: [
                "prompt": "What to ask.",
                "instructions": "How the model should behave: its role, tone and the shape of its answers.",
                "model": "Which model answers. Names that start with claude go to Claude, apple-on-device to Apple's model on this device; the others to OpenAI.",
                "effort": "For Claude: how hard it thinks. Low answers fastest.",
                "image": "A picture to show the model with the prompt, such as a Camera photo or a generated image.",
                "send": "A pulse sends the prompt.",
                "remember": "Whether each prompt follows on from the conversation so far.",
                "reset": "A pulse forgets the conversation and clears Text.",
                "stop": "A pulse stops the answer where it is: what was written so far stays, as the answer.",
            ],
            outputs: [
                "text": "The answer, growing as it streams in.",
                "loading": "On from sending until the whole answer has come.",
                "done": "Pulses when the answer is complete.",
                "failed": "Pulses when the request fails.",
                "error": "What went wrong, in words.",
                "conversation": "Every turn so far, each with role (user or assistant) and text, the answer being written included.",
            ],
            tags: ["ai", "llm", "claude", "anthropic", "openai", "gpt", "chat", "chatbot", "assistant", "generate", "prompt", "completion", "language model", "stream"]
        ),
        "aiImage": PatchGuide(
            "Makes a picture from Prompt with an OpenAI image model when Send pulses. Give it a Reference picture and it changes that picture as the prompt says instead. Image names the result, ready for an Image view. It needs your OpenAI API key in Settings.",
            tip: "Image into an Image view's Image; Loading into a spinner's Opacity.",
            inputs: [
                "prompt": "What to draw, or what to change about Reference.",
                "model": "Flare is fast, for trying ideas; Sunburst takes longer over detail.",
                "size": "Square, Portrait or Landscape; Auto lets the model choose.",
                "reference": "A picture to start from, such as a Camera photo.",
                "send": "A pulse makes the picture.",
            ],
            outputs: [
                "image": "The picture that was made, for an Image view.",
                "loading": "On while the picture is being made.",
                "done": "Pulses when it arrives.",
                "failed": "Pulses when the request fails.",
                "error": "What went wrong, in words.",
            ],
            tags: ["ai", "image generation", "openai", "gpt image", "dall-e", "picture", "draw", "art", "generate", "edit photo", "text to image"]
        ),
        "aiSpeech": PatchGuide(
            "Reads Text out loud in a natural voice with OpenAI when Speak pulses. Instructions say how to say it, such as cheerfully or in a whisper. Speaking is on while it talks and Done pulses when it finishes. OpenAI needs your API key in Settings; the apple-on-device model speaks with the device's own voices, with no key and nothing sent (Voice can name one, such as Samantha; Instructions are not used).",
            tip: "Generate Text's Done into Speak and its Text into Text, for an assistant that answers aloud.",
            inputs: [
                "text": "The words to say.",
                "voice": "Whose voice: marin and cedar sound best.",
                "instructions": "How to say it: tone, pace, accent, emotion.",
                "model": "The speech model: OpenAI's, or apple-on-device for the device's own voices.",
                "speak": "A pulse says Text.",
                "stop": "A pulse stops talking.",
            ],
            outputs: [
                "speaking": "On while the voice plays.",
                "loading": "On while the speech is being made.",
                "done": "Pulses when it has finished speaking.",
                "failed": "Pulses when the request fails.",
                "error": "What went wrong, in words.",
            ],
            tags: ["ai", "text to speech", "tts", "voice", "speak", "say", "read aloud", "openai", "audio", "narration"]
        ),
        "aiTranscribe": PatchGuide(
            "Records from the microphone while Record is on, then turns what it heard into words in Text: with OpenAI, which needs your API key in Settings, or with apple-on-device, on this device, with no key and nothing sent. macOS asks for the microphone the first time.",
            tip: "An Interaction's Down into Record makes a hold-to-talk button; Done into Generate Text's Send with Text as its Prompt.",
            inputs: [
                "record": "Listens while on; turning it off sends the recording.",
                "model": "The transcription model: OpenAI's, or apple-on-device to transcribe on this device.",
            ],
            outputs: [
                "text": "What was said.",
                "recording": "On while the microphone is listening.",
                "loading": "On while the words are being worked out.",
                "done": "Pulses when Text is ready.",
                "failed": "Pulses when it fails.",
                "error": "What went wrong, in words.",
            ],
            tags: ["ai", "speech to text", "transcribe", "dictation", "voice input", "microphone", "listen", "whisper", "openai", "audio", "recognize speech"]
        ),
        "aiObject": PatchGuide(
            "Asks Apple's on-device model for an object with exactly the fields you list, when Send pulses: the model is held to them (guided generation), so the answer is always data you can use, not prose to pick apart. Object fills in field by field as it streams. Fields has one field a line, `name: kind - what it is`: kinds are text, number, whole, yes/no, list (or list of numbers, 3 text) and choices written with bars, such as happy | sad | calm. It needs no key, costs nothing and never leaves the device; it runs where Apple Intelligence is on.",
            tip: "Fields `title: text`, `ingredients: list`, `minutes: whole`; JSON Value with path ingredients into a Loop Over Array to fill a list.",
            inputs: [
                "prompt": "What to make, such as a recipe for what is in the photo.",
                "instructions": "How the model should behave.",
                "fields": "One field a line: name, then a colon and its kind, then a dash and what it is.",
                "model": "Apple's model on this device.",
                "image": "A picture to show the model with the prompt.",
                "send": "A pulse asks.",
            ],
            outputs: [
                "object": "The object, as JSON, its fields filled in as they are written.",
                "loading": "On from sending until the whole object has come.",
                "done": "Pulses when it is complete.",
                "failed": "Pulses when it fails.",
                "error": "What went wrong, in words.",
            ],
            tags: ["ai", "apple intelligence", "foundation models", "on-device", "local", "structured output", "guided generation", "generable", "json", "schema", "extract", "classify", "generate", "llm", "private", "offline"]
        ),
        "aiTranslate": PatchGuide(
            "Translates Text into the language To names when Send pulses, on the device with Apple's translation models: no key, no cost, nothing sent. From says what language Text is in; Detect works it out. A language whose model is not on the device fails with a note saying to add it in System Settings > General > Language & Region > Translation Languages.",
            tip: "A Text Field's text into Text and its Submitted into Send; Text into a Text view.",
            inputs: [
                "text": "The words to translate.",
                "to": "The language to translate into. A language code such as pt-PT works too.",
                "from": "The language Text is in, or Detect.",
                "send": "A pulse translates.",
            ],
            outputs: [
                "text": "The translation.",
                "loading": "On while it translates.",
                "done": "Pulses when it is ready.",
                "failed": "Pulses when it fails.",
                "error": "What went wrong, in words.",
            ],
            tags: ["ai", "translate", "translation", "language", "localize", "apple", "on-device", "offline", "private", "spanish", "french", "japanese", "multilingual"]
        ),
        "jsonValue": PatchGuide(
            "Reaches into JSON and picks out one value by its path: names of fields and numbers of array items, joined by dots, such as items.0.name. Choose the type of the value it gives: text, a number, an array to loop over, or more JSON. Fed a loop of objects, it picks from each one.",
            tip: "Path user.avatar_url, type text, into an Image view's Image.",
            inputs: [
                "json": "The data to look in.",
                "path": "Where the value is, such as items.0.name. Empty gives the whole thing.",
            ],
            outputs: [
                "value": "The value at the path.",
                "found": "On when something is at the path.",
            ],
            tags: ["json", "path", "key", "field", "property", "parse", "get", "extract", "jq", "keypath", "object", "lookup"]
        ),
        "parseJSON": PatchGuide(
            "Turns JSON typed as text into data, so a design can be tried with real-looking content before there is a server. Valid says whether the text was JSON.",
            tip: "Paste a sample API response in and use it where a Network Request would go.",
            inputs: ["text": "JSON as text."],
            outputs: [
                "json": "The data, or an empty object when the text is not JSON.",
                "valid": "On when the text was JSON.",
            ],
            tags: ["json", "parse", "decode", "mock data", "sample data", "fixture", "stub", "placeholder content", "fake data"]
        ),
    ]

    static let device: [String: PatchGuide] = [
        "camera": PatchGuide(
            "Takes a photo with the camera a Camera view is showing. The photo comes out as a picture any Image view can show.",
            tip: "A shutter button's Tap into Capture, and Photo into an Image view, for a camera screen.",
            inputs: ["capture": "A pulse takes a photo."],
            outputs: [
                "photo": "The last photo taken.",
                "captured": "Pulses when a photo has been taken.",
                "available": "On when a camera can be used.",
            ],
            tags: ["photo", "picture", "shutter", "capture", "snapshot", "selfie", "take photo", "avcapture"]
        ),
        "hapticFeedback": PatchGuide(
            "Makes the device tap back, so an action can be felt. On a Mac it uses the trackpad's haptics where it can; elsewhere it does nothing.",
            tip: "Cable a toggle's Tap in with style Tap, or a slider reaching its end with Level Change.",
            inputs: [
                "trigger": "A pulse plays the haptic.",
                "style": "Which kind: Tap, Alignment or Level Change.",
            ],
            tags: ["haptics", "vibrate", "vibration", "taptic", "feedback", "buzz", "uifeedbackgenerator", "sensory feedback"]
        ),
        "playSound": PatchGuide(
            "Plays one of the system's short sounds on a pulse.",
            tip: "Play Pop when a message is sent.",
            inputs: [
                "trigger": "A pulse plays the sound.",
                "sound": "Which sound.",
                "volume": "How loud, from 0 to 1.",
            ],
            tags: ["audio", "sound effect", "sfx", "beep", "chime", "play", "noise", "alert", "click"]
        ),
        "microphone": PatchGuide(
            "Listens to the Mac's microphone and reports how loud it is. macOS asks for access the first time.",
            tip: "Level through a Transition into a circle's Scale makes a voice meter.",
            outputs: [
                "level": "How loud it is, from 0 for silence to 1.",
                "available": "On when the microphone can be used.",
            ],
            tags: ["audio", "mic", "voice", "volume", "loudness", "level", "meter", "record", "sound input"]
        ),
        "location": PatchGuide(
            "Reports where the Mac is, standing in for the phone's position. macOS asks for access the first time.",
            tip: "Join the latitude and longitude into a URL for a weather request.",
            outputs: [
                "latitude": "Degrees north of the equator; south is negative.",
                "longitude": "Degrees east of Greenwich; west is negative.",
                "available": "On when a location is known.",
            ],
            tags: ["gps", "geolocation", "coordinates", "where", "map", "position", "core location", "lat", "long"]
        ),
        "dateTime": PatchGuide(
            "The time and date now, as numbers to animate with and as text to show. It updates once a second.",
            tip: "Time into a Text in the status bar, or Seconds times 6 into a clock hand's Rotation.",
            outputs: [
                "hours": "The hour, from 0 to 23.",
                "minutes": "The minute, from 0 to 59.",
                "seconds": "The second, from 0 to 59.",
                "time": "The time as text, such as 9:41.",
                "date": "The date as text.",
            ],
            tags: ["clock", "date", "time", "now", "today", "hour", "minute", "calendar", "timestamp", "status bar"]
        ),
        "deviceInfo": PatchGuide(
            "Facts about the device the prototype is playing on: its name, whether it is in dark mode, and how many pixels make a point.",
            tip: "Dark Mode into an If choosing between two colors gives a design both appearances.",
            outputs: [
                "name": "The device's name.",
                "dark": "On when the system is in dark mode.",
                "scale": "Pixels per point on its screen: 2 or 3 on most.",
            ],
            tags: ["dark mode", "appearance", "theme", "color scheme", "light mode", "environment", "screen scale", "device", "system"]
        ),
    ]

    static let utility: [String: PatchGuide] = [
        "value": PatchGuide(
            "Holds one value and hands it to everything cabled to it, so a number or color used in many places is changed in one. Right-click to choose its type. It is how a design token lives in a graph.",
            tip: "One Value holding the brand color, cabled into every button's Fill.",
            inputs: ["value": "The value to hold."],
            outputs: ["value": "The same value."],
            tags: ["constant", "variable", "token", "design token", "literal", "number", "color", "let", "parameter", "splitter", "pass through"]
        ),
        "broadcast": PatchGuide(
            "Sends a value under a name to every Receive patch with the same name, anywhere in the document, without a cable. Use it to reach across levels or tidy up long cables.",
            tip: "Broadcast \"Selected Tab\" from the tab bar and receive it in each screen.",
            inputs: [
                "name": "The name Receive patches listen for.",
                "value": "The value to send.",
            ],
            tags: ["send", "global", "variable", "wireless", "publish", "emit", "environment", "shared state", "context"]
        ),
        "receive": PatchGuide(
            "Gives the value sent by the Broadcast patch with the same name and type.",
            inputs: ["name": "The name of the Broadcast to listen to."],
            outputs: ["value": "The value it sends."],
            tags: ["listen", "global", "variable", "wireless", "subscribe", "get", "environment", "shared state", "context"]
        ),
        "makeColor": PatchGuide(
            "Builds a color from red, green, blue and alpha, each from 0 to 1, so any of them can be animated or computed.",
            tip: "Cable a Drag Value into Alpha to fade a color in with a slider.",
            inputs: [
                "red": "How much red, from 0 to 1.",
                "green": "How much green, from 0 to 1.",
                "blue": "How much blue, from 0 to 1.",
                "alpha": "How opaque, from 0 (clear) to 1.",
            ],
            outputs: ["color": "The color."],
            tags: ["rgb", "rgba", "color", "colour", "alpha", "opacity", "hex", "tint", "hue"]
        ),
        PatchKind.javascript: PatchGuide(
            "A patch you write in JavaScript, for anything the other patches cannot do. The script declares its inputs and outputs, which become ports, and a function that turns one into the other. It can keep state between frames and ask to run every frame. A script that runs too long is stopped until it is edited.",
            tip: "Ask the assistant to write one: \"a patch that formats a number of seconds as 1:05\".",
            tags: ["script", "code", "js", "javascript", "function", "expression", "formula", "custom", "program", "logic"]
        ),
        PatchKind.componentInput: PatchGuide(
            "Inside a component, publishes an input that every use of the component shows. Its name, type and default are what people see; Choices turns a text input into a menu. Cable its Value to whatever inside should follow it.",
            inputs: [
                "value": "The value a new use of the component starts with.",
                "loops": "When a loop arrives: repeat the whole component once per value, or pass the loop inside.",
                "options": "For text, a comma-separated list of choices to show as a menu.",
            ],
            outputs: ["value": "What the use of the component was given."],
            tags: ["component", "prop", "props", "parameter", "argument", "input", "publish", "api", "interface"]
        ),
        PatchKind.componentOutput: PatchGuide(
            "Inside a component, publishes an output that every use of the component shows, such as a button's Tap or a toggle's On.",
            inputs: ["value": "What the component reports."],
            outputs: ["value": "The same value, as the component's output."],
            tags: ["component", "callback", "event", "output", "publish", "emit", "binding", "interface"]
        ),
    ]
}
