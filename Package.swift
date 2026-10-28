// swift-tools-version: 6.2
import PackageDescription

// The Mac app. Koi's core (the server, the `koi` command and libkoi, the
// link client the app embeds) is Zig, in src/core/; scripts/build-core.sh puts
// libkoi where this links it.
let package = Package(
    name: "Koi",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Koi",
            dependencies: ["GhosttyVt", "CKoi"],
            path: "src/app",
            exclude: ["resources"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .unsafeFlags(["-L\(Context.packageDirectory)/vendor/libkoi/lib"]),
                .linkedLibrary("koi"),
            ]
        ),
        .binaryTarget(name: "GhosttyVt", path: "vendor/GhosttyVt.xcframework"),
        .systemLibrary(name: "CKoi", path: "vendor/libkoi"),
        .testTarget(name: "KoiTests", dependencies: ["Koi"], path: "tests/app"),
    ]
)
