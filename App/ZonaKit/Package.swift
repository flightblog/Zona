// swift-tools-version: 6.0
import PackageDescription

// ZonaKit holds the ride core: BLE decoding, zone math, ride recording and
// summarizing, TCX export, intervals, HRV.
//
// The provider-agnostic OAuth/token plumbing is NOT here — it lives in
// HealthConnectKit, shared with the Helix aggregator so a fix benefits both apps
// and neither re-inherits the other's bugs. Until that repo is published, the
// dependency below is a local path to a sibling checkout. Once it's on GitHub,
// swap it for the commented remote form so CI can resolve it without a checkout
// next door:
//
//     .package(url: "https://github.com/flightblog/HealthConnectKit.git", from: "0.1.0")
//
// Keep exactly one of the two active.
let package = Package(
    name: "ZonaKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ZonaKit", targets: ["ZonaKit"])
    ],
    dependencies: [
        .package(name: "HealthConnectKit", path: "../../../HealthConnectKit")
    ],
    targets: [
        .target(
            name: "ZonaKit",
            dependencies: [.product(name: "HealthConnectKit", package: "HealthConnectKit")]
        ),
        .testTarget(name: "ZonaKitTests", dependencies: ["ZonaKit"])
    ]
)
