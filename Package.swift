// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ModelShelf",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ShelfCore"),
        .executableTarget(name: "ModelShelf", dependencies: ["ShelfCore"]),
        .testTarget(name: "ShelfCoreTests", dependencies: ["ShelfCore"]),
    ]
)
