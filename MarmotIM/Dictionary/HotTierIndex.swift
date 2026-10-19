import Foundation

/// Hot tier index containing top N most frequent entries
/// Uses CompactIndex (sorted arrays) for memory efficiency
///
/// This replaces the in-memory PrefixTrie for system dictionary entries.
/// User dictionary entries are handled separately by UserTierIndex.
struct HotTierIndex {

    // MARK: - Properties

    /// Pinyin index (sorted array)
    private var pinyinIndex = CompactIndex()

    /// Wubi index (sorted array)
    private var wubiIndex = CompactIndex()

    /// Whether the index is fully loaded and ready for search
    private(set) var isPreloaded = false

    /// Lock for thread safety during loading
    private let lock = NSLock()

    // MARK: - Statistics

    var statistics: (pinyinCodes: Int, pinyinEntries: Int, wubiCodes: Int, wubiEntries: Int) {
        return (
            pinyinIndex.codeCount,
            pinyinIndex.entryCount,
            wubiIndex.codeCount,
            wubiIndex.entryCount
        )
    }

    // MARK: - Loading

    /// Load pinyin indexes from database
    /// - Parameter indexes: Array of (code, entryId) tuples
    mutating func loadPinyinIndexes(_ indexes: [(code: String, entryId: UInt32)]) {
        lock.lock()
        defer { lock.unlock() }

        // Group by code
        var grouped: [String: [UInt32]] = [:]
        for (code, entryId) in indexes {
            grouped[code, default: []].append(entryId)
        }

        // Convert to sorted array format
        let items = grouped.map { ($0.key, $0.value) }
        pinyinIndex.bulkLoad(items)

        NSLog("MarmotIM: HotTierIndex loaded \(pinyinIndex.codeCount) pinyin codes")
    }

    /// Load wubi indexes from database
    /// - Parameter indexes: Array of (code, entryId) tuples
    mutating func loadWubiIndexes(_ indexes: [(code: String, entryId: UInt32)]) {
        lock.lock()
        defer { lock.unlock() }

        // Group by code
        var grouped: [String: [UInt32]] = [:]
        for (code, entryId) in indexes {
            grouped[code, default: []].append(entryId)
        }

        // Convert to sorted array format
        let items = grouped.map { ($0.key, $0.value) }
        wubiIndex.bulkLoad(items)

        NSLog("MarmotIM: HotTierIndex loaded \(wubiIndex.codeCount) wubi codes")
    }

    /// Mark index as ready for search
    mutating func finalizePreload() {
        lock.lock()
        defer { lock.unlock() }
        isPreloaded = true
        NSLog("MarmotIM: HotTierIndex preload finalized")
    }

    // MARK: - Search

    /// Search result from hot tier
    struct SearchResult {
        let code: String
        let entryIds: [UInt32]
        let codeType: InputCodeType
    }

    /// Search for matches in both pinyin and wubi indexes
    /// - Parameters:
    ///   - prefix: The search prefix
    ///   - limit: Maximum results per index type
    /// - Returns: Combined results from both indexes
    func search(prefix: String, limit: Int = 100) -> [SearchResult] {
        // Guard: Don't search if not preloaded (prevents race conditions)
        guard isPreloaded else { return [] }
        guard !prefix.isEmpty else { return [] }

        var results: [SearchResult] = []

        // Search wubi index
        let wubiMatches = wubiIndex.search(prefix: prefix, limit: limit)
        for (code, entryIds) in wubiMatches {
            results.append(SearchResult(code: code, entryIds: entryIds, codeType: .wubi))
        }

        // Search pinyin index
        let pinyinMatches = pinyinIndex.search(prefix: prefix, limit: limit)
        for (code, entryIds) in pinyinMatches {
            results.append(SearchResult(code: code, entryIds: entryIds, codeType: .pinyin))
        }

        return results
    }

    /// Check if a code exists in either index
    func contains(code: String, codeType: InputCodeType) -> Bool {
        switch codeType {
        case .pinyin:
            return pinyinIndex.contains(code: code)
        case .wubi:
            return wubiIndex.contains(code: code)
        case .english:
            return false  // English handled by EnglishWordIndex
        }
    }
}
