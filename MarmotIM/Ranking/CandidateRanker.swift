import Foundation

/// Ranks candidates using tier-based Frecency algorithm
///
/// ## Tier Structure
///
/// ### Protected Tier (CANNOT be overridden by tierOverrideBoost):
/// - Tier 0: Wubi 1-2级简码 (+1T) - Full Wubi match with code length 1-2
///   These ALWAYS rank first, regardless of user selection history.
///
/// ### Regular Tiers (CAN be overridden by tierOverrideBoost):
/// When input length <= 4 (Wubi-priority mode):
/// - Tier 1: Full Wubi match (+100B) - 3-4 character codes
/// - Tier 2: Full Pinyin match (+10B)
/// - Tier 3: Prefix Wubi match (+1B)
/// - Tier 4: Prefix Pinyin match (0)
///
/// When input length > 4 (Pinyin-priority mode):
/// - Tier 1: Full match (+100B)
/// - Tier 2: Prefix match (0)
///
/// ## Within-Tier Ranking (Frecency)
///
/// 1. **Tier Override Boost**: Short-term boost that can cross regular tiers
///    - Initial: 500B, Half-life: 1 hour
///    - Allows user preferences to override tier priority (except jiǎnmǎ)
///
/// 2. **Recency Score**: Exponentially decaying boost
///    - Immediately after selection: ~1,000,000,000 (guarantees #1 in tier)
///    - Half-life: 1 day
///
/// 3. **Frequency Score**: Permanent accumulating score
///    - 10,000 points per selection
///
/// 4. **Base Score**: Dictionary frequency (0-65535)
///
/// 5. **Short Word Bonus**: Prefer shorter words
///
/// Total = TierBonus + TierOverrideBoost + Recency + Frequency + Base + ShortWordBonus
struct CandidateRanker {

    // MARK: - Tier Bonus Constants

    /// Tier 0: Wubi 1-2级简码 (Protected tier - CANNOT be overridden)
    /// This is set to 1T (1,000,000,000,000) which is higher than:
    /// - tier1Bonus (100B) + tierOverrideBoost (500B) = 600B
    /// So jiǎnmǎ will ALWAYS rank first regardless of user history.
    static let jianmaTierBonus: Double = 1_000_000_000_000

    /// Tier 1: Full Wubi (short) or Full (long) - highest regular priority
    static let tier1Bonus: Double = 100_000_000_000

    /// Tier 2: Full Pinyin (short only)
    static let tier2Bonus: Double = 10_000_000_000

    /// Tier 3: Prefix Wubi (short only)
    static let tier3Bonus: Double = 1_000_000_000

    // Tier 4 is 0 (baseline)

    /// Short word bonus per character under 5
    static let shortWordBonusPerChar: Double = 10_000

    // MARK: - Main Ranking

    /// Rank matches and return sorted candidates
    ///
    /// - Parameters:
    ///   - matches: Dictionary matches to rank
    ///   - inputCode: The input code used for matching
    ///   - engine: Dictionary engine for user learning data
    /// - Returns: Ranked and sorted candidates
    static func rank(
        matches: [DictionaryMatch],
        inputCode: String,
        engine: DictionaryEngine
    ) -> [Candidate] {
        let inputLength = inputCode.count

        // STEP 1: Deduplicate by text, preferring entries with user data
        // This fixes the bug where duplicate entries for the same word have different IDs
        var textToMatch: [String: (match: DictionaryMatch, userData: UserEntryData?)] = [:]

        for match in matches {
            let text = match.entry.text
            let userData = engine.getUserLearning(entryId: match.entry.id)

            if let existing = textToMatch[text] {
                // Prefer entry with userData, or higher tier, or existing entry
                let existingHasUserData = existing.userData != nil
                let newHasUserData = userData != nil

                if newHasUserData && !existingHasUserData {
                    // New entry has userData, existing doesn't - prefer new
                    textToMatch[text] = (match, userData)
                } else if !newHasUserData && existingHasUserData {
                    // Existing has userData - keep existing
                } else {
                    // Both have or both lack userData - prefer higher tier match
                    let existingTier = getTierBonus(match: existing.match, inputLength: inputLength)
                    let newTier = getTierBonus(match: match, inputLength: inputLength)
                    if newTier > existingTier {
                        textToMatch[text] = (match, userData)
                    }
                    // Otherwise keep existing
                }
            } else {
                textToMatch[text] = (match, userData)
            }
        }

        // STEP 2: Calculate scores for deduplicated matches
        var candidates: [Candidate] = []

        for (_, (match, userData)) in textToMatch {
            // Calculate score using tier-based Frecency
            let score = calculateScore(
                match: match,
                userData: userData,
                inputLength: inputLength
            )

            var candidate = Candidate(from: match, score: score)
            candidate.score = score
            candidates.append(candidate)
        }

        // Sort by score descending
        candidates.sort { $0.score > $1.score }

        return candidates
    }

