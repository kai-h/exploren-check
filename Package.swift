// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ExplorenCheck",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "ExplorenCheck", path: "Sources/ExplorenCheck")
    ]
)
