// swift-tools-version: 6.0
import PackageDescription

// Termther — a terminal that happens to speak SSH.
//
// Dependency direction is one-way:
//
//   Net   <- nothing            byte streams and file descriptors only
//   SSH   <- Net                sessions, channels
//   VPN   <- Net, EC/           the campus VPN, as one more transport
//   VT    <- nothing            emulation and rendering; never sees SSH
//   Core  <- SSH, VPN           models, vault, services
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
        .library(name: "VPN", targets: ["VPN"]),
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
        // Vendored C / Zig artifacts. Each ships its own modulemap, so
        // there are no hand-written shim targets.
        .binaryTarget(name: "CSSH2", path: "Vendor/libssh2.xcframework"),
        .binaryTarget(name: "GhosttyVt", path: "Vendor/ghostty-vt.xcframework"),
        // The EasyConnect engine, in Rust (EC/), shared with the Linux proxy;
        // Sources/VPN is the Swift over it.
        .binaryTarget(name: "CEC", path: "Vendor/ec.xcframework"),

        .target(name: "Net"),
        .target(
            name: "SSH",
            dependencies: ["Net", "CSSH2"],
            linkerSettings: [.linkedLibrary("z")]),
        .target(name: "VPN", dependencies: ["Net", "CEC"]),
        .target(name: "VT", dependencies: ["GhosttyVt"]),
        .target(
            name: "Core",
            dependencies: ["SSH", "VPN", .product(name: "GRDB", package: "GRDB.swift")]),

        // The window itself. Top of the stack, so it may reach for any of
        // them -- the forwarding panel drives SSH directly, and the VPN panel
        // drives the tunnel engine.
        .target(name: "App", dependencies: ["Core", "VT", "Net", "SSH", "VPN"]),
        .executableTarget(name: "termther", dependencies: ["App", "Core", "VT", "SSH", "Net"]),

        .testTarget(name: "NetTests", dependencies: ["Net", testing]),
        .testTarget(name: "SSHTests", dependencies: ["SSH", "Net", testing]),
        .testTarget(name: "VPNTests", dependencies: ["VPN", "Net", testing]),
        .testTarget(name: "VTTests", dependencies: ["VT", testing]),
        .testTarget(name: "CoreTests", dependencies: ["Core", "SSH", "VPN", testing]),
        .testTarget(name: "AppTests", dependencies: ["App", "Core", "SSH", "Net", testing]),
    ]
)
