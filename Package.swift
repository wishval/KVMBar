// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KVMBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "KVMBar", targets: ["KVMBar"])
    ],
    targets: [
        .executableTarget(
            name: "KVMBar",
            path: "Sources/KVMBar"
        )
    ]
)
