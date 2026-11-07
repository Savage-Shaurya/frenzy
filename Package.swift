// swift-tools-version:6.0
import PackageDescription

let strict: [SwiftSetting] = [.enableUpcomingFeature("ExistentialAny")]

let package = Package(
    name: "Halo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Halo", targets: ["HaloApp"]),
        .executable(name: "HaloWorker", targets: ["HaloWorker"]),
        .library(name: "HaloCore", targets: ["HaloCore"]),
    ],
    targets: [
        // Models, protocols, registry, output naming, runner. No AppKit.
        .target(name: "HaloCore", swiftSettings: strict),
        // All file conversions (Apple frameworks only: ImageIO, PDFKit, AVFoundation, Vision).
        .target(name: "HaloConverters", dependencies: ["HaloCore"], swiftSettings: strict),
        // The ring, toasts and settings views (SwiftUI) plus pure ring geometry.
        .target(name: "HaloUI", dependencies: ["HaloCore"], swiftSettings: strict),
        // System-wide drag detection and the drop-accepting overlay panel (AppKit).
        .target(name: "HaloDrag", dependencies: ["HaloCore", "HaloUI"], swiftSettings: strict),
        // The sandboxed conversion worker (XPC service): engine, listener, sandbox self-test. Testable.
        .target(name: "HaloWorkerKit", dependencies: ["HaloCore"], path: "Sources/HaloWorker/Kit", swiftSettings: strict),
        // The XPC service executable, packaged as Halo.app/Contents/XPCServices/com.snappycrew.halo.worker.xpc.
        .executableTarget(name: "HaloWorker", dependencies: ["HaloCore", "HaloConverters", "HaloWorkerKit"],
                          path: "Sources/HaloWorker/Main", swiftSettings: strict),
        // Menu-bar app: wiring, settings, launch at login.
        .executableTarget(name: "HaloApp", dependencies: ["HaloCore", "HaloConverters", "HaloUI", "HaloDrag"], swiftSettings: strict),
        .testTarget(name: "HaloCoreTests", dependencies: ["HaloCore"]),
        .testTarget(name: "HaloConvertersTests", dependencies: ["HaloCore", "HaloConverters"]),
        // HaloConverters only so the main-window renders use the real action registry.
        .testTarget(name: "HaloUITests", dependencies: ["HaloUI", "HaloConverters"]),
        .testTarget(name: "HaloDragTests", dependencies: ["HaloDrag"]),
        .testTarget(name: "HaloWorkerTests", dependencies: ["HaloCore", "HaloWorkerKit"]),
    ]
)
