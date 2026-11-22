#if os(iOS)
import AVFoundation
import Network
import PaperEngine
import PaperHost
import PaperLink
import PaperModel
import SwiftUI
import UIKit
import VisionKit

/// The player app: the Mac it is paired with, a list of prototypes, and one playing.
/// `Player/` is an `@main` around it.
public struct PlayerScene: Scene {
    public init() {}

    public var body: some Scene {
        WindowGroup {
            PlayerRoot()
        }
    }
}

/// What is playing: one of the gallery's examples, a kept prototype, or what the Mac sends.
/// One at a time, in one cover, so nothing is presented over something being dismissed.
struct Playing: Identifiable {
    enum Source: Equatable {
        case example, kept, live
    }

    let id: String
    let title: String
    let host: PrototypeHost
    let source: Source
}

struct PlayerRoot: View {
    @State private var store = PlayerStore(
        keys: KeychainLinkKeyStore(), deviceName: UIDevice.current.name, screen: UIScreen.main.bounds.size
    )
    @State private var library = PlayerLibrary()
    @State private var playing: Playing?
    @State private var pairs = false
    @Environment(\.scenePhase) private var scenePhase

    private func play(_ item: GalleryItem) {
        playing = Playing(id: "example:\(item.id)", title: item.title, host: PrototypeHost(package: item.package()), source: .example)
    }

    private func play(_ entry: PlayerLibrary.Entry) {
        guard let package = library.package(for: entry) else { return }
        playing = Playing(id: "kept:\(entry.id)", title: entry.name, host: PrototypeHost(package: package), source: .kept)
    }

    private func play(_ live: PlayerStore.Live) {
        playing = Playing(id: "live:\(live.id)", title: live.name, host: live.host, source: .live)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LinkRow(store: store) { pairs = true }
                    if let live = store.live {
                        Button("Play “\(live.name)”", systemImage: "play.fill") { play(live) }
                    }
                } header: {
                    Text("Your Mac")
                } footer: {
                    if let notice = store.notice ?? library.problem { Text(notice) }
                }
                if !library.entries.isEmpty {
                    Section("On This iPhone") {
                        ForEach(library.entries) { entry in
                            Button {
                                play(entry)
                            } label: {
                                LibraryRow(entry: entry, picture: library.pictureURL(entry.id))
                            }
                        }
                        .onDelete { offsets in
                            for entry in offsets.map({ library.entries[$0] }) { library.delete(entry) }
                        }
                    }
                }
                ForEach(GalleryItem.Section.allCases, id: \.self) { section in
                    Section(section.rawValue) {
                        ForEach(Gallery.items.filter { $0.section == section }) { item in
                            Button {
                                play(item)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).foregroundStyle(Color.primary)
                                    Text(item.summary).font(.footnote).foregroundStyle(Color.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("tango")
        }
        .sheet(isPresented: $pairs) {
            PairingSheet { key in
                store.pair(with: key)
                pairs = false
            }
        }
        .fullScreenCover(item: $playing) { playing in
            PlayingScreen(title: playing.title, host: playing.host) { self.playing = nil }
                .task { await tapIfAsked(playing) }
        }
        // Another prototype from the Mac comes up over whatever is playing. An edit to the
        // one already sent does not: closed, it stays closed, and its row brings it back.
        .onChange(of: store.live?.id) { _, id in
            if let live = store.live {
                pairs = false
                play(live)
            } else if playing?.source == .live {
                playing = nil
            }
        }
        // A .tango file from Files or AirDrop is kept, and played.
        .onOpenURL { url in
            if let entry = library.add(fileAt: url) { play(entry) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.resumeSearching() } else { library.flush() }
        }
        .task {
            store.received = { [library] update, package in library.received(update, package) }
            // `-example <gallery id>` opens that example at once, for pictures taken with `simctl`.
            if let item = UserDefaults.standard.string(forKey: "example").flatMap(Gallery.item) { play(item) }
            // `-linkkey <text of the code>` pairs without a camera, for the simulator.
            if let text = UserDefaults.standard.string(forKey: "linkkey"), let key = LinkKey(text: text) {
                store.pair(with: key)
            }
            // `-linkhost 127.0.0.1:47900` connects straight to `papertool link`, with no search.
            if let place = UserDefaults.standard.string(forKey: "linkhost")?.split(separator: ":"), place.count == 2,
               let port = NWEndpoint.Port(String(place[1])) {
                store.connect(to: .hostPort(host: NWEndpoint.Host(String(place[0])), port: port), name: "papertool")
            } else if UserDefaults.standard.string(forKey: "linkhost") == nil {
                store.startSearching()
            }
        }
    }

    /// `-tap x,y` taps an example a second after it opens: `simctl` can send no touch.
    private func tapIfAsked(_ playing: Playing) async {
        let parts = (UserDefaults.standard.string(forKey: "tap") ?? "").split(separator: ",").compactMap { Double($0) }
        guard playing.source == .example, parts.count == 2 else { return }
        let point = Point2(x: parts[0], y: parts[1])
        try? await Task.sleep(for: .seconds(1))
        playing.host.send(.touchBegan(id: 0, point))
        try? await Task.sleep(for: .milliseconds(60))
        playing.host.send(.touchEnded(id: 0, point))
    }
}

struct LibraryRow: View {
    let entry: PlayerLibrary.Entry
    let picture: URL

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image = UIImage(contentsOfFile: picture.path) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color(.secondarySystemFill)
                }
            }
            .frame(width: 44, height: 96)
            .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).foregroundStyle(Color.primary)
                Text(entry.saved, format: .relative(presentation: .named)).font(.footnote).foregroundStyle(Color.secondary)
            }
        }
    }
}

