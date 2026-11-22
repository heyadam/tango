import AppKit
import PaperEditor
import PaperEngine
import PaperLink
import PaperModel
import SwiftUI

// Command-line companion: writes the example documents, exports a document as JSON, and
// renders snapshots of the Viewer or the whole editor window without showing a window.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadDocument(_ name: String) -> DocumentPackage {
    if let item = Gallery.item(name) { return item.package() }
    switch name {
    case "empty": return DocumentPackage(document: .blank())
    default:
        do {
            return try DocumentPackage(contentsOf: URL(fileURLWithPath: name))
        } catch {
            fail("Could not open \(name): \(error)")
        }
    }
}

/// A store that runs with the extensions installed on this Mac, and knows the ports of
/// those the document only carries a copy of.
func makeStore(_ package: DocumentPackage) -> DocumentStore {
    DocumentStore(package: package, registry: installedExtensions.registry(carrying: package.carried))
}

/// The extensions papertool works with: the app's own, or with `--extensions <folder>`
/// those kept in another folder, which leaves the app's alone.
let installedExtensions: ExtensionStore = {
    guard let index = CommandLine.arguments.firstIndex(of: "--extensions"), index + 1 < CommandLine.arguments.count else { return .shared }
    return ExtensionStore(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
}()

func writePNG(_ bitmap: NSBitmapImageRep, to path: String) {
    guard let data = bitmap.representation(using: .png, properties: [:]) else { fail("Could not encode PNG") }
    do {
        try data.write(to: URL(fileURLWithPath: path))
        print("Wrote \(path)")
    } catch {
        fail("Could not write \(path): \(error)")
    }
}

func option(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func spinRunLoop(_ seconds: Double) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("""
    usage:
      papertool examples <directory>
      papertool sample-video <out.mov>
      papertool json <document>
      papertool link <document> [--port n] [--edit "<text>"]
      papertool viewer <document> <out.png> [--tap x,y] [--seconds t]
      papertool record <document> <out.mov> [--tap x,y] [--seconds t] [--no-touches]
      papertool record <document> out.mov --replay '<steps as JSON>'
      papertool editor <document> out.png --assistant "<request>" [--chat "<earlier chat>"] [--attach picture-or-video,…] [--queue "<request>"]
      papertool assistant <document> "<request>" [--out result.tango] [--model fable|opus|sonnet|haiku] [--effort low|medium|high|xhigh|max] [--attach picture-or-video,…]
      papertool editor <document> <out.png> [--width w] [--height h] [--select-layer name] [--select-patch name]
      papertool extension validate <folder> | install <folder> | list | uninstall <id>
      papertool redline <pictures of the real thing> <out folder> [case…] | redline --cases | redline --motions
      papertool redline-motion <recordings of the real thing> <out folder> [case…] [--dark]
    <document> is a .tango path, "empty", or a gallery id: \(Gallery.items.map(\.id).joined(separator: ", "))
    """)
}

switch command {
case "examples":
    guard arguments.count >= 2 else { fail("examples needs a directory") }
    let directory = URL(fileURLWithPath: arguments[1])
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let examples = Gallery.items.map { ($0.fileName, $0.package()) }
    for (name, package) in examples {
        let url = directory.appendingPathComponent("\(name).\(DocumentPackage.fileExtension)")
        do {
            try package.write(to: url)
            print("Wrote \(url.path)")
        } catch {
            fail("Could not write \(url.path): \(error)")
        }
    }

case "sample-video":
    // The clip the Video Scrubbing pattern plays, kept in Sources/PaperEngine/Media.
    guard arguments.count >= 2 else { fail("sample-video needs an output path") }
    let url = URL(fileURLWithPath: arguments[1])
    Task { @MainActor in
        do {
            try await SampleVideo.write(to: url)
            print("Wrote \(url.path)")
            exit(0)
        } catch {
            fail("Could not write \(url.path): \(error)")
        }
    }
    RunLoop.main.run()

case "extension":
    extensionCommand(Array(arguments.dropFirst()))

case "redline":
    // The shelf against real SwiftUI: `Reference/run.sh` takes the pictures and calls this.
    if arguments.dropFirst().first == "--cases" {
        print(ReferenceCase.all.map(\.id).joined(separator: "\n"))
        break
    }
    if arguments.dropFirst().first == "--motions" {
        print(ReferenceMotion.all.map(\.id).joined(separator: "\n"))
        break
    }
    guard arguments.count >= 3 else { fail("redline needs the folder of pictures and a folder to write to") }
    do {
        let out = URL(fileURLWithPath: arguments[2])
        let cases = arguments.dropFirst(3).filter { $0 != "--dark" }
        print(try Redline.run(shots: URL(fileURLWithPath: arguments[1]), out: out, only: Set(cases), dark: arguments.contains("--dark")))
        print("\nWrote \(out.appendingPathComponent("report.md").path)")
    } catch {
        fail("Could not compare: \(error)")
    }

case "redline-motion":
    // The shelf's motion against real SwiftUI: `REFERENCE_MOTION=1 Reference/run.sh` records
    // the simulator and calls this.
    guard arguments.count >= 3 else { fail("redline-motion needs the folder of recordings and a folder to write to") }
    _ = NSApplication.shared
    do {
        let out = URL(fileURLWithPath: arguments[2])
        let cases = arguments.dropFirst(3).filter { $0 != "--dark" }
        print(try Redline.runMotion(videos: URL(fileURLWithPath: arguments[1]), out: out, only: Set(cases), dark: arguments.contains("--dark")))
        print("\nWrote \(out.appendingPathComponent("report.md").path)")
    } catch {
        fail("Could not compare: \(error)")
    }

case "glassfit":
    // Fits the glass shader's inputs to iOS 26's glass: `Reference/run.sh glass-checker
    // glass-stripes glass-circle` takes the pictures. Give each input to fit as
    // name=start:step (tint is tintLevel and tintAlpha); the rest keep the shader's own.
    guard arguments.count >= 3 else { fail("glassfit needs the folder of pictures and inputs, as blur=30:4") }
    _ = NSApplication.shared
    let shots = URL(fileURLWithPath: arguments[1])
    var values: [String: Double] = [:], steps: [String: Double] = [:]
    let darkFit = arguments.contains("--dark")
    for spec in arguments.dropFirst(2) where spec != "--dark" {
        let parts = spec.split(separator: "="), numbers = parts.count == 2 ? parts[1].split(separator: ":").compactMap { Double($0) } : []
        guard numbers.count == 2 else { fail("\(spec) is not name=start:step") }
        values[String(parts[0])] = numbers[0]; steps[String(parts[0])] = numbers[1]
    }
    func inputs(_ values: [String: Double]) -> [String: Value] {
        var made: [String: Value] = [:]
        for (name, value) in values where name != "tintLevel" && name != "tintAlpha" { made[name] = .number(value) }
        if values["tintLevel"] != nil || values["tintAlpha"] != nil {
            let start = darkFit ? SystemStyle.glassTint.dark : SystemStyle.glassTint.light
            made["tint"] = .color(ColorValue(red: values["tintLevel"] ?? start.red, green: values["tintLevel"] ?? start.green, blue: values["tintLevel"] ?? start.blue, alpha: values["tintAlpha"] ?? start.alpha))
        }
        return made
    }
    func error(_ values: [String: Double]) -> Double { Redline.glassError(shots: shots, inputs: inputs(values), dark: darkFit) ?? .infinity }
    var best = error(values)
    print(String(format: "start %.2f", best))
    for _ in 0..<6 {
        var moved = false
        for name in values.keys.sorted() {
            for direction in [1.0, -1.0] {
                while true {
                    var trial = values
                    trial[name]! += direction * steps[name]!
                    let score = error(trial)
                    guard score < best - 0.005 else { break }
                    best = score; values = trial; moved = true
                }
            }
        }
        print(String(format: "%.2f  ", best) + values.keys.sorted().map { String(format: "%@=%.3f", $0, values[$0]!) }.joined(separator: " "))
        if !moved { for name in steps.keys { steps[name]! /= 2 } }
    }

case "link":
    // Sends a document to a player, as the app's Play on iPhone does, on this Mac only:
    // nothing is advertised, and the player is told where to connect.
    guard arguments.count >= 2 else { fail("link needs a document") }
    setvbuf(stdout, nil, _IOLBF, 0)
    var port: UInt16 = 47900
    var edits: String?
    var index = 2
    while index < arguments.count {
        if arguments[index] == "--port", index + 1 < arguments.count { port = UInt16(arguments[index + 1]) ?? port; index += 1 }
        if arguments[index] == "--edit", index + 1 < arguments.count { edits = arguments[index + 1]; index += 1 }
        index += 1
    }
    var package = loadDocument(arguments[1])
    let link = DeviceLink(keys: MemoryLinkKeyStore(), advertises: false, port: port)
    link.isEnabled = true
    spinRunLoop(0.3)
    guard case .listening = link.state, let key = link.key else { fail("Could not listen on port \(port): \(link.state)") }
    print("Listening. Start the player with:  -linkkey \(key.text) -linkhost 127.0.0.1:\(port)")
    var shown: Int?
    var edited = false
    while true {
        spinRunLoop(0.1)
        // A phone that connects gets the document; `publish` does nothing until one has.
        if let phone = link.phones.first, phone.shows == nil, shown == nil {
            link.publish(.init(prototype: "papertool", name: arguments[1], package: package))
        }
        if let phone = link.phones.first, phone.shows != shown {
            shown = phone.shows
            print("\(phone.name) shows revision \(shown ?? 0)\(phone.notice.map { " (\($0))" } ?? "")")
            // `--edit <text>` retypes the first text view three seconds later, to see an edit arrive.
            if let edits, !edited {
                edited = true
                spinRunLoop(3)
                func firstText(in layer: Layer) -> LayerID? {
                    if layer.kind == .text { return layer.id }
                    for child in layer.children { if let found = firstText(in: child) { return found } }
                    return nil
                }
                if let id = firstText(in: package.document.screen) {
                    package.document.screen.update(id) { $0.set(.text, .text(edits)) }
                    link.publish(.init(prototype: "papertool", name: arguments[1], package: package))
                }
            }
        }
        if link.phones.isEmpty { shown = nil }
    }

case "json":
    guard arguments.count >= 2 else { fail("json needs a document") }
    do {
        let data = try loadDocument(arguments[1]).document.encoded()
        FileHandle.standardOutput.write(data)
        print("")
    } catch {
        fail("Could not encode: \(error)")
    }

case "viewer":
    guard arguments.count >= 3 else { fail("viewer needs a document and an output path") }
    _ = NSApplication.shared
    let package = loadDocument(arguments[1])
    var tap: Point2?
    if let text = option("--tap", in: arguments) {
        let parts = text.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { fail("--tap expects x,y") }
        tap = Point2(x: parts[0], y: parts[1])
    }
    let seconds = option("--seconds", in: arguments).flatMap(Double.init) ?? 0
    guard let bitmap = ViewerSnapshot.bitmap(
        of: package.document, assets: package.assets, registry: installedExtensions.registry(carrying: package.carried), tap: tap, seconds: seconds, margin: 16, scale: 2
    ) else { fail("Could not create bitmap") }
    writePNG(bitmap, to: arguments[2])

case "record":
    guard arguments.count >= 3 else { fail("record needs a document and an output path") }
    _ = NSApplication.shared
    let store = makeStore(loadDocument(arguments[1]))
    let screen = store.document.screen.value(.size).sizeValue
    let view = ViewerView(store: store)
    view.fillsWindow = true
    view.frame = CGRect(x: 0, y: 0, width: screen.width, height: screen.height)
    view.layoutSubtreeIfNeeded()
    let movie = URL(fileURLWithPath: arguments[2])
    do {
        try view.startRecording(to: movie, wallClock: false, touches: !arguments.contains("--no-touches"))
    } catch { fail("Could not record: \(error)") }
    view.advance(by: 1.0 / 60.0)
    if let tap = option("--tap", in: arguments) {
        let parts = tap.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { fail("--tap expects x,y") }
        view.tap(at: Point2(x: parts[0], y: parts[1]))
    }
    // --replay takes the steps of `interact_prototype` as JSON and plays them the way the
    // Viewer shows the assistant using the prototype.
    if let text = option("--replay", in: arguments) {
        guard let steps = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else {
            fail("--replay expects a JSON array of steps")
        }
        let result = AssistantToolbox(store: store).call("interact_prototype", input: ["steps": steps])
        if result.isError { fail(result.text) }
        var frames = 0
        while view.isReplaying, frames < 60 * 90 {
            view.advance(by: 1.0 / 60.0)
            frames += 1
        }
    }
    var left = option("--seconds", in: arguments).flatMap(Double.init) ?? 1
    while left > 0 {
        view.advance(by: 1.0 / 60.0)
        left -= 1.0 / 60.0
    }
    let done = DispatchSemaphore(value: 0)
    Task { @MainActor in
        if await view.stopRecording() == nil { fail("Could not finish the movie") }
        print("Wrote \(movie.path)")
        exit(0)
    }
    RunLoop.main.run()
    done.wait()

case "editor":
    guard arguments.count >= 3 else { fail("editor needs a document and an output path") }
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    // One appearance for everything drawn, or system colors come out half light, half dark.
    let appearance = NSAppearance(named: option("--appearance", in: arguments) == "light" ? .aqua : .darkAqua)!
    application.appearance = appearance
    let width = option("--width", in: arguments).flatMap(Double.init) ?? 1440
    let height = option("--height", in: arguments).flatMap(Double.init) ?? 900
    let store = makeStore(loadDocument(arguments[1]))
    if let name = option("--select-layer", in: arguments),
       let layer = store.document.screen.flattened.first(where: { $0.name == name }) {
        store.selectedLayers = [layer.id]
    }
    if let name = option("--select-patch", in: arguments),
       let node = store.document.graph.nodes.first(where: { store.title(for: $0) == name }) {
        store.selectedNodes = [node.id]
    }
    // The Canvas above the graph: every screen side by side, with the flows between them.
    store.showsCanvas = arguments.contains("--canvas")
    // Opens the code of the selected shader view under the graph.
    if arguments.contains("--shader-code"), let layer = store.selectedLayer, layer.shader != nil {
        store.editingShader = layer.id
    }
    // Shows the Assistant with a conversation played by a stand-in for Claude, what is
    // selected held as references, and --attach files in the composer.
    var chats: AssistantChats?
    if let request = option("--assistant", in: arguments) {
        let all = AssistantChats(store: store) { RehearsedTransport() }
        chats = all
        store.sidebarMode = .assistant
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            // --chat is an earlier chat, finished out of sight, beside the one shown.
            if let other = option("--chat", in: arguments) {
                await all.current.send(other)
                while all.current.isWorking { try? await Task.sleep(for: .milliseconds(20)) }
                all.newChat()
            }
            let made = all.current
            if !store.selectedNodes.isEmpty { store.addToAssistant() }
            await made.send(request)
            while made.isWorking { try? await Task.sleep(for: .milliseconds(20)) }
            if !store.selectedNodes.isEmpty { store.addToAssistant() }
            if let attached = option("--attach", in: arguments) {
                await made.attach(attached.split(separator: ",").map { URL(fileURLWithPath: String($0)) })
            }
            if let queued = option("--queue", in: arguments) {
                await made.send("Now check it once more")
                await made.send(queued)
            }
            done.signal()
        }
        while done.wait(timeout: .now()) == .timedOut { spinRunLoop(0.05) }
    }
    let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false
    )
    let host = NSHostingView(rootView: EditorView(store: store, assistant: chats, extensions: installedExtensions))
    host.frame = CGRect(x: 0, y: 0, width: width, height: height)
    window.contentView = host
    window.setFrameOrigin(CGPoint(x: -10000, y: -10000))
    window.orderBack(nil)
    spinRunLoop(0.6)
    host.layoutSubtreeIfNeeded()
    spinRunLoop(0.4)
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fail("Could not create bitmap") }
    appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
    writePNG(bitmap, to: arguments[2])

