# tango: Product Specification

**Product:** tango  
**Status:** Product concept and target specification  
**Purpose:** Define a visual environment for designing, testing, and sharing interactive interfaces, including the features and experience that make it distinctive.

## 1. Explain it to someone

### One sentence

tango is a visual environment for building interactive interfaces whose appearance, movement, and behavior you can design and try immediately.

### One minute

You lay out an interface, then connect visual building blocks called patches to give it behavior. A touch can change a state; that state can drive a spring animation; that animation can move, resize, or fade multiple elements together. The same system can respond to scrolling, typed text, live data, a camera, or device motion.

The result is an interface someone can use and react to. A designer can explore the details that are difficult to communicate in a static mockup: how far something follows a finger, when it snaps into place, how a transition reverses, or how a screen responds to actual content. tango brings those decisions into the design process.

### A concrete example

Imagine designing a photo card that opens into a detailed view. You can draw the card, wire its tap to an open/closed state, animate that state, and use the animated value to coordinate the photo’s size, its position, the background dimming, and the visibility of controls. Change the motion and immediately try it again. The behavior itself becomes something you can edit.

## 2. Scope and intent

This specification describes tango as a standalone product: its purpose, interaction model, feature set, authoring workflows, and experience requirements.

The capabilities below define the intended product. They do not imply that an implementation has already shipped. Examples illustrate how the model works; acceptance scenarios define how to assess the resulting experience.

The core scope is visual interface authoring, a composable behavior graph, and live prototype playback. Platform support, implementation architecture, and delivery milestones are decisions to resolve during development.

## 3. The product thesis and its “magic”

tango makes **interactive behavior an editable design material**. The important unit of work is a relationship: this gesture changes that value, which changes these visible properties.

Six qualities create the experience:

1. **An idea becomes tangible quickly.** A small graph can turn an ordinary layer into something that responds to a person. The first useful result can be a single interaction rather than a complete application.
2. **Continuous control has room to exist.** A design can respond throughout a drag, scroll, or animation. Intermediate positions become part of the experience the designer can shape.
3. **Cause and effect are visible.** Cables expose dependencies. A designer can follow an input through state, calculations, and animation to the properties it affects.
4. **Small pieces combine into richer behavior.** Math, logic, gestures, and animation share a common connection model. Learning a few pieces increases what someone can build with the others.
5. **Visual craft and behavior stay close together.** Layout, content, interaction rules, and motion can be adjusted within the same working environment.
6. **Real inputs make ideas convincing.** Personal photos, a live camera, typed text, sensors, and external data give a prototype situations to respond to. They help reveal decisions that placeholder screens conceal.

The emotional payoff is the moment a designer can touch an idea, notice something about its feel, and improve it without translating that observation into a separate implementation request.

## 4. Who it serves and what they do

| User | Job the product supports |
| --- | --- |
| Product or interaction designer | Explore and refine how an interface behaves. |
| Motion designer | Coordinate movement, timing, easing, and responses to input. |
| Design systems contributor | Package reusable interface elements together with their behavior. |
| Researcher or product team | Put an interactive idea in someone’s hands and observe their response. |
| Engineer or technical collaborator | Inspect the rules, dependencies, values, and motion behind a design. |

A typical session begins with a design question, such as “How should this sheet dismiss?” or “What should this header do while scrolling?” The designer builds enough of the interface to investigate that question, tries variations, and shares the resulting behavior.

## 5. The working environment

tango combines a desktop authoring environment with prototype playback. The patch graph is the primary workspace: every view is a patch in it, next to the patches that drive it. The other areas support it.

| Area | What the user does there |
| --- | --- |
| Patch Editor | Construct the graph: the views themselves and the interaction, logic, and animation that drive them. |
| View Outline | Nest and order views; add views and, through a view’s Touch menu, interactions. |
| Inspector | Edit properties of the selected view and choose which of them appear as ports on its patch. |
| Viewer | Use the running prototype and record it. |
| Patch Library | Find views and patches and learn what they do. |
| Canvas | Optional. Drag and resize views directly. |

