// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WahooFTMSPrototype",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "WahooFTMSPrototype",
            path: "Sources/WahooFTMSPrototype",
            swiftSettings: [
                // The FTMS GATT constants (CBUUID) are conceptually immutable, but
                // CBUUID isn't Sendable, so Swift 6 strict concurrency rejects them
                // as global mutable state. Strict concurrency isn't the point of
                // this prototype; use the Swift 5 language mode.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
