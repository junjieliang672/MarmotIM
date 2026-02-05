import Foundation

/// Source of dictionary entry
public enum EntrySource: Int, Codable {
    case wubi = 1      // From wb_table.txt (higher priority)
    case pinyin = 2    // From py_table.txt (lower priority)
    case user = 3      // From user dictionary (highest priority)
}

/// Represents a single dictionary entry
public struct DictionaryEntry: Codable, Identifiable, Sendable {
    /// Unique identifier for this entry
    public let id: UInt32

    /// The word/phrase text (e.g., "我国")
    public let text: String

    /// Pinyin code (e.g., "woguo" or "w'g")
    public let pinyin: String

    /// Wubi code (e.g., "qklg"), nil if not available
    public let wubi: String?

    /// Base frequency from the original dictionary (0-65535)
    public let baseFrequency: UInt16

    /// Source of this entry (wubi or pinyin dictionary)
    public let source: Int?

    /// Length of the text in characters
    public let length: Int?

    /// Computed property for convenient access
    public var entryId: UInt32 { id }

    /// Whether this entry is from wubi dictionary (higher priority)
    public var isWubiSource: Bool { source == EntrySource.wubi.rawValue }

    /// Text length for ranking
    public var textLength: Int { length ?? text.count }
    
    public init(id: UInt32, text: String, pinyin: String, wubi: String? = nil, baseFrequency: UInt16, source: Int? = nil, length: Int? = nil) {
        self.id = id
        self.text = text
        self.pinyin = pinyin
        self.wubi = wubi
        self.baseFrequency = baseFrequency
        self.source = source
        self.length = length
    }
}

/// Represents a match result from dictionary search
public struct DictionaryMatch: Sendable {
    /// The matched entry
    public let entry: DictionaryEntry

    /// The code that was matched (pinyin or wubi)
    public let matchedCode: String

    /// Type of match
    public let matchType: MatchType

    /// Type of code matched
    public let codeType: CodeType

    /// Types of matches
    public enum MatchType: Sendable {
        case full      // Exact match
        case prefix    // Prefix match
    }

    /// Types of input codes
    public enum CodeType: Sendable {
        case pinyin
        case wubi
    }
    
    public init(entry: DictionaryEntry, matchedCode: String, matchType: MatchType, codeType: CodeType) {
        self.entry = entry
        self.matchedCode = matchedCode
        self.matchType = matchType
        self.codeType = codeType
    }
}

/// Represents a candidate to be displayed
public struct Candidate: Identifiable, Sendable {
    /// Entry ID for tracking
    public let entryId: UInt32

    /// Display text
    public let text: String

    /// The code that matched
    public let code: String

    /// Code type (pinyin/wubi)
    public let codeType: DictionaryMatch.CodeType

    /// Whether this was a full match
    public let isFullMatch: Bool

    /// Base frequency for learning (used in recordSelection)
    public let baseFrequency: UInt16

    /// Calculated score for ranking
    public var score: Double

    public var id: UInt32 { entryId }

    public init(from match: DictionaryMatch, score: Double = 0) {
        self.entryId = match.entry.id
        self.text = match.entry.text
        self.code = match.matchedCode
        self.codeType = match.codeType
        self.isFullMatch = match.matchType == .full
        self.baseFrequency = match.entry.baseFrequency
        self.score = score
    }

    /// Direct initializer for filter mode candidates
    public init(entryId: UInt32, text: String, code: String, codeType: DictionaryMatch.CodeType, isFullMatch: Bool, baseFrequency: UInt16, score: Double) {
        self.entryId = entryId
        self.text = text
        self.code = code
        self.codeType = codeType
        self.isFullMatch = isFullMatch
        self.baseFrequency = baseFrequency
        self.score = score
    }
}
