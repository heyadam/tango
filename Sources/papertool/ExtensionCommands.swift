import AppKit
import SwiftUI
import Foundation
import PaperEditor
import PaperEngine
import PaperModel

/// `papertool extension …`: checks an extension folder, and installs, lists and removes
/// extensions in the same place the app keeps them.
///
/// `--extensions <folder>` keeps them somewhere else, which leaves the app's own alone:
/// for trying things out, and for drawing the Extensions window with `window`.
func extensionCommand(_ arguments: [String]) {
    let installed = installedExtensions

    func read(_ path: String) -> PaperExtension {
        do {
            return try PaperExtension(contentsOf: URL(fileURLWithPath: path))
        } catch {
            fail(error.localizedDescription)
        }
    }

    func describe(_ package: PaperExtension) -> String {
        let manifest = package.manifest
        var lines = ["\(manifest.name) \(manifest.version)  (\(manifest.id))"]
        if let author = manifest.author, !author.isEmpty { lines.append("  by \(author)") }
        for patch in manifest.patches { lines.append("  patch  \(manifest.kind(of: patch))  \(patch.name)") }
        for view in manifest.views { lines.append("  view   \(manifest.kind(of: view))  \(view.name)") }
        for path in manifest.components { lines.append("  component  \(path)") }
        if !manifest.network.isEmpty { lines.append("  may contact: \(manifest.network.joined(separator: ", "))") }
        for secret in manifest.secrets {
            lines.append("  asks for a key: \(secret.name), sent only to \(secret.hosts.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    switch arguments.first {
    case "validate":
        guard arguments.count >= 2 else { fail("extension validate needs a folder") }
        let package = read(arguments[1])
        let problems = package.problems()
        guard problems.isEmpty else { fail(problems.joined(separator: "\n")) }
        print(describe(package))
        print("No problems found.")

    case "install":
        guard arguments.count >= 2 else { fail("extension install needs a folder") }
        let url = URL(fileURLWithPath: arguments[1])
        let package = read(arguments[1])
        let before = installed.installed(package.id)?.package.version
        do {
            let entry = try installed.install(package, from: url)
            print(describe(package))
            if let before, before != package.version {
                print("Updated from \(before).")
            } else {
                print(before == nil ? "Installed." : "Installed again.")
            }
            for problem in entry.problems { print("Problem: \(problem)") }
        } catch {
            fail("Could not install: \(error.localizedDescription)")
        }

    case "list":
        let store = installed
        if store.installed.isEmpty, store.broken.isEmpty { print("No extensions are installed.") }
        for entry in store.installed {
            print(describe(entry.package))
            if !entry.isEnabled { print("  switched off") }
            for problem in entry.problems { print("  problem: \(problem)") }
        }
        for item in store.broken { print("\(item.name): \(item.message)") }

    case "uninstall":
        guard arguments.count >= 2 else { fail("extension uninstall needs an id") }
        guard installed.installed(arguments[1]) != nil else { fail("No extension with the id \(arguments[1]) is installed.") }
        do {
            try installed.uninstall(arguments[1])
            print("Removed \(arguments[1]).")
        } catch {
            fail("Could not remove it: \(error.localizedDescription)")
        }

    case "new":
        // Writes a small working extension to start from: a patch and a drawn view.
        guard arguments.count >= 2 else { fail("extension new needs a name") }
        let name = arguments[1]
        let word = name.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !word.isEmpty else { fail("Give the extension a name with letters in it.") }
        let parent = arguments.count >= 3 && !arguments[2].hasPrefix("--") ? URL(fileURLWithPath: arguments[2]) : URL(fileURLWithPath: ".")
        let folder = parent.appendingPathComponent("\(name.filter { $0.isLetter || $0.isNumber }).\(PaperExtension.fileExtension)")
        guard !FileManager.default.fileExists(atPath: folder.path) else { fail("\(folder.path) is already there.") }
        do {
            for (path, text) in starter(name: name, id: "com.example.\(word)") {
                let file = folder.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: file)
            }
            let package = try PaperExtension(contentsOf: folder)
            guard package.problems().isEmpty else { fail(package.problems().joined(separator: "\n")) }
            print("Wrote \(folder.path)")
            print(describe(package))
            print("Next: papertool extension validate \(folder.path), then install it or link it in the app's Extensions window.")
        } catch {
            fail("Could not write the extension: \(error.localizedDescription)")
        }

    case "export-component":
        // Writes a component of a document into an extension's folder.
        guard arguments.count >= 4 else { fail("extension export-component needs a document, a component name and an extension folder") }
        do {
            let paths = try ExtensionStore.export(
                component: arguments[2], of: loadDocument(arguments[1]), to: URL(fileURLWithPath: arguments[3])
            )
            for path in paths { print("Wrote \(path)") }
            print("List under \"components\" in \(ExtensionManifest.fileName): \(paths.map { "\"\($0)\"" }.joined(separator: ", "))")
        } catch {
            fail(error.localizedDescription)
        }

    case "window":
        // Draws the Extensions window, or with --review the sheet that asks before
        // installing the extension in a folder.
        guard arguments.count >= 2 else { fail("extension window needs an output path") }
        let application = NSApplication.shared
        let appearance = NSAppearance(named: option("--appearance", in: arguments) == "light" ? .aqua : .darkAqua)!
        application.appearance = appearance
        installed.checkForUpdates()
        let host: NSView
        var size = CGSize(width: 900, height: 640)
        if let folder = option("--review", in: arguments) {
            size = CGSize(width: 540, height: 600)
            host = NSHostingView(rootView: ExtensionReviewSheet(
                package: read(folder), extensions: installed, fromDocument: arguments.contains("--from-document")
            ))
        } else {
            host = NSHostingView(rootView: ExtensionManagerView(
                extensions: installed, selected: option("--select", in: arguments) ?? installed.installed.first?.id
            ))
        }
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        spinRunLoop(0.6)
        host.layoutSubtreeIfNeeded()
        spinRunLoop(0.4)
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fail("Could not create bitmap") }
        appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
        writePNG(bitmap, to: arguments[1])

    default:
        fail("usage: papertool extension new <name> [folder] | validate <folder> | install <folder> | list | uninstall <id> | export-component <document> <component> <folder> | window <out.png>  [--extensions <folder>]")
    }
}


