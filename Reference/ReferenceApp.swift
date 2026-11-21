import SwiftUI

// The real thing, to hold the iOS shelf against: one SwiftUI screen per case, each in a
// known state at a known place. `run.sh` builds this for the iOS Simulator, opens every
// case in turn and takes a picture; `papertool redline` lays tango's own component
// over each picture. A case here has the same id as one in `ReferenceCatalog` (PaperEditor).
//
// Controls stand with their top left corner at (20, 100) on the gray of Settings, with the
// status bar hidden, so their size and place can be read off the picture.

@main
struct ReferenceApp: App {
    var body: some Scene {
        WindowGroup { CaseView(id: UserDefaults.standard.string(forKey: "case") ?? "toggle-on") }
    }
}

let grouped = Color(uiColor: .systemGroupedBackground)

/// A control alone, its corner at (20, 100) whatever the safe area.
struct Alone<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        GeometryReader { _ in
            content.fixedSize().offset(x: 20, y: 100)
        }
        .background(grouped)
        .ignoresSafeArea()
        .statusBarHidden()
    }
}

/// The same, for a control that takes the width it is given.
struct Wide<Content: View>: View {
    var width: CGFloat
    @ViewBuilder var content: Content
    var body: some View {
        GeometryReader { _ in
            content.frame(width: width).offset(x: 20, y: 100)
        }
        .background(grouped)
        .ignoresSafeArea()
        .statusBarHidden()
    }
}

struct CaseView: View {
    let id: String
    @State private var on = true
    @State private var off = false
    @State private var half = 0.5
    @State private var count = 0
    @State private var choice = 0
    @State private var text = ""
    @State private var shown = true
    @State private var tab = 0

