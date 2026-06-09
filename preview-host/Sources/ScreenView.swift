// Renders one screen scale-to-fit. Same layout convention as the codegen and
// the web canvas: ZStack(.topLeading) + frame(w, h) + offset(x, y), in the
// screen's native pixel space, scaled as a whole.

import SwiftUI

struct ScreenView: View {
    let screen: WireScreen

    var body: some View {
        GeometryReader { geo in
            let scale = min(
                geo.size.width / max(screen.frame.w, 1),
                geo.size.height / max(screen.frame.h, 1)
            )
            ZStack(alignment: .topLeading) {
                ForEach(screen.nodes) { node in
                    NodeView(node: node)
                        .frame(width: node.width, height: node.height)
                        .opacity(node.style.opacity ?? 1)
                        .offset(x: node.x, y: node.y)
                }
            }
            .frame(width: screen.frame.w, height: screen.frame.h, alignment: .topLeading)
            .background(Color(red: 245 / 255, green: 238 / 255, blue: 224 / 255))
            .clipped()
            .scaleEffect(scale, anchor: .topLeading)
            .offset(
                x: (geo.size.width - screen.frame.w * scale) / 2,
                y: (geo.size.height - screen.frame.h * scale) / 2
            )
        }
        .ignoresSafeArea()
    }
}