/// The files of a new extension: enough to see a patch and a view work, and to change.
func starter(name: String, id: String) -> [String: String] {
    let manifest = """
    {
      "format": 1,
      "id": "\(id)",
      "name": "\(name)",
      "version": "1.0.0",
      "author": "",
      "summary": "What \(name) adds, in a sentence.",
      "network": [],
      "secrets": [],
      "patches": [
        {
          "id": "double",
          "name": "Double",
          "category": "Math",
          "summary": "Twice a number.",
          "script": "patches/double.js",
          "inputs": [ { "id": "value", "type": "number", "default": 1 } ],
          "outputs": [ { "id": "result", "type": "number" } ]
        }
      ],
      "views": [
        {
          "id": "dot",
          "name": "Dot",
          "summary": "A filled circle.",
          "draw": "views/dot.js",
          "size": [80, 80],
          "inputs": [ { "id": "color", "type": "color", "default": "#007AFF" } ]
        }
      ],
      "components": []
    }
    """
    let patch = """
    // The ports declared in extension.json are in `inputs` and `outputs`.
    function evaluate(inputs, outputs, time) {
      outputs.result = inputs.value * 2;
    }
    """
    let view = """
    // `canvas` works like an HTML canvas. `size` is the view's size in points.
    function draw(canvas, inputs, size, time) {
      canvas.fillStyle = inputs.color;
      canvas.beginPath();
      canvas.arc(size.width / 2, size.height / 2, Math.min(size.width, size.height) / 2, 0, Math.PI * 2);
      canvas.fill();
    }
    """
    let readme = """
    # \(name)

    What this extension is for, and how to use what it adds.
    """
    return ["extension.json": manifest, "patches/double.js": patch, "views/dot.js": view, "README.md": readme]
}
