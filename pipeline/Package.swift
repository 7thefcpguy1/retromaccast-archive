// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "RMCPipeline",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "RMCCore", targets: ["RMCCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup", from: "2.7.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0"),
    ],
    targets: [
        .target(
            name: "RMCCore",
            dependencies: ["SwiftSoup", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(
            name: "rmc-pipeline",
            dependencies: [
                "RMCCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
