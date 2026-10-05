// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LazyAsk",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LazyAskCore", targets: ["LazyAskCore"]),
        .executable(name: "LazyAsk", targets: ["LazyAsk"])
    ],
    targets: [
        .target(name: "LazyAskCore"),
        .executableTarget(name: "LazyAsk", dependencies: ["LazyAskCore"]),
        .testTarget(name: "LazyAskCoreTests", dependencies: ["LazyAskCore"]),
        .testTarget(name: "LazyAskNativeTests", dependencies: ["LazyAsk", "LazyAskCore"])
    ]
)