These areas are views of one prototype and one set of objects: a view selected in one is selected in all of them.

## 6. How it works

### 6.1 A graph of values and dependencies

A **patch** performs a function. It receives values through input ports and exposes results through output ports. A **cable** connects an output to an input; the connection defines where the value goes.

Ports carry types such as numbers, booleans, text, colors, points, images, video, sound, indices, and JSON. One output can feed multiple inputs. Each input accepts one cable, so combining or selecting sources happens explicitly through another patch.

An unconnected input can be edited directly. Connecting a cable gives the upstream graph control of that input.

The useful mental model is a live dependency graph. Spatial placement makes the graph readable; connections determine the relationships. Patches behave like functions, with computation expressed through their connections.

### 6.2 Events, persistent state, and continuous values

These concepts serve different purposes:

| Concept | Meaning | Example |
| --- | --- | --- |
| Pulse | An event signal that is on for one frame. | A tap triggers an action. |
| Persistent state | A value retained until changed. | A panel stays open after the tap ends. |
| Continuous value | A changing quantity used to control behavior. | A finger’s position moves a card. |

The Interaction patch’s **Down** output describes whether a finger is down; **Tap** emits a pulse. A pulse can flip a Switch, whose output then preserves the resulting state. Pulse patches can turn changes in state into explicit events. This distinction is essential when a momentary input needs a lasting effect.

### 6.3 State is something the designer constructs

Common tools include:

- **Switch:** Stores an on/off choice.
- **Option Switch:** Selects one of several mutually exclusive states.
- **Counter:** Moves through ordered states.
- **Option Picker:** Chooses a value using the active option.
- **Logic and comparison patches:** Combine conditions that govern behavior.

A tab selection, a popover’s visibility, or a step in onboarding can therefore be represented explicitly and used to control several parts of the interface.

### 6.4 Animation operates on changing values

Animation patches smooth changing numbers. A state can produce a target of 0 or 1; an animation patch produces progress between those values; a Transition maps that progress into a property’s start and end values.

For example, progress can map to a width from 120 to 320. The same progress can feed other Transitions, synchronizing position and opacity. Animation supports reversal and changing targets through spring-based and easing-based tools, including Spring Animation and Easing Animation.

**Product implication:** Motion can be a reusable relationship between input and output. Designers can reason about how several properties respond together, including while the target changes.

### 6.5 Views are patches

A prototype is built from views: a screen, plain views, stacks, grids, scroll views, text, images, and other specialized views. Each view is one patch in the graph. Its properties are that patch’s inputs: an input with no cable holds the value the user set, and a cable drives it. A view patch shows a short set of ports for its type; the Inspector shows or hides the rest, and a cable can also be dragged directly to an Inspector property.

That identity is fundamental: values calculated in the Patch Editor connect straight to the interface the user sees, with no intermediate object. Nesting and front-to-back order are kept in the View Outline.

The graph is shown one view at a time, the way an app is built one view controller at a time. A level holds the views directly inside one view and the patches that work on them; the view itself is one level out. Double-clicking a view that holds others steps into it; new views and patches made there go inside it. A cable may run between levels, and shows at each end where it goes.

A view that holds others can publish ports from inside it. Publishing a port of a nested view, or of a patch kept in the view, shows it by name on the view's own patch, one level out, as an input or an output. A cable there reaches the port inside, so a view has an interface the way a component does, without becoming one. A published input with no cable shows the value of the port inside.

## 7. Capability specification

### 7.1 Visual composition and adaptive layout

A view is placed by its x, y, width, and height. Layout comes from container types that a UI engineer already knows:

- Stack: arranges its children along a horizontal or vertical axis, with spacing, horizontal and vertical padding, cross-axis alignment, and distribution of free space.
- Grid: arranges its children in equal columns.
- Scroll View: a stack that scrolls when its content is longer than it is, with optional paging.
- A child of a container has fixed, Grow, or Auto sizing, and can opt out of the arrangement.
- Text measurement options using cap and baseline bounds.

