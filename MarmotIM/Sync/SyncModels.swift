import Foundation

/// Generic container for sync data files
struct SyncFile<T: Codable>: Codable {
    let version: Int
    let lastModified: TimeInterval
    var records: [String: T]

    init(version: Int = 1, records: [String: T]) {
        self.version = version
        self.lastModified = Date().timeIntervalSince1970
        self.records = records
    }
}

/// Record for user_learning table sync
struct LearningRecord: Codable {
    var accessCount: Int
    var lastAccessTimestamp: Int
    var totalScore: Double

    init(accessCount: Int, lastAccessTimestamp: Int, totalScore: Double) {
        self.accessCount = accessCount
        self.lastAccessTimestamp = lastAccessTimestamp
        self.totalScore = totalScore
    }
}

/// Record for user_favorites table sync
struct FavoriteRecord: Codable {
    var wubiCode: String?
    var pinyinCode: String?
    var addedTimestamp: Int

    init(wubiCode: String?, pinyinCode: String?, addedTimestamp: Int) {
        self.wubiCode = wubiCode
        self.pinyinCode = pinyinCode
        self.addedTimestamp = addedTimestamp
    }
}

/// Record for filter_user_freq table sync
/// Key format: "filter_type:code:word" (e.g., "e:cat:🐱")
struct FilterFreqRecord: Codable {
    var frequency: Int
    var lastUsed: Double

    init(frequency: Int, lastUsed: Double) {
        self.frequency = frequency
        self.lastUsed = lastUsed
    }
}

// MARK: - Key Generation Helpers

extension FilterFreqRecord {
    /// Generate a unique key for filter_user_freq record
    /// - Parameters:
    ///   - filterType: Filter type ('e', 'p', 's')
    ///   - code: Input code
    ///   - word: Output word
    /// - Returns: Combined key string
    static func makeKey(filterType: String, code: String, word: String) -> String {
        return "\(filterType):\(code):\(word)"
    }

    /// Parse key back to components
    /// - Parameter key: Combined key string
    /// - Returns: Tuple of (filterType, code, word) or nil if invalid
    static func parseKey(_ key: String) -> (filterType: String, code: String, word: String)? {
        let parts = key.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        return (String(parts[0]), String(parts[1]), String(parts[2]))
    }
}
