import PaperEngine
import PaperHost
import PaperModel
import SwiftUI

/// A text's typeface: typed, or chosen from the system's families and every Google Fonts
/// family in a searchable list.
struct FontField: View {
    let family: String
    let commit: (String) -> Void
    @State private var choosing = false

    var body: some View {
        HStack(spacing: 6) {
            TextValueField(text: family.isEmpty ? FontBook.systemFamily : family) { typed in
                let trimmed = typed.trimmingCharacters(in: .whitespaces)
                commit(trimmed == FontBook.systemFamily || trimmed == "System" ? "" : trimmed)
            }
            .help("The system's font, an Apple family every device has, or any Google Fonts family")
            Button("Choose…") { choosing = true }
                .popover(isPresented: $choosing, arrowEdge: .leading) {
                    FontPicker(current: family) { chosen in
                        commit(chosen)
                        choosing = false
                    }
                }
        }
    }
}

/// Every family a text can be set in, by where it comes from.
struct FontPicker: View {
    let current: String
    let choose: (String) -> Void
    @State private var search = ""

    private struct Entry: Identifiable, Hashable {
        var id: String { source + name }
        var name: String
        var source: String
        var category: String
    }

    private var entries: [Entry] {
        let system = FontBook.systemFamilies.map { Entry(name: $0, source: "Apple", category: "On every device") }
        let google = GoogleFonts.families.map { Entry(name: $0.name, source: "Google Fonts", category: $0.category) }
        let all = system + google
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.category.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search fonts", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            let shown = entries
            List {
                ForEach(["Apple", "Google Fonts"], id: \.self) { source in
                    let rows = shown.filter { $0.source == source }
                    if !rows.isEmpty {
                        Section(source) {
                            ForEach(rows.prefix(400)) { entry in
                                Button { choose(entry.name == FontBook.systemFamily ? "" : entry.name) } label: {
                                    HStack {
                                        Text(entry.name)
                                        Spacer()
                                        Text(entry.category).foregroundStyle(.secondary).font(.caption)
                                        if entry.name == current || (current.isEmpty && entry.name == FontBook.systemFamily) {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            Text("Google Fonts are fetched the first time they are used and then kept in the document, so it shows them offline and on iPhone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 320, height: 440)
    }
}

/// A Symbol view's icon: typed, or found in a set by name and tag.
struct SymbolField: View {
    let symbol: String
    let commit: (String) -> Void
    @State private var choosing = false

    var body: some View {
        HStack(spacing: 6) {
            TextValueField(text: symbol) { commit($0) }
                .help("An SF Symbol (heart.fill), or lucide:heart, material:home, material-rounded:favorite.fill")
            Button("Choose…") { choosing = true }
                .popover(isPresented: $choosing, arrowEdge: .leading) {
                    IconPicker(current: symbol) { chosen in
                        commit(chosen)
                        choosing = false
                    }
                }
        }
    }
}

/// Lucide's icons drawn as they will be; Material's listed by name (each glyph is fetched
/// only once it is chosen).
struct IconPicker: View {
    let current: String
    let choose: (String) -> Void
    @State private var set: IconSet
    @State private var search = ""
    @State private var filled = false

    init(current: String, choose: @escaping (String) -> Void) {
        self.current = current
        self.choose = choose
        let icon = IconName(current)
        _set = State(initialValue: icon?.set == .sf || icon == nil ? .lucide : icon!.set)
        _filled = State(initialValue: icon?.filled ?? false)
    }

    private var names: [String] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        switch set {
        case .lucide:
            guard !query.isEmpty else { return LucideIcons.names }
            return LucideIcons.names.filter { $0.contains(query) || (LucideIcons.tags[$0]?.contains(query) ?? false) }
        case .sf:
            return []
        default:
            guard !query.isEmpty else { return MaterialSymbols.icons.map(\.name) }
            return MaterialSymbols.icons.filter { $0.name.contains(query) || $0.tags.contains(query) || $0.categories.lowercased().contains(query) }.map(\.name)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            Picker("Set", selection: $set) {
                ForEach(IconSet.allCases.filter { $0 != .sf }, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            HStack {
                TextField("Search icons", text: $search).textFieldStyle(.roundedBorder)
                if set.isMaterial { Toggle("Filled", isOn: $filled).toggleStyle(.checkbox) }
            }
            let shown = names
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: set == .lucide ? 44 : 140), spacing: 4)], spacing: 4) {
                    ForEach(shown.prefix(1200), id: \.self) { name in
                        let icon = IconName(set: set, name: name, filled: filled && set.isMaterial)
                        Button { choose(icon.value) } label: {
                            if set == .lucide, let picture = LucideIcons.glyph(name)?.image(width: 48, height: 48, color: CGColor(gray: 0.2, alpha: 1)) {
                                Image(decorative: picture, scale: 2)
                                    .frame(width: 40, height: 40)
                                    .background(icon.value == current ? Color.accentColor.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            } else {
                                Text(name)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 3)
                                    .padding(.horizontal, 6)
                                    .background(icon.value == current ? Color.accentColor.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                        .buttonStyle(.plain)
                        .help(name)
                    }
                }
            }
            Text(set == .lucide
                ? "\(shown.count) icons. Lucide ships with Tango and draws offline."
                : "\(shown.count) icons. A Material glyph is fetched when first used and then kept in the document.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(width: 340, height: 460)
    }
}
