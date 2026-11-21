import AppKit
import PaperEngine
import PaperModel

/// Colors and fonts shared by the Patch Editor's drawing code.
enum PatchStyle {
    static let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let subtitleFont = NSFont.systemFont(ofSize: 10, weight: .regular)
    static let labelFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)

    static func color(for type: PortType) -> NSColor {
        switch type {
        case .number: .systemBlue
        case .bool: .systemGreen
        case .pulse: .systemOrange
        case .text: .systemPurple
        case .color: .systemPink
        case .point: .systemTeal
        case .size: .systemIndigo
        case .array: .systemBrown
        case .json: .systemYellow
        }
    }

    static func color(for category: PatchCategory) -> NSColor {
        switch category {
        case .input: .systemOrange
        case .state: .systemGreen
        case .logic: .systemPurple
        case .math: .systemBlue
        case .animation: .systemPink
        case .loop: .systemYellow
        case .data: .systemCyan
        case .ai: .systemIndigo
        case .device: .systemRed
        case .utility: .systemGray
        case .component: .systemMint
        case .layer: .systemTeal
        }
    }

    static func category(of node: PatchNode, in registry: PatchRegistry) -> PatchCategory {
        if node.kind == PatchKind.view { return node.componentID == nil ? .layer : .component }
        return registry.definition(node.kind)?.category ?? .utility
    }

    static func draw(
        _ text: String,
        in rect: CGRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: style,
        ]
        let height = ceil(font.ascender - font.descender)
        let target = CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        (text as NSString).draw(with: target, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }
}

/// Runs a closure when a menu item is chosen.
final class MenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() { handler() }
}

extension NSMenu {
    @discardableResult
    func addAction(_ title: String, checked: Bool = false, enabled: Bool = true, handler: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(handler)
        let item = NSMenuItem(title: title, action: enabled ? #selector(MenuAction.run) : nil, keyEquivalent: "")
        item.target = action
        // The item keeps its action object alive.
        item.representedObject = action
        item.state = checked ? .on : .off
        addItem(item)
        return item
    }
}
