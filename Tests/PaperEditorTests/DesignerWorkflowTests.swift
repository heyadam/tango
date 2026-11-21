import AppKit
import Foundation
import Testing
import PaperEngine
import PaperModel
@testable import PaperEditor

/// A designer builds a small app from an empty document, the way the Canvas lets them,
/// and plays it. Each step is what a person does; each check is what they would expect to
/// see. Written to find where the workflow breaks.
@MainActor
@Suite struct DesignerWorkflowTests {
    typealias Bench = CanvasInteractionTests.Bench
    let frame = 1.0 / 60

    func draw(_ bench: Bench, _ tool: CanvasTool, from: CGPoint, to: CGPoint) {
        bench.store.tool = tool
        bench.sync()
        bench.press(bench.at(from.x, from.y))
        bench.drag(to: bench.at(to.x, to.y), from: bench.at(from.x, from.y))
        bench.release(bench.at(to.x, to.y))
    }

    func named(_ store: DocumentStore, _ name: String) throws -> Layer {
        try #require(store.document.screen.flattened.first { $0.name == name }, "no view called \(name)")
    }

    func tap(_ runtime: Runtime, _ point: CGPoint) {
        runtime.send(.touchBegan(id: 0, Point2(x: point.x, y: point.y)))
        runtime.tick(dt: frame)
        runtime.send(.touchEnded(id: 0, Point2(x: point.x, y: point.y)))
        for _ in 0..<300 where runtime.needsAnotherFrame { runtime.tick(dt: frame) }
    }

    func middle(of id: LayerID, in runtime: Runtime) throws -> CGPoint {
        let box = try #require(runtime.resolved.find(id)).frame
        // Into the device's coordinates: what holds it may be a screen at the corner.
        let transform = try #require(runtime.resolved.transform(toRootFrom: id))
        return CGPoint(x: box.width / 2, y: box.height / 2).applying(transform)
    }

