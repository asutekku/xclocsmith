// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "xclocsmith",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "xclocsmith", targets: ["xclocsmith"]),
        .library(name: "XCLocSmithKit", targets: ["XCLocSmithKit"]),
    ],
    targets: [
        // All logic lives here so it can be tested without spawning a process.
        .target(name: "XCLocSmithKit"),
        // Argument parsing and process exit only.
        .executableTarget(name: "xclocsmith", dependencies: ["XCLocSmithKit"]),
        .testTarget(
            name: "XCLocSmithTests",
            dependencies: ["XCLocSmithKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
