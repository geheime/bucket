// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Bucket",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything that is not UI: archive, bucket state, paste rendering.
        .target(name: "BucketCore", path: "Sources/BucketCore"),
        // The menu bar app (also hosts the headless CLI modes).
        .executableTarget(name: "Bucket", dependencies: ["BucketCore"], path: "Sources/Bucket"),
        // Assert-based checks: no XCTest / swift-testing on Command Line Tools only.
        .executableTarget(name: "BucketChecks", dependencies: ["BucketCore"], path: "Sources/BucketChecks"),
    ]
)
