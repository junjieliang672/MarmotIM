import Foundation

/// High-performance dictionary engine using SQLite + Trie architecture
///
/// This engine provides:
/// - O(k) prefix matching via in-memory Trie (k = code length)
/// - Persistent storage via SQLite
/// - Instant user word addition (no restart required)
/// - Background preloading for zero-latency IME switching
class DictionaryEngine {

    // MARK: - Properties

    /// Database for persistent storage
    private let db = VocabularyDatabase.shared

    /// Pinyin code Trie for fast prefix matching
    private let pinyinTrie = PrefixTrie()

    /// Wubi code Trie for fast prefix matching
    private let wubiTrie = PrefixTrie()

    /// In-memory cache of entries (LRU-style, loaded on demand)
    private var entriesCache: [UInt32: DictionaryEntry] = [:]

    /// User learning data cache
    private var userLearningCache: [UInt32: UserEntryData] = [:]

    /// Lock for thread-safe cache access
    private let cacheLock = NSLock()

    /// Whether the engine has been preloaded
    private(set) var isPreloaded = false

    /// Total entry count in database
    var entryCount: Int { db.getEntryCount() }

    /// Starting ID for user dictionary entries (to avoid conflicts)
    private static let userDictStartId: UInt32 = 0x80000000

    /// Counter for user dictionary entry IDs
    private var userDictNextId: UInt32 = DictionaryEngine.userDictStartId

    // MARK: - Initialization

    /// Initialize the dictionary engine
    /// Note: Actual loading happens via DictionaryPreloadService
    init() throws {
        // Engine is ready, but not preloaded yet
        // DictionaryPreloadService will call preload methods
        NSLog("MarmotIM: DictionaryEngine initialized")
    }

    /// Initialize with provided entries (for testing)
    init(entries: [DictionaryEntry]) throws {
        for entry in entries {
            entriesCache[entry.id] = entry
            if !entry.pinyin.isEmpty {
                pinyinTrie.insert(code: entry.pinyin, entryId: entry.id)
            }
            if let wubi = entry.wubi {
                wubiTrie.insert(code: wubi, entryId: entry.id)
            }
        }
        isPreloaded = true
        NSLog("MarmotIM: DictionaryEngine initialized with \(entries.count) test entries")
    }

    // MARK: - Preloading (called by DictionaryPreloadService)

    /// Bulk load pinyin indexes into Trie
    func bulkLoadPinyinIndexes(_ indexes: [(code: String, entryId: UInt32)]) {
        pinyinTrie.bulkInsert(indexes)
        NSLog("MarmotIM: Loaded \(pinyinTrie.codeCount) pinyin codes")
    }

    /// Bulk load wubi indexes into Trie
    func bulkLoadWubiIndexes(_ indexes: [(code: String, entryId: UInt32)]) {
        wubiTrie.bulkInsert(indexes)
        NSLog("MarmotIM: Loaded \(wubiTrie.codeCount) wubi codes")
    }

    /// Load user learning data into cache
    func loadUserLearningData(_ data: [UInt32: (accessCount: UInt32, lastAccessTimestamp: UInt32, totalScore: Double)]) {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        for (entryId, values) in data {
            userLearningCache[entryId] = UserEntryData(
                entryId: entryId,
                accessCount: values.accessCount,
                lastAccessTimestamp: values.lastAccessTimestamp,
                cachedScore: Float(values.totalScore)
            )
        }
        NSLog("MarmotIM: Loaded \(userLearningCache.count) user learning entries")
    }

    /// Finalize preloading
    func finalizePreload() {
        isPreloaded = true
        NSLog("MarmotIM: Preload finalized - pinyinTrie: \(pinyinTrie.codeCount) codes, wubiTrie: \(wubiTrie.codeCount) codes")
    }

    // MARK: - Search