    var body: some View {
        switch id {
        case "toggle-on": Alone { Toggle("", isOn: $on).labelsHidden() }
        case "toggle-off": Alone { Toggle("", isOn: $off).labelsHidden() }
        case "slider": Wide(width: 280) { Slider(value: $half) }
        case "stepper": Alone { Stepper("", value: $count).labelsHidden() }
        case "segmented":
            Wide(width: 300) {
                Picker("", selection: $choice) {
                    Text("First").tag(0)
                    Text("Second").tag(1)
                    Text("Third").tag(2)
                }
                .pickerStyle(.segmented)
            }
        case "button-filled":
            Wide(width: 200) {
                Button { } label: { Text("Button").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large).buttonBorderShape(.capsule)
            }
        case "button-gray":
            Wide(width: 200) {
                Button { } label: { Text("Button").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large).buttonBorderShape(.capsule)
            }
        case "button-tinted":
            Wide(width: 200) {
                Button { } label: { Text("Button").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).tint(.blue).controlSize(.large).buttonBorderShape(.capsule)
            }
        case "button-plain":
            Wide(width: 200) {
                // A plain button has no body to measure, so it is given the height of the others.
                Button { } label: { Text("Button").frame(maxWidth: .infinity, minHeight: 50) }
                    .buttonStyle(.borderless).controlSize(.large)
            }
        case "search-field":
            // Where a search field is seen: under a large title, as .searchable puts it.
            NavigationStack {
                grouped.ignoresSafeArea()
                    .navigationTitle("Title")
                    .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always))
            }
        case "keyboard": KeyboardShown()
        case "glass-checker": GlassOver(backdrop: .checker) { $0.glassEffect(.regular, in: .capsule) }
        case "glass-stripes": GlassOver(backdrop: .stripes) { $0.glassEffect(.regular, in: .capsule) }
        case "glass-circle": GlassOver(backdrop: .checker, size: CGSize(width: 80, height: 80), at: CGPoint(x: 161, y: 380)) {
            $0.glassEffect(.regular, in: .circle)
        }
        case "menu-button":
            Alone {
                Picker("", selection: $choice) {
                    Text("One").tag(0)
                    Text("Two").tag(1)
                    Text("Three").tag(2)
                }
                .pickerStyle(.menu).labelsHidden()
            }
        case "activity": Alone { ProgressView() }
        case "page-control": Alone { PageDots(pages: 3) }
        case "sheet":
            grouped.ignoresSafeArea()
                // A detent of 500 puts the sheet's top 520 points above the bottom of the screen,
                // where the shelf's Sheet Height of 520 puts it.
                .sheet(isPresented: $shown) {
                    Color.clear.presentationDetents([.height(500)]).presentationDragIndicator(.visible)
                }
        case "progress": Wide(width: 280) { ProgressView(value: 0.5) }
        case "text-field": Wide(width: 300) { TextField("Placeholder", text: $text).textFieldStyle(.roundedBorder) }
        case "list": listScreen
        case "tab-bar":
            TabView(selection: $tab) {
                Tab("Home", systemImage: "house.fill", value: 0) { grouped.ignoresSafeArea() }
                Tab("Search", systemImage: "magnifyingglass", value: 1) { grouped.ignoresSafeArea() }
                Tab("Profile", systemImage: "person.fill", value: 2) { grouped.ignoresSafeArea() }
            }
        case "nav-bar":
            NavigationStack {
                grouped.ignoresSafeArea()
                    .navigationTitle("Title")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Edit") { } } }
            }
        case "toolbar":
            NavigationStack {
                grouped.ignoresSafeArea()
                    .toolbar {
                        ToolbarItemGroup(placement: .bottomBar) {
                            Button { } label: { Image(systemName: "square.and.arrow.up") }
                            Spacer()
                            Button { } label: { Image(systemName: "heart") }
                            Spacer()
                            Button { } label: { Image(systemName: "trash") }
                        }
                    }
            }
        case "alert":
            grouped.ignoresSafeArea()
                .alert("Title", isPresented: $shown) {
                    Button("Cancel", role: .cancel) { }
                    Button("OK") { }
                } message: { Text("A message that says what happened.") }
        case "action-sheet":
            grouped.ignoresSafeArea()
                .confirmationDialog("Title", isPresented: $shown, titleVisibility: .visible) {
                    Button("Duplicate") { }
                    Button("Delete", role: .destructive) { }
                    Button("Cancel", role: .cancel) { }
                }
        case let id where id.hasPrefix("motion-"): MotionCase(id: id)
        default:
            Text("No case \(id)")
        }
    }

    /// Settings as SwiftUI gives it: a large title over grouped sections.
    var listScreen: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink("Eligible to Add AppleCare") { EmptyView() }
                } footer: {
                    Text("34 days left to protect your iPhone.")
                }
                Section {
                    Toggle(isOn: $off) { Label { Text("Airplane Mode") } icon: { Tile(symbol: "airplane") } }
                    NavigationLink { EmptyView() } label: {
                        LabeledContent { Text("Beacon") } label: { Label { Text("Wi-Fi") } icon: { Tile(symbol: "wifi") } }
                    }
                    NavigationLink { EmptyView() } label: {
                        LabeledContent { Text("On") } label: { Label { Text("Bluetooth") } icon: { Tile(symbol: "dot.radiowaves.left.and.right") } }
                    }
                    NavigationLink { EmptyView() } label: { Label { Text("Cellular") } icon: { Tile(symbol: "antenna.radiowaves.left.and.right") } }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

/// UIKit's page control: SwiftUI has none of its own outside a paged TabView.
struct PageDots: UIViewRepresentable {
    var pages: Int
    func makeUIView(context: Context) -> UIPageControl {
        let control = UIPageControl()
        control.numberOfPages = pages
        control.currentPage = 0
        return control
    }
    func updateUIView(_ view: UIPageControl, context: Context) { }
}

/// The icon Settings gives a row: a white symbol on a rounded tile of color, which a bare
/// `Label` does not draw.
struct Tile: View {
    var symbol: String
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(Color.blue, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// A field with focus from the start, so the keyboard comes up under it. The simulator shows
/// its keyboard only while it has no hardware keyboard connected (I/O > Keyboard).
struct KeyboardShown: View {
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        grouped.ignoresSafeArea()
            .overlay(alignment: .top) {
                TextField("", text: $text).focused($focused).frame(width: 300).offset(y: 100)
            }
            .onAppear { focused = true }
    }
}

/// A pane of Liquid Glass over a backdrop that shows what it does to what is behind it:
/// a checkerboard (how far it bends and how much it softens) or colored stripes (what it
/// does to color). `GlassCase` in ReferenceCases draws the same backdrop.
struct GlassOver: View {
    enum Backdrop { case checker, stripes }
    var backdrop: Backdrop
    var size = CGSize(width: 300, height: 80)
    var at = CGPoint(x: 51, y: 380)
    var glass: (AnyView) -> any View

    init(backdrop: Backdrop, size: CGSize = CGSize(width: 300, height: 80), at: CGPoint = CGPoint(x: 51, y: 380),
         glass: @escaping (AnyView) -> some View) {
        self.backdrop = backdrop; self.size = size; self.at = at
        self.glass = { glass($0) }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, area in
                switch backdrop {
                case .checker:
                    for row in 0..<Int(area.height / 20) + 1 {
                        for column in 0..<Int(area.width / 20) + 1 where (row + column) % 2 == 1 {
                            context.fill(Path(CGRect(x: Double(column * 20), y: Double(row * 20), width: 20, height: 20)), with: .color(Self.dark))
                        }
                    }
                case .stripes:
                    for column in 0..<Int(area.width / 24) + 1 {
                        context.fill(Path(CGRect(x: Double(column * 24), y: 0, width: 24, height: area.height)), with: .color(Self.stripes[column % 4]))
                    }
                }
            }
            .background(Color.white)
            AnyView(glass(AnyView(Color.clear.frame(width: size.width, height: size.height))))
                .offset(x: at.x, y: at.y)
        }
        .ignoresSafeArea()
        .statusBarHidden()
    }

    // Pure colors, which come out the same whatever space each side computes in.
    static let dark = Color(red: 0, green: 0, blue: 0)
    static let stripes = [
        Color(red: 1, green: 0, blue: 0), Color(red: 0, green: 1, blue: 0),
        Color(red: 0, green: 0, blue: 1), Color(red: 1, green: 1, blue: 0),
    ]
}

