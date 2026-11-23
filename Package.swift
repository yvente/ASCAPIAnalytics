// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ASCAPIAnalytics",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ASCAPIAnalytics",
            targets: ["ASCAPIAnalytics"]
        )
    ],
    dependencies: [
        // All App Store Connect authentication and API requests are delegated
        // to ASCAPIKit. Keep this on compatible 0.5.x releases only; changing
        // this constraint requires an explicit architecture decision record.
        .package(
            url: "https://github.com/yvente/ASCAPIKit.git",
            .upToNextMinor(from: "0.5.0")
        )
    ],
    targets: [
        .target(
            name: "ASCAPIAnalytics",
            dependencies: [
                .product(name: "ASCAPIKit", package: "ASCAPIKit")
            ]
        ),
        .executableTarget(
            name: "ASCAnalyticsVerify",
            dependencies: [
                "ASCAPIAnalytics"
            ],
            path: "Sources/ASCAnalyticsVerify"
        ),
        .testTarget(
            name: "ASCAPIAnalyticsTests",
            dependencies: [
                "ASCAPIAnalytics",
                .product(name: "ASCAPIKit", package: "ASCAPIKit")
            ]
        )
    ]
)
