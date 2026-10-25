// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Clam",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ClamCore", targets: ["ClamCore"]),
        .executable(name: "Clam", targets: ["Clam"]),
    ],
    targets: [
        .target(name: "ClamCore"),
        .executableTarget(name: "Clam", dependencies: ["ClamCore"]),
        .testTarget(name: "ClamCoreTests", dependencies: ["ClamCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
