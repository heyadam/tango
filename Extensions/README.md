# Writing an extension

An extension adds patches, views and components to tango. It is a folder whose
name ends in `.paperextension`:

```
extension.json     what it is and what it adds: read before anything runs
patches/*.js       patches
views/*.js         views drawn by a script
shaders/*.metal    shader views
components/*.json  components
assets/            pictures
README.md          shown in the Extensions window
```

Start one with `swift run papertool extension new "My Extension"`, or copy
`Sampler.paperextension`. While you write it, choose **Link Folder for Development…** in
the Extensions window: the app then uses the folder where it is and picks up each save.
`swift run papertool extension validate <folder>` says what is wrong with one.

## extension.json

```json
{
  "format": 1,
  "id": "com.example.weather",
  "name": "Weather",
  "version": "1.2.0",
  "author": "Example Labs",
  "summary": "One sentence, shown where extensions are listed.",
  "network": ["api.example.com"],
  "secrets": [{ "id": "apiKey", "name": "Example API Key", "hosts": ["api.example.com"], "help": "https://example.com/keys" }],
  "patches": [{
    "id": "current", "name": "Current Weather", "category": "Data", "summary": "…",
    "script": "patches/current.js",
    "inputs": [{ "id": "city", "type": "text", "default": "Paris" }, { "id": "refresh", "type": "pulse" }],
    "outputs": [{ "id": "temperature", "type": "number" }, { "id": "error", "type": "text" }]
  }],
  "views": [
    { "id": "gauge", "name": "Gauge", "summary": "…", "draw": "views/gauge.js", "size": [120, 120],
      "inputs": [{ "id": "value", "type": "number", "default": 0.5 }] },
    { "id": "glow", "name": "Glow", "summary": "…", "shader": "shaders/glow.metal" }
  ],
  "components": ["components/Card.json"]
}
```

- `id` is lowercase letters, digits, dots and hyphens. It never changes: documents name
  a patch as `<id>/<patch id>`.
- A port has an `id` (a plain name: it is a key in `inputs` or `outputs`), a `type`
  (`number`, `bool`, `pulse`, `text`, `color`, `point`, `size`, `array`, `json`), and
  optionally a `name`, a `default` and, for text, `options`. Defaults are written
  plainly: `20`, `"#FF0000"`, `[10, 20]` for a point or size.
- `category` is one of Input, State, Logic, Math, Animation, Loop, Data, Device, Utility.
- `network` lists every host the scripts may contact: an exact name, or `*.example.com`.
- `secrets` are keys the person enters. Each names the exact hosts it may be sent to.
- Keep ids of ports, patches and views once documents use them. Changing a version
  that adds hosts or keys is shown to the person as such when they update.

## A patch

```js
function evaluate(inputs, outputs, time) {
  outputs.result = inputs.a + inputs.b;
}
```

It runs when an input changes or a pulse arrives; set `everyFrame = true` at the top to
run every frame. Variables of the script are its state: each patch, and each item of a
loop, has its own. A pulse output is set with `outputs.done = true` and lasts one frame.
A point is `point(x, y)`, a size `size(w, h)`, a color `color("#RRGGBB")`.

### Requests

```js
async function load(city) {
  outputs.loading = true;
  const reply = await paper.fetch("https://api.example.com/weather?q=" + encodeURIComponent(city), {
    headers: { "X-Api-Key": paper.secret("apiKey") }
  });
  outputs.loading = false;
  if (reply.ok) outputs.temperature = reply.json.main.temp;
  else outputs.error = reply.error;
}
function evaluate(inputs, outputs) { if (inputs.refresh) load(inputs.city); }
```

- `paper.fetch(url, { method, headers, body, timeout })` gives a promise that always
  resolves, to `{ ok, status, headers, text, json, error }`. A `body` that is not text is
  sent as JSON. `timeout` is in seconds, 120 at most.
- What was waiting for an answer goes on in a later frame, and may set `outputs` there.
- A request goes only to a host in `network`, over https (http to this Mac itself).
  Redirects are not followed, and cookies are neither sent nor kept.
- `paper.secret("id")` gives a placeholder, never the key. Put it in a header or in the
  address after the `?`. The app fills the key in when the request goes to one of the
  hosts declared for it, and removes it from whatever comes back. A key in a body or in
  a request to any other host is refused.
- `paper.log(…)` writes to the extension's Activity in the Extensions window, where
  errors in its scripts are shown too.
- Eight requests may wait at once per patch. Pictures of the prototype (thumbnails,
  what the assistant looks at) send none.

A script has nothing else to reach out with: no files, no timers, no other API. Each
call into it may take a quarter of a second; one that takes longer is stopped and not
run again until the extension changes.

## A view

```js
function draw(canvas, inputs, size, time) {
  canvas.fillStyle = inputs.color;
  canvas.fillRect(0, 0, size.width * inputs.value, size.height);
}
```

`draw` is called when an input or the size changes, or every frame with
`everyFrame = true`. Its inputs are ports on the view's patch and fields in the
Inspector. The view is an ordinary view otherwise: it has a fill behind the drawing,
can hold other views in front of it, and takes Interaction patches.

`canvas` is the part of the HTML canvas that draws, in points with y down:

- State: `fillStyle`, `strokeStyle`, `lineWidth`, `lineCap`, `lineJoin`, `setLineDash`,
  `globalAlpha`, `font` (`"bold 16px sans-serif"`: the size and weight are used),
  `textAlign`, `textBaseline`, `shadowColor`, `shadowBlur`, `shadowOffsetX`,
  `shadowOffsetY`, `save`, `restore`.
- Transforms: `translate`, `scale`, `rotate`.
- Paths: `beginPath`, `moveTo`, `lineTo`, `quadraticCurveTo`, `bezierCurveTo`, `arc`,
  `rect`, `roundRect`, `ellipse(x, y, radiusX, radiusY)`, `closePath`, `fill`, `stroke`,
  `clip`.
- Shapes and text: `fillRect`, `strokeRect`, `clearRect`, `fillText`, `measureText`.
- `createLinearGradient`, `createRadialGradient` with `addColorStop`.
- `drawImage("assets/logo.png", x, y, width, height)` draws one of the extension's own
  pictures.

Colors are `"#RGB"`, `"#RRGGBB"`, `"#RRGGBBAA"`, `rgb()`/`rgba()`, a few names, or a
color input as it arrives. A drawing may have 20,000 steps.

## A shader view

`"shader": "shaders/glow.metal"` names Metal code as a shader view takes it: a
`struct Inputs` and `float4 shader(Frame frame, Inputs in)`. Its inputs come from the
code, so the manifest gives none. Adding one copies the code into the document as an
ordinary shader view: it works without the extension, and a later version of the
extension does not change views already placed.

## A component

Build the component in a document, then write it into the extension:

```sh
swift run papertool extension export-component MyDocument.tango "Card" MyExtension.paperextension
```

That writes `components/Card.json`, the document's own components it is made of, and
the pictures they show into `assets/`. List the paths under `components`. A component
is copied into a document the first time it is used there, with what it needs.

## What the person sees

Before installing, a sheet lists what the extension adds, the hosts it may contact and
the keys it asks for. A document carries a copy of each extension it uses, so opening it
on another Mac offers to install it; nothing runs from the document itself.
