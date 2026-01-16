import Foundation

/// Memory-efficient index using sorted arrays with binary search
/// Replaces PrefixTrie for system dictionary (not user entries)
///
/// Memory usage: O(n) where n = total code characters + entry IDs
/// Search time: O(log n + k) where k = number of matches
struct CompactIndex {

    // MARK: - Storage

    /// Sorted array of codes
    private var codes: [String] = []

    /// Parallel array of entry ID arrays (same index as codes)
    private var entryIdArrays: [[UInt32]] = []

    /// Total number of unique codes
    var codeCount: Int { codes.count }

    /// Total number of entry IDs across all codes
    var entryCount: Int {
        entryIdArrays.reduce(0) { $0 + $1.count }
    }

    // MARK: - Loading

    /// Bulk load sorted data (must be pre-sorted by code)
    /// - Parameter items: Array of (code, entryIds) tuples, sorted by code
    mutating func bulkLoad(_ items: [(String, [UInt32])]) {
        // Sort by code to ensure binary search works
        let sorted = items.sorted { $0.0 < $1.0 }

        codes = sorted.map { $0.0 }
        entryIdArrays = sorted.map { $0.1 }
    }

    // MARK: - Search

    /// Search for codes matching the given prefix
    /// - Parameters:
    ///   - prefix: The prefix to search for
    ///   - limit: Maximum number of results
    /// - Returns: Array of (code, entryIds) tuples
    func search(prefix: String, limit: Int = 100) -> [(code: String, entryIds: [UInt32])] {
        guard !prefix.isEmpty, !codes.isEmpty else { return [] }

        // Binary search to find first code >= prefix
        var low = 0
        var high = codes.count

        while low < high {
            let mid = (low + high) / 2
            if codes[mid] < prefix {
                low = mid + 1
            } else {
                high = mid
            }
        }

        // Collect matches starting from 'low'
        var results: [(code: String, entryIds: [UInt32])] = []

        for i in low..<codes.count {
            let code = codes[i]

            // Stop if code no longer has the prefix
            guard code.hasPrefix(prefix) else { break }

            results.append((code, entryIdArrays[i]))

            if results.count >= limit { break }
        }

        return results
    }

    /// Check if index contains a specific code
    func contains(code: String) -> Bool {
        guard !code.isEmpty, !codes.isEmpty else { return false }

        // Binary search for exact match
        var low = 0
        var high = codes.count - 1

        while low <= high {
            let mid = (low + high) / 2
            let midCode = codes[mid]

            if midCode == code {
                return true
            } else if midCode < code {
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        return false
    }

    /// Get entry IDs for exact code match
    func exactMatch(code: String) -> [UInt32] {
        guard !code.isEmpty, !codes.isEmpty else { return [] }

        // Binary search for exact match
        var low = 0
        var high = codes.count - 1

        while low <= high {
            let mid = (low + high) / 2
            let midCode = codes[mid]

            if midCode == code {
                return entryIdArrays[mid]
            } else if midCode < code {
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        return []
    }
}
