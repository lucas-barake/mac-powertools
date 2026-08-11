// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ringlight",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Ringlight", path: "Sources/Ringlight")
    ]
)
