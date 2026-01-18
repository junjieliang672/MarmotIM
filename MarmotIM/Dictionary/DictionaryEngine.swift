import Foundation
import SQLite3

/// Candidate for filter mode search results
struct FilterCandidate {
    let text: String
    let code: String
    let codeType: String
    var frequency: Int
    var originalCode: String?
    var description: String?

    init(text: String, code: String, codeType: String, frequency: Int, originalCode: String? = nil, description: String? = nil) {
        self.text = text
        self.code = code
        self.codeType = codeType
        self.frequency = frequency
        self.originalCode = originalCode
        self.description = description
    }
}

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

    /// Hot tier index for system dictionary (compact, memory-efficient)
    private var hotTierIndex = HotTierIndex()

    /// User tier index for user-added entries (supports instant add/remove)
    private let userTierIndex = UserTierIndex()

    /// In-memory LRU cache of entries (bounded size)
    private var entriesCache = LRUCache<UInt32, DictionaryEntry>(maxSize: 10000)

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

    /// Jianma (简码) table for protected tier validation
    /// Maps code -> Set of texts that are official jianma for that code
    private var jianmaTable: [String: Set<String>] = [:]

    /// 英文单词索引
    private var englishWordIndex = EnglishWordIndex()

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
            entriesCache.set(entry.id, value: entry)
            if !entry.pinyin.isEmpty {
                userTierIndex.insert(code: entry.pinyin, entryId: entry.id, codeType: .pinyin)
            }
            if let wubi = entry.wubi {
                userTierIndex.insert(code: wubi, entryId: entry.id, codeType: .wubi)
            }
        }
        isPreloaded = true
        NSLog("MarmotIM: DictionaryEngine initialized with \(entries.count) test entries")
    }

    // MARK: - Preloading (called by DictionaryPreloadService)

    /// Bulk load pinyin indexes into hot tier
    func bulkLoadPinyinIndexes(_ indexes: [(code: String, entryId: UInt32)]) {
        hotTierIndex.loadPinyinIndexes(indexes)
    }

    /// Bulk load wubi indexes into hot tier
    func bulkLoadWubiIndexes(_ indexes: [(code: String, entryId: UInt32)]) {
        hotTierIndex.loadWubiIndexes(indexes)
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
        hotTierIndex.finalizePreload()
        isPreloaded = true
        let stats = hotTierIndex.statistics
        NSLog("MarmotIM: Preload finalized - hotTier: pinyin=\(stats.pinyinCodes), wubi=\(stats.wubiCodes)")
    }

    // MARK: - Jianma Table

    /// Load jianma table from bundle resource
    /// Called during preloading to enable protected tier validation
    func loadJianmaTable() {
        guard let url = Bundle.main.url(forResource: "jianma", withExtension: "txt") else {
            NSLog("MarmotIM: Warning - jianma.txt not found in bundle")
            return
        }

        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("MarmotIM: Warning - failed to read jianma.txt")
            return
        }

        var table: [String: Set<String>] = [:]
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }

            let code = String(parts[0])
            let text = String(parts[1])

            if table[code] == nil {
                table[code] = Set<String>()
            }
            table[code]?.insert(text)
        }

        jianmaTable = table
        NSLog("MarmotIM: Loaded jianma table with \(table.count) codes")
    }

    /// Check if a (code, text) combination is an official jianma
    /// - Parameters:
    ///   - code: The input code
    ///   - text: The candidate text
    /// - Returns: true if this is an official jianma entry
    func isOfficialJianma(code: String, text: String) -> Bool {
        return jianmaTable[code]?.contains(text) ?? false
    }

    // MARK: - English Words

    /// 加载英文词典
    func loadEnglishWords() {
        guard let url = Bundle.main.url(forResource: "en_table", withExtension: "txt") else {
            NSLog("MarmotIM: en_table.txt not found in bundle")
            return
        }
        do {
            try englishWordIndex.load(from: url)
            NSLog("MarmotIM: Loaded \(englishWordIndex.count) English words")
        } catch {
            NSLog("MarmotIM: Failed to load English words: \(error)")
        }
    }

    /// 英文完全匹配搜索
    func searchEnglishExact(code: String) -> DictionaryMatch? {
        guard englishWordIndex.isLoaded else { return nil }
        guard let matchedWord = englishWordIndex.exactMatch(code) else {
            return nil
        }

        // 创建一个虚拟的 DictionaryEntry 用于英文匹配
        let entry = DictionaryEntry(
            id: 0,  // 英文词条使用特殊 ID
            text: matchedWord,
            pinyin: code.lowercased(),
            wubi: nil,
            wubiBaseFrequency: 0,
            pinyinBaseFrequency: 50000,
            source: nil,
            length: matchedWord.count
        )

        return DictionaryMatch(
            entry: entry,
            matchedCode: code,
            matchType: .full,
            codeType: .english
        )
    }

    /// Ensure all user_favorites entries are properly indexed
    /// This fixes entries that exist in the database but weren't indexed (source=2 entries with wubi codes)
    /// Returns the number of entries that were fixed
    func ensureUserFavoritesIndexed() -> Int {
        let favorites = db.getUserFavorites()
        var fixedCount = 0

        NSLog("MarmotIM: Checking \(favorites.count) user favorites for missing indexes")

        for (_, text, wubiCode, pinyinCode, _) in favorites {
            // Try to find the entry in database
            var entry = db.getEntryByText(text: text)
            
            // If entry doesn't exist, create it (Fix for Issue 2: User entries not loading)
            if entry == nil {
                // Prioritize wubi code for creation if available, as it's more specific
                if let wubi = wubiCode, !wubi.isEmpty {
                    if let newId = addUserEntry(code: wubi, text: text, isWubi: true) {
                        entry = db.getEntry(id: newId)
                        NSLog("MarmotIM: ensureUserFavoritesIndexed - created missing entry for '%@' (id: %u)", text, newId)
                        fixedCount += 1
                    }
                } else if let pinyin = pinyinCode, !pinyin.isEmpty {
                    if let newId = addUserEntry(code: pinyin, text: text, isWubi: false) {
                        entry = db.getEntry(id: newId)
                        NSLog("MarmotIM: ensureUserFavoritesIndexed - created missing entry for '%@' (id: %u)", text, newId)
                        fixedCount += 1
                    }
                }
            }
            
            guard let validEntry = entry else {
                NSLog("MarmotIM: ensureUserFavoritesIndexed - failed to find or create entry for text: %@", text)
                continue
            }

            // Check and fix wubi index
            if let code = wubiCode, !code.isEmpty, code.count <= 4 {
                // Check if already indexed
                let existingInTrie = findExistingEntry(text: text, code: code, isWubi: true)
                if existingInTrie == nil {
                    // Not indexed - add to index and userTierIndex
                    _ = db.insertWubiIndex(code: code, entryId: validEntry.id)
                    userTierIndex.insert(code: code, entryId: validEntry.id, codeType: .wubi)
                    NSLog("MarmotIM: ensureUserFavoritesIndexed - added wubi index for '%@' code='%@' (id: %u)", text, code, validEntry.id)
                    fixedCount += 1
                }
            }

            // Check and fix pinyin index
            if let code = pinyinCode, !code.isEmpty {
                // Check if already indexed
                let existingInTrie = findExistingEntry(text: text, code: code, isWubi: false)
                if existingInTrie == nil {
                    // Not indexed - add to index and userTierIndex
                    _ = db.insertPinyinIndex(code: code, entryId: validEntry.id)
                    userTierIndex.insert(code: code, entryId: validEntry.id, codeType: .pinyin)
                    NSLog("MarmotIM: ensureUserFavoritesIndexed - added pinyin index for '%@' code='%@' (id: %u)", text, code, validEntry.id)
                    fixedCount += 1
                }
            }
        }

        return fixedCount
    }

    // MARK: - Search

    /// Search for entries matching the given code
    /// Uses tiered architecture: user tier first, then hot tier
    ///
    /// - Parameters:
    ///   - code: The input code (can be pinyin or wubi)
    ///   - limit: Maximum number of results
    /// - Returns: Array of matches
    ///
    /// The limit is distributed with two priorities:
    /// 1. Full matches before prefix matches
    /// 2. Even distribution between wubi and pinyin within each match type
    func search(code: String, limit: Int = 50) -> [DictionaryMatch] {
        guard !code.isEmpty else { return [] }

        // Don't search if not preloaded yet - prevents race conditions
        guard isPreloaded else {
            return []
        }

        // Collect all entry IDs first, then batch fetch entries
        // This avoids N individual database queries
        var matchInfos: [(entryId: UInt32, matchedCode: String, codeType: InputCodeType)] = []
        var seenEntryIds = Set<UInt32>()

        // TIER 1: User tier first (user entries get priority)
        let userResults = userTierIndex.search(prefix: code, limit: limit * 2)
        for result in userResults {
            for entryId in result.entryIds {
                guard !seenEntryIds.contains(entryId) else { continue }
                seenEntryIds.insert(entryId)
                matchInfos.append((entryId, result.code, result.codeType))
            }
        }

        // TIER 2: Hot tier
        let hotResults = hotTierIndex.search(prefix: code, limit: limit * 2)
        for result in hotResults {
            for entryId in result.entryIds {
                guard !seenEntryIds.contains(entryId) else { continue }
                seenEntryIds.insert(entryId)
                matchInfos.append((entryId, result.code, result.codeType))
            }
        }

        // Batch fetch all entries in a single database query
        let allIds = matchInfos.map { $0.entryId }
        let entriesMap = getEntries(ids: allIds)

        // Categorize matches into 4 tiers
        var fullWubiMatches: [DictionaryMatch] = []
        var fullPinyinMatches: [DictionaryMatch] = []
        var prefixWubiMatches: [DictionaryMatch] = []
        var prefixPinyinMatches: [DictionaryMatch] = []

        for info in matchInfos {
            guard let entry = entriesMap[info.entryId] else { continue }
            let isFullMatch = info.matchedCode == code
            let match = DictionaryMatch(
                entry: entry,
                matchedCode: info.matchedCode,
                matchType: isFullMatch ? .full : .prefix,
                codeType: info.codeType
            )

            switch (isFullMatch, info.codeType) {
            case (true, .wubi): fullWubiMatches.append(match)
            case (true, .pinyin): fullPinyinMatches.append(match)
            case (false, .wubi): prefixWubiMatches.append(match)
            case (false, .pinyin): prefixPinyinMatches.append(match)
            case (true, .english): fullWubiMatches.append(match)  // English full match same tier as wubi
            case (false, .english): break  // English has no prefix match
            }
        }

        // Distribute limit evenly across tiers
        // Priority 1: Full matches (even split between wubi and pinyin)
        // Priority 2: Prefix matches (even split between wubi and pinyin)
        var results: [DictionaryMatch] = []

        // Step 1: Add full matches with even distribution
        let fullWubiCount = fullWubiMatches.count
        let fullPinyinCount = fullPinyinMatches.count
        let totalFullMatches = fullWubiCount + fullPinyinCount

        if totalFullMatches > 0 {
            let fullLimit = min(limit, totalFullMatches)
            // Calculate even split, but allow overflow to the other category if one has fewer
            var wubiSlots = fullLimit / 2
            var pinyinSlots = fullLimit - wubiSlots

            // Redistribute if one category has fewer entries
            if fullWubiCount < wubiSlots {
                pinyinSlots += wubiSlots - fullWubiCount
                wubiSlots = fullWubiCount
            } else if fullPinyinCount < pinyinSlots {
                wubiSlots += pinyinSlots - fullPinyinCount
                pinyinSlots = fullPinyinCount
            }

            results.append(contentsOf: fullWubiMatches.prefix(wubiSlots))
            results.append(contentsOf: fullPinyinMatches.prefix(pinyinSlots))
        }

        // Step 2: Fill remaining slots with prefix matches
        let remaining = limit - results.count
        if remaining > 0 {
            let prefixWubiCount = prefixWubiMatches.count
            let prefixPinyinCount = prefixPinyinMatches.count

            var wubiSlots = remaining / 2
            var pinyinSlots = remaining - wubiSlots

            // Redistribute if one category has fewer entries
            if prefixWubiCount < wubiSlots {
                pinyinSlots += wubiSlots - prefixWubiCount
                wubiSlots = prefixWubiCount
            } else if prefixPinyinCount < pinyinSlots {
                wubiSlots += pinyinSlots - prefixPinyinCount
                pinyinSlots = prefixPinyinCount
            }

            results.append(contentsOf: prefixWubiMatches.prefix(wubiSlots))
            results.append(contentsOf: prefixPinyinMatches.prefix(pinyinSlots))
        }

        // 添加英文完全匹配
        // 如果已存在相同文本的候选词（可能是历史数据中错误存储为pinyin的英文词），
        // 用正确的 English match 替换，确保显示正确的 "en" 指示器
        if let englishMatch = searchEnglishExact(code: code) {
            let englishText = englishMatch.entry.text
            if let existingIndex = results.firstIndex(where: { $0.entry.text == englishText }) {
                // 替换已存在的条目（优先使用正确的 codeType=.english）
                results[existingIndex] = englishMatch
            } else {
                results.append(englishMatch)
            }
        }

        return results
    }

    /// Get entry by ID (from cache or database)
    func getEntry(id: UInt32) -> DictionaryEntry? {
        cacheLock.lock()
        if let cached = entriesCache.get(id) {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // Fetch from database
        if let entry = db.getEntry(id: id) {
            cacheLock.lock()
            entriesCache.set(id, value: entry)
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
            if let cached = entriesCache.get(id) {
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
                entriesCache.set(id, value: entry)
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

        // Create entry with specified baseFrequency (user entries get same freq in both modes)
        let entry = DictionaryEntry(
            id: entryId,
            text: text,
            pinyin: isWubi ? "" : code,
            wubi: isWubi ? code : nil,
            wubiBaseFrequency: baseFrequency,
            pinyinBaseFrequency: baseFrequency,
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

        // Update userTierIndex immediately (available for next search)
        if isWubi {
            userTierIndex.insert(code: code, entryId: entryId, codeType: .wubi)
        } else {
            userTierIndex.insert(code: code, entryId: entryId, codeType: .pinyin)
        }

        // Add to cache
        cacheLock.lock()
        entriesCache.set(entryId, value: entry)
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

        // First, try to find ANY existing entry for this text in the database
        // This handles the case where entry exists but may not be indexed for all codes
        let existingEntryByText = findEntryByText(text: text)

        // 1. 处理五笔入库
        if let code = wubiCode, code.count >= 1, code.count <= 4 {
            // 检查是否已在五笔索引中
            if let existingId = findExistingEntry(text: text, code: code, isWubi: true) {
                // 已在索引中，仅更新 ranking
                result.wubiEntryId = existingId
                result.wubiWasExisting = true
                recordSelection(entryId: existingId, baseFrequency: 35000)
                NSLog("MarmotIM: addDualEntry - wubi entry exists in index, updated ranking (id: %u)", existingId)
            } else if let existingEntry = existingEntryByText {
                // 词条存在但未在五笔索引中，添加索引
                result.wubiEntryId = existingEntry.id
                result.wubiWasExisting = true
                // Add to wubi index and userTierIndex
                _ = db.insertWubiIndex(code: code, entryId: existingEntry.id)
                userTierIndex.insert(code: code, entryId: existingEntry.id, codeType: .wubi)
                recordSelection(entryId: existingEntry.id, baseFrequency: 35000)
                NSLog("MarmotIM: addDualEntry - added existing entry to wubi index (id: %u, code: %@)", existingEntry.id, code)
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
            // 检查是否已在拼音索引中
            if let existingId = findExistingEntry(text: text, code: code, isWubi: false) {
                // 已在索引中，仅更新 ranking
                result.pinyinEntryId = existingId
                result.pinyinWasExisting = true
                recordSelection(entryId: existingId, baseFrequency: 65000)
                NSLog("MarmotIM: addDualEntry - pinyin entry exists in index, updated ranking (id: %u)", existingId)
            } else if let existingEntry = existingEntryByText {
                // 词条存在但未在拼音索引中，添加索引
                result.pinyinEntryId = existingEntry.id
                result.pinyinWasExisting = true
                // Add to pinyin index and userTierIndex
                _ = db.insertPinyinIndex(code: code, entryId: existingEntry.id)
                userTierIndex.insert(code: code, entryId: existingEntry.id, codeType: .pinyin)
                recordSelection(entryId: existingEntry.id, baseFrequency: 65000)
                NSLog("MarmotIM: addDualEntry - added existing entry to pinyin index (id: %u, code: %@)", existingEntry.id, code)
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

        // 3. 记录到 user_favorites 表（用于在设置中显示用户入库的词条）
        if result.success {
            // 注意：addUserFavorite 会重置 is_deleted=0，所以如果是之前删除过的词条，这里会复活
            _ = db.addUserFavorite(text: text, wubiCode: wubiCode, pinyinCode: pinyinCode)
            NSLog("MarmotIM: addDualEntry - added to user_favorites")
        }

        NSLog("MarmotIM: addDualEntry complete - %@", result.description)
        return result
    }

    /// Find an entry by its text (direct database lookup, ignoring index)
    private func findEntryByText(text: String) -> DictionaryEntry? {
        return db.getEntryByText(text: text)
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
        
        // 3. 从 user_favorites 表中软删除 (设置 is_deleted = 1)
        _ = db.removeUserFavorite(text: text)
        NSLog("MarmotIM: removeDualEntry - removed from user_favorites (soft delete)")
        
        // 4. CRITICAL FIX: 立即从当前内存 Trie 树中移除所有相关索引
        // 即使 findExistingEntry 没有找到具体的 ID（可能因为编码参数不全），我们也应该
        // 尝试通过文本反查 ID，并从内存中清理，确保即时生效。
        if let entry = db.getEntryByText(text: text) {
             // 只有用户词条才应该被完全移除
             if entry.id >= DictionaryEngine.userDictStartId {
                 // 再次确认移除，防止上面的逻辑漏网
                 removeUserEntry(entryId: entry.id)
                 NSLog("MarmotIM: removeDualEntry - force removed from cache/trie by text lookup (id: %u)", entry.id)
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
        let codeType: InputCodeType = isWubi ? .wubi : .pinyin

        // Search user tier first
        let userResults = userTierIndex.search(prefix: code, limit: 200)
        for result in userResults {
            guard result.code == code else { continue }
            guard result.codeType == codeType else { continue }
            for entryId in result.entryIds {
                if let entry = getEntry(id: entryId), entry.text == text {
                    return entryId
                }
            }
        }

        // Search hot tier
        let hotResults = hotTierIndex.search(prefix: code, limit: 200)
        for result in hotResults {
            guard result.code == code else { continue }
            guard result.codeType == codeType else { continue }
            for entryId in result.entryIds {
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

        // Remove from userTierIndex
        if !entry.pinyin.isEmpty {
            userTierIndex.remove(code: entry.pinyin, entryId: entryId, codeType: .pinyin)
        }
        if let wubi = entry.wubi {
            userTierIndex.remove(code: wubi, entryId: entryId, codeType: .wubi)
        }

        // Remove from cache
        cacheLock.lock()
        entriesCache.remove(entryId)
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

    /// Get index statistics for debugging (combines hot tier and user tier)
    var trieStatistics: (pinyin: (codes: Int, entries: Int), wubi: (codes: Int, entries: Int)) {
        let hotStats = hotTierIndex.statistics
        let userStats = userTierIndex.statistics
        return (
            (hotStats.pinyinCodes + userStats.pinyinCodes, hotStats.pinyinEntries),
            (hotStats.wubiCodes + userStats.wubiCodes, hotStats.wubiEntries)
        )
    }

    // MARK: - Filter Mode Search

    /// Helper: increment last character for range query upper bound
    /// e.g., "ni" -> "nj", "abc" -> "abd"
    private func incrementLastChar(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        var chars = Array(s)
        if let lastChar = chars.last, let scalar = lastChar.unicodeScalars.first {
            let nextScalar = UnicodeScalar(scalar.value + 1)!
            chars[chars.count - 1] = Character(nextScalar)
        }
        return String(chars)
    }

    /// Search emoji by code (pinyin or english)
    func searchEmoji(code: String, limit: Int = 100) -> [FilterCandidate] {
        guard let db = VocabularyDatabase.shared.getConnection() else { return [] }

        var results: [FilterCandidate] = []
        let sql = """
            SELECT emoji, code, code_type, frequency
            FROM emoji_index
            WHERE code LIKE '%' || ? || '%'
            ORDER BY frequency DESC
            LIMIT ?
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            // Use NSString for proper SQLite binding
            let codeNS = code as NSString
            sqlite3_bind_text(stmt, 1, codeNS.utf8String, -1, nil)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let emojiPtr = sqlite3_column_text(stmt, 0),
                      let codePtr = sqlite3_column_text(stmt, 1),
                      let typePtr = sqlite3_column_text(stmt, 2) else {
                    continue
                }
                let emoji = String(cString: emojiPtr)
                let matchCode = String(cString: codePtr)
                let codeType = String(cString: typePtr)
                let frequency = Int(sqlite3_column_int(stmt, 3))

                results.append(FilterCandidate(
                    text: emoji,
                    code: matchCode,
                    codeType: codeType,
                    frequency: frequency
                ))
            }
        }
        sqlite3_finalize(stmt)

        return results
    }

    /// Search fuzzy pinyin using index-optimized range query
    func searchFuzzyPinyin(code: String, limit: Int = 100) -> [FilterCandidate] {
        guard let db = VocabularyDatabase.shared.getConnection() else { return [] }
        guard !code.isEmpty else { return [] }

        var results: [FilterCandidate] = []

        // Use range query instead of LIKE for index efficiency
        // For prefix "ni", search: fuzzy_code >= "ni" AND fuzzy_code < "nj"
        let upperBound = incrementLastChar(code)

        let sql = """
            SELECT word, fuzzy_code, original_code, fuzzy_type
            FROM fuzzy_pinyin
            WHERE fuzzy_code >= ? AND fuzzy_code < ?
            LIMIT ?
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            // Use NSString for proper SQLite binding
            let codeNS = code as NSString
            let upperNS = upperBound as NSString
            sqlite3_bind_text(stmt, 1, codeNS.utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, upperNS.utf8String, -1, nil)
            sqlite3_bind_int(stmt, 3, Int32(limit))

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let wordPtr = sqlite3_column_text(stmt, 0),
                      let fuzzyCodePtr = sqlite3_column_text(stmt, 1),
                      let originalCodePtr = sqlite3_column_text(stmt, 2),
                      let fuzzyTypePtr = sqlite3_column_text(stmt, 3) else {
                    continue
                }
                let word = String(cString: wordPtr)
                let fuzzyCode = String(cString: fuzzyCodePtr)
                let originalCode = String(cString: originalCodePtr)
                let fuzzyType = String(cString: fuzzyTypePtr)

                results.append(FilterCandidate(
                    text: word,
                    code: fuzzyCode,
                    codeType: "fuzzy_\(fuzzyType)",
                    frequency: 0,
                    originalCode: originalCode
                ))
            }
        }
        sqlite3_finalize(stmt)

        return results
    }

    /// Search symbols by code or category
    func searchSymbol(code: String, limit: Int = 100) -> [FilterCandidate] {
        guard let db = VocabularyDatabase.shared.getConnection() else { return [] }

        var results: [FilterCandidate] = []
        let sql = """
            SELECT symbol, code, category, description
            FROM symbol_index
            WHERE code LIKE '%' || ? || '%' OR category = ?
            LIMIT ?
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            // Use NSString for proper SQLite binding
            let codeNS = code as NSString
            sqlite3_bind_text(stmt, 1, codeNS.utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, codeNS.utf8String, -1, nil)
            sqlite3_bind_int(stmt, 3, Int32(limit))

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let symbolPtr = sqlite3_column_text(stmt, 0),
                      let codePtr = sqlite3_column_text(stmt, 1) else {
                    continue
                }
                let symbol = String(cString: symbolPtr)
                let matchCode = String(cString: codePtr)
                let category = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                let description = sqlite3_column_text(stmt, 3).map { String(cString: $0) }

                results.append(FilterCandidate(
                    text: symbol,
                    code: matchCode,
                    codeType: category ?? "symbol",
                    frequency: 0,
                    description: description
                ))
            }
        }
        sqlite3_finalize(stmt)

        return results
    }
}

// MARK: - Test Helpers
//
// These methods are intended for unit testing only.
// They allow tests to set up jianma table and user learning data without
// loading from disk or database.

extension DictionaryEngine {
    /// Set jianma table for testing purposes
    /// - Parameter table: Dictionary mapping code to set of texts
    func setJianmaTable(_ table: [String: Set<String>]) {
        jianmaTable = table
    }

    /// Add a single jianma entry for testing
    /// - Parameters:
    ///   - code: The jianma code
    ///   - text: The text for this code
    func addJianmaEntry(code: String, text: String) {
        if jianmaTable[code] == nil {
            jianmaTable[code] = Set<String>()
        }
        jianmaTable[code]?.insert(text)
    }

    /// Set user learning data for testing
    /// - Parameters:
    ///   - entryId: The entry ID
    ///   - accessCount: Number of times selected
    ///   - lastAccessTimestamp: Last selection timestamp
    func setUserLearning(entryId: UInt32, accessCount: UInt32, lastAccessTimestamp: UInt32) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        userLearningCache[entryId] = UserEntryData(
            entryId: entryId,
            accessCount: accessCount,
            lastAccessTimestamp: lastAccessTimestamp,
            cachedScore: 0
        )
    }

    /// Clear all user learning data for testing
    func clearUserLearning() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        userLearningCache.removeAll()
    }
}
