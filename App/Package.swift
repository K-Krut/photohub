// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PhotoHub",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "PhotoHub", path: "Sources/PhotoHub"),
        .executableTarget(name: "PhotoHubAnalyzer", path: "Sources/PhotoHubAnalyzer", resources: [.copy("Resources/labels.json"), .copy("Resources/sface-fp16.mlpackage")])
    ]
)