    /// A tab bar app: three tabs that switch at once, a settings screen pushed from one of
    /// them, and a sheet that comes up over everything.
    @Test func aTabBarAppWithAPushAndASheet() throws {
        let bench = Bench(Document.blank())
        let store = bench.store
        let width = store.document.screen.value(.size).sizeValue.width

        // 1. A heading on the one screen there is, then a second and third screen.
        draw(bench, .text, from: CGPoint(x: 20, y: 70), to: CGPoint(x: 200, y: 110))
        bench.click(CGPoint(x: bench.at(width, 400).x + 60, y: bench.at(0, 400).y))
        #expect(store.screens.count == 2, "the add slot made the first two screens")
        bench.click(CGPoint(x: bench.at(2 * width + Board.gap, 400).x + 60, y: bench.at(0, 400).y))
        #expect(store.screens.count == 3)
        for (index, name) in ["Home", "Search", "Profile"].enumerated() {
            store.renameLayer(store.screens[index].id, to: name)
        }
        bench.sync()
        let home = store.screens[0].id, search = store.screens[1].id, profile = store.screens[2].id
        #expect(store.screen(holding: try named(store, "Text").id)?.id == home, "the heading went with the first screen")

        // 2. A tab bar along the bottom of Home, shown on every screen.
        draw(bench, .view, from: CGPoint(x: 0, y: 790), to: CGPoint(x: width, y: 874))
        let bar = try #require(store.selectedLayer)
        #expect(store.screen(holding: bar.id)?.id == home)
        store.renameLayer(bar.id, to: "Tab Bar")
        store.move(bar.id, toScreen: nil)
        bench.sync()
        #expect(store.screen(holding: bar.id) == nil)
        // Its patch is somewhere free at the top level of the graph.
        let barPatch = try #require(store.viewNode(for: bar.id))
        let others = store.document.levelGraph(of: nil).nodes.filter { $0.id != barPatch.id }
        #expect(!others.contains { $0.position == barPatch.position }, "the moved view's patch is not on top of another")

        // 3. Three tabs in it: step in (double-click), draw them.
        bench.click(bench.at(width / 2, 830), clicks: 2)
        #expect(store.openView == bar.id, "a double-click on the bar steps into it")
        var tabs: [LayerID] = []
        for index in 0..<3 {
            let left = 30 + Double(index) * 130
            draw(bench, .view, from: CGPoint(x: left, y: 805), to: CGPoint(x: left + 80, y: 855))
            let tab = try #require(store.selectedLayer)
            #expect(store.document.screen.parent(of: tab.id)?.id == bar.id, "tab \(index) went into the bar")
            tabs.append(tab.id)
        }
        bench.key(53)
        bench.key(53)

        // 4. Each tab shows its screen at once.
        for (tab, screen) in zip(tabs, [home, search, profile]) {
            let choices = bench.canvas.flowChoices(from: tab, at: CGPoint(x: store.screens.firstIndex { $0.id == screen }.map { Double($0) * (width + Board.gap) + 100 } ?? 0, y: 300))
            let instant = try #require(choices.first { $0.title == "Instant" }, "a tab can show its own screen")
            instant.run()
            bench.sync()
        }
        #expect(store.flows.filter { $0.style == .replace }.count == 3)

        // 5. A Settings screen pushed from a button on Profile, and a Back on it.
        bench.click(CGPoint(x: bench.at(3 * width + 2 * Board.gap, 400).x + 60, y: bench.at(0, 400).y))
        let settings = try #require(store.screens.last).id
        store.renameLayer(settings, to: "Settings")
        let profileLeft = 2 * (width + Board.gap)
        draw(bench, .view, from: CGPoint(x: profileLeft + 20, y: 200), to: CGPoint(x: profileLeft + 300, y: 250))
        let open = try #require(store.selectedLayer)
        #expect(store.screen(holding: open.id)?.id == profile)
        store.addFlow(from: open.id, to: settings, style: .push)
        let settingsLeft = 3 * (width + Board.gap)
        draw(bench, .view, from: CGPoint(x: settingsLeft + 10, y: 60), to: CGPoint(x: settingsLeft + 90, y: 100))
        let back = try #require(store.selectedLayer)
        #expect(store.screen(holding: back.id)?.id == settings)
        store.addFlow(from: back.id, to: nil)

        // 6. A sheet from a button on Home.
        draw(bench, .view, from: CGPoint(x: 20, y: 300), to: CGPoint(x: 200, y: 350))
        let compose = try #require(store.selectedLayer)
        bench.click(CGPoint(x: bench.at(4 * width + 3 * Board.gap, 400).x + 60, y: bench.at(0, 400).y))
        let sheet = try #require(store.screens.last).id
        store.addFlow(from: compose.id, to: sheet, style: .modal)
        let sheetLeft = 4 * (width + Board.gap)
        draw(bench, .view, from: CGPoint(x: sheetLeft + 10, y: 60), to: CGPoint(x: sheetLeft + 90, y: 100))
        let dismiss = try #require(store.selectedLayer)
        store.addFlow(from: dismiss.id, to: nil)

        // To look at what was built: TANGO_WORKFLOW_OUT=<folder> keeps the document.
        if let folder = ProcessInfo.processInfo.environment["TANGO_WORKFLOW_OUT"] {
            let url = URL(fileURLWithPath: folder).appendingPathComponent("TabBarApp.tango")
            try? FileManager.default.removeItem(at: url)
            try store.package.fileWrapper().write(to: url, options: .atomic, originalContentsURL: nil)
        }

        // Play it.
        let runtime = Runtime(document: store.document, registry: store.runtimeRegistry)
        runtime.tick(dt: frame)
        #expect(runtime.navigation.current == home)
        #expect(runtime.resolved.children.map(\.id) == [home, bar.id], "Home with the tab bar over it")

        tap(runtime, try middle(of: tabs[2], in: runtime))
        #expect(runtime.navigation.current == profile, "the third tab shows Profile")
        tap(runtime, try middle(of: open.id, in: runtime))
        #expect(runtime.navigation.current == settings, "the button on Profile pushes Settings")
        #expect(runtime.resolved.children.map(\.id).contains(bar.id), "the tab bar stays over a pushed screen")

        // Switching tabs from a pushed screen starts that tab over: nothing to go back to.
        tap(runtime, try middle(of: tabs[0], in: runtime))
        #expect(runtime.navigation.current == home)
        #expect(!runtime.navigation.canGoBack, "a tab is not somewhere to go back from")

        // The sheet comes up over everything, the tab bar too, and takes its touches.
        tap(runtime, try middle(of: compose.id, in: runtime))
        #expect(runtime.navigation.current == sheet)
        #expect(runtime.resolved.children.last?.id == sheet, "a sheet covers the tab bar")
        tap(runtime, CGPoint(x: width / 2, y: 830))
        #expect(runtime.navigation.current == sheet, "the tab bar under a sheet cannot be tapped")
        tap(runtime, try middle(of: dismiss.id, in: runtime))
        #expect(runtime.navigation.current == home, "Back on the sheet dismisses it")
        #expect(runtime.resolved.children.last?.id == bar.id, "and the tab bar is on top again")
    }
}
