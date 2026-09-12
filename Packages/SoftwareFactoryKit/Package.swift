// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SoftwareFactoryKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "SoftwareFactoryKit", targets: ["SoftwareFactoryKit"]),
        .executable(name: "software-factory", targets: ["software-factory"]),
    ],
    targets: [
        .target(name: "SoftwareFactoryKit"),
        .executableTarget(name: "software-factory", dependencies: ["SoftwareFactoryKit"]),
        .testTarget(name: "SoftwareFactoryKitTests", dependencies: ["SoftwareFactoryKit"]),
    ]
)
