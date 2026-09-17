// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "IPSWSync",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "IPSWSync", path: "Sources/IPSWSync"),
        .testTarget(name: "IPSWSyncTests", dependencies: ["IPSWSync"], path: "Tests/IPSWSyncTests"),
    ]
)
