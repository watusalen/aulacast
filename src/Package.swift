// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AulaCast",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "AulaCast",
            targets: ["AulaCast"]
        ),
        .executable(
            name: "AulaCastTestRunner",
            targets: ["AulaCastTestRunner"]
        )
    ],
    targets: [
        .target(
            name: "AulaCastCore",
            path: "sources/aulacast"
        ),
        .executableTarget(
            name: "AulaCast",
            dependencies: ["AulaCastCore"],
            path: "sources/aulacast-app"
        ),
        .executableTarget(
            name: "AulaCastTestRunner",
            dependencies: ["AulaCastCore"],
            path: "tests/aulacast-tests"
        )
    ]
)