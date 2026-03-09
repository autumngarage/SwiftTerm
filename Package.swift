// swift-tools-version:5.9
//
// Vesper's fork of SwiftTerm. This manifest is intentionally narrower than
// upstream's: it declares the library and its tests only. Upstream's tool
// targets (SwiftTermFuzz, Termcast, SwiftTermBenchmarks) pull three external
// packages into any host that depends on this package, and Vesper consumes
// only the library product.

import PackageDescription

#if os(Linux) || os(Windows)
let platformExcludes = ["Apple", "Mac", "iOS"]
#else
let platformExcludes: [String] = []
#endif

let package = Package(
    name: "SwiftTerm",
    platforms: [
        .iOS(.v13),
        .macOS(.v13),
        .tvOS(.v13),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "SwiftTerm",
            targets: ["SwiftTerm"]
        ),
    ],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: platformExcludes + ["Mac/README.md"]
        ),
        .testTarget(
            name: "SwiftTermTests",
            dependencies: ["SwiftTerm"],
            path: "Tests/SwiftTermTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
