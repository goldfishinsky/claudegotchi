// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PetCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PetCore", targets: ["PetCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.6"),
    ],
    targets: [
        .target(
            name: "PetCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "Yams",
            ]
        ),
        .testTarget(
            name: "PetCoreTests",
            dependencies: ["PetCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
