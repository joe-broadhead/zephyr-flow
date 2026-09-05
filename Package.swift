// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ZephyrFlow",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ZephyrFlow", targets: ["ZephyrFlow"]),
        .library(name: "ZephyrFlowCore", targets: ["ZephyrFlowCore"]),
    ],
    dependencies: [
        // Pin to current major line used in Package.resolved (avoid silent major drift).
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.18.0"),
        // Explicit local-tokenizer API; same version/revision already resolved via WhisperKit.
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.1.9"),
    ],
    targets: [
        // Pure logic + protocols (unit-tested)
        .target(
            name: "ZephyrFlowCore",
            dependencies: [],
            path: "Sources/ZephyrFlowCore"
        ),
        // Full app
        .executableTarget(
            name: "ZephyrFlow",
            dependencies: [
                "ZephyrFlowCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Hub", package: "swift-transformers"),
            ],
            path: "Sources/ZephyrFlow"
        ),
        .testTarget(
            name: "ZephyrFlowTests",
            // Keep the app dependency available for production-adapter tests.
            // Core contracts and bounded in-memory adapter checks are tested;
            // this does not establish full production-path coverage (JOE-2243/2291).
            dependencies: ["ZephyrFlowCore", "ZephyrFlow"],
            path: "Tests/ZephyrFlowTests"
        ),
        // CLT-friendly runner (no XCTest / full Xcode required)
        .executableTarget(
            name: "ZephyrFlowCoreTests",
            dependencies: ["ZephyrFlowCore"],
            path: "Tests/ZephyrFlowCoreTests"
        ),
    ]
)
