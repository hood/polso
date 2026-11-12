// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Polso",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "Polso", path: "Sources/Polso")]
)
