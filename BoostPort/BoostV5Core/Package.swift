// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "BoostV5Core",
    targets: [
        .target(name: "BoostV5Core"),
        .testTarget(name: "BoostV5CoreTests", dependencies: ["BoostV5Core"])
    ]
)
