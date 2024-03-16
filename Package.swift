// swift-tools-version: 5.7.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftOBD2",
    platforms: [
        .iOS(.v14),
        .macOS(.v12)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "SwiftOBD2",
            targets: ["SwiftOBD2"]
        )
    ],
//    dependencies: [
//        // ...
//        .package(url: "https://github.com/lukepistrol/SwiftLintPlugin", from: "0.2.2"),
//    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "SwiftOBD2"
//            plugins: [
//                .plugin(name: "SwiftLint", package: "SwiftLintPlugin")
//            ]
        ),
        .testTarget(
            name: "SwiftOBD2Tests",
            dependencies: ["SwiftOBD2"]
        )
    ]
)
