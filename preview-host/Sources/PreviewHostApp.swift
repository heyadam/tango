// tango preview host — renders the live design spec streamed from the tango
// server over /ws/preview. Canvas edits appear here in under a second, no
// rebuild. Built once per machine into ~/.tango/preview-host-build and
// launched on the booted simulator by tango's "Preview" button.

import SwiftUI

@main
struct PreviewHostApp: App {
    @StateObject private var client = PreviewClient()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PreviewRootView()
                .environmentObject(client)
                .statusBarHidden()
                .onChange(of: scenePhase) { phase in
                    // Coming back to the foreground after a long sleep can
                    // leave the socket half-dead; reconnect proactively.
                    if phase == .active { client.reconnectIfNeeded() }
                }
        }
    }
}

struct PreviewRootView: View {
    @EnvironmentObject private var client: PreviewClient

    var body: some View {
        ZStack {
            Color(red: 245 / 255, green: 238 / 255, blue: 224 / 255)
                .ignoresSafeArea()

            if let screen = client.currentScreen {
                ScreenView(screen: screen)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "square.dashed")
                        .font(.system(size: 40))
                    Text(client.state == .connected ? "No design yet" : "Connecting to tango…")
                        .font(.system(size: 15, weight: .medium))
                    Text(client.state == .connected
                        ? "Draw something on the tango canvas."
                        : "ws://localhost:\(client.port)/ws/preview")
                        .font(.system(size: 12))
                        .opacity(0.6)
                }
                .foregroundColor(Color(red: 10 / 255, green: 18 / 255, blue: 53 / 255))
            }

            if client.state != .connected {
                VStack {
                    Text("disconnected — retrying")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.7)))
                        .foregroundColor(.white)
                        .padding(.top, 8)
                    Spacer()
                }
            }
        }
    }
}
