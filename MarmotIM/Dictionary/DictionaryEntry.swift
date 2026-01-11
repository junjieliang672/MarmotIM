import Foundation

/// Source of dictionary entry
enum EntrySource: Int, Codable {
    case wubi = 1      // From wb_table.txt (higher priority)
    case pinyin = 2    // From py_table.txt (lower priority)
    case user = 3      // From user dictionary (highest priority)
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

    /// Base frequency from the original dictionary (0-65535)
    let baseFrequency: UInt16

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
    let codeType: CodeType

    /// Types of matches
    enum MatchType {
        case full      // Exact match
        case prefix    // Prefix match
    }

    /// Types of input codes
    enum CodeType {
        case pinyin
        case wubi
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
    let codeType: DictionaryMatch.CodeType

    /// Whether this was a full match
    let isFullMatch: Bool

    /// Base frequency for learning (used in recordSelection)
    let baseFrequency: UInt16

    /// Calculated score for ranking
    var score: Double

    var id: UInt32 { entryId }

    init(from match: DictionaryMatch, score: Double = 0) {
        self.entryId = match.entry.id
        self.text = match.entry.text
        self.code = match.matchedCode
        self.codeType = match.codeType
        self.isFullMatch = match.matchType == .full
        self.baseFrequency = match.entry.baseFrequency
        self.score = score
    }
}