case "assistant":
    // One request to the assistant without the app: prints the conversation and, with
    // --out, saves what it built. Uses the Claude login on this Mac.
    guard arguments.count >= 3 else { fail("assistant needs a document and a request") }
    _ = NSApplication.shared
    let store = makeStore(loadDocument(arguments[1]))
    let session = AssistantSession(store: store)
    if let model = option("--model", in: arguments).flatMap(AssistantSession.Model.init(named:)) { session.model = model }
    if let effort = option("--effort", in: arguments).flatMap(AssistantSession.Effort.init(rawValue:)) { session.effort = effort }
    var printed = 0
    var lastStatus = ""
    func printNew() {
        // The last entry may still be growing, so hold it back until the turn is over.
        let ready = session.isWorking ? max(session.entries.count - 1, printed) : session.entries.count
        for entry in session.entries[printed..<ready] {
            switch entry.kind {
            case .user: print("> \(entry.text)")
            case .assistant: print(entry.text)
            case .action: print("  * \(entry.text)")
            case .problem, .signIn: print("  ! \(entry.text)")
            case .notice, .changes: print("  - \(entry.text)")
            }
            if let timing = entry.timing { print("  ⏱ \(timing)") }
        }
        printed = ready
        // What the status line says, with what the document holds at that moment, so a run
        // shows the prototype being built while the model writes.
        if session.isWorking, session.status != lastStatus {
            lastStatus = session.status
            let views = store.document.screen.flattened.count - 1
            print("  … \(session.status.isEmpty ? "Working…" : session.status)  [\(views) views, \(store.document.graph.patches.count) patches]")
        }
    }
    Task { @MainActor in
        // --attach takes pictures and videos, separated by commas.
        if let attached = option("--attach", in: arguments) {
            await session.attach(attached.split(separator: ",").map { URL(fileURLWithPath: String($0)) })
            if let problem = session.composerNotice { fail(problem) }
        }
        await session.send(arguments[2])
        while session.isWorking {
            printNew()
            try? await Task.sleep(for: .milliseconds(100))
        }
        printNew()
        if let out = option("--out", in: arguments) {
            do {
                try store.package.write(to: URL(fileURLWithPath: out))
                print("Wrote \(out)")
            } catch {
                fail("Could not write \(out): \(error)")
            }
        }
        exit(session.entries.contains { $0.kind == .signIn } ? 2 : 0)
    }
    RunLoop.main.run()

