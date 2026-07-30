// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "xclocsmith",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "xclocsmith", targets: ["xclocsmith"]),
        .executable(name: "xclocsmith-mcp", targets: ["xclocsmith-mcp"]),
        .library(name: "XCLocSmithKit", targets: ["XCLocSmithKit"]),
    ],
    targets: [
        // All logic lives here so it can be tested without spawning a process.
        .target(name: "XCLocSmithKit"),
        // Argument parsing and process exit only.
        .executableTarget(name: "xclocsmith", dependencies: ["XCLocSmithKit"]),
        // MCP server over stdio. Reading and writing tools are separate, so a
        // host can grant one set and confirm the other.
        .executableTarget(name: "xclocsmith-mcp", dependencies: ["XCLocSmithKit"]),
        .testTarget(name: "XCLocSmithTests", dependencies: ["XCLocSmithKit", "xclocsmith"]),
    ]
)
