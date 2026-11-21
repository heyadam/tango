import AppKit
import PaperEngine
import PaperModel
import SwiftUI

/// The Viewer as a window of its own: a small resizable panel that floats above the
/// editor and shows nothing but the running prototype.
///
/// It is deliberately not a child window of the document window. A child window is moved
/// by the app, in step with its parent, which makes dragging it stutter whenever the app
/// is busy drawing; an independent floating panel is moved by the system.
final class ViewerPanelController: NSObject, NSWindowDelegate {
    private let store: DocumentStore
    private let viewer: ViewerView
    private let panel: NSPanel
    private weak var host: NSWindow?
    private var wantsShown = true
    private var artboardSize = Size2(width: 390, height: 844)
    private var hasPlaced = false

    private static let autosaveName = "TangoViewer"

    init(store: DocumentStore, keys: ExtensionKeys? = nil) {
        self.store = store
        viewer = ViewerView(store: store)
        // The Viewer the person watches is the one whose requests may carry their keys.
        viewer.keyLookup = keys?.lookup
        viewer.fillsWindow = true
        viewer.usesDevice = true
        panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 650),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: true
        )
        super.init()
        panel.title = "Viewer"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = false
        panel.contentView = viewer
        panel.delegate = self

        // Restart sits in the title bar, as a standard accessory.
        let restart = NSHostingView(rootView: ViewerTitleControls(store: store) { [weak self] in
            self?.toggleRecording()
        })
        restart.frame.size = restart.fittingSize
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = restart
        accessory.layoutAttribute = .trailing
        panel.addTitlebarAccessoryViewController(accessory)
        applyAspect(resize: true)
    }

    func update(document: PaperModel.Document, restartToken: Int, shown: Bool) {
        viewer.update(document: document, restartToken: restartToken)
        let size = document.screen.value(.size).sizeValue
        if size != artboardSize, size.width > 0, size.height > 0 {
            artboardSize = size
            applyAspect(resize: true)
        }
        wantsShown = shown
        syncVisibility()
    }

    /// Starts a recording, or stops the one in progress and asks where to keep it.
    func toggleRecording() {
        if viewer.isRecording {
            store.isRecording = false
            Task { @MainActor [viewer, panel] in
                guard let movie = await viewer.stopRecording() else {
                    NSSound.beep()
                    return
                }
                let save = NSSavePanel()
                save.allowedContentTypes = [.quickTimeMovie]
                save.nameFieldStringValue = "Prototype.mov"
                // A window of its own: the Viewer is too narrow to hold a save sheet.
                _ = panel
                save.begin { response in
                    if response == .OK, let destination = save.url {
                        try? FileManager.default.removeItem(at: destination)
                        try? FileManager.default.moveItem(at: movie, to: destination)
                    } else {
                        try? FileManager.default.removeItem(at: movie)
                    }
                }
            }
        } else {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Recording-\(UUID().uuidString.prefix(8)).mov")
            do {
                try viewer.startRecording(to: url)
                store.isRecording = true
            } catch {
                NSSound.beep()
            }
        }
    }

    /// Called when the document window appears, changes or goes away.
    func hostChanged(_ window: NSWindow?) {
        let center = NotificationCenter.default
        if let old = host { center.removeObserver(self, name: nil, object: old) }
        host = window
        if window?.isMainWindow == true || DocumentStore.current == nil { DocumentStore.current = store }
        if let window {
            // The Viewer belongs to one document: it shows while that document's window
            // is the one being worked in.
            for name in [
                NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
                NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                NSWindow.willCloseNotification,
            ] {
                center.addObserver(self, selector: #selector(hostStateChanged), name: name, object: window)
            }
        }
        syncVisibility()
    }

    @objc private func hostStateChanged(_ notification: Notification) {
        if notification.name == NSWindow.didBecomeMainNotification { DocumentStore.current = store }
        if notification.name == NSWindow.willCloseNotification {
            panel.orderOut(nil)
            return
        }
        // Let the change of main window finish before looking at it.
        DispatchQueue.main.async { [weak self] in self?.syncVisibility() }
    }

    func close() {
        NotificationCenter.default.removeObserver(self)
        panel.delegate = nil
        panel.orderOut(nil)
    }

    /// The window keeps the screen's proportions, so the prototype always fills it.
    private func applyAspect(resize: Bool) {
        let ratio = artboardSize.height / artboardSize.width
        panel.contentAspectRatio = NSSize(width: artboardSize.width, height: artboardSize.height)
        panel.contentMinSize = NSSize(width: 140, height: 140 * ratio)
        guard resize else { return }
        let width = panel.contentLayoutRect.width > 0 ? panel.contentLayoutRect.width : 300
        let top = panel.frame.maxY
        panel.setContentSize(NSSize(width: width, height: (width * ratio).rounded()))
        if hasPlaced { panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top)) }
    }

    private func place(over host: NSWindow) {
        guard !hasPlaced else { return }
        hasPlaced = true
        if panel.setFrameUsingName(Self.autosaveName) {
            applyAspect(resize: true)
        } else {
            // First time: as tall as fits, toward the right of the document window.
            let ratio = artboardSize.height / artboardSize.width
            let height = min(650, host.frame.height - 140)
            panel.setContentSize(NSSize(width: (height / ratio).rounded(), height: height))
            panel.setFrameOrigin(NSPoint(
                x: host.frame.maxX - panel.frame.width - 330,
                y: host.frame.midY - panel.frame.height / 2 - 20
            ))
        }
        panel.setFrameAutosaveName(Self.autosaveName)
    }

    private func syncVisibility() {
        guard let host, wantsShown, !host.isMiniaturized else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        guard host.isVisible else {
            DispatchQueue.main.async { [weak self] in self?.syncVisibility() }
            return
        }
        // Another document in front has its own Viewer.
        let mainWindow = NSApp.mainWindow
        if let mainWindow, mainWindow !== host {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        place(over: host)
        if !panel.isVisible { panel.orderFront(nil) }
    }

    func windowWillClose(_ notification: Notification) {
        store.showsViewer = false
    }
}

/// The controls in the Viewer's title bar: record and restart.
struct ViewerTitleControls: View {
    let store: DocumentStore
    let toggleRecording: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(store.isRecording ? "Stop Recording" : "Record", systemImage: store.isRecording ? "stop.circle.fill" : "record.circle") {
                toggleRecording()
            }
            .foregroundStyle(store.isRecording ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .help(store.isRecording ? "Stop and save the recording" : "Record the prototype as a movie")
            Button("Restart", systemImage: "arrow.counterclockwise") { store.restartPrototype() }
                .help("Restart the prototype")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
    }
}

/// Ties a Viewer window to the document window this view sits in.
struct ViewerWindowBridge: NSViewRepresentable {
    let store: DocumentStore
    let document: PaperModel.Document
    let restartToken: Int
    let shown: Bool
    var keys: ExtensionKeys?

    final class Anchor: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }

    func makeCoordinator() -> ViewerPanelController { ViewerPanelController(store: store, keys: keys) }

    func makeNSView(context: Context) -> Anchor {
        let anchor = Anchor()
        let controller = context.coordinator
        anchor.onWindow = { [weak controller] window in controller?.hostChanged(window) }
        return anchor
    }

    func updateNSView(_ anchor: Anchor, context: Context) {
        context.coordinator.update(document: document, restartToken: restartToken, shown: shown)
    }

    static func dismantleNSView(_ anchor: Anchor, coordinator: ViewerPanelController) {
        coordinator.close()
    }
}
