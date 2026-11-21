import AppKit
import Combine
import PaperEngine
import PaperModel
import SwiftUI

/// The window Tango opens with, in place of the Open panel a document app shows at launch:
/// what to start (a new prototype, an example, a file) on the left, and on the right the
/// prototypes opened lately, each with a picture of its first screen. With nothing opened yet
/// the right side offers a few examples instead. It closes itself once a document is in front.
/// Window > Welcome to Tango (Shift-Command-1) brings it back.
struct WelcomeView: View {
    static let windowID = "welcome"
    /// Shown on the right while nothing has been opened yet.
    static let featuredExamples = ["card", "flow", "kit", "morph", "sheet"]

    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @State private var recents: [WelcomeRecent] = []
    @State private var selection: WelcomeEntry.ID?

    var body: some View {
        HStack(spacing: 0) {
            start
                .frame(width: 420)
            Divider()
            list
                .frame(width: 340)
        }
        .frame(height: 460)
        .onAppear(perform: reload)
        // Recents change while the window is away (a document opened from the Finder).
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification))) { note in
            guard let window = note.object as? NSWindow else { return }
            if window.windowController?.document != nil {
                // A document is in front: this window has done its job.
                dismissWindow(id: Self.windowID)
            } else if window.identifier?.rawValue.hasPrefix(Self.windowID) == true {
                reload()
            }
        }
    }

    // MARK: Start

    private var start: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 36)
            WelcomeMark()
                .frame(width: 104, height: 104)
            Text("Tango")
                .font(.system(size: 34, weight: .bold))
                .padding(.top, 18)
            Text("Version \(Self.version)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Spacer(minLength: 32)
            VStack(spacing: 4) {
                WelcomeAction(
                    symbol: "plus.rectangle.portrait", title: "New Prototype",
                    detail: "Start from an empty iPhone screen", shortcut: "⌘N"
                ) {
                    NSDocumentController.shared.newDocument(nil)
                    dismissWindow(id: Self.windowID)
                }
                WelcomeAction(
                    symbol: "square.grid.2x2", title: "Start from an Example",
                    detail: "Take apart a prototype or pattern", shortcut: "⇧⌘N"
                ) {
                    openWindow(id: GalleryView.windowID)
                    dismissWindow(id: Self.windowID)
                }
                WelcomeAction(
                    symbol: "folder", title: "Open…",
                    detail: "Find a prototype on this Mac", shortcut: "⌘O"
                ) { NSDocumentController.shared.openDocument(nil) }
            }
            .padding(.horizontal, 40)
            Spacer(minLength: 36)
        }
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }

    // MARK: Recents, or examples

    private var entries: [WelcomeEntry] {
        if !recents.isEmpty { return recents.map(WelcomeEntry.recent) }
        return Self.featuredExamples.compactMap { id in Gallery.items.first { $0.id == id } }.map(WelcomeEntry.example)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(recents.isEmpty ? "Try an Example" : "Recent")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 6)
            List(entries, selection: $selection) { entry in
                WelcomeRow(entry: entry)
                    .tag(entry.id)
                    .contextMenu {
                        if case .recent(let recent) = entry {
                            Button("Open") { open(entry) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([recent.url]) }
                        }
                    }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: WelcomeEntry.ID.self) { _ in } primaryAction: { ids in
                ids.compactMap { id in entries.first { $0.id == id } }.forEach(open)
            }
            .onKeyPress(.return) {
                guard let id = selection, let entry = entries.first(where: { $0.id == id }) else { return .ignored }
                open(entry)
                return .handled
            }
            if recents.isEmpty {
                Text("Your prototypes will be listed here once you open one.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(20)
            } else {
                HStack {
                    Spacer()
                    Button("Clear Recents") {
                        NSDocumentController.shared.clearRecentDocuments(nil)
                        reload()
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .background(.quinary.opacity(0.6))
    }

    private func reload() {
        recents = WelcomeRecent.list(NSDocumentController.shared.recentDocumentURLs)
    }

    private func open(_ entry: WelcomeEntry) {
        switch entry {
        case .recent(let recent):
            NSDocumentController.shared.openDocument(withContentsOf: recent.url, display: true) { document, _, error in
                if let error { NSApp.presentError(error) }
                if document != nil { dismissWindow(id: Self.windowID) } else { reload() }
            }
        case .example(let item):
            GalleryView.open(item)
            dismissWindow(id: Self.windowID)
        }
    }
}

// MARK: - Model

/// A prototype opened lately, as the list shows it.
struct WelcomeRecent: Hashable {
    let url: URL
    let name: String
    /// Where it is, with the home folder as "~".
    let folder: String
    let modified: Date?

    /// The recent documents that are Tango files and still there, newest first as the
    /// document controller keeps them.
    static func list(
        _ urls: [URL], home: String = NSHomeDirectory(), exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        modified: (URL) -> Date? = { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
    ) -> [WelcomeRecent] {
        var seen: Set<String> = []
        return urls.compactMap { url in
            let url = url.standardizedFileURL
            guard url.pathExtension == DocumentPackage.fileExtension, exists(url), seen.insert(url.path).inserted else { return nil }
            // Copies the gallery opened live in a temporary folder; they are not anyone's work.
            if url.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path) { return nil }
            return WelcomeRecent(
                url: url, name: url.deletingPathExtension().lastPathComponent,
                folder: abbreviated(url.deletingLastPathComponent().path, home: home), modified: modified(url)
            )
        }
    }

    static func abbreviated(_ path: String, home: String) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

enum WelcomeEntry: Identifiable, Hashable {
    case recent(WelcomeRecent)
    case example(GalleryItem)

    var id: String {
        switch self {
        case .recent(let recent): "file:" + recent.url.path
        case .example(let item): "example:" + item.id
        }
    }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Pieces

/// The app's mark: a tile with three patches cabled together.
struct WelcomeMark: View {
    var body: some View {
        GeometryReader { proxy in
            let side = proxy.size.width
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(red: 1.0, green: 0.42, blue: 0.36), Color(red: 0.86, green: 0.18, blue: 0.47)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    .font(.system(size: side * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            }
            .shadow(color: Color(red: 0.86, green: 0.18, blue: 0.47).opacity(0.35), radius: 14, y: 6)
        }
        .accessibilityHidden(true)
    }
}

/// One of the three things to start, as a wide row that lights up under the pointer.
struct WelcomeAction: View {
    let symbol: String
    let title: String
    let detail: String
    let shortcut: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.semibold))
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text(shortcut)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.primary.opacity(hovering ? 0.07 : 0))
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityHint(detail)
    }
}

/// A recent prototype or an example: a picture of its first screen, its name, and where it is.
struct WelcomeRow: View {
    let entry: WelcomeEntry
    @State private var picture: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let picture {
                    Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 30, height: 56)
            .clipShape(.rect(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 3)
        .help(help)
        .task(id: entry.id) { picture = await WelcomeThumbnails.shared.picture(for: entry) }
    }

    private var title: String {
        switch entry {
        case .recent(let recent): recent.name
        case .example(let item): item.title
        }
    }

    private var subtitle: String {
        switch entry {
        case .recent(let recent):
            if let date = recent.modified { "\(recent.folder) · \(date.formatted(.relative(presentation: .named)))" } else { recent.folder }
        case .example(let item): item.summary
        }
    }

    private var help: String {
        switch entry {
        case .recent(let recent): recent.url.path
        case .example(let item): "Open a copy of \(item.title)"
        }
    }
}

/// Pictures of first screens, made once each, one at a time so the window stays responsive.
@MainActor final class WelcomeThumbnails {
    static let shared = WelcomeThumbnails()
    private var cache: [String: NSImage] = [:]

    func picture(for entry: WelcomeEntry) async -> NSImage? {
        let key: String
        switch entry {
        case .recent(let recent): key = entry.id + "@" + String(recent.modified?.timeIntervalSince1970 ?? 0)
        case .example: key = entry.id
        }
        if let image = cache[key] { return image }
        await Task.yield()
        let package: DocumentPackage
        switch entry {
        case .recent(let recent):
            guard let read = try? DocumentPackage(contentsOf: recent.url) else { return nil }
            package = read
        case .example(let item):
            package = item.package()
        }
        guard let bitmap = ViewerSnapshot.bitmap(
            of: package.document, assets: package.assets,
            registry: ExtensionStore.shared.registry(carrying: package.carried)
        ) else { return nil }
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        cache[key] = image
        return image
    }
}