Layout allows an interface to respond when its content or dimensions change. It also arranges repeated elements produced by loops.

### 7.2 Gestures and input

Interaction patches capture touches and taps, dragging, scrolling, paging, swipes, pinch-based interactions, long presses, double taps, keyboard input, and hover. Scrolling belongs to the Scroll View, which reports its offset, velocity, and whether it is being dragged. A view’s interactions are accessible from its Touch menu or the Patch Library.

Input also depends on the hierarchy. Touch propagation supports tappable content within a scroll view. Hit testing excludes disabled or fully transparent views.

**Product implication:** Gesture behavior and visual composition have to be designed together, particularly when interactive regions overlap or nest.

### 7.3 Reusable visual and behavioral components

tango components can encapsulate patches, or layers and patches together. A reusable button can therefore carry both its appearance and its interaction behavior.

Components expose published inputs and outputs. Their interface can be edited, including port types, defaults, and bounds. Users can enter a component to edit its internals. Changes propagate to uses of the component within the prototype.

Component libraries distinguish platform components, device components, document components, and user library components. Platform offerings include familiar iOS and Android interface elements; device components include a viewfinder and text input.

### 7.4 Repeated interfaces and data collections

Loops produce repeated values and can cause connected layers or components to be evaluated for each item. Loop, Loop Builder, and Loop Over Array support indexed, custom, and array-derived content.

Combined with Layout and components, they build lists, grids, and nested repeated interfaces. Interactions on repeated elements are looped too, allowing the graph to identify a selected item. Component input settings distinguish repeating a component from passing a loop into its internals.

**Product implication:** A designer can describe the rule for a collection and let actual content determine its instances.

### 7.5 Shared values and graph organization

Variable Broadcasters and Receivers distribute named values without long cables. Local values simplify a graph; global values cascade through descendant components. A descendant can override an inherited global with the same name and type.

This supports shared settings such as header dimensions, text, or appearance choices. Receivers also provide a way to navigate to their source.

Patches can be renamed and grouped with comments to explain their purpose. These features help a complex graph remain understandable to its author and collaborators.

### 7.6 Real data and external systems

The Network Request patch supports GET and POST requests for text, JSON, images, video, and sound. It exposes parameters, headers, body, loading state, results, and error information. Resources can be uploaded using multipart form data. Device players use HTTPS for remote requests.

WebSocket patches separately manage connection, sending, and receiving. They support text and JSON messages, with connection and error outputs available to the graph.

**Product implication:** Prototypes can model loading, successful responses, and failures as part of the experience rather than relying only on prearranged content.

### 7.7 Device capabilities and media

Device integrations include photo library access, audio metering, haptics, location, and device motion.

Additional inputs and outputs include camera, microphone, sound playback, device information and buttons, game controllers, and trackpads. Media layers include video, maps, Lottie animation, and particles. The available combination depends on the player, device, and hardware.

These capabilities let a prototype use physical context as an input and media or physical feedback as an output.

### 7.8 Custom logic and rendering

JavaScript patches let users add imperative logic while preserving the patch interface: a script declares inputs, outputs, and evaluation logic. Scripts can be inserted through the patch picker or dragged in as JavaScript files. An embedded JavaScript runtime evaluates scripts in response to input changes or, when explicitly enabled, on every frame.

Shader layers support custom visual effects using GPU shader code. Uniforms become layer input properties that the patch graph can control. A shader can generate imagery or process its child layer hierarchy as a texture.

**Product implication:** Specialized work can be packaged behind the same input/output model used by ordinary patches and layers.

### 7.9 Import, preview, and communication

Import preserves editable vector and text layers from design tools such as Figma. A built-in recorder captures the prototype and supports trimming and exporting video. A companion player supports nearby sharing and device playback.

Device mirroring reflects authoring changes immediately. Users can also export a prototype to take on a device and send prototype files through ordinary file-sharing channels. Custom fonts are explicitly embedded when permitted by their licenses.

