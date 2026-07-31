// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FreeReps",
    platforms: [.iOS("17.6")],
    targets: [
        .target(
            name: "FreeReps",
            path: "Sources/FreeReps",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
