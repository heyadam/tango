# Writing a gallery example

For a coding agent (any model) asked to add an example to Tango's starting gallery. Read all of
this before you touch code. It tells you what to read, what to build, and how to check it,
so you do not need to look through the rest of the repository. If something here disagrees
with the code, the code is right: say so in your report.

## What you are making

Tango is a native macOS app for designing interactive prototypes. A prototype is a tree of
**views** (what is drawn) and a **patch graph** (what makes them behave). Every view is also
a patch in the graph. The **gallery** is the window that opens with File > New from Gallery
and on the welcome screen. Each entry is a prototype **built in Swift code**, not saved by
hand. One list, `Gallery.items`, feeds the gallery window, `papertool`, the files in
`Examples/` and several tests.

A good gallery example:

1. **Shows one idea a person can take away**: "a like button that pops", "a row you swipe
   to delete", "a tab bar that switches screens". It is not a whole app.
2. **Looks finished.** It uses the shared look (`ExampleStyle`), real icons and real-looking
   words, never "Lorem ipsum" or "Button 1".
3. **Responds to a touch the moment it opens**, and its hint pill says what to try.
4. **Explains itself in its graph**: every group of patches that does something has a
   comment round it saying what it does (`b.note`).
5. **Uses what Tango has now**: icons from Lucide or SF Symbols, gesture patches (tap, pan,
   swipe, long press, pinch, hover), springs, screens and flows, components from the iOS
   shelf, and, where it fits, a shader or glass.
6. **Has a test** that plays the hint's promise and checks the result.

## Read these, and only these

| File | Why |
|---|---|
| `AGENTS.md`, the sections "Views are patches", "How the engine works" and "Screens and flows" | the model. Skip the rest unless a section below sends you there |
| `Sources/PaperEngine/ExampleStyle.swift` | the shared look: sizes, palette, `text`, `symbol`, `header`, `hint`, `button`, `roundButton`, `avatar`, `scene` |
| `Sources/PaperEngine/Samples.swift`, lines 1–130 | `SampleDocuments.Builder`: `add`, `attach`, `interaction`, `view`, `property`, `connect`, `note` |
| `Sources/PaperEngine/Patterns.swift`, `signIn()` and `screenFlow()`, then `Gallery.items` at the end | two finished examples to copy the shape of, and the list you add to |
| `Tests/PaperEngineTests/ShowcaseTests.swift`, the first 50 lines | how a test plays an example |
| The output of `swift run papertool reference` | **every patch kind with its exact port ids, every view property, every shelf component and template, icons and fonts.** Save it to a file and search it, rather than guessing a port name |

Read more only when your idea needs it:

- iOS components (Toggle, Tab Bar, List Row, Sheet…): `Sources/PaperEngine/Samples.swift`,
  `controls()`, and `Builder.place` / `Builder.wire` in `Library/ComponentLibrary.swift`.
- A JavaScript patch: `nowPlaying()` in `Sources/PaperEngine/MarqueeSamples.swift` (search
  `PatchKind.javascript`).
- A shader or glass: AGENTS.md "Shader views", and `Sources/PaperEngine/ShaderSamples.swift`.

Do **not** read or change the engine, the renderer, the editor or other examples to make
yours work. If the engine cannot do what you want, change the idea, or stop and report the
gap (see "When to stop").

## How Tango thinks (the ten things to know)

1. A view is a `Layer`: `Layer(name:kind:properties:children:)`. Kinds: `.screen` (the
   root), `.view` (a box; a stack or grid when it has `layout`), `.text`, `.textField`,
   `.symbol` (an icon), `.ellipse`, `.image`, `.video`. Properties are
   `[LayerProperty: Value]`, such as `.fill: .color(…)`, `.size: .size(Size2(…))`.
