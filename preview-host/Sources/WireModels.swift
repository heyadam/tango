// Codable mirrors of tango's ResolvedSpec wire format (src/lib/uiResolve.ts +
// src/server/previewBridge.ts). Everything arrives pre-resolved — concrete
// RGBA colors, pixel sizes, SF Symbol names — so this app never parses CSS or
// Tailwind.
//
// Totality rules: `kind` stays a raw String (unknown kinds render as a
// placeholder, never crash), and a frame that fails to decode keeps the last
// good spec on screen.

import SwiftUI

struct RGBAColor: Codable {
    let r: Int
    let g: Int
    let b: Int
    let a: Double

    var color: Color {
        Color(
            .sRGB,
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            opacity: a
        )
    }
}

struct WireGradientStop: Codable {
    let color: RGBAColor
    let at: Double
}

struct WireGradient: Codable {
    let angleDeg: Double
    let stops: [WireGradientStop]

    // CSS angle convention: 0deg = to top, clockwise. Same math as the
    // SwiftUI codegen's gradientPoints().
    var points: (start: UnitPoint, end: UnitPoint) {
        let rad = angleDeg * .pi / 180
        let dx = sin(rad)
        let dy = -cos(rad)
        return (
            UnitPoint(x: 0.5 - dx / 2, y: 0.5 - dy / 2),
            UnitPoint(x: 0.5 + dx / 2, y: 0.5 + dy / 2)
        )
    }

    var linearGradient: LinearGradient {
        let (start, end) = points
        return LinearGradient(
            stops: stops.map { .init(color: $0.color.color, location: $0.at) },
            startPoint: start,
            endPoint: end
        )
    }
}

struct WirePadding: Codable {
    let top: Double
    let right: Double
    let bottom: Double
    let left: Double
}

struct WireShadow: Codable {
    let radius: Double
    let y: Double
    let alpha: Double
}

struct WireStyle: Codable {
    let backgroundColor: RGBAColor?
    let gradient: WireGradient?
    let textColor: RGBAColor?
    let fontSize: Double?
    let fontWeight: Int?
    let fontFamily: String?
    let italic: Bool?
    let textAlign: String?
    let cornerRadius: Double?
    let borderWidth: Double?
    let borderColor: RGBAColor?
    let borderDashed: Bool?
    let opacity: Double?
    let padding: WirePadding?
    let shadow: WireShadow?

    var swiftFontWeight: Font.Weight {
        switch fontWeight ?? 400 {
        case ..<150: return .ultraLight
        case ..<250: return .thin
        case ..<350: return .light
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        case ..<750: return .bold
        case ..<850: return .heavy
        default: return .black
        }
    }

    var font: Font {
        let size = fontSize ?? 14
        let design: Font.Design =
            fontFamily == "serif" ? .serif : fontFamily == "mono" ? .monospaced : .default
        let base = Font.system(size: size, weight: swiftFontWeight, design: design)
        return (italic ?? false) ? base.italic() : base
    }

    var multilineAlignment: TextAlignment {
        switch textAlign {
        case "center": return .center
        case "trailing": return .trailing
        default: return .leading
        }
    }
}

struct WirePoint: Codable {
    let x: Double
    let y: Double
}

struct WireNode: Codable, Identifiable {
    let id: String
    let kind: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let text: String?
    let isPlaceholderText: Bool?
    let sfSymbol: String?
    let imageSrc: String?
    let separatorVertical: Bool?
    // Vector shapes (kind "polygon"/"line"): pre-computed pixel coords inside
    // the node box. Plot them verbatim — geometry math lives in tango's
    // resolver, never here.
    let shapePoints: [WirePoint]?
    let arrowHead: [WirePoint]?
    let style: WireStyle
}

struct WireFrame: Codable {
    let w: Double
    let h: Double
}

struct WireScreen: Codable, Identifiable {
    let id: String
    let title: String
    let frame: WireFrame
    let nodes: [WireNode]
}

struct WireSpec: Codable {
    let version: Int
    let screens: [WireScreen]
}

struct WireMessage: Codable {
    let v: Int?
    let type: String
    let activeScreenId: String?
    let spec: WireSpec?
    let screenId: String?
}