    /// Search for entries matching the given code
    /// Uses Trie for O(k) prefix matching
    ///
    /// - Parameters:
    ///   - code: The input code (can be pinyin or wubi)
    ///   - limit: Maximum number of results
    /// - Returns: Array of matches
    func search(code: String, limit: Int = 50) -> [DictionaryMatch] {
        guard !code.isEmpty else { return [] }

        // Don't search if not preloaded yet - prevents race conditions
        guard isPreloaded else {
            return []
        }

        // Collect all entry IDs first, then batch fetch entries
        // This avoids N individual database queries
        var matchInfos: [(entryId: UInt32, matchedCode: String, codeType: DictionaryMatch.CodeType)] = []
        var seenEntryIds = Set<UInt32>()

        // Search wubi Trie FIRST (exact and prefix matches) - wubi has priority for short codes
        let wubiResults = wubiTrie.search(prefix: code, limit: limit)
        for (matchedCode, entryIds) in wubiResults {
            for entryId in entryIds {
                guard !seenEntryIds.contains(entryId) else { continue }
                seenEntryIds.insert(entryId)
                matchInfos.append((entryId, matchedCode, .wubi))
            }
        }

        // Search pinyin Trie (exact and prefix matches)
        let pinyinResults = pinyinTrie.search(prefix: code, limit: limit)
        for (matchedCode, entryIds) in pinyinResults {
            for entryId in entryIds {
                guard !seenEntryIds.contains(entryId) else { continue }
                seenEntryIds.insert(entryId)
                matchInfos.append((entryId, matchedCode, .pinyin))
            }
        }

        // Batch fetch all entries in a single database query
        let allIds = matchInfos.map { $0.entryId }
        let entriesMap = getEntries(ids: allIds)

        // Build matches with fetched entries
        var matches: [DictionaryMatch] = []
        for info in matchInfos {
            if let entry = entriesMap[info.entryId] {
                let matchType: DictionaryMatch.MatchType = info.matchedCode == code ? .full : .prefix
                matches.append(DictionaryMatch(
                    entry: entry,
                    matchedCode: info.matchedCode,
                    matchType: matchType,
                    codeType: info.codeType
                ))
            }
        }

        return Array(matches.prefix(limit))
    }

    /// Get entry by ID (from cache or database)
    func getEntry(id: UInt32) -> DictionaryEntry? {
        cacheLock.lock()
        if let cached = entriesCache[id] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // Fetch from database
        if let entry = db.getEntry(id: id) {
            cacheLock.lock()
            entriesCache[id] = entry
            cacheLock.unlock()
            return entry
        }

        return nil
    }

    /// Get multiple entries by IDs (batch fetch for efficiency)
    func getEntries(ids: [UInt32]) -> [UInt32: DictionaryEntry] {
        var results: [UInt32: DictionaryEntry] = [:]
        var uncachedIds: [UInt32] = []

        cacheLock.lock()
        for id in ids {
            if let cached = entriesCache[id] {
                results[id] = cached
            } else {
                uncachedIds.append(id)
            }
        }
        cacheLock.unlock()

        // Batch fetch uncached entries
        if !uncachedIds.isEmpty {
            let fetched = db.getEntries(ids: uncachedIds)
            cacheLock.lock()
            for (id, entry) in fetched {
                entriesCache[id] = entry
                results[id] = entry
            }
            cacheLock.unlock()
        }

        return results
    }

    // MARK: - User Learning