2. Coordinates are points, the origin is the parent's top-left, y goes down. The screen is
   402 × 874 (`ExampleStyle.device`). Keep content below `ExampleStyle.top` (62, the status
   bar) and above `device.height - ExampleStyle.bottom` (the home indicator).
3. A view in a stack (`.layout: .text("Stack")`) is placed by the stack; its x and y are
   ignored. `widthMode`/`heightMode` are `Fixed`, `Grow` or `Auto`.
4. Every view has one view patch. Its inputs are the view's properties. To drive a property
   from the graph, `let h = b.property(.opacity, of: layer.id, at: …)`, then
   `b.connect(source, "value", to: h, "value")`.
5. Touch comes from patches attached to a view: `b.attach(PatchKind.tap, to: view.id, at: …)`
   (also `pan`, `swipe`, `longPress`, `pinch`, `rotation`, `"hover"`, `"textInput"`), or
   `b.interaction(on:at:)` for the raw touch (down, position, drag). The view under the
   finger must be the one with the patch, or contain it.
6. A **pulse** lasts one frame (`tapped`). A **bool** lasts (`switch`'s `on`). Turn pulses
   into state with `switch` (`flip`, `turnOn`, `turnOff` → `on`) or `counter`.
7. Motion: state → `spring` (`target` → `value`, a 0-to-1 number) → one `transition` per
   property (`progress`, `start`, `end` → `value`; give it `type: .number`, `.color`,
   `.point` or `.size`) → the property. One spring can drive many transitions; that is
   the house style ("one spring moves everything together").
8. A loop repeats a view: an array into a view's input makes one copy per value. The loop
   must reach the view that should repeat as a whole (see `searchList()`'s "Every Row").
9. Several screens: `Layer.newPage(name:)` pages inside a `.screen` named "Device"; a
   `navigate` patch attached to a page with `go` from a Tap, and `navigateBack`. See
   `screenFlow()`.
10. The runtime is deterministic and has no clock. A test sends touches and ticks frames.
    Nothing does network or device work in a test or a gallery picture.

## The recipe

### 1. Pick the idea and its section

`GalleryItem.Section`: `.patterns` (one reusable solution, a few views), `.examples` (a
whole little workflow), `.showcase` (polished: shaders, glass and motion together). Most new
items are patterns. Write the card's title (two to four words) and summary (one sentence
saying what the person will see) before you write code. Check `Gallery.items` so you do not
repeat an existing idea.

### 2. Write the builder in its own file

`Sources/PaperEngine/<Name>Sample.swift`, as an extension of `SampleDocuments`. It returns a
small struct with the document and the ids your test needs. A skeleton, a heart that pops
and turns rose when tapped:

```swift
import Foundation
import PaperModel

extension SampleDocuments {
    public struct LikeButton {
        public let document: Document
        public let heart: LayerID
        public let button: LayerID
        public let liked: NodeID
    }

    /// One tap likes a post: a switch remembers it, and one bouncy spring pops the heart
    /// larger and tints it rose together.
    public static func likeButton() -> LikeButton {
        typealias S = ExampleStyle
        let heart = S.symbol("Heart", "lucide:heart", side: 28, color: S.tertiary, weight: 400)
        let button = Layer(name: "Like", kind: .view, properties: [
            .position: .point(Point2(x: (S.device.width - 72) / 2, y: 400)),
            .size: .size(Size2(width: 72, height: 72)), .cornerRadius: .number(36), .fill: .color(S.surface),
            .shadowColor: .color(S.shadow), .shadowRadius: .number(12), .shadowOffset: .point(Point2(x: 0, y: 4)),
            .layout: .text("Stack"), .axis: .text("Horizontal"), .alignment: .text("Center"), .distribution: .text("Center"),
        ], children: [heart])
        let screen = Layer(name: "Screen", kind: .screen, properties: [.fill: .color(S.paper)],
                           children: S.header("Moments", "Kyoto at dawn") + [button, S.hint("Tap the heart")])

        var b = Builder(screen: screen)
        let tap = b.attach(PatchKind.tap, to: button.id, at: Point2(x: 48, y: 96))
        let liked = b.add("switch", at: Point2(x: 336, y: 96), name: "Liked")
        let spring = b.add("spring", at: Point2(x: 624, y: 96), inputs: ["response": .number(0.3), "damping": .number(0.5)])
        let pop = b.add("transition", at: Point2(x: 912, y: 96), name: "Pop", type: .number,
                        inputs: ["start": .number(1), "end": .number(1.25)])
        let tint = b.add("transition", at: Point2(x: 912, y: 456), name: "Tint", type: .color,
                         inputs: ["start": .color(S.tertiary), "end": .color(S.rose)])
        let scale = b.property(.scale, of: heart.id, at: Point2(x: 1200, y: 96))
        let color = b.property(.fill, of: heart.id, at: Point2(x: 1200, y: 456))
        b.connect(tap, "tapped", to: liked, "flip")
        b.connect(liked, "on", to: spring, "target")
        b.connect(spring, "value", to: pop, "progress")
        b.connect(spring, "value", to: tint, "progress")
        b.connect(pop, "value", to: scale, "value")
        b.connect(tint, "value", to: color, "value")
        b.note("Like · A tap flips the switch", around: [tap, liked])
        b.note("Pop · A bouncy spring scales it", around: [spring, pop, scale])
        b.note("Tint · The same spring colors it", around: [tint, color])
        return LikeButton(document: b.document, heart: heart.id, button: button.id, liked: liked)
    }
}
```

(The skeleton shows the shape. Check every kind and port id against `papertool reference`
before you rely on it: that list is the truth.)

### 3. Add it to the gallery

Append a `GalleryItem` to `Gallery.items` in `Sources/PaperEngine/Patterns.swift`, in its
section's group:

```swift
GalleryItem(id: "like", title: "Like Button", summary: "A tap pops the heart and tints it with one spring.",
            section: .patterns, fileName: "LikeButton") { SampleDocuments.likeButton().document },
```

`id` is short, lower case, unique, and is what `papertool` takes. `fileName` is unique too.
Add the id to the list of gallery ids in `AGENTS.md` ("`<doc>` is a `.tango` path, `empty`,
or a gallery id").

### 4. Write its test

`Tests/PaperEngineTests/<Name>ExampleTests.swift`. Play exactly what the hint says and check
the result through `runtime.resolved.find(id)`:

```swift
import Foundation
import Testing
import PaperModel
@testable import PaperEngine

@Suite struct LikeButtonExampleTests {
    @Test func aTapPopsTheHeartAndTintsIt() {
        let example = SampleDocuments.likeButton()
        let runtime = Runtime(document: example.document)
        runtime.advance(seconds: 0.2)
        func heart() -> ResolvedLayer { runtime.resolved.find(example.heart)! }
        let middle = Point2(x: 201, y: 436)
        runtime.send(.touchDown(middle)); runtime.tick(dt: 1.0 / 60)
        runtime.send(.touchUp(middle)); runtime.advance(seconds: 0.15)
        #expect(heart().scale > 1.05)
        runtime.settle(within: 3)
        #expect(abs(heart().scale - 1.25) < 0.01)
        #expect(heart().value(.fill) == .color(ExampleStyle.rose))
    }
}
```

Find the point to tap from your own layout (a view's position plus half its size, in screen
coordinates). Drags: copy `drag` from `ShowcaseTests`. Typing: `runtime.send(.text("…"))`
after a tap on the field. Hover: see `aRestingPointerLiftsTheButton` in `PatternTests`.

## Use the new features (pick what serves the idea)

- **Icons.** A `.symbol` view's `symbol` is an SF Symbol (`heart.fill`) or **Lucide**
  (`lucide:heart`, `lucide:shopping-cart`). Lucide ships in the app, so it draws everywhere,
  including the gallery's thumbnail. Give a Lucide icon a square frame (24–28 points) and
  `fontWeight` 400 for Lucide's own 2-point line. Pick one set per example and keep to it:
  SF Symbols for an Apple-looking screen, Lucide for anything else. The **Icon** patch
  (`icon`: `set`, `name`, `filled` → `symbol`) swaps icons with state. **Lucide has no
  filled glyphs** (`filled` does nothing for it): to show "on", change the icon's `fill`
  color, swap to another name (`bookmark` → `bookmark-check`), or use SF Symbols, whose
  `.fill` variants `filled` picks. Search
  `Sources/PaperEngine/Catalogs/lucide.json` to check a Lucide name exists.
- **Do not use Material Symbols, Google Fonts or Unsplash in a gallery example.** They are
  fetched from the web, and gallery pictures and tests fetch nothing, so the thumbnail
  would be blank or in the wrong font. For type, `fontFamily` may be Apple's: `SF Pro`
  (empty), `SF Pro Rounded`, `New York`, `SF Mono`, and `italic: .bool(true)`.
- **Gestures.** `tap` (`taps: 2` for a double tap), `longPress`, `pan` (`translation`,
  `velocity`, `ended`; `direction` to share a scroll view), `swipe` (`left`, `right`…),
  `pinch` and `rotation` (together they move, zoom and turn), `hover`, `textInput` on a text
  field. A pan released with a spring that settles open or closed is the classic pattern
  (see `sheet()` in `Samples.swift`).
- **Frame outputs.** Every view patch can output its laid-out `frameX`, `frameY`,
  `frameWidth`, `frameHeight` (one frame late), for following a view or measuring text.
- **Screens and flows.** Push, Modal, Fade, Instant and Morph (views with the same name on
  both screens move between them). Swipe back from the left edge works by itself.
- **The iOS shelf.** `b.place(ComponentLibrary.iOS("Toggle"), in: parent, inputs: [...],
  patchAt: …)` and `b.wire(…)` by port name. Use it when the idea is about behavior and
  the control is not the point; the whole list is in `papertool reference` under Components.
- **Glass and shaders.** A view's `backgroundBlur` with a partly clear fill is a material;
  `ComponentLibrary.glass(…)` is Liquid Glass. Showcase items only, and drive a shader from
  a spring, not from `time`, unless it truly moves forever.
- **JavaScript.** For logic that would take ten patches (formatting a time, keeping a list).
  Keep it short and say in a comment at its top what it does.

## Comments on the graph

The graph is half of what an example teaches. Rules:

- One `b.note` per group of patches that does one job. Every non-view patch is in a note.
- The text is `Verb · what it does`, short enough for the width of what it surrounds:
  "Wake · Empty keeps the button dim", "Settle · Past half way it opens". Two to six words
  after the dot.
- Notes must not overlap. Put each job on its own row of patches, so each note's box is
  its own.
- Name patches whose kind does not say what they mean: `name: "Liked"`, `name: "Pop"`. A
  switch is named after the state it holds.

## Laying out the graph

- Patches are 192 points wide on a 12-point grid. Use columns at x = 48, 336, 624, 912, 1200
  (288 apart), starting at y = 96. A patch is 24 points a row of ports plus about 60, so a
  Spring is about 260 tall, and a note adds 48 above and 24 below what it surrounds: leave
  the tallest patch in a row plus 100 before the next row (360 after a row with a Spring). Positions passed to the
  builder are snapped for you; any patch you add without the builder needs `PatchGrid.snap`.
- Left to right is cause to effect: the touch, then state, then motion, then the view
  properties. Every cable should go to a column further right; one that goes back to the
  same column or left loops round and crosses comments. Put each property handle (`b.property`) in the last column of its row.
- Cables should never run behind a patch. If two rows cross, move one.
- A patch attached to a view inside a container lives at that container's level, so a
  person sees it after stepping in. Keep the graph shallow; put what you want seen first at
  the top level.

## The look

- Use `ExampleStyle` (imported as `typealias S = ExampleStyle`) for every size, color and
  text. Page `S.paper`, cards `S.surface`, text `S.ink` / `S.secondary` / `S.tertiary`,
  the one color things that act are drawn in `S.accent`, a few others for pictures (`coral`,
  `amber`, `sage`, `sky`, `plum`, `rose`, `teal`).
- `S.margin` (20) at the sides, `S.header("Kicker", "Title")` at the top, `S.hint("…")` near
  the bottom saying what to try (it takes no touches, so it never blocks one).
- For a picture use `S.scene(…)` (drawn with views). No image files.
- Text sizes: 34/700 for a title, 17 for body, 15 or 13 for secondary.
- Real words: names, places, times, prices. Keep to a few views; a person must be able to
  read the whole outline at a glance.

## Check your own work

Run these in order. Do not report done until all pass and you have looked at the pictures.

```bash
swift build
swift test --filter <Name>ExampleTests
swift test --filter PatternTests          # every cable joins real ports of fitting types; saves and reopens
swift test --filter PatchGridTests        # every patch on the grid
swift test --filter TextAndGalleryTests   # every gallery card gets a picture
swift run papertool viewer <id> build/<id>-start.png
swift run papertool viewer <id> build/<id>-tapped.png --tap x,y --seconds 1
swift run papertool editor <id> build/<id>-graph.png  # the window: outline, graph with your comments, inspector
swift run papertool record <id> build/<id>.mov --tap x,y --seconds 2
swift test                                # everything, last
```

Open each picture (read the PNG) and ask:

- [ ] Does the first picture look like a finished screen, inside the status bar and home
      indicator, with nothing cut off or overlapping?
- [ ] Is every icon drawn (no empty boxes), in one set?
- [ ] Does the tapped picture show the change the hint promises?
- [ ] In the graph picture, is every working patch inside a comment, are the comments
      readable and apart, and does no cable run behind a patch?
      The picture shows about four columns (x up to about 1100); what is further right is
      cut off, so keep the patches that do the work in the first four columns.
- [ ] Do the title and summary describe what the pictures show?
- [ ] Is nothing named "Layer 1", "Patch", "Untitled"?

Then write the example's file into `Examples/`:

```bash
swift run papertool examples Examples
git status Examples
```

That rewrites **every** file in `Examples/` with new ids. Keep only your new file:
`git checkout -- Examples/` for the others (then `git add` your new `.tango`).

## Hard rules

- Never `Int(someDouble)` on a value from a document or a patch; use `Double.whole`.
- Never store a pulse as on (`.pulse(true)`) in inputs.
- A plain `.view` made with `Layer(kind: .view)` has a clear fill: give it one if it should
  be seen.
- Metal needs `max(x, 1.0)`, not `max(x, 1)`.
- Do not change `ExampleStyle`, the Builder, other examples, or any test you did not write.
  A change there changes every example.
- Do not add files to `Sources/PaperEngine/Media` or assets to the item unless the idea is
  about media; examples draw their pictures with views.
- Keep the example offline: no `networkRequest` to a real address, no AI patches that need a
  key. (`apple-on-device` models are allowed only in showcase items, and need a test that
  skips when the model is missing; see `OnDeviceChatTests`.)

## When to stop and ask

Stop and report, instead of working round it, when:

- a port or patch you need is not in `papertool reference`;
- the prototype does something you did not cable (a touch reaches the wrong view, a value
  is not finite, it never comes to rest);
- a test outside your own fails;
- making it work would mean touching the engine, the renderer or the editor.

Say what you tried, what happened, and the smallest example that shows it.

## Your report

When done, reply with: the id, title and summary; the files you added or changed; the test
names and that they pass; the paths of the pictures you looked at; and anything that did not
look right that you left.
