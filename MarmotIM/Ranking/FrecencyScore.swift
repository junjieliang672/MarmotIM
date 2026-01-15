import Foundation

/// Dual-Score Frecency Algorithm
///
/// This algorithm combines two components:
/// 1. **Recency Score**: Strong immediate boost that decays exponentially over time
///    - Guarantees recently selected words rank #1
///    - Formula: initialBoost × e^(-λ × timeSince)
///    - Half-life of 1 day means score drops by 50% every 24 hours
///
/// 2. **Frequency Score**: Permanent score that accumulates with each selection
///    - Never decays, so most-used words eventually dominate
///    - Formula: accessCount × frequencyMultiplier
///
/// Total Score = RecencyScore + FrequencyScore + BaseScore
///
/// Key Properties:
/// - Immediately after selection: ~1,000,000,000 points (guarantees #1)
/// - After 1 day: ~500,000,000 points (half-life)
/// - After 7 days: ~7,812,500 points (still significant)
/// - After 14 days: ~61,035 points (recency fading)
/// - 100 selections with no recency: 1,000,000 points (frequency dominates)
///
/// NOTE: Wubi 1-2级简码 have a protected tier (1T bonus) that cannot be overridden.
struct FrecencyScore {

    // MARK: - Configuration

    /// Recency decay half-life in seconds (1 day)
    /// After this time, recency score is halved
    static let recencyHalfLife: TimeInterval = 86400

    /// Initial recency boost immediately after selection
    /// This value is high enough to guarantee #1 ranking
    /// With half-life of 1 day, 2 seconds of time difference produces ~16K score difference,
    /// which exceeds the max short word bonus difference (10K)
    static let recencyInitialBoost: Double = 1_000_000_000

    /// Lambda for exponential decay: ln(2) / halfLife
    static var lambda: Double {
        log(2.0) / recencyHalfLife
    }

    // MARK: - Tier Override Boost (Short-term, 1 hour half-life)
    //
    // This is a separate boost that can override tier priority for non-jiǎnmǎ entries.
    // Use case: User repeatedly selects a pinyin word over a wubi word
    // The tier-override boost should push the pinyin word above wubi temporarily.
    // NOTE: This does NOT affect Wubi 1-2级简码 which have a protected tier (1T bonus).

    /// Tier override half-life in seconds (1 hour)
    /// This decays much faster than regular recency
    static let tierOverrideHalfLife: TimeInterval = 3600

    /// Lambda for tier override decay
    static var tierOverrideLambda: Double {
        log(2.0) / tierOverrideHalfLife
    }

    /// Initial tier override boost
    /// Must be large enough that a recent selection beats a less-recent selection
    /// even accounting for tier gaps. With 500B initial and 1hr half-life:
    /// - Just selected: 500B boost
    /// - 30 min ago: 354B boost (500B * 0.707)
    /// - Difference: 146B > 100B tier gap
    /// This ensures "last selection wins" within ~30 minutes (except for jiǎnmǎ)
    static let tierOverrideInitialBoost: Double = 500_000_000_000

    /// Permanent frequency multiplier per access
    /// This accumulates and never decays
    /// Value: 5,000,000 (5 Million)
    /// Effect:
    /// - 1 access: 5M points (vs 1000M recency)
    /// - 20 accesses: 100M points (10% of recency)
    /// - 200 accesses: 1000M points (Equals full recency boost)
    /// This ensures frequently used words (>200 times) become permanently sticky at the top,
    /// even after recency boost has fully decayed.
    static let frequencyMultiplier: Double = 5_000_000

    // MARK: - Score Calculation

