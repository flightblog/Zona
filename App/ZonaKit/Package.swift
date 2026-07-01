// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZonaKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ZonaKit", targets: ["ZonaKit"])
    ],
    targets: [
        .target(name: "ZonaKit"),
        .testTarget(name: "ZonaKitTests", dependencies: ["ZonaKit"])
    ]
)
