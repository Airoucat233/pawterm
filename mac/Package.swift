// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PawTerm",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PawTerm",
            path: "Sources/PawTerm"
        )
    ]
)
