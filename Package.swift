// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MafiaNightsServer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Run", targets: ["Run"])
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.86.0")
    ],
    targets: [
        .target(name: "App", dependencies: [
            .product(name: "Vapor", package: "vapor")
        ]),
        .executableTarget(name: "Run", dependencies: ["App"])
    ]
)
