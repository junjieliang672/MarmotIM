import Foundation

/// One line of en_table.txt
struct EnglishWord: Equatable {
    /// What the user types: the display form lowercased, spaces removed
    let key: String
    /// The word as written in the table ("GitHub", "the", "iPhone 11 Pro")
    let display: String
    /// 1-based frequency rank, smaller = more common
    let rank: Int
    /// Stable entry id, keys this word's learning record
    let id: UInt32
}

/// 英文单词索引：完全匹配 + 前缀补全
///
/// Words are kept sorted by key, so both lookups are a binary search for the
/// start of a run followed by a walk along it.
struct EnglishWordIndex {
    /// Sorted by key, then by rank
    private var words: [EnglishWord] = []

    /// 是否已加载
    private(set) var isLoaded = false

    /// 词条数量
    var count: Int { words.count }

    // MARK: - Entry ids

    /// English ids live in 0x40000000..0x7FFFFFFF: above every system
    /// dictionary entry, below the user-entry range starting at 0x80000000.
    static let idBase: UInt32 = 0x4000_0000
    static let idMask: UInt32 = 0x3FFF_FFFF

    static func isEnglishId(_ id: UInt32) -> Bool {
        return id >= idBase && id <= idBase | idMask
    }

    /// FNV-1a (32-bit) of "key<TAB>display<salt>", folded into the English id
    /// range. The id depends on nothing but the entry, so it is the same on
    /// every machine and survives words being added to the table.
    /// Must stay identical to word_id() in tools/build_en_table.py.
    static func wordId(key: String, display: String, salt: String = "") -> UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        for byte in "\(key)\t\(display)\(salt)".utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return idBase | (hash & idMask)
    }

    /// Dictionary base frequency (0-65535 scale) for a frequency rank:
    /// rank 1 -> 60000, rank 80000 -> 20000, floor 5000.
    static func baseFrequency(rank: Int) -> UInt16 {
        return UInt16(max(5000, 60000 - rank / 2))
    }

    // MARK: - Loading

    /// 从文件加载英文词典
    /// 格式: "键\t显示形式\t词频名次[\tid salt]" (tab-separated), written by
    /// tools/build_en_table.py. 例如: "github\tGitHub\t22985"
    mutating func load(from url: URL) throws {
        let content = try String(contentsOf: url, encoding: .utf8)
        var loaded: [EnglishWord] = []
        var seenIds = Set<UInt32>()

        for line in content.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, !parts[0].isEmpty, !parts[1].isEmpty, let rank = Int(parts[2]) else { continue }

            let salt = parts.count > 3 ? parts[3] : ""
            let id = Self.wordId(key: parts[0], display: parts[1], salt: salt)
            // The build tool salts colliding ids; a duplicate here means a
            // hand-edited table, and two words must not share a learning record.
            guard seenIds.insert(id).inserted else { continue }

            loaded.append(EnglishWord(key: parts[0], display: parts[1], rank: rank, id: id))
        }

        setWords(loaded)
    }

    private mutating func setWords(_ newWords: [EnglishWord]) {
        words = newWords.sorted { $0.key != $1.key ? $0.key < $1.key : $0.rank < $1.rank }
        isLoaded = true
    }

    // MARK: - Lookup

    /// Index of the first word whose key is >= `key`
    private func lowerBound(_ key: String) -> Int {
        var low = 0
        var high = words.count
        while low < high {
            let mid = (low + high) / 2
            if words[mid].key < key {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// 完全匹配：所有键等于输入（不区分大小写）的词条，按词频排序
    func exactMatches(_ code: String) -> [EnglishWord] {
        let key = code.lowercased()
        guard !key.isEmpty else { return [] }

        var result: [EnglishWord] = []
        var index = lowerBound(key)
        while index < words.count && words[index].key == key {
            result.append(words[index])
            index += 1
        }
        return result
    }

    /// 前缀补全：键以输入开头、且比输入长的词条，取词频最高的 `limit` 个
    func completions(prefix code: String, limit: Int) -> [EnglishWord] {
        let prefix = code.lowercased()
        guard !prefix.isEmpty, limit > 0 else { return [] }

        // The `limit` most common words of the run, most common first
        var best: [EnglishWord] = []
        var index = lowerBound(prefix)
        while index < words.count && words[index].key.hasPrefix(prefix) {
            let word = words[index]
            index += 1
            if word.key == prefix { continue }
            if best.count == limit && word.rank >= best[limit - 1].rank { continue }

            let position = best.firstIndex { word.rank < $0.rank } ?? best.count
            best.insert(word, at: position)
            if best.count > limit { best.removeLast() }
        }
        return best
    }

    /// 完全匹配的显示形式（跟随输入的大小写），没有则返回 nil
    func exactMatch(_ code: String) -> String? {
        return exactMatches(code).first.map { Self.display($0, typedAs: code) }
    }

    /// 检查是否包含某个词（不区分大小写）
    func contains(_ code: String) -> Bool {
        return !exactMatches(code).isEmpty
    }

    // MARK: - Capitalisation

    /// How a word is shown for a given input.
    ///
    /// - All-lowercase input: as the table writes it ("github" -> "GitHub").
    /// - The table's own capitals always win ("IPHONE" -> "iPhone").
    /// - Otherwise the word follows the input: "Wor" -> "World",
    ///   "WOR" -> "WORLD".
    static func display(_ word: EnglishWord, typedAs input: String) -> String {
        guard input != input.lowercased() else { return word.display }
        guard word.display == word.display.lowercased() else { return word.display }

        if input.count > 1 && input == input.uppercased() {
            return word.display.uppercased()
        }
        if input.first?.isUppercase == true {
            return word.display.prefix(1).uppercased() + word.display.dropFirst()
        }
        return word.display
    }
}

// MARK: - Test Helpers

extension EnglishWordIndex {
    /// 用于测试：直接设置数据。Each key maps to its display forms; rank follows
    /// the order given (first form of a key is its most common).
    mutating func setTestData(_ data: [String: [String]]) {
        var testWords: [EnglishWord] = []
        for (key, displays) in data {
            for (position, display) in displays.enumerated() {
                let lowered = key.lowercased()
                testWords.append(EnglishWord(key: lowered, display: display, rank: position + 1,
                                             id: Self.wordId(key: lowered, display: display)))
            }
        }
        setWords(testWords)
    }

    /// 用于测试：按词频名次设置数据
    mutating func setTestWords(_ ranked: [(display: String, rank: Int)]) {
        setWords(ranked.map { entry in
            let key = entry.display.lowercased().replacingOccurrences(of: " ", with: "")
            return EnglishWord(key: key, display: entry.display, rank: entry.rank,
                               id: Self.wordId(key: key, display: entry.display))
        })
    }

    /// 用于测试：清空数据
    mutating func clear() {
        words.removeAll()
        isLoaded = false
    }
}
