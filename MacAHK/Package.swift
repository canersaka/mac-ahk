// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacAHK",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CEventCodec"),
        .executableTarget(
            name: "MacAHK",
            dependencies: ["CEventCodec"]
        ),
    ]
)
