// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentUsage",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentUsageApp", targets: ["AgentUsageApp"]),
        .library(name: "AgentUsageCore", targets: ["AgentUsageCore"]),
    ],
    targets: [
        .executableTarget(name: "AgentUsageApp", dependencies: ["AgentUsageCore"]),
        .target(name: "AgentUsageCore"),
        .testTarget(name: "AgentUsageCoreTests", dependencies: ["AgentUsageCore"]),
    ]
)
