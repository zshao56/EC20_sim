// swift-tools-version: 5.9
import PackageDescription

let brewIncludeFlags = ["-Xcc", "-I/opt/homebrew/include", "-Xcc", "-I/opt/homebrew/include/libusb-1.0"]

let package = Package(
    name: "EC20Companion",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "EC20App", targets: ["EC20App"]),
        .executable(name: "ec20-cli", targets: ["EC20CLI"]),
        .executable(name: "ec20-tests", targets: ["EC20Tests"]),
        .library(name: "EC20BridgeProtocol", targets: ["EC20BridgeProtocol"]),
        .library(name: "EC20Core", targets: ["EC20Core"]),
        .library(name: "EC20Transport", targets: ["EC20Transport"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CLibUSB",
            cSettings: [
                .unsafeFlags(["-I/opt/homebrew/include", "-I/opt/homebrew/include/libusb-1.0"])
            ],
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/lib", "-lusb-1.0"])
            ]
        ),
        .target(
            name: "EC20BridgeProtocol",
            dependencies: []
        ),
        .target(
            name: "EC20Core",
            dependencies: ["EC20BridgeProtocol"]
        ),
        .target(
            name: "EC20Transport",
            dependencies: ["CLibUSB", "EC20Core"],
            cSettings: [
                .unsafeFlags(["-I/opt/homebrew/include", "-I/opt/homebrew/include/libusb-1.0"])
            ],
            swiftSettings: [
                .unsafeFlags(brewIncludeFlags)
            ]
        ),
        .executableTarget(
            name: "EC20App",
            dependencies: ["EC20Core", "EC20Transport", "EC20BridgeProtocol"],
            swiftSettings: [
                .unsafeFlags(brewIncludeFlags)
            ]
        ),
        .executableTarget(
            name: "EC20CLI",
            dependencies: ["EC20Core", "EC20Transport"],
            swiftSettings: [
                .unsafeFlags(brewIncludeFlags)
            ]
        ),
        .executableTarget(
            name: "EC20Tests",
            dependencies: ["EC20Core", "EC20Transport", "EC20BridgeProtocol"],
            swiftSettings: [
                .unsafeFlags(brewIncludeFlags)
            ]
        ),
    ]
)
