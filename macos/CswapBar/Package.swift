// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CswapBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "CswapBar", path: "Sources/CswapBar")
    ]
)
