// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StoryWriter",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "StoryWriter", targets: ["StoryWriter"])],
    targets: [
        .executableTarget(name: "StoryWriter"),
        .testTarget(name: "StoryWriterTests", dependencies: ["StoryWriter"])
    ]
)
