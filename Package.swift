// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Macasnap",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Macasnap",
            path: "Sources/Macasnap",
            linkerSettings: [.linkedFramework("Carbon")]
        ),
    ]
)
