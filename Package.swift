// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "meeting-vault",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MeetingVaultCore",
            targets: ["MeetingVaultCore"]
        ),
        .executable(
            name: "meeting-vault",
            targets: ["meeting-vault"]
        ),
        .executable(
            name: "meeting-vault-app",
            targets: ["meeting-vault-app"]
        ),
    ],
    targets: [
        .target(
            name: "MeetingVaultCore"
        ),
        .executableTarget(
            name: "meeting-vault",
            dependencies: ["MeetingVaultCore"]
        ),
        .executableTarget(
            name: "meeting-vault-app",
            dependencies: [
                "MeetingVaultCore",
            ]
        ),
    ]
)
