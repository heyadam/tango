import CoreGraphics
import Foundation
import PaperModel

/// The Morph style: while one screen gives way to another, a view on both screens under
/// the same name moves, resizes and changes color from where it is on the one to where it
/// is on the other, and everything else crossfades. What design tools call smart animate.
extension ResolvedLayer {
    /// The properties a matched view blends between its two screens, besides its frame.
    static let morphedProperties: [LayerProperty] = [.fill, .cornerRadius, .opacity, .fontSize, .textColor, .strokeColor, .strokeWidth]

    /// A view on a screen that the other screen has too.
    private struct Match {
        /// Its frame on the device, at rest.
        var rect: CGRect
        var layer: ResolvedLayer
    }

    /// Blends two screens of this tree (the device): `over` drawn on top, `shown` from 0
    /// (only `under` is seen) to 1 (only `over` is). Both are laid out where they rest.
    mutating func morph(over: LayerID, under: LayerID, shown: Double) {
        let t = min(max(shown.clampedFinite, 0), 1)
        guard let overIndex = children.firstIndex(where: { $0.id == over && $0.isPage }),
              let underIndex = children.firstIndex(where: { $0.id == under && $0.isPage }) else { return }
        let onUnder = ResolvedLayer.namedViews(in: children[underIndex])
        let onOver = ResolvedLayer.namedViews(in: children[overIndex])
        let matched = Set(onUnder.keys).intersection(onOver.keys)

        // The screen arriving: its own fill and what it does not share come in; what it
        // shares comes from where it was on the other screen.
        children[overIndex].fadeFill(by: t)
        for index in children[overIndex].children.indices {
            children[overIndex].children[index].blendArriving(matched: matched, from: onUnder, shown: t, parent: children[overIndex].transformToParent)
        }
        // The screen going: what it does not share goes, and what it shares is drawn by the
        // other screen, so it is hidden here.
        for index in children[underIndex].children.indices {
            children[underIndex].children[index].blendLeaving(matched: matched, shown: t)
        }
    }

    /// The views of a screen by name, with their frames on the device. A name used twice,
    /// or by a repeated view, matches nothing.
    private static func namedViews(in page: ResolvedLayer) -> [String: Match] {
        var found: [String: Match] = [:]
        var twice: Set<String> = []
        func walk(_ layer: ResolvedLayer, _ transform: CGAffineTransform) {
            for child in layer.children {
                let own = child.transformToParent.concatenating(transform)
                if child.instance != 0 || found[child.name] != nil || twice.contains(child.name) {
                    found[child.name] = nil
                    twice.insert(child.name)
                } else {
                    found[child.name] = Match(rect: CGRect(origin: .zero, size: CGSize(width: child.size.width, height: child.size.height)).applying(own), layer: child)
                }
                walk(child, own)
            }
        }
        walk(page, page.transformToParent)
        return found
    }

    private func contains(anyOf names: Set<String>) -> Bool {
        children.contains { names.contains($0.name) || $0.contains(anyOf: names) }
    }

    private mutating func fadeFill(by factor: Double) {
        guard case let .color(color) = value(.fill) else { return }
        var faded = color
        faded.alpha *= factor
        overrides[.fill] = .color(faded)
    }

    private mutating func blendArriving(matched: Set<String>, from other: [String: Match], shown t: Double, parent: CGAffineTransform) {
        let own = transformToParent.concatenating(parent)
        if matched.contains(name), let start = other[name] {
            // From its frame on the other screen to its own, in its parent's coordinates
            // (scale and rotation of what holds it are not followed).
            let end = CGRect(origin: .zero, size: CGSize(width: size.width, height: size.height)).applying(own)
            let lerp = { (a: Double, b: Double) in (a + (b - a) * t).clampedFinite }
            let frame = CGRect(
                x: lerp(start.rect.minX, end.minX), y: lerp(start.rect.minY, end.minY),
                width: max(lerp(start.rect.width, end.width), 0), height: max(lerp(start.rect.height, end.height), 0)
            )
            let anchor = self.anchor
            overrides[.size] = .size(Size2(width: frame.width, height: frame.height))
            overrides[.position] = .point(Point2(
                x: (frame.minX - parent.tx + anchor.x * frame.width).clampedFinite,
                y: (frame.minY - parent.ty + anchor.y * frame.height).clampedFinite
            ))
            for property in ResolvedLayer.morphedProperties {
                let from = start.layer.value(property), to = value(property)
                if from != to { overrides[property] = Value.lerp(from, to, t) }
            }
            return
        }
        guard contains(anyOf: matched) else {
            overrides[.opacity] = .number(opacity * t)
            return
        }
        // It holds something that moves: its own fill fades, and what is in it is looked at.
        fadeFill(by: t)
        for index in children.indices {
            children[index].blendArriving(matched: matched, from: other, shown: t, parent: own)
        }
    }

    private mutating func blendLeaving(matched: Set<String>, shown t: Double) {
        if matched.contains(name) {
            overrides[.opacity] = .number(0)
            return
        }
        guard contains(anyOf: matched) else {
            overrides[.opacity] = .number(opacity * (1 - t))
            return
        }
        fadeFill(by: 1 - t)
        for index in children.indices { children[index].blendLeaving(matched: matched, shown: t) }
    }
}
