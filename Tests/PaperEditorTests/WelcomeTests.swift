import Foundation
import PaperEngine
import Testing
@testable import PaperEditor

@MainActor
struct WelcomeTests {
    @Test func recentsKeepTangoFilesThatAreStillThere() {
        let urls = [
            URL(fileURLWithPath: "/Users/me/Work/Onboarding.tango"),
            URL(fileURLWithPath: "/Users/me/Work/notes.txt"),
            URL(fileURLWithPath: "/Users/me/Gone.tango"),
            URL(fileURLWithPath: "/Users/me/Work/./Onboarding.tango"),
            URL(fileURLWithPath: "/Volumes/Shared/Team.tango"),
            FileManager.default.temporaryDirectory.appendingPathComponent("Gallery-1/Card That Opens.tango"),
        ]
        let recents = WelcomeRecent.list(urls, home: "/Users/me", exists: { !$0.path.hasSuffix("Gone.tango") }, modified: { _ in nil })
        #expect(recents.map(\.name) == ["Onboarding", "Team"])
        #expect(recents.map(\.folder) == ["~/Work", "/Volumes/Shared"])
    }

    @Test func theHomeFolderIsOnlyAbbreviatedWhole() {
        #expect(WelcomeRecent.abbreviated("/Users/me", home: "/Users/me") == "~")
        #expect(WelcomeRecent.abbreviated("/Users/meg/Work", home: "/Users/me") == "/Users/meg/Work")
    }

    @Test func everyFeaturedExampleIsInTheGallery() {
        for id in WelcomeView.featuredExamples {
            #expect(Gallery.items.contains { $0.id == id }, "\(id)")
        }
    }
}
