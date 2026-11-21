// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TangoKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PaperModel", targets: ["PaperModel"]),
        .library(name: "PaperEngine", targets: ["PaperEngine"]),
        .library(name: "PaperRender", targets: ["PaperRender"]),
        .library(name: "PaperEditor", targets: ["PaperEditor"]),
    ],
    targets: [
        .target(name: "PaperModel"),
        .target(
            name: "PaperEngine",
            dependencies: ["PaperModel"],
            // The clip the Video Scrubbing pattern plays (`papertool sample-video`).
            resources: [.copy("Media")]
        ),
        .target(
            name: "PaperRender",
            dependencies: ["PaperModel", "PaperEngine"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .target(
            name: "PaperEditor",
            dependencies: ["PaperModel", "PaperEngine", "PaperRender"],
            // The assistant's Node program, installed in Application Support on first use.
            resources: [.copy("Assistant")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .executableTarget(
            name: "papertool",
            dependencies: ["PaperModel", "PaperEngine", "PaperEditor"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "PaperModelTests", dependencies: ["PaperModel"]),
        .testTarget(name: "PaperEngineTests", dependencies: ["PaperEngine", "PaperModel"]),
        .testTarget(name: "PaperRenderTests", dependencies: ["PaperRender", "PaperEngine", "PaperModel"]),
        .testTarget(name: "PaperEditorTests", dependencies: ["PaperEditor", "PaperEngine", "PaperModel"]),
    ],
    swiftLanguageModes: [.v6]
)