    /// Calculate the total score for an entry
    ///
    /// - Parameters:
    ///   - accessCount: Total number of times this entry was selected
    ///   - lastAccessTimestamp: Unix timestamp of last access (0 if never accessed)
    ///   - baseFrequency: Base frequency from dictionary (0-65535)
    /// - Returns: Total score for ranking
    static func calculate(
        accessCount: UInt32,
        lastAccessTimestamp: UInt32,
        baseFrequency: UInt16
    ) -> Double {
        // 1. Recency score (decays exponentially)
        let recencyScore = calculateRecencyScore(lastAccessTimestamp: lastAccessTimestamp)

        // 2. Frequency score (permanent, never decays)
        let frequencyScore = calculateFrequencyScore(accessCount: accessCount)

        // 3. Base score (dictionary default)
        let baseScore = calculateBaseScore(baseFrequency: baseFrequency)

        return recencyScore + frequencyScore + baseScore
    }

    /// Calculate recency score only
    /// Uses exponential decay with configurable half-life
    ///
    /// - Parameter lastAccessTimestamp: Unix timestamp of last access (0 if never)
    /// - Returns: Recency score (0 if never accessed)
    static func calculateRecencyScore(lastAccessTimestamp: UInt32) -> Double {
        guard lastAccessTimestamp > 0 else { return 0 }

        let now = Date().timeIntervalSince1970
        let lastAccess = TimeInterval(lastAccessTimestamp)
        let timeSince = now - lastAccess

        // Handle edge cases
        guard timeSince >= 0 else {
            // Future timestamp (clock skew?) - treat as just now
            return recencyInitialBoost
        }

        // Exponential decay: initialBoost × e^(-λ × t)
        return recencyInitialBoost * exp(-lambda * timeSince)
    }

    /// Calculate tier override boost
    /// This is a separate high-value boost with 1-hour half-life
    /// It can override tier priority for recently selected entries
    ///
    /// - Parameter lastAccessTimestamp: Unix timestamp of last access (0 if never)
    /// - Returns: Tier override boost (0 if never accessed or decayed)
    static func calculateTierOverrideBoost(lastAccessTimestamp: UInt32) -> Double {
        guard lastAccessTimestamp > 0 else { return 0 }

        let now = Date().timeIntervalSince1970
        let lastAccess = TimeInterval(lastAccessTimestamp)
        let timeSince = now - lastAccess

        // Handle edge cases
        guard timeSince >= 0 else {
            return tierOverrideInitialBoost
        }

        // Exponential decay with 1-hour half-life
        let boost = tierOverrideInitialBoost * exp(-tierOverrideLambda * timeSince)

        // Cut off when boost is less than 1B (no longer meaningful)
        return boost > 1_000_000_000 ? boost : 0
    }

    /// Calculate frequency score only
    /// This score is permanent and accumulates with each selection
    ///
    /// - Parameter accessCount: Total number of selections
    /// - Returns: Frequency score
    static func calculateFrequencyScore(accessCount: UInt32) -> Double {
        return Double(accessCount) * frequencyMultiplier
    }

    /// Calculate base score from dictionary frequency
    ///
    /// - Parameter baseFrequency: Base frequency from dictionary (0-65535)
    /// - Returns: Base score
    static func calculateBaseScore(baseFrequency: UInt16) -> Double {
        return Double(baseFrequency)
    }

    // MARK: - Utility Methods

    /// Get the recency score at a specific time offset from now
    /// Useful for understanding decay behavior
    ///
    /// - Parameter hoursAgo: Hours since last access
    /// - Returns: Recency score at that time
    static func recencyScoreAfterHours(_ hoursAgo: Double) -> Double {
        let timeSince = hoursAgo * 3600
        return recencyInitialBoost * exp(-lambda * timeSince)
    }

    /// Estimate how long until recency score falls below a threshold
    ///
    /// - Parameter threshold: Score threshold
    /// - Returns: Time in seconds, or nil if already below threshold
    static func timeUntilRecencyBelowThreshold(_ threshold: Double) -> TimeInterval? {
        guard threshold < recencyInitialBoost else { return 0 }
        guard threshold > 0 else { return nil }

        // Solve: threshold = initialBoost × e^(-λ × t)
        // t = -ln(threshold / initialBoost) / λ
        return -log(threshold / recencyInitialBoost) / lambda
    }

