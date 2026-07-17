// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MeetWhisper",
    platforms: [
        .macOS("14.4")
    ],
    targets: [
        .executableTarget(
            name: "MeetWhisper",
            path: "Sources/MeetWhisper"
        )
    ]
)
