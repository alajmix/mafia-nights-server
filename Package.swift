// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MafiaNightsServer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Run", targets: ["Run"])
    ],
    dependencies: [
        // Vapor 4
        .package(url: "https://github.com/vapor/vapor.git", from: "4.92.0")
    ],
    targets: [
        .target(name: "App", dependencies: [
            .product(name: "Vapor", package: "vapor")
        ],
        path: "Sources/App"),
        .executableTarget(
            name: "Run",
            dependencies: ["App"],
            path: "Sources/Run"
        )
    ]
)
