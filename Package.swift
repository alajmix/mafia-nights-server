
// swift-tools-version:5.9
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
        .package(url: "https://github.com/vapor/vapor.git", from: "4.92.0")
    ],
    targets: [
        .executableTarget(
            name: "Run",
            dependencies: [
                .product(name: "Vapor", package: "vapor")
            ],
            path: "Sources"
        )
    ]
)
