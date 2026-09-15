// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "IPSWSync",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "IPSWSync", path: "Sources/IPSWSync")
    ]
)
