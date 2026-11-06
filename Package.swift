// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GracefulInstruments",
    platforms: [.macOS(.v11)],
    targets: [
        .executableTarget(
            name: "GracefulInstruments",
            path: "Sources/GracefulInstruments",
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .release))]
        )
    ]
)
