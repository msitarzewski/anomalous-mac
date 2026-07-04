// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AnomalousCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "AnomalousCore", targets: ["AnomalousCore"]),
        .executable(name: "RateLimitSpike", targets: ["RateLimitSpike"]),
        .executable(name: "AnomalousE2E", targets: ["AnomalousE2E"]),
        .executable(name: "AnomalousHelper", targets: ["AnomalousHelper"]),
    ],
    targets: [
        .target(
            name: "AnomalousCore",
            resources: [.copy("KnowledgeMap/knowledge-map.json")]
        ),
        .executableTarget(name: "RateLimitSpike", dependencies: ["AnomalousCore"]),
        .executableTarget(name: "AnomalousE2E", dependencies: ["AnomalousCore"]),
        .executableTarget(name: "AnomalousHelper", dependencies: ["AnomalousCore"]),
        .testTarget(
            name: "AnomalousCoreTests",
            dependencies: ["AnomalousCore"]
        ),
    ]
)
