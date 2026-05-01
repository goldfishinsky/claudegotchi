// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PetCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PetCore", targets: ["PetCore"]),
        .executable(name: "claudegotchi-hook", targets: ["HookHelper"]),
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
        .executableTarget(
            name: "HookHelper",
            dependencies: ["PetCore"],
            path: "Sources/HookHelper"
        ),
        .testTarget(
            name: "PetCoreTests",
            dependencies: ["PetCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "HookHelperTests",
            dependencies: ["HookHelper", "PetCore"],
            path: "Tests/HookHelperTests"
        ),
    ]
)