    // MARK: - Tier Calculation

    /// Determine tier bonus based on match type, code type, and input length
    ///
    /// - Parameters:
    ///   - match: The dictionary match
    ///   - inputLength: Length of the input code
    /// - Returns: Tier bonus value
    static func getTierBonus(
        match: DictionaryMatch,
        inputLength: Int
    ) -> Double {
        let isFullMatch = match.matchType == .full
        let isWubiCode = match.codeType == .wubi

        // Check for Wubi 1-2级简码 (protected tier)
        // These are Full Wubi matches where the user input is 1-2 characters
        if isFullMatch && isWubiCode && inputLength <= 2 {
            return jianmaTierBonus  // Protected tier - cannot be overridden
        }

        if inputLength <= 4 {
            // Short code mode: Wubi priority
            switch (isFullMatch, isWubiCode) {
            case (true, true):   return tier1Bonus  // Full Wubi (3-4 chars)
            case (true, false):  return tier2Bonus  // Full Pinyin
            case (false, true):  return tier3Bonus  // Prefix Wubi
            case (false, false): return 0           // Prefix Pinyin
            }
        } else {
            // Long code mode: Full match priority only
            return isFullMatch ? tier1Bonus : 0
        }
    }

    // MARK: - Score Calculation

    /// Calculate score for a single match
    private static func calculateScore(
        match: DictionaryMatch,
        userData: UserEntryData?,
        inputLength: Int
    ) -> Double {
        // 1. Tier bonus (absolute, determines tier)
        let tierBonus = getTierBonus(match: match, inputLength: inputLength)

        // 2. Core Frecency score (recency + frequency + base)
        let accessCount = userData?.accessCount ?? 0
        let timestamp = userData?.lastAccessTimestamp ?? 0
        let recencyScore = FrecencyScore.calculateRecencyScore(lastAccessTimestamp: timestamp)
        let frequencyScore = FrecencyScore.calculateFrequencyScore(accessCount: accessCount)
        // Use mode-specific base frequency based on how this match was found
        let baseFrequency = match.entry.baseFrequency(for: match.codeType)
        let baseScore = FrecencyScore.calculateBaseScore(baseFrequency: baseFrequency)

        // 3. Tier override boost (short-term, can override tier priority)
        // This allows recently selected entries to temporarily rank above higher-tier entries
        let tierOverrideBoost = FrecencyScore.calculateTierOverrideBoost(lastAccessTimestamp: timestamp)

        // 4. Short word bonus (prefer shorter words within tier)
        var shortWordBonus: Double = 0
        let textLength = match.entry.textLength
        if textLength < 5 {
            shortWordBonus = Double(5 - textLength) * shortWordBonusPerChar
        }

        let totalScore = tierBonus + tierOverrideBoost + recencyScore + frequencyScore + baseScore + shortWordBonus

        // Debug logging for top candidates
        if accessCount > 0 {
            NSLog("MarmotIM: Score for '%@' (id=%u): tier=%.0fB, override=%.0fB, recency=%.0f, freq=%.0f, base=%.0f, short=%.0f, TOTAL=%.0f (accessCount=%u, ts=%u)",
                  match.entry.text, match.entry.id,
                  tierBonus / 1_000_000_000, tierOverrideBoost / 1_000_000_000,
                  recencyScore, frequencyScore, baseScore, shortWordBonus, totalScore,
                  accessCount, timestamp)
        }

        return totalScore
    }

