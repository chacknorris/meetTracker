// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MeetTracker",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MeetTracker", targets: ["MeetTracker"])
    ],
    targets: [
        .executableTarget(
            name: "MeetTracker",
            path: "Sources/MeetTracker",
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "MeetTrackerTests",
            dependencies: ["MeetTracker"],
            path: "Tests/MeetTrackerTests"
        )
    ]
)
