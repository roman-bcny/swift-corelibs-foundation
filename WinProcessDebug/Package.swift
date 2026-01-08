// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "WinProcessDebug",
    platforms: [.macOS(.v14)], // For local development; on Windows this is ignored
    targets: [
        .executableTarget(
            name: "WinProcessDebug",
            path: "Sources"
        )
    ]
)