**Product implication:** A working prototype communicates behavior through use; a recording preserves a particular demonstration for asynchronous discussion.

### 7.10 Distributable systems

Users can publish collections of components as reusable libraries. The publishing workflow collects components in one document, selects what to publish, and supplies library metadata and version information. Libraries may include supporting JSON for styles, colors, or data.

A library can be installed locally or from a shared location. Updates are distributed to its users, with prompts to upgrade older components in existing documents.

### 7.11 Examples and patterns as part of the product

The example gallery supplies inspectable prototypes for camera interactions, search, photo selection, motion input, scrolling, live data, and other workflows.

The patterns collection supplies smaller reusable solutions such as bottom sheets, sticky headers, swipe menus, nested scrolling, and video scrubbing.

**Product implication:** These libraries teach the product’s vocabulary through working behavior. They help someone move from seeing an effect to understanding how to construct it.

## 8. Extended capabilities

These capabilities extend the core authoring and playback model. Delivery can be phased while preserving the same layer, property, patch, and connection abstractions.

| Area | Target capabilities |
| --- | --- |
| Rendering and media | Layer effects, glass and material effects, background effects, continuous corner curves, variable fonts, HDR/EXR images. |
| 3D | A scene layer, USDZ model support, and image-based lighting. |
| Maps | Interactive maps with panning, zooming, and custom annotations. |
| AI assistance | Generate and refine JavaScript patches and shaders through configurable model providers. |
| Interoperability | JSON copy/paste and a CLI for exporting a document as JSON. |
| Device and runtime | Bluetooth LE, hand detection, and playback at up to 120 fps where supported. |
| Animation | Fluid spring motion with coherent responses to changing targets. |
| Design import | Masks, strokes, fills, gradients, blend modes, and adaptive layout properties. |

The extensions broaden available inputs, outputs, and authoring tools. The organizing model remains layers, properties, patches, and connections.

## 9. A representative authoring workflow

*This workflow describes the intended authoring experience.*

1. **Frame the question.** Choose a behavior to investigate and the context needed to judge it.
2. **Create the visual structure.** Draw or import layers, organize groups, and set up adaptive layout where needed.
3. **Add an input.** Attach an interaction to a layer or introduce a device or data source.
4. **Represent the rules.** Decide what should persist, what should trigger once, and what should continuously track input.
5. **Connect the visible response.** Route values through calculations and animation into layer properties.
6. **Try it.** Use the Viewer or a physical device and inspect the behavior between its endpoints.
7. **Refine and package.** Adjust values, simplify the graph, and extract reusable components when useful.
8. **Communicate the result.** Share a runnable prototype or a recording, with enough context to explain the design decision.

## 10. Four examples that reveal the product

*These recipes illustrate the target interaction model. Specific values and thresholds are chosen by the designer.*

### A. A card that opens and closes

A tap flips an `Expanded` state. An animation smooths that state into progress. Several mappings use the same progress to change the card’s bounds, background dimming, and control visibility. Tapping again changes the target back.

**What this demonstrates:** A single behavioral value can orchestrate several visual changes. The designer can investigate reversal and repeated input.

### B. A sheet that follows a finger

A drag controls the sheet’s position while the finger is down. On release, logic selects a destination using a chosen threshold; animation carries the sheet to that destination. Background dimming follows its position or progress.

**What this demonstrates:** Direct manipulation and animated settling can be parts of the same behavior. The handoff must occur without a visible jump.

### C. A list that uses actual content

A request returns JSON. An array becomes repeated row components, Layout arranges them, and row interactions select an item. Loading and error outputs govern the surrounding interface.

**What this demonstrates:** The prototype can express a system of behavior across changing data, including states that a carefully staged demonstration might omit.

### D. A camera experience with feedback

A viewfinder shows the camera. A capture action changes the displayed image and triggers visual or haptic feedback on supported hardware. The designer tries the sequence on a phone.

**What this demonstrates:** The person’s environment becomes part of the design experiment.

## 11. Conceptual model

*This model defines product concepts and responsibilities. Internal schemas and software architecture are implementation decisions.*

