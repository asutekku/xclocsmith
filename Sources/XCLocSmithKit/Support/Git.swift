import Foundation

/// The one thing this tool needs from git: the bytes of a file as some earlier
/// commit had it.
///
/// Shelling out rather than reading `.git` directly. Object storage, packfiles,
/// worktrees, submodules and alternates are a lot of format to reimplement for
/// one read, and `git` is already installed anywhere a `.xcstrings` is being
/// reviewed.
public enum Git {
    /// The repository root containing `directory`, for a caller outside this
    /// module deciding whether a git-based comparison is even possible.
    public static func repositoryRoot(of directory: String) -> String? {
        root(of: directory)
    }

    /// `git show <ref>:<path>`, or nil with the reason when git says no.
    ///
    /// The path must be repository-relative, which is what `git show` takes —
    /// an absolute path fails with a message about being outside the
    /// repository, and that message is passed through rather than swallowed.
    static func show(reference: String, path: String, directory: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory, "show", "\(reference):\(path)"]

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw SmithError.usage("could not run git: \(error.localizedDescription)")
        }
        // Read before waiting: a catalog larger than the pipe buffer deadlocks
        // a process that waits first, and catalogs run to megabytes.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SmithError.cannotRead(
                path: "\(reference):\(path)",
                reason: detail.isEmpty ? "git exited \(process.terminationStatus)" : detail
            )
        }
        return data
    }

    /// Whether `reference` names a commit.
    ///
    /// Checked once before any file is read, so a mistyped ref fails the run
    /// instead of turning every catalog into "this file is new" — which is what
    /// a per-file error looks like, and which would report a clean diff for a
    /// ref that does not exist.
    static func resolves(reference: String, directory: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory, "rev-parse", "--verify", "--quiet", "\(reference)^{commit}"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// The repository root containing `directory`, or nil if there is none.
    static func root(of directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory, "rev-parse", "--show-toplevel"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
