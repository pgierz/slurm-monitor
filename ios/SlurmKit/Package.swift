// swift-tools-version: 5.10
// Tools version 5.10 keeps the package in the Swift 5 language mode on every
// toolchain, including the Swift 6 toolchain of Xcode 16.
import PackageDescription

let package = Package(
    name: "SlurmKit",
    platforms: [
        .iOS("18.0"),
        .macOS(.v14),
    ],
    products: [
        .library(name: "SlurmKit", targets: ["SlurmKit"]),
    ],
    targets: [
        .target(name: "SlurmKit", path: "Sources/SlurmKit"),
        .testTarget(name: "SlurmKitTests", dependencies: ["SlurmKit"], path: "Tests/SlurmKitTests"),
    ]
)
