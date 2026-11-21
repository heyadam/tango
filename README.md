# tango

A native macOS app for designing interactive interfaces. Every view is a patch in a graph, next to the patches that give it behavior (gestures, springs, state, network requests, shaders, video), and a live Viewer plays the prototype as you build it.

- Several screens on a canvas, with flows between them (push, modal, fade, morph, swipe back)
- A shelf of iOS 26 controls, bars, rows and presentations, measured against real SwiftUI, with Liquid Glass as a shader
- A built-in assistant, and an MCP server so Claude Code, Codex or any MCP client can build and test prototypes
- Extensions: your own patches, views and components in sandboxed JavaScript, Metal and JSON

## Build

Requires Xcode 27, Swift 6.2, macOS 26 and `brew install xcodegen`. The assistant also needs Node.js 18 or later.

```bash
swift test
xcodegen generate
xcodebuild -project Tango.xcodeproj -scheme Tango -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Tango.app
```

`Examples/` holds sample documents; `swift run papertool` drives the same code without a window.

## Where to read more

- `tango-product-spec.md`: what the product is for
- `AGENTS.md`: how the code is laid out and how it works
- `Extensions/README.md`: writing an extension
- `Integrations/claude-code`: a Claude Code plugin for sketching screens from code

## License

MIT
