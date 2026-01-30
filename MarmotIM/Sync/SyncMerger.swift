import Foundation

/// Handles record-level merging for sync operations
/// Uses "latest-write-wins" strategy based on numeric values
struct SyncMerger {

    // MARK: - User Learning Merge

    /// Merge user_learning records
    /// Conflict resolution: keep record with higher accessCount
    /// - Parameters:
    ///   - local: Local records (key: entry_id as string)
    ///   - remote: Remote records from iCloud
    /// - Returns: Merged records
    static func mergeLearning(
        local: [String: LearningRecord],
        remote: [String: LearningRecord]
    ) -> [String: LearningRecord] {
        var result = local

        for (key, remoteRecord) in remote {
            if let localRecord = result[key] {
                // Conflict: keep the one with higher accessCount
                if remoteRecord.accessCount > localRecord.accessCount {
                    result[key] = remoteRecord
                }
            } else {
                // Only exists in remote: add it
                result[key] = remoteRecord
            }
        }

        return result
    }

    // MARK: - User Favorites Merge

    /// Merge user_favorites records
    /// Conflict resolution: keep record with newer addedTimestamp
    /// IMPORTANT: Respects is_deleted flag to prevent resurrecting deleted entries
    /// - Parameters:
    ///   - local: Local records (key: text)
    ///   - remote: Remote records from iCloud
    /// - Returns: Merged records
    static func mergeFavorites(
        local: [String: FavoriteRecord],
        remote: [String: FavoriteRecord]
    ) -> [String: FavoriteRecord] {
        var result = local

        for (key, remoteRecord) in remote {
            if let localRecord = result[key] {
                // Conflict: keep the one with newer timestamp
                // The newer timestamp wins, regardless of is_deleted state
                // This ensures that a deletion with newer timestamp takes precedence
                if remoteRecord.addedTimestamp > localRecord.addedTimestamp {
                    result[key] = remoteRecord
                }
            } else {
                // Only exists in remote: only add if NOT deleted
                // This prevents resurrecting entries that were deleted locally
                // and the local deletion record was purged
                if !remoteRecord.isDeleted {
                    result[key] = remoteRecord
                }
            }
        }

        return result
    }

    // MARK: - Filter User Freq Merge

    /// Merge filter_user_freq records
    /// Conflict resolution: keep record with higher frequency
    /// - Parameters:
    ///   - local: Local records (key: "filter_type:code:word")
    ///   - remote: Remote records from iCloud
    /// - Returns: Merged records
    static func mergeFilterFreq(
        local: [String: FilterFreqRecord],
        remote: [String: FilterFreqRecord]
    ) -> [String: FilterFreqRecord] {
        var result = local

        for (key, remoteRecord) in remote {
            if let localRecord = result[key] {
                // Conflict: keep the one with higher frequency
                if remoteRecord.frequency > localRecord.frequency {
                    result[key] = remoteRecord
                }
            } else {
                // Only exists in remote: add it
                result[key] = remoteRecord
            }
        }

        return result
    }

    // MARK: - Diff Detection

    /// Find records that need to be updated in local database
    /// - Parameters:
    ///   - merged: Merged records
    ///   - original: Original local records
    /// - Returns: Records that are new or changed
    static func findChangedLearning(
        merged: [String: LearningRecord],
        original: [String: LearningRecord]
    ) -> [(String, LearningRecord)] {
        var changed: [(String, LearningRecord)] = []

        for (key, record) in merged {
            if let orig = original[key] {
                // Check if values differ
                if record.accessCount != orig.accessCount ||
                   record.lastAccessTimestamp != orig.lastAccessTimestamp ||
                   record.totalScore != orig.totalScore {
                    changed.append((key, record))
                }
            } else {
                // New record
                changed.append((key, record))
            }
        }

        return changed
    }

    static func findChangedFavorites(
        merged: [String: FavoriteRecord],
        original: [String: FavoriteRecord]
    ) -> [(String, FavoriteRecord)] {
        var changed: [(String, FavoriteRecord)] = []

        for (key, record) in merged {
            if let orig = original[key] {
                if record.addedTimestamp != orig.addedTimestamp ||
                   record.wubiCode != orig.wubiCode ||
                   record.pinyinCode != orig.pinyinCode ||
                   record.isDeleted != orig.isDeleted {
                    changed.append((key, record))
                }
            } else {
                changed.append((key, record))
            }
        }

        return changed
    }

    static func findChangedFilterFreq(
        merged: [String: FilterFreqRecord],
        original: [String: FilterFreqRecord]
    ) -> [(String, FilterFreqRecord)] {
        var changed: [(String, FilterFreqRecord)] = []

        for (key, record) in merged {
            if let orig = original[key] {
                if record.frequency != orig.frequency ||
                   record.lastUsed != orig.lastUsed {
                    changed.append((key, record))
                }
            } else {
                changed.append((key, record))
            }
        }

        return changed
    }

    // MARK: - User Suppressed Words Merge

    /// Merge user_suppressed_words records
    /// Conflict resolution: keep record with newer suppressedTimestamp
    /// IMPORTANT: Respects is_deleted flag to prevent resurrecting deleted entries
    /// - Parameters:
    ///   - local: Local records (key: text)
    ///   - remote: Remote records from iCloud
    /// - Returns: Merged records
    static func mergeSuppressedWords(
        local: [String: SuppressedWordRecord],
        remote: [String: SuppressedWordRecord]
    ) -> [String: SuppressedWordRecord] {
        var result = local

        for (key, remoteRecord) in remote {
            if let localRecord = result[key] {
                // Conflict: keep the one with newer timestamp
                // The newer timestamp wins, regardless of is_deleted state
                // This ensures that a deletion with newer timestamp takes precedence
                if remoteRecord.suppressedTimestamp > localRecord.suppressedTimestamp {
                    result[key] = remoteRecord
                }
            } else {
                // Only exists in remote: only add if NOT deleted
                // This prevents resurrecting entries that were deleted locally
                // and the local deletion record was purged
                if !remoteRecord.isDeleted {
                    result[key] = remoteRecord
                }
            }
        }

        return result
    }

    static func findChangedSuppressedWords(
        merged: [String: SuppressedWordRecord],
        original: [String: SuppressedWordRecord]
    ) -> [(String, SuppressedWordRecord)] {
        var changed: [(String, SuppressedWordRecord)] = []

        for (key, record) in merged {
            if let orig = original[key] {
                if record.suppressedTimestamp != orig.suppressedTimestamp ||
                   record.isDeleted != orig.isDeleted {
                    changed.append((key, record))
                }
            } else {
                changed.append((key, record))
            }
        }

        return changed
    }
}
