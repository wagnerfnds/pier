// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "pierctl",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/PierKit")],
    targets: [
        .executableTarget(
            name: "pierctl",
            dependencies: [.product(name: "PierKit", package: "PierKit")]
        )
    ]
)
