import XCTest
@testable import XCLocSmithKit

/// Finding the nearest `.xclocsmith.json` at or above a directory.
///
/// The interesting property is not which file it finds — it is that the search
/// stops. The first version walked upward with `deletingLastPathComponent()`
/// and trusted `parent == current` to mean "reached the root". That does not
/// hold: once there is no component left to remove, Foundation answers `…/../`,
/// which is longer than its input and never equal to it. The loop then runs
/// forever, appending three characters to a path on every pass. It terminated
/// on a developer's machine and did not on a GitHub macOS runner, where `check`
/// in a directory with no catalogs burned twelve minutes and 1.2 GB before the
/// kernel killed it — the whole test suite failed on one call that should have
/// taken microseconds.
final class ConfigSearchTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The regression. A directory with no config above it anywhere has to
    /// answer "no" rather than walk to the end of memory.
    func testTheSearchTerminatesWhenThereIsNoConfigAnywhere() throws {
        let deep = root.appendingPathComponent("a/b/c/d/e/f")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

        let finished = expectation(description: "the upward search returned")
        DispatchQueue.global().async {
            _ = Configuration.findConfigFile(startingAt: deep.path)
            finished.fulfill()
        }
        // Bounded by the depth of the path, so this is thousands of times more
        // headroom than it needs. It is a deadlock detector, not a benchmark.
        wait(for: [finished], timeout: 10)
    }

    /// A path that has already reached the root is the case the old loop could
    /// not express, so it is worth its own test.
    func testTheRootDirectoryTerminates() {
        XCTAssertNil(Configuration.findConfigFile(startingAt: "/"))
    }

    func testAConfigInTheDirectoryItselfIsFound() throws {
        let config = root.appendingPathComponent(Configuration.fileName)
        try "{}".write(to: config, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            Configuration.findConfigFile(startingAt: root.path).map(resolved),
            resolved(config.path)
        )
    }

    /// The reason the search walks upward at all: run the tool from a
    /// subdirectory and it should still find the project's config.
    func testAConfigAboveTheStartingDirectoryIsFound() throws {
        let config = root.appendingPathComponent(Configuration.fileName)
        try "{}".write(to: config, atomically: true, encoding: .utf8)
        let deep = root.appendingPathComponent("Sources/Feature/Views")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

        XCTAssertEqual(
            Configuration.findConfigFile(startingAt: deep.path).map(resolved),
            resolved(config.path)
        )
    }

    /// The nearest one wins, so a package inside a repository gets its own.
    func testTheNearestConfigWins() throws {
        let outer = root.appendingPathComponent(Configuration.fileName)
        try "{}".write(to: outer, atomically: true, encoding: .utf8)
        let inner = root.appendingPathComponent("Packages/Feature")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let innerConfig = inner.appendingPathComponent(Configuration.fileName)
        try "{}".write(to: innerConfig, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            Configuration.findConfigFile(startingAt: inner.path).map(resolved),
            resolved(innerConfig.path)
        )
    }

    /// A trailing slash is the same directory, and a non-existent path is a
    /// question with an answer rather than a hang.
    func testAwkwardPathsStillTerminate() throws {
        let config = root.appendingPathComponent(Configuration.fileName)
        try "{}".write(to: config, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            Configuration.findConfigFile(startingAt: root.path + "/").map(resolved),
            resolved(config.path)
        )
        XCTAssertEqual(
            Configuration.findConfigFile(startingAt: root.appendingPathComponent("nope/nope").path).map(resolved),
            resolved(config.path)
        )
    }

    /// `/private/var` and `/var` are the same directory on macOS, and which one
    /// a temporary path reports differs by how it was built.
    private func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
    }
}
