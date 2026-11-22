#if os(iOS)
import PaperEngine
import PaperModel
import SwiftUI

/// The player app: a list of prototypes, and one playing. `Player/` is an `@main` around it.
public struct PlayerScene: Scene {
    public init() {}

    public var body: some Scene {
        WindowGroup {
            PlayerRoot()
        }
    }
}

/// A prototype the player can play.
struct PlayerItem: Identifiable, Hashable {
    let id: String
    let title: String
    let summary: String

    static func == (a: PlayerItem, b: PlayerItem) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct PlayerRoot: View {
    /// `-example <gallery id>` on the command line opens that example at once, for
    /// pictures taken with `simctl`.
    @State private var playing: GalleryItem? = UserDefaults.standard.string(forKey: "example").flatMap(Gallery.item)

    var body: some View {
        NavigationStack {
            List {
                ForEach(GalleryItem.Section.allCases, id: \.self) { section in
                    Section(section.rawValue) {
                        ForEach(Gallery.items.filter { $0.section == section }) { item in
                            Button {
                                playing = item
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
        .fullScreenCover(item: $playing) { item in
            PlayingScreen(title: item.title, package: item.package()) { playing = nil }
        }
    }
}

/// A prototype filling the phone. Every touch is the prototype's; three fingers held down
/// bring up the player's own bar.
struct PlayingScreen: View {
    let title: String
    let package: DocumentPackage
    let close: () -> Void
    @State private var showsMenu = false
    @State private var restart = 0

    var body: some View {
        PlayerSurface(package: package, restart: restart) { showsMenu = true }
            .ignoresSafeArea()
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
            // The prototype's own swipe from an edge comes before the system's.
            .defersSystemGestures(on: .all)
            .confirmationDialog(title, isPresented: $showsMenu, titleVisibility: .visible) {
                Button("Restart") { restart += 1 }
                Button("Close") { close() }
                Button("Keep Playing", role: .cancel) {}
            }
    }
}
#endif