    /// Check if an entry would rank #1 based on recency alone
    /// (i.e., recency score exceeds typical base frequency range)
    ///
    /// - Parameter lastAccessTimestamp: Unix timestamp of last access
    /// - Returns: True if entry would likely rank #1
    static func wouldRankFirst(lastAccessTimestamp: UInt32) -> Bool {
        let recencyScore = calculateRecencyScore(lastAccessTimestamp: lastAccessTimestamp)
        // Compare against max possible base score (65535) plus some buffer
        return recencyScore > 100_000
    }
}

// MARK: - User Entry Data

/// User learning data for a single entry
/// Stored in the unified database and cached in memory
struct UserEntryData: Codable {
    /// Entry ID
    let entryId: UInt32

    /// Number of times this entry was selected (permanent counter)
    var accessCount: UInt32

    /// Last access timestamp (Unix epoch seconds)
    var lastAccessTimestamp: UInt32

    /// Cached total score (for quick sorting)
    var cachedScore: Float

    /// Convert timestamp to Date
    var lastAccess: Date {
        return Date(timeIntervalSince1970: TimeInterval(lastAccessTimestamp))
    }

    /// Initialize with zero values
    init(entryId: UInt32) {
        self.entryId = entryId
        self.accessCount = 0
        self.lastAccessTimestamp = 0
        self.cachedScore = 0
    }

    /// Initialize with all values
    init(
        entryId: UInt32,
        accessCount: UInt32,
        lastAccessTimestamp: UInt32,
        cachedScore: Float
    ) {
        self.entryId = entryId
        self.accessCount = accessCount
        self.lastAccessTimestamp = lastAccessTimestamp
        self.cachedScore = cachedScore
    }

    /// Record a selection - increments counter and updates timestamp
    mutating func recordAccess() {
        accessCount += 1
        lastAccessTimestamp = UInt32(Date().timeIntervalSince1970)
    }

    /// Recalculate cached score
    mutating func updateCachedScore(baseFrequency: UInt16) {
        cachedScore = Float(FrecencyScore.calculate(
            accessCount: accessCount,
            lastAccessTimestamp: lastAccessTimestamp,
            baseFrequency: baseFrequency
        ))
    }
}

// MARK: - Debug Helpers

#if DEBUG
extension FrecencyScore {
    /// Print decay curve for debugging
    static func printDecayCurve() {
        let points: [(String, Double)] = [
            ("0 hours", 0),
            ("6 hours", 6),
            ("12 hours", 12),
            ("1 day", 24),
            ("2 days", 48),
            ("3 days", 72),
            ("7 days", 168),
            ("14 days", 336),
        ]

        NSLog("FrecencyScore Decay Curve (halfLife=%.0f sec = 1 day):", recencyHalfLife)
        for (label, hours) in points {
            let score = recencyScoreAfterHours(hours)
            NSLog("  %@: %.0f (%.2f%%)", label, score, score / recencyInitialBoost * 100)
        }
    }

    /// Example score comparison
    static func printScoreComparison() {
        NSLog("FrecencyScore Example Comparisons:")

        // Just selected
        let justSelected = calculate(accessCount: 1, lastAccessTimestamp: UInt32(Date().timeIntervalSince1970), baseFrequency: 50000)
        NSLog("  Just selected (1 access, base 50k): %.0f", justSelected)

        // Selected 1 hour ago
        let oneHourAgo = calculate(accessCount: 1, lastAccessTimestamp: UInt32(Date().timeIntervalSince1970 - 3600), baseFrequency: 50000)
        NSLog("  1 hour ago (1 access, base 50k): %.0f", oneHourAgo)

        // Frequent word, not recent
        let frequent = calculate(accessCount: 100, lastAccessTimestamp: UInt32(Date().timeIntervalSince1970 - 86400), baseFrequency: 50000)
        NSLog("  Frequent (100 accesses, 24h ago, base 50k): %.0f", frequent)

        // Default only
        let defaultOnly = calculate(accessCount: 0, lastAccessTimestamp: 0, baseFrequency: 65000)
        NSLog("  Default only (0 accesses, base 65k): %.0f", defaultOnly)
    }
}
#endif