    /// Get user learning data for an entry
    func getUserLearning(entryId: UInt32) -> UserEntryData? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let data = userLearningCache[entryId]
        if let d = data {
            NSLog("MarmotIM: getUserLearning - entryId=%u, accessCount=%u, timestamp=%u",
                  entryId, d.accessCount, d.lastAccessTimestamp)
        }
        return data
    }

    /// Background queue for database writes
    private static let dbWriteQueue = DispatchQueue(label: "com.marmotim.dbwrite", qos: .utility)

    /// Record a selection (user chose this candidate)
    func recordSelection(entryId: UInt32, baseFrequency: UInt16) {
        cacheLock.lock()

        // Update cache
        if var data = userLearningCache[entryId] {
            data.recordAccess()
            data.updateCachedScore(baseFrequency: baseFrequency)
            userLearningCache[entryId] = data
            NSLog("MarmotIM: recordSelection - UPDATED entryId=%u, accessCount=%u, timestamp=%u",
                  entryId, data.accessCount, data.lastAccessTimestamp)
        } else {
            var newData = UserEntryData(entryId: entryId)
            newData.recordAccess()
            newData.updateCachedScore(baseFrequency: baseFrequency)
            userLearningCache[entryId] = newData
            NSLog("MarmotIM: recordSelection - NEW entryId=%u, accessCount=%u, timestamp=%u",
                  entryId, newData.accessCount, newData.lastAccessTimestamp)
        }

        let score = userLearningCache[entryId]?.cachedScore ?? 0
        let timestamp = userLearningCache[entryId]?.lastAccessTimestamp ?? 0
        cacheLock.unlock()

        NSLog("MarmotIM: recordSelection - cachedScore=%.0f, timestamp=%u", score, timestamp)

        // Persist to database asynchronously to avoid blocking main thread
        Self.dbWriteQueue.async { [weak self] in
            _ = self?.db.recordSelection(entryId: entryId, totalScore: Double(score))
        }
    }

    // MARK: - User Dictionary

    /// Add a user dictionary entry with immediate indexing
    /// The entry is available for search immediately - no restart required
    ///
    /// - Parameters:
    ///   - code: The input code (1-4 letters for wubi, unlimited for pinyin)
    ///   - text: The text to insert
    ///   - isWubi: Whether this is a wubi code (default: false, meaning pinyin)
    ///   - baseFrequency: Base frequency for ranking (default: 65000)
    /// - Returns: The new entry ID, or nil on failure
    @discardableResult
    func addUserEntry(code: String, text: String, isWubi: Bool = false, baseFrequency: UInt16 = 65000) -> UInt32? {
        // Validate code
        let maxCodeLength = isWubi ? 4 : 100  // Wubi max 4, pinyin unlimited
        guard code.count >= 1 && code.count <= maxCodeLength,
              code.allSatisfy({ $0.isLetter && $0.isASCII && $0.isLowercase }) else {
            NSLog("MarmotIM: Invalid user entry code: \(code)")
            return nil
        }

        let entryId = userDictNextId
        userDictNextId += 1

        // Create entry with specified baseFrequency
        let entry = DictionaryEntry(
            id: entryId,
            text: text,
            pinyin: isWubi ? "" : code,
            wubi: isWubi ? code : nil,
            baseFrequency: baseFrequency,
            source: EntrySource.user.rawValue,
            length: text.count
        )

        // Insert into database
        guard db.insertEntry(entry) else {
            NSLog("MarmotIM: Failed to insert user entry into database")
            return nil
        }

        // Insert into index table
        if isWubi {
            _ = db.insertWubiIndex(code: code, entryId: entryId)
        } else {
            _ = db.insertPinyinIndex(code: code, entryId: entryId)
        }

        // Update Trie immediately (available for next search)
        if isWubi {
            wubiTrie.insert(code: code, entryId: entryId)
        } else {
            pinyinTrie.insert(code: code, entryId: entryId)
        }

        // Add to cache
        cacheLock.lock()
        entriesCache[entryId] = entry
        cacheLock.unlock()

        NSLog("MarmotIM: Added user entry '\(text)' with code '\(code)' (id: \(entryId), baseFreq: \(baseFrequency))")
        return entryId
    }

    // MARK: - Dual Entry (划词入库)

    /// 双词条入库结果
    struct DualEntryResult {
        var wubiEntryId: UInt32?
        var pinyinEntryId: UInt32?
        var wubiWasExisting: Bool = false
        var pinyinWasExisting: Bool = false

        var success: Bool {
            return wubiEntryId != nil || pinyinEntryId != nil
        }

        var description: String {
            var parts: [String] = []
            if let wId = wubiEntryId {
                parts.append("wubi:\(wId)\(wubiWasExisting ? "(existing)" : "")")
            }
            if let pId = pinyinEntryId {
                parts.append("pinyin:\(pId)\(pinyinWasExisting ? "(existing)" : "")")
            }
            return parts.isEmpty ? "no entries" : parts.joined(separator: ", ")
        }
    }

    /// 同时添加五笔和拼音词条（划词入库功能核心方法）
    ///
    /// - Parameters:
    ///   - text: 要入库的文本
    ///   - wubiCode: 五笔编码（可选，如果为nil则跳过五笔入库）
    ///   - pinyinCode: 拼音编码（可选，如果为nil则跳过拼音入库）
    /// - Returns: 入库结果，包含创建的entry IDs
    @discardableResult
    func addDualEntry(text: String, wubiCode: String?, pinyinCode: String?) -> DualEntryResult {
        var result = DualEntryResult()

        NSLog("MarmotIM: addDualEntry - text='%@', wubiCode=%@, pinyinCode=%@",
              text,
              wubiCode ?? "nil",
              pinyinCode ?? "nil")

        // 1. 处理五笔入库
        if let code = wubiCode, code.count >= 1, code.count <= 4 {
            // 检查是否已存在
            if let existingId = findExistingEntry(text: text, code: code, isWubi: true) {
                // 已存在，仅更新 ranking
                result.wubiEntryId = existingId
                result.wubiWasExisting = true
                recordSelection(entryId: existingId, baseFrequency: 35000)
                NSLog("MarmotIM: addDualEntry - wubi entry exists, updated ranking (id: %u)", existingId)
            } else {
                // 新增词条，使用 4-char 模式的 baseFrequency
                if let entryId = addUserEntry(code: code, text: text, isWubi: true, baseFrequency: 35000) {
                    result.wubiEntryId = entryId
                    // 模拟一次选择
                    recordSelection(entryId: entryId, baseFrequency: 35000)
                    NSLog("MarmotIM: addDualEntry - created new wubi entry (id: %u)", entryId)
                }
            }
        }

        // 2. 处理拼音入库
        if let code = pinyinCode, !code.isEmpty {
            // 检查是否已存在
            if let existingId = findExistingEntry(text: text, code: code, isWubi: false) {
                // 已存在，仅更新 ranking
                result.pinyinEntryId = existingId
                result.pinyinWasExisting = true
                recordSelection(entryId: existingId, baseFrequency: 65000)
                NSLog("MarmotIM: addDualEntry - pinyin entry exists, updated ranking (id: %u)", existingId)
            } else {
                // 新增词条，使用 first 模式的 baseFrequency
                if let entryId = addUserEntry(code: code, text: text, isWubi: false, baseFrequency: 65000) {
                    result.pinyinEntryId = entryId
                    // 模拟一次选择
                    recordSelection(entryId: entryId, baseFrequency: 65000)
                    NSLog("MarmotIM: addDualEntry - created new pinyin entry (id: %u)", entryId)
                }
            }
        }

        NSLog("MarmotIM: addDualEntry complete - %@", result.description)
        return result
    }

    /// 删除词条结果
    struct RemovalResult {
        var wubiRemoved: Bool = false
        var pinyinRemoved: Bool = false
        var wubiFound: Bool = false
        var pinyinFound: Bool = false
        var wubiWasUserEntry: Bool = false
        var pinyinWasUserEntry: Bool = false

        var success: Bool {
            return wubiRemoved || pinyinRemoved
        }

        /// 词条完全不存在（两个都没找到）
        var notFound: Bool {
            return !wubiFound && !pinyinFound
        }

        /// 找到了但不是用户词条（系统词库）
        var foundButNotUserEntry: Bool {
            return (wubiFound || pinyinFound) && !wubiWasUserEntry && !pinyinWasUserEntry
        }

        var description: String {
            var parts: [String] = []
            if wubiRemoved {
                parts.append("wubi:removed")
            } else if wubiFound && !wubiWasUserEntry {
                parts.append("wubi:system_entry")
            } else if !wubiFound {
                parts.append("wubi:not_found")
            } else {
                parts.append("wubi:remove_failed")
            }
            if pinyinRemoved {
                parts.append("pinyin:removed")
            } else if pinyinFound && !pinyinWasUserEntry {
                parts.append("pinyin:system_entry")
            } else if !pinyinFound {
                parts.append("pinyin:not_found")
            } else {
                parts.append("pinyin:remove_failed")
            }
            return parts.joined(separator: ", ")
        }
    }

    /// 同时删除五笔和拼音词条（划词删除功能核心方法）
    ///
    /// - Parameters:
    ///   - text: 要删除的文本
    ///   - wubiCode: 五笔编码（可选）
    ///   - pinyinCode: 拼音编码（可选）
    /// - Returns: 删除结果
    @discardableResult
    func removeDualEntry(text: String, wubiCode: String?, pinyinCode: String?) -> RemovalResult {
        var result = RemovalResult()

        NSLog("MarmotIM: removeDualEntry - text='%@', wubiCode=%@, pinyinCode=%@",
              text,
              wubiCode ?? "nil",
              pinyinCode ?? "nil")

        // 1. 处理五笔删除
        if let code = wubiCode, !code.isEmpty {
            if let existingId = findExistingEntry(text: text, code: code, isWubi: true) {
                result.wubiFound = true
                NSLog("MarmotIM: removeDualEntry - found wubi entry (id: %u)", existingId)
                // 检查是否是用户词条
                if existingId >= DictionaryEngine.userDictStartId {
                    result.wubiWasUserEntry = true
                    if removeUserEntry(entryId: existingId) {
                        result.wubiRemoved = true
                        NSLog("MarmotIM: removeDualEntry - removed wubi entry (id: %u)", existingId)
                    } else {
                        NSLog("MarmotIM: removeDualEntry - FAILED to remove wubi entry (id: %u)", existingId)
                    }
                } else {
                    NSLog("MarmotIM: removeDualEntry - wubi entry is system entry (id: %u)", existingId)
                }
            } else {
                NSLog("MarmotIM: removeDualEntry - wubi entry not found for code '%@'", code)
            }
        }

        // 2. 处理拼音删除
        if let code = pinyinCode, !code.isEmpty {
            if let existingId = findExistingEntry(text: text, code: code, isWubi: false) {
                result.pinyinFound = true
                NSLog("MarmotIM: removeDualEntry - found pinyin entry (id: %u)", existingId)
                // 检查是否是用户词条
                if existingId >= DictionaryEngine.userDictStartId {
                    result.pinyinWasUserEntry = true
                    if removeUserEntry(entryId: existingId) {
                        result.pinyinRemoved = true
                        NSLog("MarmotIM: removeDualEntry - removed pinyin entry (id: %u)", existingId)
                    } else {
                        NSLog("MarmotIM: removeDualEntry - FAILED to remove pinyin entry (id: %u)", existingId)
                    }
                } else {
                    NSLog("MarmotIM: removeDualEntry - pinyin entry is system entry (id: %u)", existingId)
                }
            } else {
                NSLog("MarmotIM: removeDualEntry - pinyin entry not found for code '%@'", code)
            }
        }

        NSLog("MarmotIM: removeDualEntry complete - %@", result.description)
        return result
    }

    /// 查找已存在的词条
    ///
    /// - Parameters:
    ///   - text: 词条文本
    ///   - code: 编码
    ///   - isWubi: 是否是五笔编码
    /// - Returns: 已存在词条的ID，如果不存在则返回nil
    private func findExistingEntry(text: String, code: String, isWubi: Bool) -> UInt32? {
        // 搜索该编码
        let trie = isWubi ? wubiTrie : pinyinTrie
        let results = trie.search(prefix: code, limit: 200)

        // 查找完全匹配的词条（编码完全匹配 + 文本完全匹配）
        for (matchedCode, entryIds) in results {
            // 编码必须完全匹配
            guard matchedCode == code else { continue }

            for entryId in entryIds {
                if let entry = getEntry(id: entryId), entry.text == text {
                    return entryId
                }
            }
        }

        return nil
    }

    /// Remove a user dictionary entry
    ///
    /// - Parameter entryId: The entry ID to remove
    /// - Returns: True if the entry was removed
    @discardableResult
    func removeUserEntry(entryId: UInt32) -> Bool {
        NSLog("MarmotIM: removeUserEntry - attempting to remove entry %u", entryId)

        // Only allow removing user entries
        guard entryId >= DictionaryEngine.userDictStartId else {
            NSLog("MarmotIM: removeUserEntry - FAILED: entry %u is not a user entry (startId=%u)", entryId, DictionaryEngine.userDictStartId)
            return false
        }

        // Get entry to find its code
        guard let entry = getEntry(id: entryId) else {
            NSLog("MarmotIM: removeUserEntry - FAILED: getEntry returned nil for %u", entryId)
            return false
        }
        NSLog("MarmotIM: removeUserEntry - got entry: text='%@', pinyin='%@', wubi=%@", entry.text, entry.pinyin, entry.wubi ?? "nil")

        // Remove from database
        guard db.deleteEntry(id: entryId) else {
            NSLog("MarmotIM: removeUserEntry - FAILED: db.deleteEntry returned false for %u", entryId)
            return false
        }

        // Remove from Trie
        if !entry.pinyin.isEmpty {
            pinyinTrie.remove(code: entry.pinyin, entryId: entryId)
        }
        if let wubi = entry.wubi {
            wubiTrie.remove(code: wubi, entryId: entryId)
        }

        // Remove from cache
        cacheLock.lock()
        entriesCache.removeValue(forKey: entryId)
        userLearningCache.removeValue(forKey: entryId)
        cacheLock.unlock()

        NSLog("MarmotIM: Removed user entry \(entryId)")
        return true
    }

    /// Get all user dictionary entries
    func getUserEntries() -> [DictionaryEntry] {
        // Query database directly for user entries (source = 3)
        return db.getUserEntries()
    }

    // MARK: - Legacy Support (for gradual migration)

    /// Load user dictionary from text file (legacy format)
    /// This method is kept for backward compatibility during migration
    func loadUserDictionary() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let userDictURL = appSupport?.appendingPathComponent("MarmotIM/user_dict.txt") else {
            return
        }

        guard FileManager.default.fileExists(atPath: userDictURL.path) else {
            return
        }

        guard let content = try? String(contentsOf: userDictURL, encoding: .utf8) else {
            NSLog("MarmotIM: Failed to read legacy user dictionary")
            return
        }

        var addedCount = 0
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }

            let code = String(parts[0]).lowercased()

            // Add each word as a separate entry
            for i in 1..<parts.count {
                let word = String(parts[i])
                if addUserEntry(code: code, text: word) != nil {
                    addedCount += 1
                }
            }
        }

        if addedCount > 0 {
            NSLog("MarmotIM: Migrated \(addedCount) entries from legacy user_dict.txt")

            // Optionally rename the old file to indicate migration
            let backupURL = userDictURL.deletingPathExtension().appendingPathExtension("txt.migrated")
            try? FileManager.default.moveItem(at: userDictURL, to: backupURL)
        }
    }

    // MARK: - Statistics

    /// Get Trie statistics for debugging
    var trieStatistics: (pinyin: (codes: Int, entries: Int), wubi: (codes: Int, entries: Int)) {
        return (
            (pinyinTrie.codeCount, pinyinTrie.entryCount),
            (wubiTrie.codeCount, wubiTrie.entryCount)
        )
    }
}
