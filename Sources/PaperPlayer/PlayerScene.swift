#if os(iOS)
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

struct PlayerRoot: View {
    @State private var store = PlayerStore(
        keys: KeychainLinkKeyStore(), deviceName: UIDevice.current.name, screen: UIScreen.main.bounds.size
    )
    /// `-example <gallery id>` on the command line opens that example at once, for
    /// pictures taken with `simctl`.
    @State private var example: GalleryItem? = UserDefaults.standard.string(forKey: "example").flatMap(Gallery.item)
    @State private var pairs = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LinkRow(store: store) { pairs = true }
                } header: {
                    Text("Your Mac")
                } footer: {
                    if let notice = store.notice { Text(notice) }
                }
                ForEach(GalleryItem.Section.allCases, id: \.self) { section in
                    Section(section.rawValue) {
                        ForEach(Gallery.items.filter { $0.section == section }) { item in
                            Button {
                                example = item
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).foregroundStyle(.primary)
                                    Text(item.summary).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
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
        .fullScreenCover(item: $example) { item in
            ExampleScreen(item: item) { example = nil }
        }
        // What the Mac sends comes up over everything, and follows it.
        .fullScreenCover(item: Binding(get: { example == nil ? store.live : nil }, set: { if $0 == nil { store.closeLive() } })) { live in
            PlayingScreen(title: live.name, host: live.host, restart: nil) { store.closeLive() }
        }
        .onChange(of: store.live?.id) { _, id in
            if id != nil { example = nil }
        }
        .task {
            // `-linkkey <text of the code>` pairs without a camera, for the simulator.
            if let text = UserDefaults.standard.string(forKey: "linkkey"), let key = LinkKey(text: text) {
                store.pair(with: key)
            }
            // `-linkhost 127.0.0.1:47900` connects straight to `papertool link`, with no search.
            if let place = UserDefaults.standard.string(forKey: "linkhost")?.split(separator: ":"), place.count == 2,
               let port = NWEndpoint.Port(String(place[1])) {
                store.connect(to: .hostPort(host: NWEndpoint.Host(String(place[0])), port: port), name: "papertool")
            } else {
                store.startSearching()
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
                    CodeScanner { found in
                        if let key = LinkKey(text: found) { paired(key) }
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .bottom) {
                        Text("In tango on the Mac, click the iPhone button in the toolbar and point the camera at the code.")
                            .font(.callout).multilineTextAlignment(.center).padding()
                            .background(.regularMaterial, in: .rect(cornerRadius: 16)).padding()
                    }
                } else {
                    Form {
                        Section {
                            TextField("tango-link:…", text: $text).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button("Pair") { if let key = LinkKey(text: text) { paired(key) } }
                                .disabled(LinkKey(text: text) == nil)
                        } footer: {
                            Text("This device cannot scan a code. Paste the text of the code instead.")
                        }
                    }
                }
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

/// One of the gallery's examples, playing.
struct ExampleScreen: View {
    let item: GalleryItem
    let close: () -> Void
    @State private var host: PrototypeHost

    init(item: GalleryItem, close: @escaping () -> Void) {
        self.item = item
        self.close = close
        _host = State(initialValue: PrototypeHost(package: item.package()))
    }

    var body: some View {
        PlayingScreen(title: item.title, host: host, restart: { host.restart() }, close: close)
    }
}

/// A prototype filling the phone. Every touch is the prototype's; three fingers held down
/// bring up the player's own bar.
struct PlayingScreen: View {
    let title: String
    let host: PrototypeHost
    /// Starts the prototype over; nil for one the Mac sends, which the Mac restarts.
    let restart: (() -> Void)?
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
            .confirmationDialog(title, isPresented: $showsMenu, titleVisibility: .visible) {
                Button("Restart") { restart?() ?? host.restart() }
                Button("Close") { close() }
                Button("Keep Playing", role: .cancel) {}
            }
    }
}
#endif
