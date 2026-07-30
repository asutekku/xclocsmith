import Foundation

/// Finds catalogs and source roots when there is no configuration file.
///
/// Discovery is deliberately conservative about shared code: a directory of
/// Swift files that no catalog sits in (a local package, say) is attached as a
/// *reference* source to every target rather than as a compiled source. That
/// prevents false orphans without asserting that every target ships every
/// shared string — an assertion only the project's build settings can settle.
public enum ProjectDiscovery {
    /// Directory bundles that are never project sources.
    ///
    /// `.xcloc` matters most: an exported localization catalog carries a *copy*
    /// of every string catalog under "Source Contents", so walking into one
    /// makes the tool audit — and offer to prune — an export artifact instead
    /// of the files Xcode actually builds.
    static let opaqueBundleSuffixes = [
        ".xcodeproj", ".xcworkspace", ".xcloc", ".xcarchive", ".xcassets",
        ".app", ".framework", ".bundle", ".playground",
    ]

    static func isOpaqueBundle(_ component: String) -> Bool {
        opaqueBundleSuffixes.contains { component.hasSuffix($0) }
    }

    public static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public static func discoverCatalogs(root: String, excluded: Set<String>) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return [] }
        var found: [String] = []
        while let relative = enumerator.nextObject() as? String {
            let components = relative.split(separator: "/").map(String.init)
            if let last = components.last, excluded.contains(last) || isOpaqueBundle(last) {
                enumerator.skipDescendants()
                continue
            }
            if components.contains(where: { excluded.contains($0) || isOpaqueBundle($0) }) { continue }
            if relative.hasSuffix(".xcstrings") { found.append(relative) }
        }
        return found.sorted()
    }

    static func containsSwift(_ directory: String, excluded: Set<String>) -> Bool {
        guard let enumerator = FileManager.default.enumerator(atPath: directory) else { return false }
        while let relative = enumerator.nextObject() as? String {
            let components = relative.split(separator: "/").map(String.init)
            if components.contains(where: { excluded.contains($0) || isOpaqueBundle($0) }) { continue }
            if relative.hasSuffix(".swift") { return true }
        }
        return false
    }

    public static func discoverSourceDirectories(root: String, excluded: Set<String>) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return entries.sorted().filter { entry in
            guard !excluded.contains(entry), !entry.hasPrefix("."), !isOpaqueBundle(entry) else { return false }
            let path = URL(fileURLWithPath: root).appendingPathComponent(entry).path
            return isDirectory(path) && containsSwift(path, excluded: excluded)
        }
    }

    public static func discoverTargets(root: String, excluded: Set<String>) throws -> [Target] {
        let catalogs = discoverCatalogs(root: root, excluded: excluded)
        guard !catalogs.isEmpty else { throw SmithError.noCatalogs(searchedIn: root) }

        let sourceDirectories = discoverSourceDirectories(root: root, excluded: excluded)

        // Group catalogs by the directory they live in: several tables in one
        // directory belong to the same target.
        var byDirectory: [String: [String]] = [:]
        for catalog in catalogs {
            let directory = URL(fileURLWithPath: catalog).deletingLastPathComponent().path
            byDirectory[directory, default: []].append(catalog)
        }

        // The top-level directory a catalog belongs to, e.g. "App" for "App/Resources/…".
        func owner(of catalog: String) -> String? {
            catalog.split(separator: "/").first.map(String.init)
        }

        let owned = Set(catalogs.compactMap(owner(of:)))
        let shared = sourceDirectories.filter { !owned.contains($0) }

        if byDirectory.count == 1, let (_, group) = byDirectory.first {
            return [Target(
                name: owner(of: group[0]) ?? "default",
                sources: sourceDirectories.isEmpty ? ["."] : sourceDirectories,
                catalogs: group.sorted()
            )]
        }

        // Two catalog directories under one top-level folder would otherwise
        // both be named after it. Duplicate target names make the config
        // ambiguous — `--target` could not address either of them.
        var used = Set<String>()
        return byDirectory.keys.sorted().map { directory in
            let group = (byDirectory[directory] ?? []).sorted()
            let ownerName = owner(of: group[0])
            var sources: [String] = []
            if let ownerName, sourceDirectories.contains(ownerName) { sources.append(ownerName) }
            if sources.isEmpty { sources = [directory] }
            var name = ownerName ?? directory
            if !used.insert(name).inserted {
                name = directory
                var suffix = 2
                while !used.insert(name).inserted {
                    name = "\(directory) (\(suffix))"
                    suffix += 1
                }
            }
            return Target(
                name: name,
                sources: sources,
                referenceSources: shared,
                catalogs: group
            )
        }
    }
}

/// Collects files under a set of roots, honouring exclusions and de-duplicating
/// overlapping roots.
public enum FileCollector {
    public static func files(
        in directories: [String],
        configuration: Configuration,
        extensions: Set<String>
    ) -> [String] {
        var results: [String] = []
        var seen = Set<String>()

        for directory in directories {
            let absolute = configuration.absolute(directory)

            guard ProjectDiscovery.isDirectory(absolute) else {
                if FileManager.default.fileExists(atPath: absolute),
                   let ext = absolute.split(separator: ".").last.map(String.init),
                   extensions.contains(ext),
                   seen.insert(absolute).inserted {
                    results.append(absolute)
                }
                continue
            }

            guard let enumerator = FileManager.default.enumerator(atPath: absolute) else { continue }
            while let relative = enumerator.nextObject() as? String {
                let components = relative.split(separator: "/").map(String.init)
                if let last = components.last,
                   configuration.excludedDirectories.contains(last)
                    || ProjectDiscovery.isOpaqueBundle(last) {
                    enumerator.skipDescendants()
                    continue
                }
                guard let ext = relative.split(separator: ".").last.map(String.init),
                      extensions.contains(ext) else { continue }
                let path = URL(fileURLWithPath: absolute).appendingPathComponent(relative).standardized.path
                guard !configuration.isExcluded(path), seen.insert(path).inserted else { continue }
                results.append(path)
            }
        }
        return results.sorted()
    }
}
