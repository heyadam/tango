import AppKit
import PaperEngine
import PaperModel
import SwiftUI

/// The example gallery (spec 7.11): every prototype that ships with the app, as a picture
/// of its first frame. Choosing one opens a copy to take apart.
struct GalleryView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var pictures: [String: NSImage] = [:]

    static let windowID = "gallery"
    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 170), spacing: 24, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                ForEach(GalleryItem.Section.allCases, id: \.self) { section in
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.rawValue).font(.title2.bold())
                            Text(section.blurb)
                                .foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                            ForEach(Gallery.items.filter { $0.section == section }) { item in
                                card(item)
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    private func card(_ item: GalleryItem) -> some View {
        Button {
            Self.open(item)
            dismissWindow(id: Self.windowID)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if let picture = pictures[item.id] {
                        Image(nsImage: picture).resizable()
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .aspectRatio(390.0 / 844.0, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.separator))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.headline)
                    Text(item.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title). \(item.summary)")
        .help("Open a copy of \(item.title)")
        .task {
            guard pictures[item.id] == nil else { return }
            // One at a time, so the window stays responsive while the pictures fill in.
            await Task.yield()
            let package = item.package()
            if let bitmap = ViewerSnapshot.bitmap(of: package.document, assets: package.assets) {
                let image = NSImage(size: bitmap.size)
                image.addRepresentation(bitmap)
                pictures[item.id] = image
            }
        }
    }

    /// Opens a fresh copy of a gallery prototype as its own document.
    static func open(_ item: GalleryItem) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Gallery-\(UUID().uuidString.prefix(8))")
        let url = folder.appendingPathComponent("\(item.title).\(DocumentPackage.fileExtension)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try item.package().write(to: url)
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        } catch {
            NSApp.presentError(error)
        }
    }
}

private extension GalleryItem.Section {
    var blurb: String {
        switch self {
        case .showcase: "Finished-looking prototypes: shaders, glass and motion working together."
        case .examples: "Whole prototypes to explore and take apart."
        case .patterns: "One reusable solution each. Copy the views and patches into your own work."
        }
    }
}
