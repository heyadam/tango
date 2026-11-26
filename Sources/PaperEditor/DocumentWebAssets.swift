import Foundation
import PaperEngine
import PaperHost
import PaperModel

/// A document keeps the files of the fetched fonts and icons it uses (`web.…` assets), so it
/// draws the same offline, on the phone and on another Mac. Which ones it uses: those its
/// stored values name (a text's Font, a Symbol view's symbol, the Icon and Font patches'
/// inputs) and those the Viewer or the Canvas drew this session. What it used this session and
/// no longer uses is let go; a file it came with that nothing has used yet is kept, since a
/// cable may choose it once the prototype runs. None of this is an undo step.
extension DocumentStore {
    /// Starts keeping what the document uses: the app's documents do, from when they open.
    func startKeepingWebAssets() {
        if webAssetObserver == nil {
            webAssetObserver = NotificationCenter.default.addObserver(forName: WebAssets.didArrive, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keepWebAssets() }
            }
        }
        scheduleWebAssets()
    }

    /// Hears that a host drew a fetched font or icon of this document.
    public func noteWebAsset(_ name: String) {
        guard WebAssetNames.isWebAsset(name), notedWebAssets.insert(name).inserted else { return }
        scheduleWebAssets()
    }

    /// Whether this document drew, or names, the web asset `name`: what an arrival must be
    /// for its Viewer and Canvas to draw again.
    public func usesWebAsset(_ name: String) -> Bool {
        notedWebAssets.contains(name) || usedWebAssets.contains(name)
    }

    /// Looks again once the current burst of changes is over, not on every step of a drag.
    func scheduleWebAssets() {
        guard keepsWebAssets, !webAssetsScheduled else { return }
        webAssetsScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.webAssetsScheduled = false
                self?.keepWebAssets()
            }
        }
    }

    /// Copies into the assets each fetched file the document uses that has arrived, asks for
    /// those that have not, and lets go of the ones it no longer uses.
    func keepWebAssets() {
        guard keepsWebAssets else { return }
        let wanted = namedWebAssets(fetching: true).union(notedWebAssets)
        usedWebAssets.formUnion(wanted)
        var next = assets.filter { !WebAssetNames.isWebAsset($0.key) || wanted.contains($0.key) || !usedWebAssets.contains($0.key) }
        for name in wanted where next[name] == nil {
            if let data = WebAssets.shared.data(named: name) { next[name] = data }
        }
        if next != assets { assets = next }
    }

    /// The `web.…` assets what the document stores names. With `fetching`, those not yet on
    /// this device are asked for.
    func namedWebAssets(fetching: Bool) -> Set<String> {
        let document = fullDocument
        var names: Set<String> = []
        let web = WebAssets.shared
        func icon(_ value: String, weight: Double) {
            guard let icon = IconName(value), icon.set.isMaterial, let name = MaterialSymbols.assetName(icon, weight: weight) else { return }
            names.insert(name)
            if fetching, !assets.keys.contains(name) { _ = web.glyph(icon, weight: weight, assets: assets, fetches: true) }
        }
        func font(_ family: String, weight: Double, italic: Bool) {
            if let name = web.wantFont(family: family, weight: weight, italic: italic, assets: assets, fetches: fetching) {
                names.insert(name)
            }
        }
        let roots = [document.screen] + document.components.map(\.root)
        for layer in roots.flatMap(\.flattened) {
            let weight = layer.value(.fontWeight).numberValue
            switch layer.kind {
            case .symbol: icon(layer.value(.symbol).textValue, weight: weight)
            case .text, .textField:
                let family = layer.value(.fontFamily).textValue
                if !FontBook.isSystemDesign(family) { font(family, weight: weight, italic: layer.value(.italic).boolValue) }
            default: break
            }
        }
        // An Icon or Font patch is drawn at the weight of the views it feeds.
        let layers = Dictionary(roots.flatMap(\.flattened).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let graphs = [document.graph] + document.components.map(\.graph)
        for graph in graphs {
            let viewOf = Dictionary(graph.nodes.compactMap { node in node.layerID.map { (node.id, $0) } }, uniquingKeysWith: { a, _ in a })
            func fed(_ node: PatchNode, from port: String) -> [Layer] {
                graph.connections.filter { $0.from == PortRef(node: node.id, port: port) }
                    .compactMap { viewOf[$0.to.node].flatMap { layers[$0] } }
            }
            for node in graph.nodes {
                switch node.kind {
                case PatchKind.icon:
                    let named = IconName.forPatch(
                        set: node.inputs["set"]?.textValue ?? IconSet.lucide.displayName,
                        name: node.inputs["name"]?.textValue ?? "heart",
                        filled: node.inputs["filled"]?.boolValue ?? false
                    )
                    guard let named else { continue }
                    let weights = Set(fed(node, from: "symbol").map { $0.value(.fontWeight).numberValue })
                    for weight in weights.isEmpty ? [400] : Array(weights) { icon(named.value, weight: weight) }
                case PatchKind.font:
                    let family = node.inputs["family"]?.textValue ?? "Inter"
                    guard !FontBook.isSystemDesign(family) else { continue }
                    let texts = fed(node, from: "font")
                    if texts.isEmpty { font(family, weight: 400, italic: false) }
                    for text in texts {
                        font(family, weight: text.value(.fontWeight).numberValue, italic: text.value(.italic).boolValue)
                    }
                default: break
                }
            }
        }
        return names
    }
}
