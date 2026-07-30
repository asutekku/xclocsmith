import Foundation

public enum Similarity {
    /// Levenshtein distance, abandoned once it is known to exceed `limit`.
    /// Returns `limit + 1` in that case — callers must treat any value above
    /// the limit as "not similar" rather than as a real distance.
    public static func editDistance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        let rows = a.count, columns = b.count
        if abs(rows - columns) > limit { return limit + 1 }
        if rows == 0 { return columns }
        if columns == 0 { return rows }

        var previous = Array(0...columns)
        var current = [Int](repeating: 0, count: columns + 1)

        for row in 1...rows {
            current[0] = row
            var rowMinimum = current[0]
            for column in 1...columns {
                let cost = a[row - 1] == b[column - 1] ? 0 : 1
                current[column] = min(previous[column] + 1, current[column - 1] + 1, previous[column - 1] + cost)
                rowMinimum = min(rowMinimum, current[column])
            }
            if rowMinimum > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[columns]
    }

    /// Similarity as a percentage, or 0 when the strings are further apart than
    /// `limit` edits.
    public static func percent(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 100 }
        let distance = editDistance(a, b, limit: limit)
        guard distance <= limit else { return 0 }
        return Int(((Double(longest - distance) / Double(longest)) * 100).rounded())
    }

    public static func percent(_ a: String, _ b: String) -> Int {
        let left = Array(a), right = Array(b)
        return percent(left, right, limit: max(left.count, right.count))
    }

    /// The largest edit distance that still rounds up to `threshold` percent.
    public static func distanceLimit(longest: Int, threshold: Int) -> Int {
        Int((Double(longest) * Double(100 - threshold) / 100).rounded())
    }
}