default:
    fail("Unknown command \(command)")
}


/// Plays Claude's side of a conversation for `editor --assistant`: it reads the document,
/// nudges the first view, looks at the prototype and answers. Nothing leaves the Mac.
final class RehearsedTransport: AssistantTransport {
    var onMessage: (([String: Any]) -> Void)?
    var onClose: ((String?) -> Void)?
    private var turns = 0

    func start(progress: @escaping (String) -> Void) async throws {}
    func stop() {}

    func send(_ message: [String: Any]) {
        guard message["type"] as? String == "user" else { return }
        turns += 1
        // The second message is left unanswered, so the picture shows an answer in progress.
        guard turns == 1 else { return }
        let answer = """
        ## What I changed
        The card now opens **a little slower** and settles without a bounce.

        - Lowered the spring's `tension`
        1. Tap the card to try it
        2. Undo below if it is too slow

        ```
        spring.tension = 120
        ```
        """
        DispatchQueue.main.async { [self] in
            onMessage?(["type": "model", "model": "claude-opus-5-5"])
            onMessage?(["type": "tool_call", "id": "1", "name": "get_document", "input": [:]])
            onMessage?(["type": "tool_call", "id": "2", "name": "edit_document", "input": ["operations": [
                ["op": "add_view", "kind": "text", "name": "Caption", "properties": ["text": "Hello", "x": 40, "y": 80]],
            ]]])
            onMessage?(["type": "tool_call", "id": "3", "name": "view_prototype", "input": [:]])
            onMessage?(["type": "text", "delta": answer])
            onMessage?(["type": "done"])
        }
    }
}
