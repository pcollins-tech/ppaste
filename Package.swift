// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PPasteCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "PPasteCore", targets: ["PPasteCore"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(name: "PPasteCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "PPasteCoreTests", dependencies: ["PPasteCore"]),
    ]
)
