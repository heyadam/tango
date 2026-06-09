// WebSocket client to tango's /ws/preview. The iOS simulator shares the
// host's network stack, so ws://localhost:<port> reaches the tango server
// directly. The port arrives via SIMCTL_CHILD_TANGO_WS_PORT → TANGO_WS_PORT
// (simctl strips the prefix when launching).

import Foundation
import SwiftUI

@MainActor
final class PreviewClient: ObservableObject {
    enum ConnState {
        case connecting
        case connected
        case disconnected
    }

    @Published private(set) var spec: WireSpec?
    @Published private(set) var screenId: String?
    @Published private(set) var state: ConnState = .connecting
    @Published private(set) var decodeErrorCount = 0

    let port: String

    private var task: URLSessionWebSocketTask?
    private var backoff: TimeInterval = 0.5
    private var reconnectWork: Task<Void, Never>?

    var currentScreen: WireScreen? {
        guard let spec, !spec.screens.isEmpty else { return nil }
        if let screenId, let match = spec.screens.first(where: { $0.id == screenId }) {
            return match
        }
        return spec.screens.first
    }

    init() {
        port = ProcessInfo.processInfo.environment["TANGO_WS_PORT"] ?? "3000"
        connect()
    }

    func reconnectIfNeeded() {
        if state != .connected { connect() }
    }

    private func connect() {
        reconnectWork?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        guard let url = URL(string: "ws://localhost:\(port)/ws/preview") else { return }
        state = .connecting
        let t = URLSession.shared.webSocketTask(with: url)
        task = t
        t.resume()
        sendHello(t)
        receiveLoop(t)
    }

    private func sendHello(_ t: URLSessionWebSocketTask) {
        let hello = #"{"type":"hello","client":"preview-host","version":1}"#
        t.send(.string(hello)) { _ in }
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.task === t else { return }
                switch result {
                case .success(let message):
                    self.state = .connected
                    self.backoff = 0.5
                    if case .string(let text) = message {
                        self.handle(text)
                    }
                    self.receiveLoop(t)
                case .failure:
                    self.state = .disconnected
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        do {
            let message = try JSONDecoder().decode(WireMessage.self, from: data)
            switch message.type {
            case "spec":
                // Keep the last good spec if this frame carries none.
                if let spec = message.spec { self.spec = spec }
                if let active = message.activeScreenId { self.screenId = active }
            case "show_screen":
                if let id = message.screenId { self.screenId = id }
            default:
                break // future message types — ignore, don't crash
            }
        } catch {
            // Malformed frame: keep rendering the last good spec.
            decodeErrorCount += 1
        }
    }

    private func scheduleReconnect() {
        reconnectWork?.cancel()
        let delay = backoff
        backoff = min(backoff * 2, 5.0)
        reconnectWork = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.connect() }
        }
    }
}
