import Foundation
import PaperEngine
import PaperModel

/// The MCP server an outside coding agent (Claude Code, Codex) talks to: JSON-RPC messages
/// in, JSON-RPC messages out. No sockets here, so tests can drive it directly; `AgentListener`
/// carries the messages over HTTP.
///
/// Only what a tool server needs is answered: `initialize`, `ping`, `tools/list`, `tools/call`.
public final class AgentServer {
    public static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static let editName = "Agent Edit"

    public let documents: OpenDocuments

    public init(documents: OpenDocuments = .shared) {
        self.documents = documents
    }

    // MARK: Messages

    /// Answers one message, or a batch of them. `nil` when nothing is owed (notifications).
    public func handle(_ body: Data) -> Data? {
        guard let parsed = try? JSONSerialization.jsonObject(with: body) else {
            return Self.encode(Self.failure(id: NSNull(), code: -32700, message: "Parse error"))
        }
        if let batch = parsed as? [Any] {
            let answers = batch.compactMap(answer)
            return answers.isEmpty ? nil : Self.encode(answers)
        }
        return answer(parsed).map(Self.encode)
    }

    private func answer(_ any: Any) -> [String: Any]? {
        guard let message = any as? [String: Any], let method = message["method"] as? String else {
            // A response to something we never asked, or not a request at all.
            if let message = any as? [String: Any], message["result"] != nil || message["error"] != nil { return nil }
            return Self.failure(id: NSNull(), code: -32600, message: "Invalid request")
        }
        guard let id = message["id"], !(id is NSNull) else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            return Self.success(id: id, [
                "protocolVersion": Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0],
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": [
                    "name": "tango",
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1",
                ],
                "instructions": Self.instructions,
            ])
        case "ping":
            return Self.success(id: id, [:])
        case "tools/list":
            return Self.success(id: id, ["tools": Self.tools])
        case "tools/call":
            guard let name = params["name"] as? String, Self.tools.contains(where: { $0["name"] as? String == name }) else {
                return Self.failure(id: id, code: -32602, message: "Unknown tool \(params["name"] ?? "")")
            }
            return Self.success(id: id, call(name, params["arguments"] as? [String: Any] ?? [:]))
        default:
            return Self.failure(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private static func success(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func failure(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static func encode(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    // MARK: Tools

    private func call(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        func reply(_ text: String, images: [Data] = [], isError: Bool = false) -> [String: Any] {
            var content: [[String: Any]] = [["type": "text", "text": text]]
            for image in images {
                content.append(["type": "image", "data": image.base64EncodedString(), "mimeType": "image/png"])
            }
            return ["content": content, "isError": isError]
        }

        switch name {
        case "list_documents":
            let list = documents.all.map { entry, store -> [String: Any] in
                var item: [String: Any] = ["id": entry.id, "name": entry.name, "front": documents.isFront(entry)]
                if let scope = store.scope, let component = store.fullDocument.component(scope) {
                    item["editing_component"] = component.name
                }
                return item
            }
            return reply(AssistantToolbox.json(["documents": list]))
        case "get_reference":
            // Components the open document defines are part of what can be inserted.
            let store = try? documents.find(arguments["document"] as? String).store
            // The advice for outside agents comes first: the reference is long, and a client
            // that saves a long answer to a file may have its agent read only the start.
            return reply(Self.pacingGuide + "\n\n" + AssistantPrompt.reference(
                registry: store?.registry ?? .standard, components: store?.fullDocument.components ?? []
            ) + "\n\n" + Self.sketchGuide)
        default:
            do {
                let store = try documents.find(arguments["document"] as? String).store
                let result = AssistantToolbox(store: store, editName: Self.editName).call(name, input: arguments)
                return reply(result.text, images: result.images, isError: result.isError)
            } catch let problem as OpenDocuments.NotFound {
                return reply(problem.message, isError: true)
            } catch {
                return reply("\(error)", isError: true)
            }
        }
    }

    static let instructions = """
    tango is a macOS app for designing interactive mobile prototypes: views on a \
    screen, each one a patch in a graph, and more patches that give them behavior. These tools read and change the \
    document open in the app; the person sees every edit live and can undo it. Call \
    `get_reference` once before your first edit: it explains how a prototype is made and lists \
    every edit operation, view, property, patch and component; read all of it. Then `get_document`, then \
    `edit_document` (a big build a screen or section at a time, so the person sees it grow), \
    and check interactions with `view_prototype` or `interact_prototype`. \
    The person sees the graph one view at a time, so build with containers that hold their own \
    views and patches, and pipe values in and out of a container through ports it publishes \
    (`publish_port`). The app is also a scratch pad for a screen that lives in code: build the \
    screen here from the code and call `mark_baseline`; when the person has played with it, \
    `get_changes` says what they changed so you can write it into the code. `get_reference` \
    explains both under "Sketching from code".
    """

    /// How an outside agent should pace a big build. The built-in assistant's batches are
    /// built while its model writes them, so one batch is best there; an outside agent's call
    /// reaches the app only when it is whole, so the person sees nothing until then.
    static let pacingGuide = """
    # Building in steps

    The person watches the prototype in the app while you work, but an `edit_document` call \
    reaches the app only once you have written all of it, so a big batch means a minute in which \
    nothing happens for them. For anything bigger than a few views, build in steps the person \
    can see: one `edit_document` call per screen or per section (a header, a list, a tab bar), \
    each with its views, patches and cables together, in the order a designer would build it. \
    This takes precedence over the advice below to make as few calls as you can. Small changes \
    stay one call. A `ref` you gave in an earlier call still names what it made, so the next call \
    can build on it without calling `get_document` again.

    This reference is long. Read all of it before your first edit: every operation, view, \
    property, patch and component is in it, and the last section is about sketching a screen \
    that lives in code.
    """

    /// What an outside agent needs to bring a screen in from code and carry changes back.
    /// It follows the reference in `get_reference`; the built-in assistant has no code to read.
    static let sketchGuide = """
    # Sketching from code

    tango can be a scratch pad for a screen that already exists in code (SwiftUI, React Native, \
    anything). The code stays the truth. You bring the screen in, the person plays with it, and you \
    carry what they changed back into the code. The app never reads the code: you are the bridge.

    ## Bringing a screen in

    - Read the code for the screen and everything it uses: subviews, theme and token files, the model its data comes from.
    - Call `get_document`. If the document already has views in it, ask the person to open a new one \
    (File > New) rather than building over their work.
    - Give the screen the device's size with `set_properties` on "screen", then build with `edit_document`.
    - Keep the code's structure. One container per view in the code, with the code's name. A subview \
    used several times with different data is built once per use, with the same structure and names each time. \
    A list drawn from an array is a `loopOverArray` into one row.
    - Write `source` on every view and patch: the file, the line, and what it is, such as \
    `ProfileScreen.swift:57 statsCard VStack`. This is how you will find your way back.
    - Keep tokens as tokens. A spacing, radius or color that the code reads from a theme becomes one \
    `value` patch named after the token (`Theme.spacing.m`), cabled to every input that uses it, with \
    `source` naming where the token is defined. The person then changes it once, as in the code.
    - Name state after the code. A `@State var expanded` or `useState` boolean is a `switch` named \
    "expanded"; an enum of tabs or modes within one screen is an `optionSwitch`. Give each the starting value the code has.
    - Keep the code's screens as screens. Each destination of a `NavigationStack`, `.sheet`, \
    `.fullScreenCover` or a stack/modal navigator is a screen (`add_view` kind `screen`), built once, \
    and each way between them is an `add_flow`: a `NavigationLink` or `navigation.navigate` is Push, \
    a sheet or modal is Modal, `dismiss()` or `goBack()` is `back: true`, tabs are Instant.
    - Reproduce motion with the code's numbers. `.spring(response:dampingFraction:)` is a `spring` patch \
    with the same `response` and `damping`. Reanimated's `withSpring({stiffness, damping, mass: 1})` is \
    response 2π/√stiffness and damping ratio damping/(2·√stiffness). A timed animation is an `easing` patch.
    - SwiftUI to tango: `VStack`/`HStack` are a `stack` with `axis`, `spacing` and `alignment`; \
    `ZStack` is a `view` with children placed by x and y; `Spacer()` is a clear view whose mode along the \
    stack is Grow; `.frame(maxWidth: .infinity)` is `widthMode` Grow; a view with no frame is Auto; \
    `.padding(.top, n)` is `paddingTop` on the stack around it; `if flag { view }` is that view's \
    `visible` cabled from the flag; `.background(color, in: RoundedRectangle(cornerRadius:))` is `fill` \
    and `cornerRadius`; `.shadow(color:radius:y:)` is `shadowColor`, `shadowRadius`, `shadowOffset`; \
    `Image(systemName:)` is a `symbol` whose height is about 1.25 times the font size; `.secondary` on \
    a light screen is "#3C3C4399" and `.tertiary` "#3C3C434D"; `Button`, `Toggle`, `Slider` and the \
    other system controls are the prebuilt components, never rebuilt from views: `Button` (its \
    `.buttonStyle` is Style: `.borderedProminent` Filled, `.bordered` Gray or Tinted, `.plain` Plain; \
    it has Corner Radius and Weight), `Toggle`, `Slider` (`in:` is Minimum and Maximum), `Stepper` \
    (`in:` and `step:`), `Picker` with `.segmented` is Segmented Control and with `.menu` Menu Button, \
    `TextField` is Text Field, `.searchable` is Search Field, `ProgressView(value:)` is Progress Bar \
    and `ProgressView()` Activity Indicator, `.navigationTitle` is Navigation Bar and with \
    `.navigationBarTitleDisplayMode(.large)` Large Title Bar (its Scroll Offset from the scroll \
    view's Offset; a `ToolbarItem` at the trailing end is its Action), `TabView` is Tab Bar \
    (Floating on for iOS 26), a bottom `.toolbar` is Toolbar; `List` or `Form` is the Form template \
    and each `Section` a List Section template with one List Row per row (`LabeledContent` is Title \
    and Detail, a `Label` is Title and Symbol, a `Toggle` in a row is Accessory Switch, a \
    `NavigationLink` Accessory Chevron, `.swipeActions` is Swipe Actions Row); `.alert` is Alert, \
    `.confirmationDialog` Action Sheet, `.contextMenu` Context Menu, and a `.sheet` with \
    `presentationDetents` that stays on its screen is the Sheet template (Sheet Height is the \
    detent), where a sheet that is a destination of its own is a screen shown with Modal; \
    `VideoPlayer` or an `AVPlayerLayer` is a `video` (its URL in `video`, `player.rate` in `playbackRate`, \
    a seek is a change to `time`). Gestures are patches on the view: `.onTapGesture` or `TapGesture` \
    is `tap` (`count` is `taps`), `LongPressGesture` is `longPress` (`minimumDuration` is `duration`), \
    `DragGesture` is `pan` (`value.translation` is `translation`; its `minimumDistance` of 10 is the \
    slop a pan already has), `MagnifyGesture` is `pinch` (`magnification` is `scale`), `RotateGesture` \
    is `rotation`, and `.simultaneously(with:)` is what `pan`, `pinch` and `rotation` on one view do \
    without being asked. A `@GestureState` that resets is the gesture's value through a `spring` with \
    Hold on while the gesture is under way. In UIKit each `UI…GestureRecognizer` is the patch of the \
    same name.
    - React Native to tango: a `View` is a `stack` (`flexDirection` is `axis`, `gap` is \
    `spacing`, `alignItems` is `alignment`, `justifyContent` is `distribution`, `flex: 1` is Grow); \
    `position: "absolute"` is `absolute`; `Text` is `text`; `borderRadius` is `cornerRadius`; \
    `Pressable` is an `interaction` patch on the view; `expo-video`'s `VideoView` is a `video`; \
    `Switch`, `Alert.alert`, `ActionSheetIOS`, `ActivityIndicator`, `TextInput` and a navigator's \
    header and tab bar are the prebuilt components of those names, as in the SwiftUI list above. \
    React Native Gesture Handler's `Gesture.Tap()` (`numberOfTaps` is `taps`), `LongPress()` \
    (`minDuration` in milliseconds is `duration` in seconds), `Pan()` (`translationX`/`Y` is \
    `translation`, `activeOffsetX` alone is `direction` Horizontal), `Pinch()` and `Rotation()` \
    (radians there, degrees here) are the patches of those names; `Gesture.Simultaneous` of the last \
    three is what they do on one view.
    - Check your work against the real thing. Get a picture of the real screen (a simulator screenshot, \
    a preview, a test render) and call `compare_prototype` with its path: it returns the picture and \
    the prototype side by side. Fix what differs and compare again, for each state worth checking \
    (`tap` and `seconds` work as in `view_prototype`).
    - When it matches, call `mark_baseline` with `source` naming the screen. Tell the person briefly \
    what you could only approximate.

    ## Carrying changes back

    - Call `get_changes` with `pictures` true. It lists what differs from the starting point: views \
    changed (each property from and to), added, removed, moved and reordered; patches and cables; and \
    under `motion` every animation whose feel changed, with what it drives, what starts it, and its \
    numbers as SwiftUI and Reanimated write them.
    - Find each change in the code by its `source` and make it there, in the code's own way. If the \
    value comes from a token or a shared style, either change the token (say how many places that \
    affects) or override it locally, whichever the change calls for; when unsure, ask.
    - A new view is new code beside what its `parent` and `after` name. A view that is gone is removed \
    from the code. New patches describe behavior to write: read them and their cables as a specification.
    - Tell the person what you changed and anything you could not carry over. Then call `mark_baseline` \
    again, so the next `get_changes` starts from here.
    """

    private static let documentArgument: [String: Any] = [
        "type": "string",
        "description": "Which open document: an id or name from list_documents. Leave out for the front one.",
    ]

    private static let pointSchema: [String: Any] = [
        "type": "object",
        "properties": ["x": ["type": "number"], "y": ["type": "number"]],
        "required": ["x", "y"],
    ]

    private static func tool(
        _ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = [],
        readOnly: Bool = false, forDocument: Bool = true
    ) -> [String: Any] {
        var all = properties
        if forDocument { all["document"] = documentArgument }
        return [
            "name": name,
            "description": description,
            "inputSchema": ["type": "object", "properties": all, "required": required],
            "annotations": ["readOnlyHint": readOnly, "openWorldHint": false],
        ]
    }

    static let tools: [[String: Any]] = [
        tool(
            "get_reference",
            "How a tango prototype is made, how views nest and publish ports, how to write shader views in Metal, how to read get_document, every edit_document operation, and every view, property, patch and component. Read this once before your first edit.",
            readOnly: true
        ),
        tool(
            "list_documents",
            "The documents open in tango, and which one is in front.",
            readOnly: true, forDocument: false
        ),
        tool(
            "get_document",
            "Read a prototype as JSON with short ids: its tree of views with the ports each publishes, the patches and which view each is attached to or kept inside, the cables, what is selected and which view the person has stepped into. A shader view comes with its Metal code, its inputs and, when the code does not compile, the error.",
            readOnly: true
        ),
        tool(
            "edit_document",
            "Change the prototype with a batch of operations, applied in order as one undo step. The operations are listed in get_reference: adding and changing views, patches and cables, writing the Metal code of shader views, publishing ports from inside a view, and showing the person a level of the graph. Returns the ids of what was created and any errors.",
            ["operations": [
                "type": "array", "items": ["type": "object"],
                "description": "Operations, each an object with an `op`.",
            ]],
            required: ["operations"]
        ),
        tool(
            "view_prototype",
            "See the prototype as the Viewer shows it, shader views included. It is started fresh, optionally tapped once, then drawn after some seconds. Returns an image where one pixel is one point.",
            [
                "tap": pointSchema.merging(["description": "Where to tap, in screen points."]) { $1 },
                "seconds": ["type": "number", "description": "How long to let it run before drawing. Use about 1 after a tap."],
                "screen": ["type": "string", "description": "Start on this screen (its name or id) instead of the first, as if the person had arrived there."],
            ],
            readOnly: true
        ),
        tool(
            "interact_prototype",
            "Use the prototype with several touches in a row and look at it along the way. It is started fresh, the steps run in order, and an image is returned for each `look` and one at the end.",
            ["steps": [
                "type": "array",
                "description": "Each step is {do:\"tap\", at:{x,y}}, {do:\"drag\", from:{x,y}, to:{x,y}, seconds?} (a fast drag is a swipe), {do:\"down\", at:{x,y}} (a finger that stays down, so you can look while it is held), {do:\"move\", to:{x,y}, seconds?} and {do:\"up\"} for that finger (add finger:2 to any of the three for a second finger beside the first), {do:\"wait\", seconds}, {do:\"type\", text} (tap a text field first), {do:\"press\", key:\"return\"|\"delete\"}, {do:\"pinch\", at:{x,y}, scale, rotation?, pan?:{x,y}, seconds?} (two fingers 88 points apart around `at`, spread to `scale` times that, turned `rotation` degrees clockwise and carried `pan` points, then lifted; both must land on the view that listens), {do:\"hover\", at:{x,y}} or {do:\"look\"}. Points are screen points. A gesture patch counts from where its gesture began, about 10 points after the fingers set off, so it reports a little less than the fingers did.",
                "items": [
                    "type": "object",
                    "properties": [
                        "do": ["type": "string", "enum": ["tap", "drag", "down", "move", "up", "wait", "type", "press", "pinch", "hover", "look"]],
                        "at": pointSchema, "from": pointSchema, "to": pointSchema,
                        "seconds": ["type": "number"], "text": ["type": "string"],
                        "key": ["type": "string", "enum": ["return", "delete"]],
                        "scale": ["type": "number"], "rotation": ["type": "number"],
                        "finger": ["type": "integer", "enum": [1, 2]], "pan": pointSchema,
                    ],
                    "required": ["do"],
                ],
            ], "screen": ["type": "string", "description": "Start on this screen (its name or id) instead of the first, as if the person had arrived there."]],
            required: ["steps"], readOnly: true
        ),
        tool("undo", "Undo the last change to the document, yours or the person's."),
        tool("redo", "Redo the change that was just undone."),
        tool(
            "mark_baseline",
            "Make the document as it is now the starting point of a sketch of existing code. Call it when the screen you built matches the code, and again after you have carried the person's changes back.",
            ["source": ["type": "string", "description": "What was sketched: the file and view, such as \"ProfileScreen.swift, ProfileScreen\"."]]
        ),
        tool(
            "get_changes",
            "What the person changed since the starting point, for writing into code: views changed (each property from and to), added, removed and moved, each with the `source` noted on it; patches and cables; and every animation whose feel changed, with its numbers in SwiftUI's and Reanimated's terms.",
            ["pictures": ["type": "boolean", "description": "Also return two images: the starting point, and the sketch now."]],
            readOnly: true
        ),
        tool(
            "compare_prototype",
            "See the prototype beside a picture of the real screen (a simulator screenshot, a preview render), to check a sketch against the code it came from. Returns one image, the picture on the left and the prototype on the right, and how much of it differs.",
            [
                "path": ["type": "string", "description": "A PNG or JPEG file on this Mac."],
                "tap": pointSchema.merging(["description": "Where to tap the prototype first, in screen points."]) { $1 },
                "seconds": ["type": "number", "description": "How long to let the prototype run before drawing."],
            ],
            required: ["path"], readOnly: true
        ),
    ]
}
