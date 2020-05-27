// swift-tools-version:5.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SRVResolver",
    platforms: [
       .macOS(.v10_15)
    ],
    products: [
        .library(
            name: "SRVResolver",
            targets: ["SRVResolver"]),
    ],
    dependencies: [
    ],
    targets: [
        .target(name: "SRVResolver",
                linkerSettings: [
                    .linkedLibrary("resolv")
                ]),
        .testTarget(
            name: "SRVResolverTests",
            dependencies: [
                "SRVResolver",
            ]
        )
    ]
)