    // MARK: - Legacy Support

    /// Rank matches using UserDataStore (legacy method)
    /// This method is kept for backward compatibility
    static func rank(
        matches: [DictionaryMatch],
        inputCode: String,
        userDataStore: UserDataStore?
    ) -> [Candidate] {
        let inputLength = inputCode.count
        var candidates: [Candidate] = []

        for match in matches {
            // Get user data from legacy store
            let legacyData = userDataStore?.getData(for: match.entry.id)

            // Convert to new format
            let userData: UserEntryData?
            if let data = legacyData {
                userData = UserEntryData(
                    entryId: data.entryId,
                    accessCount: data.accessCount,
                    lastAccessTimestamp: data.lastAccessTimestamp,
                    cachedScore: data.cachedScore
                )
            } else {
                userData = nil
            }

            let score = calculateScore(match: match, userData: userData, inputLength: inputLength)

            var candidate = Candidate(from: match, score: score)
            candidate.score = score
            candidates.append(candidate)
        }

        candidates.sort { $0.score > $1.score }
        return candidates
    }

    // MARK: - Re-ranking

    /// Re-rank candidates after user interaction (e.g., manual boost)
    /// - Parameters:
    ///   - candidates: Current candidate list
    ///   - boostIndex: Index of candidate to boost
    static func boost(candidates: inout [Candidate], at boostIndex: Int) {
        guard boostIndex > 0 && boostIndex < candidates.count else { return }

        // Move the boosted candidate to the top
        let boosted = candidates.remove(at: boostIndex)
        candidates.insert(boosted, at: 0)
    }
}

// MARK: - Debug Helpers

#if DEBUG
extension CandidateRanker {
    /// Print score breakdown for debugging
    static func printScoreBreakdown(
        match: DictionaryMatch,
        userData: UserEntryData?,
        inputLength: Int = 4
    ) {
        let tierBonus = getTierBonus(match: match, inputLength: inputLength)
        let recency = FrecencyScore.calculateRecencyScore(
            lastAccessTimestamp: userData?.lastAccessTimestamp ?? 0
        )
        let frequency = FrecencyScore.calculateFrequencyScore(
            accessCount: userData?.accessCount ?? 0
        )
        let base = FrecencyScore.calculateBaseScore(
            baseFrequency: match.entry.baseFrequency(for: match.codeType)
        )

        var shortWordBonus: Double = 0
        if match.entry.textLength < 5 {
            shortWordBonus = Double(5 - match.entry.textLength) * shortWordBonusPerChar
        }

        let total = tierBonus + recency + frequency + base + shortWordBonus

        let tierName: String
        if inputLength <= 4 {
            switch (match.matchType == .full, match.codeType == .wubi) {
            case (true, true): tierName = "Tier 1 (Full Wubi)"
            case (true, false): tierName = "Tier 2 (Full Pinyin)"
            case (false, true): tierName = "Tier 3 (Prefix Wubi)"
            case (false, false): tierName = "Tier 4 (Prefix Pinyin)"
            }
        } else {
            tierName = match.matchType == .full ? "Tier 1 (Full)" : "Tier 2 (Prefix)"
        }

        NSLog("Score breakdown for '\(match.entry.text)' [\(tierName)]:")
        NSLog("  Tier:      %.0f", tierBonus)
        NSLog("  Recency:   %.0f", recency)
        NSLog("  Frequency: %.0f (count: \(userData?.accessCount ?? 0))", frequency)
        NSLog("  Base:      %.0f", base)
        NSLog("  ShortWord: %.0f", shortWordBonus)
        NSLog("  Total:     %.0f", total)
    }
}
#endif