/// The color a pushed or covering screen has, as `ReferenceMotion.arriving` has it.
let arriving = Color(red: 0x5A / 255.0, green: 0xC8 / 255.0, blue: 0xFA / 255.0)

/// A case that moves: at rest when it opens, it makes its change 5 seconds later, as
/// a person's tap would, while `run.sh` records the screen. `ReferenceMotion` (PaperEngine)
/// has ours under the same ids. The change is made from code because the simulator takes
/// no taps from a script; each control animates it the way it animates a tap.
struct MotionCase: View {
    let id: String
    @State private var changed = false
    @State private var choice = 0
    @State private var tab = 0
    @State private var path: [Int] = []

    var body: some View {
        content
            .statusBarHidden()
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    withAnimation {
                        changed = true
                        choice = 1
                        tab = 1
                    }
                    path = [1]
                }
            }
    }

    @ViewBuilder var content: some View {
        switch id {
        case "motion-toggle": Alone { Toggle("", isOn: $changed).labelsHidden() }
        case "motion-segmented":
            Wide(width: 300) {
                Picker("", selection: $choice) {
                    Text("First").tag(0)
                    Text("Second").tag(1)
                    Text("Third").tag(2)
                }
                .pickerStyle(.segmented)
            }
        case "motion-tab-bar":
            TabView(selection: $tab) {
                Tab("Home", systemImage: "house.fill", value: 0) { grouped.ignoresSafeArea() }
                Tab("Search", systemImage: "magnifyingglass", value: 1) { grouped.ignoresSafeArea() }
                Tab("Profile", systemImage: "person.fill", value: 2) { grouped.ignoresSafeArea() }
            }
        case "motion-sheet":
            grouped.ignoresSafeArea()
                .sheet(isPresented: $changed) {
                    Color.clear.presentationDetents([.height(500)]).presentationDragIndicator(.visible)
                }
        case "motion-alert":
            grouped.ignoresSafeArea()
                .alert("Title", isPresented: $changed) {
                    Button("Cancel", role: .cancel) { }
                    Button("OK") { }
                } message: { Text("A message that says what happened.") }
        case "motion-action-sheet":
            grouped.ignoresSafeArea()
                .confirmationDialog("Title", isPresented: $changed, titleVisibility: .visible) {
                    Button("Duplicate") { }
                    Button("Delete", role: .destructive) { }
                    Button("Cancel", role: .cancel) { }
                }
        case "motion-push":
            NavigationStack(path: $path) {
                grouped.ignoresSafeArea()
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationDestination(for: Int.self) { _ in
                        arriving.ignoresSafeArea().toolbar(.hidden, for: .navigationBar)
                    }
            }
        case "motion-cover":
            grouped.ignoresSafeArea()
                .fullScreenCover(isPresented: $changed) { arriving.ignoresSafeArea() }
        default:
            Text("No case \(id)")
        }
    }
}
