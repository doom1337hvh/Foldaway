// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Foldaway",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Foldaway",
            path: "Sources/Foldaway"
        )
    ]
)
