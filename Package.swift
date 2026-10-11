// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Landfill",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "LandfillCore"),
        .executableTarget(name: "Landfill", dependencies: ["LandfillCore"]),
        .testTarget(name: "LandfillCoreTests", dependencies: ["LandfillCore"]),
    ]
)
