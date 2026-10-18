// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StrandAnalytics",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "StrandAnalytics", targets: ["StrandAnalytics"]),
        .library(name: "WhoopProtocol", targets: ["WhoopProtocol"]),
    ],
    targets: [
        .target(name: "StrandAnalytics"),
        .target(name: "WhoopProtocol"),
        .testTarget(name: "StrandAnalyticsTests", dependencies: ["StrandAnalytics", "WhoopProtocol"]),
    ]
)
