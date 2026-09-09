// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Oatmeal",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess.git", from: "4.2.2"),
    ],
    targets: [
        .executableTarget(
            name: "Oatmeal",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "KeychainAccess", package: "KeychainAccess"),
            ],
            path: "Sources/Oatmeal"
        ),
        .testTarget(name: "OatmealTests", dependencies: ["Oatmeal"])
    ]
)
