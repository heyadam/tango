// Renders one resolved node by `kind`. Mirrors the visual mapping of the
// SwiftUI codegen (specToSwiftUI.ts) minus interactivity — buttons don't tap,
// fields don't focus. Unknown kinds render as a labeled placeholder so a
// newer tango server never crashes an older preview build.

import SwiftUI

struct NodeView: View {
    let node: WireNode

    private var style: WireStyle { node.style }

    var body: some View {
        switch node.kind {
        case "box":
            chrome
        case "text":
            textBody
        case "button":
            buttonBody
        case "input":
            inputBody
        case "textarea":
            textareaBody
        case "badge":
            badgeBody
        case "separator":
            separatorBody
        case "image":
            imageBody
        case "icon":
            iconBody
        default:
            unknownBody
        }
    }

    // ── shared chrome ──────────────────────────────────────────────────────

    @ViewBuilder
    private var shapeBackground: some View {
        let radius = style.cornerRadius ?? 0
        if radius >= 9999 {
            Capsule().fill(fillStyle)
        } else if radius > 0 {
            RoundedRectangle(cornerRadius: radius).fill(fillStyle)
        } else {
            Rectangle().fill(fillStyle)
        }
    }

    private var fillStyle: AnyShapeStyle {
        if let gradient = style.gradient {
            return AnyShapeStyle(gradient.linearGradient)
        }
        if let bg = style.backgroundColor, bg.a > 0 {
            return AnyShapeStyle(bg.color)
        }
        return AnyShapeStyle(Color.clear)
    }

    @ViewBuilder
    private var borderOverlay: some View {
        if let width = style.borderWidth, width > 0 {
            let color = style.borderColor?.color ?? Color.gray
            let strokeStyle = StrokeStyle(
                lineWidth: width,
                dash: (style.borderDashed ?? false) ? [4] : []
            )
            let radius = style.cornerRadius ?? 0
            if radius >= 9999 {
                Capsule().strokeBorder(color, style: strokeStyle)
            } else if radius > 0 {
                RoundedRectangle(cornerRadius: radius).strokeBorder(color, style: strokeStyle)
            } else {
                Rectangle().strokeBorder(color, style: strokeStyle)
            }
        }
    }

    private var chrome: some View {
        shapeBackground
            .overlay(borderOverlay)
            .shadowIfAny(style.shadow)
    }

    private func styledText(_ value: String) -> some View {
        Text(value)
            .font(style.font) // italic folded into the Font in WireStyle
            .foregroundColor(style.textColor?.color ?? .primary)
            .multilineTextAlignment(style.multilineAlignment)
    }

    private var frameAlignmentTop: Alignment {
        switch style.textAlign {
        case "center": return .top
        case "trailing": return .topTrailing
        default: return .topLeading
        }
    }

    // ── per-kind bodies ────────────────────────────────────────────────────

    private var textBody: some View {
        styledText(node.text ?? "")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignmentTop)
            .background(shapeBackground)
            .overlay(borderOverlay)
    }

    private var buttonBody: some View {
        styledText(node.text ?? "Button")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(shapeBackground)
            .overlay(borderOverlay)
            .shadowIfAny(style.shadow)
    }

    private var inputBody: some View {
        styledText(node.text ?? "")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, style.padding?.left ?? 12)
            .background(shapeBackground)
            .overlay(borderOverlay)
    }

    private var textareaBody: some View {
        styledText(node.text ?? "")
            .padding(EdgeInsets(
                top: style.padding?.top ?? 8,
                leading: style.padding?.left ?? 12,
                bottom: style.padding?.bottom ?? 8,
                trailing: style.padding?.right ?? 12
            ))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(shapeBackground)
            .overlay(borderOverlay)
    }

    private var badgeBody: some View {
        styledText(node.text ?? "Badge")
            .padding(EdgeInsets(
                top: style.padding?.top ?? 2,
                leading: style.padding?.left ?? 8,
                bottom: style.padding?.bottom ?? 2,
                trailing: style.padding?.right ?? 8
            ))
            .background(shapeBackground)
            .overlay(borderOverlay)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var separatorBody: some View {
        let color = style.backgroundColor?.color ?? Color.gray.opacity(0.4)
        return Rectangle()
            .fill(color)
            .frame(
                width: (node.separatorVertical ?? false) ? 1 : nil,
                height: (node.separatorVertical ?? false) ? nil : 1
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var imageBody: some View {
        if let src = node.imageSrc, let url = URL(string: src) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.gray.opacity(0.2)
            }
            .frame(width: node.width, height: node.height)
            .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius ?? 0))
        } else {
            chrome.overlay(
                Image(systemName: "photo")
                    .foregroundColor(style.textColor?.color ?? .secondary)
            )
        }
    }

    private var iconBody: some View {
        Image(systemName: node.sfSymbol ?? "circle")
            .resizable()
            .scaledToFit()
            .foregroundColor(style.textColor?.color ?? .primary)
    }

    private var unknownBody: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.15))
            .overlay(
                Rectangle().strokeBorder(
                    Color.gray.opacity(0.5),
                    style: StrokeStyle(lineWidth: 1, dash: [4])
                )
            )
            .overlay(
                Text(node.kind)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            )
    }
}

private extension View {
    @ViewBuilder
    func shadowIfAny(_ shadow: WireShadow?) -> some View {
        if let shadow {
            self.shadow(
                color: .black.opacity(shadow.alpha),
                radius: shadow.radius,
                x: 0,
                y: shadow.y
            )
        } else {
            self
        }
    }
}
