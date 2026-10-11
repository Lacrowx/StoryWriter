// swift-tools-version: 5.9
import PackageDescription

// MLX is an Apple Silicon runtime. The universal build omits it from the
// Intel slice while retaining the native editor and existing review backends.
let mlxEnabled: Bool
if let override = Context.environment["STORYWRITER_DISABLE_MLX"] {
    mlxEnabled = override != "1"
} else {
    #if arch(arm64)
    mlxEnabled = true
    #else
    mlxEnabled = false
    #endif
}
let mlxDependencies: [Target.Dependency] = mlxEnabled ? [
    .product(name: "MLXLLM", package: "mlx-swift-lm"),
    .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
    .product(name: "MLX", package: "mlx-swift")
] : []

let package = Package(
    name: "StoryWriter",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "StoryWriter", targets: ["StoryWriter"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "2.31.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.3"),
        // Keep transitive resolution compatible with the Swift 6.2 CI floor.
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.3.0")
    ],
    targets: [
        .executableTarget(name: "StoryWriter", dependencies: [.product(name: "Sparkle", package: "Sparkle")] + mlxDependencies,
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "StoryWriterTests", dependencies: ["StoryWriter"])
    ]
)
