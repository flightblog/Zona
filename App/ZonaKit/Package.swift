// swift-tools-version: 6.0
import PackageDescription

// ZonaKit holds the ride core: BLE decoding, zone math, ride recording and
// summarizing, TCX export, intervals, HRV.
//
// The provider-agnostic OAuth/token plumbing is NOT here — it lives in
// HealthConnectKit, shared with the Helix aggregator so a fix benefits both apps
// and neither re-inherits the other's bugs.
//
// That repo exists (flightblog/HealthConnectKit, private) but is resolved here by
// relative path, NOT by URL: a fresh clone needs it checked out as a sibling
// (~/Dev/github/HealthConnectKit) or this manifest won't resolve. The path form is
// deliberate for now — the two packages are changing together, and a versioned URL
// dependency would mean tagging a release to land a two-line fix. Switch to
//
//     .package(url: "https://github.com/flightblog/HealthConnectKit.git", from: "0.1.0")
//
// once it stabilizes, and drop CI's checkout step at the same time. Keep exactly
// one of the two active.
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
