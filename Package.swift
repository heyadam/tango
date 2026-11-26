// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "TangoKit",
    platforms: [.macOS(.v27), .iOS(.v27)],
    products: [
        .library(name: "PaperModel", targets: ["PaperModel"]),
        .library(name: "PaperEngine", targets: ["PaperEngine"]),
        .library(name: "PaperRender", targets: ["PaperRender"]),
        .library(name: "PaperHost", targets: ["PaperHost"]),
        .library(name: "PaperLink", targets: ["PaperLink"]),
        .library(name: "PaperEditor", targets: ["PaperEditor"]),
        .library(name: "PaperPlayer", targets: ["PaperPlayer"]),
    ],
    targets: [
        .target(name: "PaperModel"),
        .target(
            name: "PaperEngine",
            dependencies: ["PaperModel"],
            // The clip the Video Scrubbing pattern plays (`papertool sample-video`), and the
            // catalogs of icons and fonts (`scripts/update-catalogs.py`).
            resources: [.copy("Media"), .copy("Catalogs")]
        ),
        .target(
            name: "PaperRender",
            dependencies: ["PaperModel", "PaperEngine"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // The wire between the Mac and a phone's player. It knows documents, not the engine.
        .target(name: "PaperLink", dependencies: ["PaperModel"]),
        // What any host of a running prototype does that is not a view: its requests,
        // pictures and video files. The Mac's Viewer uses it, and so will the player.
        .target(
            name: "PaperHost",
            dependencies: ["PaperModel", "PaperEngine", "PaperRender"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .target(
            name: "PaperEditor",
            dependencies: ["PaperModel", "PaperEngine", "PaperRender", "PaperHost", "PaperLink"],
            // The assistant's Node program, installed in Application Support on first use.
            resources: [.copy("Assistant")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // The iOS player. Its views are iOS only; the Mac builds what is left, for tests.
        .target(
            name: "PaperPlayer",
            dependencies: ["PaperModel", "PaperEngine", "PaperHost", "PaperLink"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .executableTarget(
            name: "papertool",
            dependencies: ["PaperModel", "PaperEngine", "PaperEditor", "PaperLink"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "PaperModelTests", dependencies: ["PaperModel"]),
        .testTarget(name: "PaperEngineTests", dependencies: ["PaperEngine", "PaperModel"]),
        .testTarget(name: "PaperRenderTests", dependencies: ["PaperRender", "PaperEngine", "PaperModel"]),
        .testTarget(name: "PaperLinkTests", dependencies: ["PaperLink", "PaperModel"]),
        .testTarget(
            name: "PaperPlayerTests",
            dependencies: ["PaperPlayer", "PaperLink", "PaperHost", "PaperEngine", "PaperModel"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "PaperHostTests",
            dependencies: ["PaperHost", "PaperEngine", "PaperModel"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "PaperEditorTests", dependencies: ["PaperEditor", "PaperPlayer", "PaperLink", "PaperHost", "PaperEngine", "PaperModel"]),
    ],
    swiftLanguageModes: [.v6]
)
