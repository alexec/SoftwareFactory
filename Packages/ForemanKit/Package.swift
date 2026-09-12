// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ForemanKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "ForemanKit", targets: ["ForemanKit"]),
        .executable(name: "foreman", targets: ["foreman"]),
    ],
    targets: [
        .target(name: "ForemanKit"),
        .executableTarget(name: "foreman", dependencies: ["ForemanKit"]),
        .testTarget(name: "ForemanKitTests", dependencies: ["ForemanKit"]),
    ]
)
