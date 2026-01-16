import Foundation

/// User tier index for dynamically added/removed user entries
/// Uses PrefixTrie internally since user dictionary is small (<1000 entries)
/// and requires immediate insert/remove operations
///
/// This is separate from HotTierIndex to allow instant user word additions
/// without rebuilding the entire index.
final class UserTierIndex {

    // MARK: - Properties

    /// Pinyin trie for user entries
    private let pinyinTrie = PrefixTrie()

    /// Wubi trie for user entries
    private let wubiTrie = PrefixTrie()

    /// Lock for thread safety
    private let lock = NSLock()

    // MARK: - Properties

    var isEmpty: Bool {
        return pinyinTrie.codeCount == 0 && wubiTrie.codeCount == 0
    }

    var statistics: (pinyinCodes: Int, wubiCodes: Int) {
        return (pinyinTrie.codeCount, wubiTrie.codeCount)
    }

    // MARK: - Insert/Remove

    /// Insert a user entry
    func insert(code: String, entryId: UInt32, codeType: InputCodeType) {
        lock.lock()
        defer { lock.unlock() }

        switch codeType {
        case .pinyin:
            pinyinTrie.insert(code: code, entryId: entryId)
        case .wubi:
            wubiTrie.insert(code: code, entryId: entryId)
        }
    }

    /// Remove a user entry
    func remove(code: String, entryId: UInt32, codeType: InputCodeType) {
        lock.lock()
        defer { lock.unlock() }

        switch codeType {
        case .pinyin:
            pinyinTrie.remove(code: code, entryId: entryId)
        case .wubi:
            wubiTrie.remove(code: code, entryId: entryId)
        }
    }

    // MARK: - Search

    /// Search result from user tier
    struct SearchResult {
        let code: String
        let entryIds: [UInt32]
        let codeType: InputCodeType
    }

    /// Search for matches in user dictionary
    func search(prefix: String, limit: Int = 100) -> [SearchResult] {
        guard !prefix.isEmpty else { return [] }

        lock.lock()
        defer { lock.unlock() }

        var results: [SearchResult] = []

        // Search wubi trie
        let wubiMatches = wubiTrie.search(prefix: prefix, limit: limit)
        for (code, entryIds) in wubiMatches {
            results.append(SearchResult(code: code, entryIds: entryIds, codeType: .wubi))
        }

        // Search pinyin trie
        let pinyinMatches = pinyinTrie.search(prefix: prefix, limit: limit)
        for (code, entryIds) in pinyinMatches {
            results.append(SearchResult(code: code, entryIds: entryIds, codeType: .pinyin))
        }

        return results
    }

    /// Clear all user entries
    func clear() {
        lock.lock()
        defer { lock.unlock() }

        pinyinTrie.clear()
        wubiTrie.clear()
    }
}
