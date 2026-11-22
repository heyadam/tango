import Foundation
import Testing
import PaperLink
@testable import PaperPlayer

@Suite struct PlayerStoreTests {
    @Test func pairingIsRememberedAndForgotten() {
        let keys = MemoryLinkKeyStore()
        let store = PlayerStore(keys: keys, deviceName: "Test", screen: .zero, sendsRequests: false)
        #expect(store.link == .unpaired)
        #expect(!store.isPaired)
        let key = LinkKey.random()
        store.pair(with: key)
        #expect(store.link == .searching)
        #expect(keys.load() == key)
        // The next launch is paired from the start.
        #expect(PlayerStore(keys: keys, deviceName: "Test", screen: .zero).link == .searching)
        store.unpair()
        #expect(store.link == .unpaired)
        #expect(keys.load() == nil)
    }

    @Test func anUnpairedPlayerConnectsToNothing() {
        let store = PlayerStore(keys: MemoryLinkKeyStore(), deviceName: "Test", screen: .zero, sendsRequests: false)
        store.connect(to: .hostPort(host: .ipv4(.loopback), port: 9), name: "Nobody")
        #expect(store.link == .unpaired)
        #expect(store.live == nil)
    }
}
