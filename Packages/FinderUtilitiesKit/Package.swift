// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FinderUtilitiesKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "FinderUtilitiesKit", targets: ["FinderUtilitiesKit"])],
    targets: [
        .target(name: "FinderUtilitiesKit"),
        .testTarget(name: "FinderUtilitiesKitTests", dependencies: ["FinderUtilitiesKit"]),
    ]
)
