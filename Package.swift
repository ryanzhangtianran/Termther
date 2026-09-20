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

private let testing = Target.Dependency.product(
    name: "Testing", package: "swift-testing")

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
        // CLT 27 omits TestingMacros even though its Testing framework exposes
        // @Test and #expect. This pins the upstream fix for Swift Build's
        // "unknown platform DoesNotExist" warning after the 6.3.2 release.
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "0cdad5ddc9e03a58fd782b3432be1d188e97cf26"),
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
            // Kept as source and compiled at runtime. A .metal extension makes
            // SwiftPM 6.4 invoke the `metal` tool, which the Command Line Tools
            // do not ship; the neutral extension and `.copy` preserve it.
            resources: [.copy("Render/shaders.metal-source")]),
        .target(
            name: "Core",
            dependencies: ["SSH", "EC", .product(name: "GRDB", package: "GRDB.swift")]),

        // The window itself. Top of the stack, so it may reach for any of
        // them -- the forwarding panel drives SSH directly, and the VPN panel
        // drives the tunnel engine.
        .target(name: "App", dependencies: ["Core", "VT", "Net", "SSH", "EC"]),
        .executableTarget(name: "termther", dependencies: ["App", "Core", "VT", "SSH", "Net"]),

        .testTarget(name: "NetTests", dependencies: ["Net", testing]),
        .testTarget(name: "SSHTests", dependencies: ["SSH", "Net", testing]),
        .testTarget(name: "ECTests", dependencies: ["EC", "Net", testing]),
        .testTarget(name: "VTTests", dependencies: ["VT", testing]),
        .testTarget(name: "CoreTests", dependencies: ["Core", testing]),
        .testTarget(name: "AppTests", dependencies: ["App", "Core", "SSH", "Net", testing]),
    ]
)
