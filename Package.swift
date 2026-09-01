// swift-tools-version: 6.0
import PackageDescription

// Termther — a terminal that happens to speak SSH.
//
// Dependency direction is one-way:
//
//   Net   <- nothing            byte streams and file descriptors only
//   SSH   <- Net                sessions, channels, SFTP
//   EC    <- Net                the campus VPN, as one more transport
//   VT    <- nothing            emulation and rendering; never sees SSH
//   Core  <- SSH, EC            models, vault, services
//   app   <- everything
//
// The three vendored binaries are built by Vendor/build-*.sh.

let package = Package(
    name: "Termther",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "termther", targets: ["termther"]),
        .library(name: "Net", targets: ["Net"]),
        .library(name: "SSH", targets: ["SSH"]),
        .library(name: "EC", targets: ["EC"]),
        .library(name: "VT", targets: ["VT"]),
        .library(name: "Core", targets: ["Core"]),
    ],
    dependencies: [
        // SQLite. Chosen over SwiftData because the store stays an ordinary
        // file anyone can inspect and repair, and because migrations here are
        // declarative and testable rather than inferred.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // Vendored C / Go / Zig artifacts. Each ships its own modulemap, so
        // there are no hand-written shim targets.
        .binaryTarget(name: "CSSH2", path: "Vendor/libssh2.xcframework"),
        .binaryTarget(name: "GhosttyVt", path: "Vendor/ghostty-vt.xcframework"),
        .binaryTarget(name: "CECShim", path: "Vendor/ecshim.xcframework"),

        .target(name: "Net"),
        .target(
            name: "SSH",
            dependencies: ["Net", "CSSH2"],
            linkerSettings: [.linkedLibrary("z")]),
        .target(
            name: "EC",
            dependencies: ["Net", "CECShim"],
            linkerSettings: [
                .linkedLibrary("resolv"),
                .linkedFramework("Security"),
            ]),
        .target(
            name: "VT",
            dependencies: ["GhosttyVt"],
            // Only the shader is a resource; the Swift beside it is source.
            // Declaring the directory would quietly stop compiling all of it.
            resources: [.process("Render/shaders.metal")]),
        .target(
            name: "Core",
            dependencies: ["SSH", "EC", .product(name: "GRDB", package: "GRDB.swift")]),

        // The window itself. Top of the stack, so it may reach for any of
        // them -- the forwarding panel drives SSH directly, and the VPN panel
        // drives the tunnel engine.
        .target(name: "App", dependencies: ["Core", "VT", "Net", "SSH", "EC"]),
        .executableTarget(name: "termther", dependencies: ["App", "Core", "VT", "SSH", "Net"]),

        .testTarget(name: "NetTests", dependencies: ["Net"]),
        .testTarget(name: "SSHTests", dependencies: ["SSH", "Net"]),
        .testTarget(name: "ECTests", dependencies: ["EC", "Net"]),
        .testTarget(name: "VTTests", dependencies: ["VT"]),
        .testTarget(name: "CoreTests", dependencies: ["Core"]),
        .testTarget(name: "AppTests", dependencies: ["App", "Core", "SSH", "Net"]),
    ]
)
