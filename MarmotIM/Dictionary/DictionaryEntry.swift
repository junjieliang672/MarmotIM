import Foundation

/// Source of dictionary entry
enum EntrySource: Int, Codable {
    case wubi = 1      // From wb_table.txt (higher priority)
    case pinyin = 2    // From py_table.txt (lower priority)
    case user = 3      // From user dictionary (highest priority)
}

/// Types of input codes - defined at top level for forward reference
enum InputCodeType {
    case pinyin
    case wubi
    case english
}

/// Represents a single dictionary entry
struct DictionaryEntry: Codable, Identifiable {
    /// Unique identifier for this entry
    let id: UInt32

    /// The word/phrase text (e.g., "我国")
    let text: String

    /// Pinyin code (e.g., "woguo" or "w'g")
    let pinyin: String

    /// Wubi code (e.g., "qklg"), nil if not available
    let wubi: String?

    /// Base frequency when searched via wubi (0-65535)
    /// Schema version 3: Separate frequencies for each input mode
    let wubiBaseFrequency: UInt16

    /// Base frequency when searched via pinyin (0-65535)
    /// Schema version 3: Separate frequencies for each input mode
    let pinyinBaseFrequency: UInt16

    /// Source of this entry (wubi or pinyin dictionary)
    let source: Int?

    /// Length of the text in characters
    let length: Int?

    /// Computed property for convenient access
    var entryId: UInt32 { id }

    /// Whether this entry is from wubi dictionary (higher priority)
    var isWubiSource: Bool { source == EntrySource.wubi.rawValue }

    /// Text length for ranking
    var textLength: Int { length ?? text.count }

    /// Get base frequency for a specific code type
    func baseFrequency(for codeType: InputCodeType) -> UInt16 {
        switch codeType {
        case .wubi:
            return wubiBaseFrequency
        case .pinyin:
            return pinyinBaseFrequency
        case .english:
            return 50000  // 英文默认词频
        }
    }
}

/// Represents a match result from dictionary search
struct DictionaryMatch {
    /// The matched entry
    let entry: DictionaryEntry

    /// The code that was matched (pinyin or wubi)
    let matchedCode: String

    /// Type of match
    let matchType: MatchType

    /// Type of code matched
    let codeType: InputCodeType

    /// Types of matches
    enum MatchType {
        case full      // Exact match
        case prefix    // Prefix match
    }
}

/// Represents a candidate to be displayed
struct Candidate: Identifiable {
    /// Entry ID for tracking
    let entryId: UInt32

    /// Display text
    let text: String

    /// The code that matched
    let code: String

    /// Code type (pinyin/wubi)
    let codeType: InputCodeType

    /// Whether this was a full match
    let isFullMatch: Bool

    /// Wubi base frequency (used in recordSelection for wubi mode)
    let wubiBaseFrequency: UInt16

    /// Pinyin base frequency (used in recordSelection for pinyin mode)
    let pinyinBaseFrequency: UInt16

    /// Calculated score for ranking
    var score: Double

    /// True if this is a protected Wubi 1-2 char shortcode (简码)
    var isJianma: Bool

    /// True if this candidate is #1 due to active tier override boost
    /// (would not be #1 without recent user selection)
    var isBoosted: Bool

    var id: UInt32 { entryId }

    /// Get base frequency for the current code type
    var baseFrequency: UInt16 {
        switch codeType {
        case .wubi:
            return wubiBaseFrequency
        case .pinyin:
            return pinyinBaseFrequency
        case .english:
            return 50000  // 英文默认词频
        }
    }

    init(from match: DictionaryMatch, score: Double = 0, isJianma: Bool = false, isBoosted: Bool = false) {
        self.entryId = match.entry.id
        self.text = match.entry.text
        self.code = match.matchedCode
        self.codeType = match.codeType
        self.isFullMatch = match.matchType == .full
        self.wubiBaseFrequency = match.entry.wubiBaseFrequency
        self.pinyinBaseFrequency = match.entry.pinyinBaseFrequency
        self.score = score
        self.isJianma = isJianma
        self.isBoosted = isBoosted
    }

    /// Direct initializer for filter mode candidates
    init(entryId: UInt32, text: String, code: String, codeType: InputCodeType, isFullMatch: Bool, wubiBaseFrequency: UInt16, pinyinBaseFrequency: UInt16, score: Double, isJianma: Bool = false, isBoosted: Bool = false) {
        self.entryId = entryId
        self.text = text
        self.code = code
        self.codeType = codeType
        self.isFullMatch = isFullMatch
        self.wubiBaseFrequency = wubiBaseFrequency
        self.pinyinBaseFrequency = pinyinBaseFrequency
        self.score = score
        self.isJianma = isJianma
        self.isBoosted = isBoosted
    }
}