| Entity | Responsibility |
| --- | --- |
| Document | Contains a prototype and its reusable definitions. |
| View | Represents visible content, a container, or a specialized output. It is a patch. |
| Property | A configurable aspect of a view, and an input of its patch. |
| Patch | Transforms values, handles input, maintains state, performs an operation, or is a view. |
| Port | A typed boundary through which a patch or component exchanges values. |
| Connection | Declares a dependency from an output to an input. |
| Component | Encapsulates reusable structure and behavior behind a published interface. |
| Loop | Applies behavior across repeated values or instances. |
| Variable | Makes a named value available within a defined scope. |
| Player | Runs the interactive result in a desktop or device context. |

At the conceptual level, input enters a graph, the graph computes values and maintains state, those values affect layout or presentation, and the person responds to the rendered result. Editing changes that working system while the designer evaluates it.

## 12. Experience requirements

These requirements define the experience tango should deliver and the scenarios used to evaluate it.

### Essential qualities

- **Immediate feedback:** Changes should appear quickly enough to support a continuous edit-and-try rhythm.
- **Input continuity:** Direct manipulation should feel attached to the person’s movement.
- **Responsive motion:** A changed target should have a coherent result, including during an active animation.
- **Visible causality:** Users should be able to discover what controls a property and where a value originates.
- **Composability:** Inputs, calculations, state, animation, and presentation should share useful interfaces.
- **Reusable behavior:** Components should retain their behavior and expose meaningful controls.
- **Realistic context:** Content, input, and device behavior should be representative enough to answer the design question.
- **Manageable complexity:** Naming, comments, components, variables, and inspection should help larger prototypes remain editable.

### Acceptance scenarios

| Scenario | Acceptance criterion |
| --- | --- |
| Build a first interaction | A newcomer can connect an input to a visible result and understand the relationship. |
| Coordinate motion | One progress value can drive several properties without manually duplicating timing. |
| Reverse an interaction | Changing the target midway through motion produces a coherent visible response. |
| Release a drag | The transition from direct input to settling motion has no unexpected position jump. |
| Repeat a component | A collection creates distinct instances with usable per-item interactions. |
| Change content | Layout adapts to longer text, a different item count, and different container dimensions. |
| Encapsulate behavior | Extracting a component preserves behavior while exposing the controls another designer needs. |
| Inspect someone else’s prototype | A collaborator can trace a visible effect back to its source and understand the state involved. |
| Test an external dependency | Loading, success, and failure produce deliberate interface states. |
| Try it on a device | A person can evaluate touch, text input, and supported hardware in the relevant context. |

### Delivery priorities

| Priority | Deliver |
| --- | --- |
| Foundational | Layer editing, property binding, typed connections, state and events, direct input, animation, live preview. |
| Depth | Adaptive layout, components, loops, variables, graph inspection and organization, realistic scrolling. |
| Breadth | Device APIs, networking, system distribution, media, scripting, shaders, newer rendering and AI capabilities. |

The priority order expresses dependencies in the experience. Broad feature coverage becomes valuable when the foundational act of connecting and trying behavior remains clear and fast.

## 13. Implementation decisions and boundaries

- **Authoring platform:** Desktop authoring is the initial product model. Operating-system support and distribution need to be selected.
- **Player support:** Define the supported mobile and desktop players, their feature parity, and which capabilities require specific hardware.
- **Runtime architecture:** Choose the graph scheduler, renderer, serialization format, and dependency implementation while preserving observable behavior.
- **Coordinate conventions:** Define logical layout units, layer origins, anchors, and pivots. Specify conversions between layout coordinates and shader pixel coordinates.
- **Advanced integrations:** Specify the contracts for AI generation, 3D assets, JSON interchange, visual effects, and external devices before implementation.
- **Delivery model:** The core deliverables are runnable prototypes and recordings. Production application export is a separate scope decision.
- **Collaboration model:** File sharing and component-library distribution are included. Simultaneous authoring and browser-hosted playback are separate scope decisions.