/// Where the link to the Mac stands, and the way to pair.
struct LinkRow: View {
    let store: PlayerStore
    let pair: () -> Void

    var body: some View {
        switch store.link {
        case .unpaired:
            Button("Pair with a Mac", systemImage: "qrcode.viewfinder", action: pair)
        case .searching:
            Label("Looking for your Mac…", systemImage: "wifi")
            Text("Turn on Play on iPhone in tango on the Mac, from the toolbar.").font(.footnote).foregroundStyle(.secondary)
            Button("Scan Another Code", systemImage: "qrcode.viewfinder", action: pair)
        case let .connecting(name):
            Label("Connecting to \(name)…", systemImage: "wifi")
        case let .connected(name):
            Label("Connected to \(name)", systemImage: "checkmark.circle.fill")
            Text("The prototype in tango's front window plays here.").font(.footnote).foregroundStyle(.secondary)
            Button("Forget This Mac", role: .destructive) { store.unpair() }
        }
    }
}

/// Scans the code a Mac shows. Where there is no camera to scan with, its text can be pasted.
struct PairingSheet: View {
    let paired: (LinkKey) -> Void
    @State private var text = ""
    /// Whether the camera may be used; nil until the person has answered.
    @State private var camera: Bool?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported, camera == true {
                    CodeScanner { found in
                        if let key = LinkKey(text: found) { paired(key) }
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .bottom) {
                        Text("In tango on the Mac, click the iPhone button in the toolbar and point the camera at the code.")
                            .font(.callout).multilineTextAlignment(.center).padding()
                            .background(.regularMaterial, in: .rect(cornerRadius: 16)).padding()
                    }
                } else if DataScannerViewController.isSupported, camera == nil {
                    ProgressView()
                } else {
                    Form {
                        Section {
                            TextField("tango-link:…", text: $text).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button("Pair") { if let key = LinkKey(text: text) { paired(key) } }
                                .disabled(LinkKey(text: text) == nil)
                        } footer: {
                            Text(DataScannerViewController.isSupported
                                ? "tango may not use the camera, so it cannot scan the code. Allow the camera in Settings, or paste the text of the code here."
                                : "This device cannot scan a code. Paste the text of the code instead.")
                        }
                    }
                }
            }
            // The scanner cannot start until the person has been asked about the camera.
            .task {
                guard DataScannerViewController.isSupported else { return }
                camera = await AVCaptureDevice.requestAccess(for: .video)
            }
            .navigationTitle("Pair with a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

/// The camera, looking for a QR code.
struct CodeScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.found = found
    }

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var found: (String) -> Void
        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for case let .barcode(code) in addedItems {
                if let text = code.payloadStringValue { found(text) }
            }
        }
    }
}

/// A prototype filling the phone. Every touch is the prototype's; three fingers held down
/// bring up the player's own bar.
struct PlayingScreen: View {
    let title: String
    let host: PrototypeHost
    let close: () -> Void
    @State private var showsMenu = false

    var body: some View {
        PlayerSurface(host: host) { showsMenu = true }
            .id(ObjectIdentifier(host))
            .ignoresSafeArea()
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
            // The prototype's own swipe from an edge comes before the system's.
            .defersSystemGestures(on: .all)
            // Watching a prototype follow the Mac is not touching the phone: it stays awake.
            .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
            .confirmationDialog(title, isPresented: $showsMenu, titleVisibility: .visible) {
                Button("Restart") { host.restart() }
                Button("Close") { close() }
                Button("Keep Playing", role: .cancel) {}
            }
    }
}
#endif
