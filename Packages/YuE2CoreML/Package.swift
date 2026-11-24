// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "YuE2CoreML",
    platforms: [.macOS(.v15), .iOS(.v18), .visionOS(.v2)],
    products: [
        .library(name: "YuE2CoreML", targets: ["YuE2CoreML"]),
        .executable(name: "yue2-coreml", targets: ["YuE2CoreMLCLI"]),
    ],
    targets: [
        .target(name: "YuE2CoreML", resources: [.copy("Resources/Decoder.metal")]),
        .executableTarget(name: "YuE2CoreMLCLI", dependencies: ["YuE2CoreML"]),
        .testTarget(name: "YuE2CoreMLTests", dependencies: ["YuE2CoreML"]),
    ]
)
