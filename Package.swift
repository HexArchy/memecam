// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemeCam",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MemeCam", targets: ["MemeCam"])
    ],
    targets: [
        // Pure, platform-light logic (signals -> reaction). Fully unit-testable.
        .target(name: "MemeCamCore"),
        // Memes live in Resources/Memes and are copied into the .app by scripts/build-app.sh.
        .executableTarget(name: "MemeCam", dependencies: ["MemeCamCore"]),
        // Dev tool: `swift run memecam-eval <recording.json>` — per-label feature stats + scores.
        .executableTarget(name: "memecam-eval", dependencies: ["MemeCamCore"], path: "Tools/memecam-eval"),
        .testTarget(name: "MemeCamCoreTests", dependencies: ["MemeCamCore"]),
    ]
)
