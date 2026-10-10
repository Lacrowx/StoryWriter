// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StoryWriter",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "StoryWriter", targets: ["StoryWriter"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(name: "StoryWriter", dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "StoryWriterTests", dependencies: ["StoryWriter"])
    ]
)
