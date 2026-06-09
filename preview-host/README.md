# tango preview host

A ~400-line SwiftUI app that renders tango's design spec **live** on the iOS
simulator. It connects to `ws://localhost:<port>/ws/preview` (the simulator
shares the host's network stack) and re-renders on every frame the server
pushes — canvas edits appear in under a second, with no rebuild.

## How it runs

Tango's **Preview** button (or the `preview_start` MCP tool) does:

1. `xcodebuild` this project into `~/.tango/preview-host-build`
   (cold: ~30–60s once per machine/Xcode version; warm: a ~2–4s no-op)
2. `xcrun simctl install <udid> PreviewHost.app`
3. `SIMCTL_CHILD_TANGO_WS_PORT=<port> xcrun simctl launch <udid> dev.tango.preview-host`
   — simctl strips the `SIMCTL_CHILD_` prefix, so the app reads
   `TANGO_WS_PORT` from its environment (default 3000).

## Project format

Hand-authored `objectVersion 77` pbxproj with a filesystem-synchronized
`Sources/` group — new `.swift` files are picked up automatically, no per-file
pbxproj entries. The shared scheme exists because `xcodebuild -scheme`
requires one. `Info.plist` (outside `Sources/`, merged via
`GENERATE_INFOPLIST_FILE = YES`) carries the one load-bearing key:
`NSAppTransportSecurity > NSAllowsLocalNetworking` so cleartext `ws://`
to localhost is allowed.

If the pbxproj ever fights back, the fallback is assembling the bundle by
hand: `swiftc Sources/*.swift -sdk $(xcrun --show-sdk-path --sdk
iphonesimulator) -target arm64-apple-ios16.0-simulator -o PreviewHost`, plus a
minimal `Info.plist` in a `PreviewHost.app/` folder — `simctl install`
accepts unsigned simulator bundles.

## Wire protocol (versioned JSON over /ws/preview)

- server → app: `{ v: 1, type: "spec", activeScreenId, spec: ResolvedSpec }`
  — the WHOLE resolved spec every time (a few KB; no diffing keeps Swift dumb)
- server → app: `{ v: 1, type: "show_screen", screenId }`
- app → server: `{ type: "hello", client: "preview-host", version: 1 }`

`ResolvedSpec` (see `src/lib/uiResolve.ts`) arrives pre-resolved: concrete
RGBA colors, pixel sizes, SF Symbol names. The renderer is total — unknown
node kinds draw a labeled placeholder, malformed frames keep the last good
spec, and the socket reconnects with 0.5s→5s backoff.
