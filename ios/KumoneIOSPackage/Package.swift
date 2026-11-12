// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KumoneIOSFeature",
    defaultLocalization: "zh-Hans",
    platforms: [.iOS(.v16_1)],
    products: [
        .library(
            name: "KumoneIOSFeature",
            targets: ["KumoneIOSFeature"]
        ),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .target(
            name: "KumoneIOSFeature",
            dependencies: [
                .product(name: "KumoneCore", package: "kun"),
            ],
            path: "Sources/KumoneIOSFeature"
        ),
        .testTarget(
            name: "KumoneIOSFeatureTests",
            dependencies: [
                "KumoneIOSFeature"
            ]
        ),
    ]
)
