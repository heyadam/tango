import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import PaperLink
import PaperModel
import SwiftUI

/// Hands the window's prototype to `DeviceLink` whenever it changes, as
/// `ViewerWindowBridge` hands it to the Viewer. Only the front window sends.
struct DeviceLinkBridge: View {
    let store: DocumentStore
    let name: String
    let fileURL: URL?
    let isFront: Bool
    @Bindable var link: DeviceLink
    /// For a document not saved yet: one id while its window is open.
    @State private var untitled = UUID().uuidString

    /// The same for a file every time it is opened, so a phone keeps one copy of it.
    private var prototype: String {
        guard let fileURL else { return untitled }
        return SHA256.hash(data: Data(fileURL.standardizedFileURL.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// What a change to is worth sending. While the link is off or no phone is there it
    /// is one constant, so an edit costs no comparison of documents.
    private struct Trigger: Equatable {
        var document: PaperModel.Document?
        var assets: [String: Data] = [:]
        var restartToken = 0
        var startScreen: LayerID?
        var extensions: Set<String> = []
        var name = ""
        var isFront = false
    }

    private var trigger: Trigger {
        guard link.isEnabled, isFront, !link.phones.isEmpty else { return Trigger() }
        return Trigger(
            document: store.runtimeDocument, assets: store.assets, restartToken: store.restartToken,
            startScreen: store.previewScreen, extensions: Set(store.usedExtensionIDs), name: name, isFront: true
        )
    }

    var body: some View {
        Color.clear
            .onChange(of: trigger, initial: true) { _, trigger in
                guard let document = trigger.document else { return }
                var package = store.package
                package.document = document
                link.publish(.init(
                    prototype: prototype, name: name, package: package, restartToken: trigger.restartToken,
                    startScreen: trigger.startScreen, keeps: store.scope == nil
                ))
            }
            .onDisappear { link.withdraw(prototype: prototype) }
    }
}

/// The toolbar's button: whether a phone is connected, and the popover that pairs one.
struct DeviceLinkButton: View {
    @Bindable var link: DeviceLink
    @State private var shows = false

    var body: some View {
        Button {
            shows.toggle()
        } label: {
            Label("Send to iPhone", systemImage: link.phones.isEmpty ? "iphone.and.arrow.forward" : "iphone.radiowaves.left.and.right")
        }
        .help(link.phones.isEmpty ? "Play the prototype on an iPhone" : "Playing on \(link.phones.map(\.name).joined(separator: ", "))")
        .popover(isPresented: $shows, arrowEdge: .bottom) {
            DeviceLinkPanel(link: link).frame(width: 300).padding(16)
        }
    }
}

/// Turning the link on, the code a phone scans, and the phones that are connected.
struct DeviceLinkPanel: View {
    @Bindable var link: DeviceLink

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Play on iPhone", isOn: $link.isEnabled)
                .toggleStyle(.switch)
            Text("The prototype in the front window plays in the tango app on a paired iPhone nearby, and follows every change you make.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if link.isEnabled {
                if case let .failed(reason) = link.state {
                    Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                ForEach(link.phones) { phone in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(phone.name, systemImage: "iphone")
                        if let notice = phone.notice {
                            Text(notice).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Divider()
                if let key = link.key, let code = Self.code(for: key.text) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(decorative: code, scale: 1)
                            .interpolation(.none).resizable().frame(width: 120, height: 120)
                            .padding(6).background(.white, in: .rect(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 8) {
                            Text("To pair an iPhone, open tango on it and scan this code.")
                                .font(.callout).fixedSize(horizontal: false, vertical: true)
                            Button("New Code") { link.newKey() }
                                .help("Make another code. Every iPhone has to scan the new one.")
                        }
                    }
                }
            }
        }
    }

    /// A QR code holding `text`, one pixel per module.
    static func code(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
