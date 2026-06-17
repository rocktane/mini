// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Mini",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "MiniApp",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/MiniApp"
        ),
        .executableTarget(
            name: "MiniCLI",
            path: "Sources/MiniCLI"
        ),
    ]
)
