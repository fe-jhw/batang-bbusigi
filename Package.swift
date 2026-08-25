// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BatangBbusigi",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "BatangBbusigi", targets: ["BatangBbusigi"])
    ],
    targets: [
        .executableTarget(
            name: "BatangBbusigi",
            path: "Sources/BatangBbusigi",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
