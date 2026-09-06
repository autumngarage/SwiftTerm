// swift-tools-version:6.0
//
// Vesper's fork of SwiftTerm. This manifest is deliberately narrower than
// upstream's: it declares the library and its tests only.
//
// Upstream also declares SwiftTermFuzz, Termcast and a benchmark target, which
// pull in swift-argument-parser, swift-docc-plugin and package-benchmark. SwiftPM
// resolves a dependency's whole manifest, so a host pinning this package would
// inherit all three. Vesper consumes the library product alone and keeps a single
// external dependency.
//
// Everything the library itself needs is kept: the build-info build-tool plugin
// and the Metal shader resource are not optional.

import PackageDescription
import Foundation

// A package manifest is compiled and run on the HOST, so `os(Linux)` is false
// when cross-compiling from macOS to Linux — and the Apple/Mac/iOS sources are
// then handed to the Linux target, which fails on `import CoreText`. There is
// no way for a manifest to see the destination, so allow the exclude to be
// forced explicitly.
let excludeAppleSources =
    ProcessInfo.processInfo.environment["SWIFTTERM_EXCLUDE_APPLE"] == "1"
#if os(Linux) || os(Windows)
let platformExcludes = ["Apple", "Mac", "iOS"]
#else
let platformExcludes: [String] = excludeAppleSources ? ["Apple", "Mac", "iOS"] : []
#endif

let package = Package(
    name: "SwiftTerm",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
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
            exclude: platformExcludes + ["Mac/README.md"],
            resources: [
                .process("Apple/Metal/Shaders.metal")
            ]
        ),
        .testTarget(
            name: "SwiftTermTests",
            dependencies: ["SwiftTerm"],
            path: "Tests/SwiftTermTests",
            resources: [
                .copy("Fixtures/xterm-ghostty.infocmp"),
                .copy("Fixtures/swifterm-terminfo.infocmp")
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
