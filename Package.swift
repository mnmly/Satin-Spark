// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Satin-Spark",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "SatinSpark",
            targets: ["SatinSpark"]
        ),
        .executable(
            name: "satin-spark-render-fixture",
            targets: ["SatinSparkRenderFixture"]
        ),
        .executable(
            name: "satin-spark-demo",
            targets: ["SatinSparkDemo"]
        ),
        .executable(
            name: "satin-spark-bench",
            targets: ["SatinSparkBench"]
        ),
    ],
    dependencies: [
        .package(path: "../Satin"),
    ],
    targets: [
        .target(
            name: "SatinSpark",
            dependencies: [
                .product(name: "Satin", package: "Satin"),
            ],
            resources: [
                .copy("Pipelines"),
            ]
        ),
        .executableTarget(
            name: "SatinSparkRenderFixture",
            dependencies: [
                "SatinSpark",
                .product(name: "Satin", package: "Satin"),
            ]
        ),
        .executableTarget(
            name: "SatinSparkDemo",
            dependencies: ["SatinSpark"]
        ),
        .executableTarget(
            name: "SatinSparkBench",
            dependencies: ["SatinSpark"]
        ),
        .testTarget(
            name: "SatinSparkTests",
            dependencies: ["SatinSpark"]
        ),
    ]
)
