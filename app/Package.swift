// swift-tools-version:5.9
import Foundation
import PackageDescription

// The Rust ad blocker is built into adblock/target/release/libmizu_adblock.a
// by build.sh (or `cargo build --release`); point the linker at it.
let adblockLib = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../adblock/target/release").standardized.path

let package = Package(
    name: "Mizu",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(name: "CAdblock", path: "Sources/CAdblock"),
        .executableTarget(
            name: "Mizu",
            dependencies: ["CAdblock", .product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/Mizu",
            linkerSettings: [
                .unsafeFlags(["-L\(adblockLib)"]),
                .linkedLibrary("mizu_adblock"),
                .linkedFramework("WebKit"),
                .linkedFramework("Security"),
            ]
        ),
    ]
)
