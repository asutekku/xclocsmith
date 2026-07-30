import Foundation

/// One accepted finding, identified by what it is rather than by where it is.
///
/// Written out as readable JSON rather than hashed, because the file is
/// something a person reviews in a pull request: deleting a line un-suppresses
/// a finding, and a diff that says which string stopped being accepted is worth
/// more than one that says a hash changed.
public struct BaselineEntry: Hashable, Sendable, Comparable {
    public let rule: String
    public let file: String
    public let key: String
    public let language: String

    public init(rule: String, file: String, key: String, language: String) {
        self.rule = rule
        self.file = file
        self.key = key
        self.language = language
    }

    public static func < (left: BaselineEntry, right: BaselineEntry) -> Bool {
        (left.file, left.rule, left.key, left.language)
            < (right.file, right.rule, right.key, right.language)
    }
}

/// The findings a project has decided to live with, so that CI can fail on new
/// ones without first demanding that the old ones be fixed.
///
/// DuckDuckGo's catalogs carry 352 duplicate strings, 166 unlocalized strings
/// and 172 hygiene findings. There is no version of "fix these first" that ends
/// with the check being switched on, so the check never gets switched on, and
/// the 353rd duplicate arrives unnoticed. A baseline inverts that: today's
/// findings are accepted, tomorrow's are not, and the number can only go down.
///
/// It is deliberately not a suppression *rule* system. There are no globs and no
/// wildcards — every entry names one finding, so nothing can be silenced by
/// accident and the file cannot quietly grow to cover things nobody looked at.
public struct Baseline: Equatable, Sendable {
    public static let fileName = ".xclocsmith-baseline.json"

    public private(set) var entries: Set<BaselineEntry>

    public init(entries: Set<BaselineEntry> = []) {
        self.entries = entries
    }

    public init(findings: [Finding]) {
        self.entries = Set(findings.map(\.identity))
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    // MARK: - Applying

    public struct Result {
        /// Findings not in the baseline. These are what the run reports.
        public let reported: [Finding]
        /// How many findings the baseline accounted for.
        public let suppressed: Int
        /// Entries that matched nothing this run — defects that have been fixed,
        /// or that moved. Reported so the file can be tightened; a baseline
        /// nobody prunes stops being a ratchet and becomes a drawer.
        public let stale: [BaselineEntry]

        public init(reported: [Finding], suppressed: Int, stale: [BaselineEntry]) {
            self.reported = reported
            self.suppressed = suppressed
            self.stale = stale
        }
    }

    public func apply(to findings: [Finding]) -> Result {
        var reported: [Finding] = []
        var matched = Set<BaselineEntry>()
        for finding in findings {
            let identity = finding.identity
            if entries.contains(identity) {
                matched.insert(identity)
            } else {
                reported.append(finding)
            }
        }
        return Result(
            reported: reported,
            suppressed: findings.count - reported.count,
            stale: entries.subtracting(matched).sorted()
        )
    }

    // MARK: - Storage

    public static func load(path: String) throws -> Baseline {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw SmithError.cannotRead(path: path, reason: "unreadable")
        }
        let document: JSONValue
        do {
            document = try JSONParser.parse(data)
        } catch let error as JSONParseError {
            throw SmithError.invalidConfiguration(path: path, reason: error.description)
        }
        guard let fields = document.objectValue,
              let list = fields["findings"]?.arrayValue else {
            throw SmithError.invalidConfiguration(
                path: path,
                reason: "expected an object with a \"findings\" array"
            )
        }
        var entries = Set<BaselineEntry>()
        for item in list {
            guard let entry = item.objectValue, let rule = entry["rule"]?.stringValue else {
                throw SmithError.invalidConfiguration(
                    path: path,
                    reason: "every entry needs at least a \"rule\""
                )
            }
            entries.insert(BaselineEntry(
                rule: rule,
                file: entry["file"]?.stringValue ?? "",
                key: entry["key"]?.stringValue ?? "",
                language: entry["language"]?.stringValue ?? ""
            ))
        }
        return Baseline(entries: entries)
    }

    public func serialized(toolVersion: String) -> String {
        // Sorted, so the file is stable across runs and a diff shows only what
        // actually changed rather than however the set happened to iterate.
        let sorted = entries.sorted()
        let document = JSONValue.object([
            "version": .number("1"),
            "tool": .string(toolVersion),
            "findings": .array(sorted.map { entry in
                var fields: [String: JSONValue] = ["rule": .string(entry.rule)]
                if !entry.file.isEmpty { fields["file"] = .string(entry.file) }
                if !entry.key.isEmpty { fields["key"] = .string(entry.key) }
                if !entry.language.isEmpty { fields["language"] = .string(entry.language) }
                return .object(fields)
            }),
        ])
        return JSONWriter.text(document, style: .plain)
    }

    public func write(to path: String, toolVersion: String) throws {
        do {
            try serialized(toolVersion: toolVersion)
                .write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            throw SmithError.cannotWrite(path: path, reason: error.localizedDescription)
        }
    }
}

/// A report with a baseline applied.
///
/// Counts are recomputed from the surviving findings rather than carried over
/// from the original, which is only correct because every report's finding
/// count equals its failures plus its advisories — a property two tests pin.
public struct BaselinedReport: Report {
    public let command: String
    public let findings: [Finding]
    public let suppressed: Int
    public let stale: [BaselineEntry]
    /// Set when the run wrote or rewrote the baseline file.
    public let written: String?

    public init(
        command: String,
        result: Baseline.Result,
        written: String? = nil
    ) {
        self.command = command
        self.findings = result.reported
        self.suppressed = result.suppressed
        self.stale = result.stale
        self.written = written
    }

    public var failures: Int { findings.filter { $0.level == .error }.count }
    public var advisories: Int { findings.filter { $0.level != .error }.count }

    public var jsonValue: JSONValue {
        .object([
            "command": .string(command),
            "baseline": .object([
                "suppressed": .number("\(suppressed)"),
                "stale": .array(stale.map { entry in
                    .object([
                        "rule": .string(entry.rule),
                        "file": .string(entry.file),
                        "key": .string(entry.key),
                        "language": .string(entry.language),
                    ])
                }),
                "written": written.map { JSONValue.string($0) } ?? .null,
            ]),
            "findings": .array(findings.map { finding in
                var fields: [String: JSONValue] = [
                    "rule": .string(finding.rule),
                    "level": .string(finding.level.rawValue),
                    "message": .string(finding.message),
                ]
                if let file = finding.file { fields["file"] = .string(file) }
                if let line = finding.line { fields["line"] = .number("\(line)") }
                if let key = finding.key { fields["key"] = .string(key) }
                if let language = finding.language { fields["language"] = .string(language) }
                return .object(fields)
            }),
            "failures": .number("\(failures)"),
            "advisories": .number("\(advisories)"),
        ])
    }
}
